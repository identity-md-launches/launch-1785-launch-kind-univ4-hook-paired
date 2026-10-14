// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Protocol, ILaunchFactory, IIntake, IMediciHook} from "./Protocol.sol";

/// @notice Immutable burn voting, commissioning, backer distribution and buyback rules.
contract MediciTreasury is ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint64 public constant WEEK = 7 days;
    uint64 public constant LAUNCH_WINDOW = 14 days;
    uint256 public constant MIN_BURN = 1_000 ether;
    uint256 public constant MAX_BURN = 50_000_000 ether;
    uint256 public constant INTAKE_PRICE = 0.5 ether;
    uint256 public constant BUYBACK_SLIPPAGE_BPS = 500;
    IPoolManager public immutable poolManager;
    address public immutable token;
    IMediciHook public immutable hook;
    address public team = Protocol.TEAM;
    address public keeper = Protocol.KEEPER;
    uint256 public totalBurned;
    uint256 public totalBuybackBurned;
    uint256 public escrowed;
    uint256 public buybackReserved;
    uint256 public buybackSpent;
    bool private swapping;

    struct Proposal {
        address proposer;
        uint64 blockNumber;
        bytes32 briefHash;
        uint256 burned;
        string title;
        string flag;
    }

    struct Epoch {
        uint8 status;
        bool promoted;
        bool commissioned;
        uint64 winnerSetAt;
        uint64 deadline;
        uint64 launchNumber;
        uint256 winner;
        uint256 runner;
        uint256 bounty;
        uint256 valuation;
        bytes32 liveRequest;
        bytes32 lastRequest;
        bytes32 resultHash;
        string uri;
        string jobId;
    }

    struct Share {
        address token;
        uint64 claimUntil;
        bool swept;
        uint256 amount;
        uint256 claimed;
    }

    struct Stream {
        uint64 start;
        uint256 cumulative;
        uint256 weighted;
    }
    mapping(uint256 => Epoch) private epochs;
    mapping(uint256 => mapping(uint256 => Proposal)) private proposals;
    mapping(uint256 => uint256) public proposalCount;
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) public votesOf;
    mapping(uint256 => mapping(address => bool)) public backerClaimed;
    mapping(uint256 => Share) private shares;
    mapping(address => uint256) public reservedToken;
    mapping(bytes32 => uint256) private requestEpoch;
    mapping(uint64 => address) public launchFactory;
    mapping(uint64 => address) public launchToken;
    mapping(uint256 => uint256) public income;
    mapping(uint256 => uint256) public keeperSpent;
    mapping(uint256 => uint64) public extension;
    Stream[] private streams;

    error Unauthorized();
    error InvalidInput();
    error WrongState();
    error TooEarly();
    error InsufficientFreeETH();
    error Slippage();
    error UnknownRequest();
    error TransferFailed();
    event Proposed(uint256 indexed epoch, uint256 indexed id, address indexed proposer, string title, bytes brief);
    event Voted(uint256 indexed epoch, uint256 indexed id, address indexed voter, uint256 amount);
    event Extended(uint256 indexed epoch, uint64 end);
    event Flagged(uint256 indexed epoch, uint256 indexed id, string note);
    event Settled(uint256 indexed epoch, uint8 status, uint256 winner, uint256 runner, uint256 bounty);
    event Commissioned(uint256 indexed epoch, bytes32 indexed requestId);
    event Result(uint256 indexed epoch, bytes32 indexed requestId, bytes32 resultHash, string uri);
    event Failure(uint256 indexed epoch, bytes32 indexed requestId, uint8 status, bytes32 reason);
    event Promoted(uint256 indexed epoch, uint8 status, uint256 winner, uint256 bounty);
    event Lapsed(uint256 indexed epoch);
    event Skipped(uint256 indexed epoch, string reason);
    event Recorded(uint256 indexed epoch, uint64 indexed launchNumber, string jobId);
    event BountyPaid(uint256 indexed epoch, address indexed proposer, uint256 amount, bool success);
    event BackerClaimed(uint256 indexed epoch, address indexed voter, uint256 amount);
    event UnclaimedBurned(uint256 indexed epoch, uint256 amount);
    event Buyback(address indexed caller, uint256 ethSpent, uint256 tip, uint256 burned);
    event KeeperWithdrawn(uint256 indexed epoch, uint256 amount);
    event Harvested(uint64 indexed launchNumber, uint256 burned);
    event TeamChanged(address indexed previous, address indexed next);
    event KeeperChanged(address indexed previous, address indexed next);
    event Burned(uint256 amount);
    event Income(uint256 indexed epoch, uint256 amount);

    constructor(IPoolManager manager_, address token_, IMediciHook hook_) {
        if (address(manager_) == address(0) || token_ == address(0) || address(hook_) == address(0)) {
            revert InvalidInput();
        }
        poolManager = manager_;
        token = token_;
        hook = hook_;
    }
    modifier onlyKeeper() {
        if (msg.sender != keeper) revert Unauthorized();
        _;
    }

    function setTeam(address next) external {
        if (msg.sender != team) revert Unauthorized();
        if (next == address(0)) revert InvalidInput();
        emit TeamChanged(team, next);
        team = next;
    }

    function setKeeper(address next) external {
        if (msg.sender != keeper) revert Unauthorized();
        if (next == address(0)) revert InvalidInput();
        emit KeeperChanged(keeper, next);
        keeper = next;
    }

    function price() public view returns (uint256) {
        return hook.price();
    }

    /// @dev Nominal weeks stay anchored to pool open. An extension delays the next
    /// epoch's active start, without moving any later week's original deadline.
    function proposeDeadline(uint256 e) public view returns (uint64) {
        uint64 opened = hook.openedAt();
        if (e == 0 || opened == 0) revert WrongState();
        uint256 end = uint256(opened) + e * WEEK;
        if (end > type(uint64).max) revert InvalidInput();
        return uint64(end);
    }

    function epochEnd(uint256 e) public view returns (uint64) {
        return proposeDeadline(e) + extension[e];
    }

    function _start(uint256 e) internal view returns (uint64) {
        if (e == 0) revert WrongState();
        return e == 1 ? hook.openedAt() : epochEnd(e - 1);
    }

    function currentEpoch() public view returns (uint256 e) {
        uint64 opened = hook.openedAt();
        if (opened == 0) return 0;
        e = 1 + (block.timestamp - opened) / WEEK;
        if (e > 1 && block.timestamp < uint256(opened) + (e - 1) * WEEK + extension[e - 1]) --e;
    }

    function proposeCost() public view returns (uint256 cost) {
        uint256 e = currentEpoch();
        if (e == 0) revert WrongState();
        uint256 eth = 0.002 ether;
        uint256 count = proposalCount[e];
        for (uint256 i; i < count; ++i) {
            eth = eth * 115 / 100;
        }
        cost = FullMath.mulDiv(eth, 1 ether, price());
        if (cost < MIN_BURN) cost = MIN_BURN;
        if (cost > MAX_BURN) cost = MAX_BURN;
    }

    function propose(string calldata title, bytes calldata brief) external nonReentrant returns (uint256 id) {
        uint256 e = currentEpoch();
        if (e == 0 || block.timestamp >= proposeDeadline(e) || proposalCount[e] >= 20) revert WrongState();
        if (bytes(title).length == 0 || bytes(title).length > 80 || brief.length == 0 || brief.length > 12_000) {
            revert InvalidInput();
        }
        uint256 cost = proposeCost();
        id = ++proposalCount[e];
        Proposal storage p = proposals[e][id];
        p.proposer = msg.sender;
        p.title = title;
        p.briefHash = keccak256(brief);
        p.blockNumber = uint64(block.number);
        _vote(e, id, cost);
        emit Proposed(e, id, msg.sender, title, brief);
    }

    function vote(uint256 e, uint256 id, uint256 amount) external nonReentrant {
        if (e == 0 || e != currentEpoch() || amount == 0) revert InvalidInput();
        _proposal(e, id);
        _vote(e, id, amount);
    }

    function _vote(uint256 e, uint256 id, uint256 amount) internal {
        proposals[e][id].burned += amount;
        votesOf[e][id][msg.sender] += amount;
        totalBurned += amount;
        uint64 end = epochEnd(e);
        if (block.timestamp >= end - 1 hours) {
            uint64 next = uint64(block.timestamp + 10 minutes);
            uint64 cap = proposeDeadline(e) + 1 days;
            if (next > cap) next = cap;
            if (next > end) {
                extension[e] = next - proposeDeadline(e);
                emit Extended(e, next);
            }
        }
        IERC20(token).safeTransferFrom(msg.sender, Protocol.DEAD, amount);
        emit Voted(e, id, msg.sender, amount);
    }

    function _proposal(uint256 e, uint256 id) internal view {
        if (id == 0 || id > proposalCount[e]) revert InvalidInput();
    }

    function flag(uint256 e, uint256 id, string calldata note) external onlyKeeper {
        _proposal(e, id);
        if (bytes(note).length > 120) revert InvalidInput();
        proposals[e][id].flag = note;
        emit Flagged(e, id, note);
    }

    function proposalOf(uint256 e, uint256 id)
        external
        view
        returns (
            address proposer,
            string memory title,
            bytes32 briefHash,
            uint64 blockNumber,
            uint256 burned,
            string memory flag
        )
    {
        Proposal storage p = proposals[e][id];
        return (p.proposer, p.title, p.briefHash, p.blockNumber, p.burned, p.flag);
    }

    function epochResult(uint256 e)
        external
        view
        returns (
            uint8 status,
            uint256 winnerId,
            uint256 runnerUpId,
            uint256 bounty,
            uint64 launchNumber,
            uint64 deadline,
            string memory jobId
        )
    {
        Epoch storage x = epochs[e];
        return (x.status, x.winner, x.runner, x.bounty, x.launchNumber, x.deadline, x.jobId);
    }

    function requestOf(uint256 e) external view returns (bytes32 requestId, uint64 openToAllAt) {
        Epoch storage x = epochs[e];
        return (x.liveRequest, x.winnerSetAt == 0 ? 0 : x.winnerSetAt + 1 days);
    }

    function resultOf(uint256 e) external view returns (bytes32 requestId, bytes32 resultHash, string memory uri) {
        Epoch storage x = epochs[e];
        return (x.lastRequest, x.resultHash, x.uri);
    }

    function backerShare(uint256 e)
        external
        view
        returns (address token, uint256 amount, uint256 claimed, uint64 claimUntil)
    {
        Share storage s = shares[e];
        return (s.token, s.amount, s.claimed, s.claimUntil);
    }

    function freeETH() public view returns (uint256) {
        uint256 liabilities = escrowed + buybackReserved;
        return address(this).balance > liabilities ? address(this).balance - liabilities : 0;
    }

    function settle(uint256 e) external nonReentrant {
        Epoch storage x = epochs[e];
        if (e == 0 || x.status != 0 || block.timestamp < epochEnd(e)) revert WrongState();
        uint256 best;
        uint256 second;
        for (uint256 i = 1; i <= proposalCount[e]; ++i) {
            if (best == 0 || proposals[e][i].burned > proposals[e][best].burned) {
                second = best;
                best = i;
            } else if (second == 0 || proposals[e][i].burned > proposals[e][second].burned) {
                second = i;
            }
        }
        x.runner = second;
        x.valuation = hook.twap(_start(e), epochEnd(e));
        _select(e, best);
        _stream(income[e] * 40 / 100);
        emit Settled(e, x.status, x.winner, x.runner, x.bounty);
    }

    function _select(uint256 e, uint256 winner) internal {
        Epoch storage x = epochs[e];
        uint256 value = FullMath.mulDiv(proposals[e][winner].burned, x.valuation, 1 ether);
        if (winner == 0 || value < 0.01 ether) {
            x.status = 4;
            x.winner = 0;
            x.deadline = 0;
            return;
        }
        x.status = 1;
        x.winner = winner;
        x.winnerSetAt = uint64(block.timestamp);
        x.deadline = uint64(block.timestamp + LAUNCH_WINDOW);
        uint256 bounty = freeETH() / 10;
        if (bounty > 1 ether) bounty = 1 ether;
        if (bounty > value / 2) bounty = value / 2;
        x.bounty = bounty;
        escrowed += bounty;
    }

    function _clearRequest(Epoch storage x) internal {
        if (x.liveRequest != bytes32(0)) {
            delete requestEpoch[x.liveRequest];
            x.liveRequest = bytes32(0);
        }
    }

    function _promote(uint256 e) internal {
        Epoch storage x = epochs[e];
        _clearRequest(x);
        escrowed -= x.bounty;
        x.bounty = 0;
        x.commissioned = false;
        x.lastRequest = bytes32(0);
        x.resultHash = bytes32(0);
        delete x.uri;
        if (x.promoted || x.runner == 0) {
            x.status = 3;
            x.deadline = 0;
            emit Promoted(e, x.status, x.winner, 0);
            return;
        }
        x.promoted = true;
        uint256 next = x.runner;
        x.runner = 0;
        _select(e, next);
        emit Promoted(e, x.status, x.winner, x.bounty);
    }

    function commission(uint256 e, bytes calldata brief) external nonReentrant {
        Epoch storage x = epochs[e];
        if (x.status != 1 || x.commissioned || block.timestamp >= x.deadline) revert WrongState();
        if (msg.sender != keeper && block.timestamp < x.winnerSetAt + 1 days) revert Unauthorized();
        if (keccak256(brief) != proposals[e][x.winner].briefHash) revert InvalidInput();
        x.commissioned = true;
        if (IERC20(Protocol.IMD).balanceOf(address(this)) < INTAKE_PRICE) {
            uint256 ceiling = freeETH();
            if (ceiling > 0.03 ether) ceiling = 0.03 ether;
            if (ceiling == 0) revert InsufficientFreeETH();
            PoolKey memory key =
                PoolKey(Currency.wrap(address(0)), Currency.wrap(Protocol.IMD), 10_000, 200, IHooks(address(0)));
            _swap(key, int256(INTAKE_PRICE), ceiling, INTAKE_PRICE);
        }
        IERC20(Protocol.IMD).forceApprove(Protocol.INTAKE, INTAKE_PRICE);
        bytes32 id = IIntake(Protocol.INTAKE)
            .requestWithFailure(
                bytes32("launch.open@launch-1"),
                brief,
                IIntake.Callback(address(this), this.onResult.selector),
                this.onFailure.selector,
                Protocol.IMD,
                INTAKE_PRICE
            );
        if (id == bytes32(0) || requestEpoch[id] != 0) revert InvalidInput();
        IERC20(Protocol.IMD).forceApprove(Protocol.INTAKE, 0);
        x.liveRequest = id;
        x.lastRequest = id;
        requestEpoch[id] = e;
        emit Commissioned(e, id);
    }

    function _request(bytes32 id) internal view returns (uint256 e) {
        if (msg.sender != Protocol.INTAKE) revert Unauthorized();
        e = requestEpoch[id];
        if (e == 0 || epochs[e].liveRequest != id || epochs[e].status != 1) revert UnknownRequest();
    }

    function onResult(bytes32 id, bytes32 resultHash, string calldata uri) external {
        uint256 e = _request(id);
        Epoch storage x = epochs[e];
        _clearRequest(x);
        x.resultHash = resultHash;
        bytes calldata b = bytes(uri);
        x.uri = string(b[:b.length > 96 ? 96 : b.length]);
        emit Result(e, id, resultHash, x.uri);
    }

    function onFailure(bytes32 id, uint8 status, bytes32 reason, uint16, uint16, bytes calldata) external {
        uint256 e = _request(id);
        _promote(e);
        emit Failure(e, id, status, reason);
    }

    function lapse(uint256 e) external nonReentrant {
        Epoch storage x = epochs[e];
        if (x.status != 1 || block.timestamp < x.deadline) revert TooEarly();
        _promote(e);
        emit Lapsed(e);
    }

    function skip(uint256 e, string calldata reason) external onlyKeeper nonReentrant {
        Epoch storage x = epochs[e];
        if (x.status != 1 || x.commissioned) revert WrongState();
        _promote(e);
        emit Skipped(e, reason);
    }

    function _findLaunch(uint64 n) internal view returns (address factory, address asset) {
        (factory, asset) = _probeLaunch(Protocol.LAUNCH_FACTORY, n);
        if (factory == address(0)) (factory, asset) = _probeLaunch(Protocol.PROJECT_FACTORY, n);
        if (factory == address(0)) revert InvalidInput();
    }

    function _probeLaunch(address f, uint64 n) internal view returns (address, address) {
        try ILaunchFactory(f).positionOf(n) returns (PoolKey memory key, int24 lower, int24 upper, address requester) {
            if (requester != address(this) || lower >= upper) return (address(0), address(0));
            address a = Currency.unwrap(key.currency0);
            address b = Currency.unwrap(key.currency1);
            if ((a == address(0) || a == Protocol.IMD) && b != address(0) && b != Protocol.IMD) return (f, b);
            if ((b == address(0) || b == Protocol.IMD) && a != address(0) && a != Protocol.IMD) return (f, a);
        } catch {}
        return (address(0), address(0));
    }

    function recordCommission(uint256 e, uint64 n, string calldata jobId) external onlyKeeper nonReentrant {
        Epoch storage x = epochs[e];
        if (x.status != 1 || !x.commissioned || launchFactory[n] != address(0) || block.timestamp >= x.deadline) {
            revert WrongState();
        }
        if (bytes(jobId).length == 0) revert InvalidInput();
        (address f, address asset) = _findLaunch(n);
        if (asset == token) revert InvalidInput();
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 available = balance - reservedToken[asset];
        uint256 supply = IERC20(asset).totalSupply();
        if (supply == 0 || available < (supply + 19) / 20) revert InvalidInput();
        launchFactory[n] = f;
        launchToken[n] = asset;
        x.status = 2;
        x.launchNumber = n;
        x.jobId = jobId;
        _clearRequest(x);
        shares[e] = Share(asset, uint64(block.timestamp + 90 days), false, available, 0);
        reservedToken[asset] += available;
        _payBounty(e);
        emit Recorded(e, n, jobId);
    }

    function _payBounty(uint256 e) internal {
        Epoch storage x = epochs[e];
        uint256 amount = x.bounty;
        if (amount == 0) return;
        x.bounty = 0;
        escrowed -= amount;
        address proposer = proposals[e][x.winner].proposer;
        (bool ok,) = proposer.call{value: amount}("");
        if (!ok) {
            x.bounty = amount;
            escrowed += amount;
        }
        emit BountyPaid(e, proposer, amount, ok);
    }

    function claimBounty(uint256 e) external nonReentrant {
        if (epochs[e].status != 2) revert WrongState();
        _payBounty(e);
    }

    function claimable(uint256 e, address voter) public view returns (uint256) {
        Share storage s = shares[e];
        if (s.token == address(0) || backerClaimed[e][voter] || block.timestamp >= s.claimUntil) return 0;
        uint256 winner = epochs[e].winner;
        return FullMath.mulDiv(s.amount, votesOf[e][winner][voter], proposals[e][winner].burned);
    }

    function claimBacker(uint256 e) external nonReentrant {
        uint256 amount = claimable(e, msg.sender);
        if (amount == 0) revert WrongState();
        Share storage s = shares[e];
        backerClaimed[e][msg.sender] = true;
        s.claimed += amount;
        reservedToken[s.token] -= amount;
        IERC20(s.token).safeTransfer(msg.sender, amount);
        emit BackerClaimed(e, msg.sender, amount);
    }

    function burnUnclaimed(uint256 e) external nonReentrant {
        Share storage s = shares[e];
        if (s.token == address(0) || block.timestamp < s.claimUntil) revert TooEarly();
        if (s.swept) revert WrongState();
        uint256 amount = s.amount - s.claimed;
        s.swept = true;
        reservedToken[s.token] -= amount;
        if (amount != 0) IERC20(s.token).safeTransfer(Protocol.DEAD, amount);
        emit UnclaimedBurned(e, amount);
    }

    function _stream(uint256 amount) internal {
        if (amount == 0) return;
        uint256 n = streams.length;
        uint256 cumulative = amount;
        uint256 weighted = amount * block.timestamp;
        if (n != 0) {
            cumulative += streams[n - 1].cumulative;
            weighted += streams[n - 1].weighted;
        }
        streams.push(Stream(uint64(block.timestamp), cumulative, weighted));
    }

    function buybackChunk() public view returns (uint256 unlocked, uint256 tip) {
        uint256 n = streams.length;
        if (n == 0) return (0, 0);
        uint256 lo;
        uint256 hi = n;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (uint256(streams[mid].start) + 1 days <= block.timestamp) lo = mid + 1;
            else hi = mid;
        }
        uint256 complete;
        uint256 weightedComplete;
        if (lo != 0) {
            complete = streams[lo - 1].cumulative;
            weightedComplete = streams[lo - 1].weighted;
        }
        Stream storage last = streams[n - 1];
        uint256 vested =
            complete + ((last.cumulative - complete) * block.timestamp - (last.weighted - weightedComplete)) / 1 days;
        unlocked = vested - buybackSpent;
        tip = unlocked / 200;
    }

    function buyback(uint256 maxEth) external nonReentrant {
        (uint256 budget,) = buybackChunk();
        if (budget > maxEth) budget = maxEth;
        if (budget == 0) revert InvalidInput();
        uint256 tip = budget / 200;
        uint256 spend = budget - tip;
        uint256 minimum = FullMath.mulDiv(spend, 1 ether, price()) * (10_000 - BUYBACK_SLIPPAGE_BPS) / 10_000;
        if (minimum == 0) revert Slippage();
        (uint256 paid, uint256 bought) = _swap(hook.poolKey(), -int256(spend), spend, minimum);
        // Partial fills pay a tip only on the budget actually consumed.
        tip = FullMath.mulDiv(paid, tip, spend);
        buybackSpent += paid + tip;
        buybackReserved -= paid + tip;
        totalBuybackBurned += bought;
        totalBurned += bought;
        IERC20(token).safeTransfer(Protocol.DEAD, bought);
        if (tip != 0) {
            (bool ok,) = msg.sender.call{value: tip}("");
            if (!ok) revert TransferFailed();
        }
        emit Buyback(msg.sender, paid, tip, bought);
    }

    function _swap(PoolKey memory key, int256 specified, uint256 maxEth, uint256 minimum)
        internal
        returns (uint256 paid, uint256 bought)
    {
        swapping = true;
        (paid, bought) = abi.decode(poolManager.unlock(abi.encode(key, specified, maxEth, minimum)), (uint256, uint256));
        swapping = false;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !swapping) revert Unauthorized();
        (PoolKey memory key, int256 specified, uint256 maxEth, uint256 minimum) =
            abi.decode(data, (PoolKey, int256, uint256, uint256));
        BalanceDelta d = poolManager.swap(key, SwapParams(true, specified, TickMath.MIN_SQRT_PRICE + 1), "");
        if (d.amount0() >= 0 || d.amount1() <= 0) revert Slippage();
        uint256 paid = uint256(-int256(d.amount0()));
        uint256 bought = uint256(int256(d.amount1()));
        if (paid > maxEth || bought < minimum || (specified > 0 && bought != uint256(specified))) revert Slippage();
        poolManager.sync(key.currency0);
        poolManager.settle{value: paid}();
        poolManager.take(key.currency1, address(this), bought);
        return abi.encode(paid, bought);
    }

    function keeperWithdraw(uint256 amount) external onlyKeeper nonReentrant {
        uint256 e = currentEpoch();
        if (e == 0 || amount == 0 || keeperSpent[e] + amount > 0.01 ether) revert InvalidInput();
        if (amount > freeETH()) revert InsufficientFreeETH();
        keeperSpent[e] += amount;
        (bool ok,) = keeper.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit KeeperWithdrawn(e, amount);
    }

    function harvest(uint64 n) external nonReentrant {
        address f = launchFactory[n];
        if (f == address(0)) revert InvalidInput();
        ILaunchFactory factory = ILaunchFactory(f);
        (PoolKey memory key,,, address requester) = factory.positionOf(n);
        if (requester != address(this)) revert WrongState();
        factory.claimFees(n);
        factory.withdraw(address(this), key.currency0);
        factory.withdraw(address(this), key.currency1);
        address asset = launchToken[n];
        uint256 amount = IERC20(asset).balanceOf(address(this)) - reservedToken[asset];
        if (amount != 0) IERC20(asset).safeTransfer(Protocol.DEAD, amount);
        emit Harvested(n, amount);
    }

    function burnDeposited() external nonReentrant returns (uint256 amount) {
        amount = IERC20(token).balanceOf(address(this));
        if (amount != 0) {
            totalBurned += amount;
            IERC20(token).safeTransfer(Protocol.DEAD, amount);
        }
        emit Burned(amount);
    }

    receive() external payable {
        uint256 e = currentEpoch();
        if (e == 0) e = 1;
        uint256 beforeIncome = income[e];
        income[e] = beforeIncome + msg.value;
        buybackReserved += income[e] * 40 / 100 - beforeIncome * 40 / 100;
        emit Income(e, msg.value);
    }
}
