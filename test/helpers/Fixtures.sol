// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {MediciToken} from "../../src/MediciToken.sol";
import {MediciHook} from "../../src/MediciHook.sol";
import {MediciTreasury} from "../../src/MediciTreasury.sol";
import {MediciFeeRouter} from "../../src/MediciFeeRouter.sol";
import {Protocol, IIntake, IMediciHook} from "../../src/Protocol.sol";
import {HookFlags} from "../../src/HookFlags.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Launch asset", "ASSET") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PoolActor {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function modify(PoolKey memory k, int24 lower, int24 upper, int256 liquidity) external returns (BalanceDelta) {
        return abi.decode(
            manager.unlock(abi.encode(uint8(0), k, abi.encode(ModifyLiquidityParams(lower, upper, liquidity, 0)))),
            (BalanceDelta)
        );
    }

    function swap(PoolKey memory k, bool zeroForOne, int256 amount, uint160 limit) external returns (BalanceDelta) {
        return abi.decode(
            manager.unlock(abi.encode(uint8(1), k, abi.encode(SwapParams(zeroForOne, amount, limit)))), (BalanceDelta)
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (uint8 action, PoolKey memory k, bytes memory args) = abi.decode(data, (uint8, PoolKey, bytes));
        BalanceDelta d;
        if (action == 0) (d,) = manager.modifyLiquidity(k, abi.decode(args, (ModifyLiquidityParams)), "");
        else d = manager.swap(k, abi.decode(args, (SwapParams)), "");
        _settle(k.currency0, d.amount0());
        _settle(k.currency1, d.amount1());
        return abi.encode(d);
    }

    function _settle(Currency c, int128 d) internal {
        if (d < 0) {
            uint256 amount = uint256(-int256(d));
            manager.sync(c);
            if (c.isAddressZero()) {
                manager.settle{value: amount}();
            } else {
                require(IERC20(Currency.unwrap(c)).transfer(address(manager), amount));
                manager.settle();
            }
        } else if (d > 0) {
            manager.take(c, address(this), uint128(d));
        }
    }
    receive() external payable {}
}

contract MockFactory {
    struct Position {
        PoolKey key;
        int24 lower;
        int24 upper;
        address requester;
    }
    mapping(uint64 => Position) private positions;
    mapping(uint64 => uint256) public pending0;
    mapping(uint64 => uint256) public pending1;
    mapping(address => mapping(address => uint256)) public owed;
    uint256 public claims;
    uint256 public withdrawals;

    function register(uint64 n, PoolKey memory key, address requester) external {
        positions[n] = Position(key, -60, 60, requester);
    }

    function positionOf(uint64 n) external view returns (PoolKey memory, int24, int24, address) {
        Position storage p = positions[n];
        return (p.key, p.lower, p.upper, p.requester);
    }

    function setRequester(uint64 n, address next) external {
        require(msg.sender == positions[n].requester);
        positions[n].requester = next;
    }

    function seed(uint64 n, uint256 a0, uint256 a1) external {
        pending0[n] += a0;
        pending1[n] += a1;
    }

    function claimFees(uint64 n) external returns (uint256 a0, uint256 a1) {
        Position storage p = positions[n];
        require(p.requester != address(0));
        claims++;
        a0 = pending0[n];
        a1 = pending1[n];
        delete pending0[n];
        delete pending1[n];
        owed[p.requester][Currency.unwrap(p.key.currency0)] += a0;
        owed[p.requester][Currency.unwrap(p.key.currency1)] += a1;
    }

    function withdraw(address account, Currency c) external {
        withdrawals++;
        uint256 amount = owed[account][Currency.unwrap(c)];
        delete owed[account][Currency.unwrap(c)];
        if (c.isAddressZero()) {
            (bool ok,) = account.call{value: amount}("");
            require(ok);
        } else {
            require(IERC20(Currency.unwrap(c)).transfer(account, amount));
        }
    }
    receive() external payable {}
}

contract MockIntake is IIntake {
    uint256 public nonce;
    bytes32 public lastAction;
    bytes public lastBody;
    Callback public lastCallback;
    bytes4 public lastFailure;
    uint256 public allowanceSeen;
    bool public reject;

    function setReject(bool r) external {
        reject = r;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 failureSelector,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 id) {
        require(!reject, "intake rejected");
        require(asset == Protocol.IMD && amount == 0.5 ether && msg.value == 0);
        allowanceSeen = IERC20(asset).allowance(msg.sender, address(this));
        require(allowanceSeen == amount, "approval not exact");
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount));
        lastAction = action;
        lastBody = body;
        lastCallback = callback;
        lastFailure = failureSelector;
        id = keccak256(abi.encode(msg.sender, ++nonce));
    }

    function result(address target, bytes32 id, bytes32 hash, string calldata uri) external returns (bool success) {
        (success,) = target.call{gas: 200_000}(abi.encodeWithSelector(MediciTreasury.onResult.selector, id, hash, uri));
    }

    function failure(address target, bytes32 id) external returns (bool success) {
        (success,) = target.call{gas: 200_000}(
            abi.encodeWithSelector(
                MediciTreasury.onFailure.selector, id, uint8(2), bytes32("failed"), uint16(1), uint16(2), bytes("")
            )
        );
    }
}

contract MockHook is IMediciHook {
    uint64 public openedAt;
    uint256 public price = 1e10;

    constructor(uint64 at) {
        openedAt = at;
    }

    function setPrice(uint256 p) external {
        price = p;
    }

    function twap(uint64, uint64) external view returns (uint256) {
        return price;
    }

    function poolKey() external pure returns (PoolKey memory) {
        revert();
    }
}

abstract contract Fixture is Test {
    using StateLibrary for IPoolManager;
    PoolManager internal manager;
    MediciToken internal token;
    MediciHook internal hook;
    MediciTreasury internal treasury;
    MediciFeeRouter internal router;
    PoolKey internal key;
    PoolActor internal actor;
    MockIntake internal intake;
    MockFactory internal launchFactory;
    MockFactory internal projectFactory;
    MockToken internal imd;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    uint64 internal constant OPEN = 1_800_000_000;
    uint160 internal constant Q96 = 79228162514264337593543950336;

    function _protocolMocks() internal {
        MockFactory f = new MockFactory();
        vm.etch(Protocol.LAUNCH_FACTORY, address(f).code);
        vm.etch(Protocol.PROJECT_FACTORY, address(f).code);
        launchFactory = MockFactory(payable(Protocol.LAUNCH_FACTORY));
        projectFactory = MockFactory(payable(Protocol.PROJECT_FACTORY));
        MockIntake i = new MockIntake();
        vm.etch(Protocol.INTAKE, address(i).code);
        intake = MockIntake(Protocol.INTAKE);
        MockToken t = new MockToken();
        vm.etch(Protocol.IMD, address(t).code);
        imd = MockToken(Protocol.IMD);
    }

    function _deployReal(bool liquidity) internal {
        vm.warp(OPEN);
        vm.deal(address(this), 1_000 ether);
        manager = new PoolManager(address(this));
        token = new MediciToken();
        bytes memory code = abi.encodePacked(type(MediciHook).creationCode, abi.encode(manager, address(token)));
        bytes32 hash = keccak256(code);
        address at;
        for (uint256 i; i < 200_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
            if (!HookFlags.matches(predicted, HookFlags.MEDICI)) continue;
            assembly ("memory-safe") { at := create2(0, add(code, 32), mload(code), salt) }
            break;
        }
        require(at != address(0), "CREATE2 mining/deployment failed");
        hook = MediciHook(payable(at));
        treasury = hook.treasury();
        router = hook.feeRouter();
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12_500, 60, IHooks(at));
        manager.initialize(key, Q96 * 10_000);
        actor = new PoolActor(manager);
        vm.deal(address(actor), 100 ether);
        token.transfer(address(actor), 600_000_000 ether);
        if (liquidity) actor.modify(key, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1e22);
        token.transfer(alice, 100_000_000 ether);
        token.transfer(bob, 100_000_000 ether);
        vm.prank(alice);
        token.approve(address(treasury), type(uint256).max);
        vm.prank(bob);
        token.approve(address(treasury), type(uint256).max);
        _protocolMocks();
    }

    function _donate(uint256 amount) internal {
        (bool ok,) = address(treasury).call{value: amount}("");
        require(ok);
    }

    function _proposal(address user, bytes memory brief) internal returns (uint256 id) {
        vm.prank(user);
        id = treasury.propose("A commissioned launch", brief);
    }

    function _vote(address user, uint256 e, uint256 id, uint256 amount) internal {
        vm.prank(user);
        treasury.vote(e, id, amount);
    }

    function _twoWinners() internal {
        vm.warp(OPEN + 1 days);
        _proposal(alice, bytes("{\"idea\":\"one\"}"));
        _proposal(bob, bytes("{\"idea\":\"two\"}"));
        _vote(alice, 1, 1, 3_000_000 ether);
        _vote(bob, 1, 2, 2_000_000 ether);
        _donate(10 ether);
        vm.warp(treasury.epochEnd(1));
        treasury.settle(1);
    }

    function _commission() internal returns (bytes32 id) {
        imd.mint(address(treasury), 0.5 ether);
        vm.prank(Protocol.KEEPER);
        treasury.commission(1, bytes("{\"idea\":\"one\"}"));
        (id,) = treasury.requestOf(1);
    }

    function _record(uint64 n, MockToken launchAsset, bool project) internal {
        MockFactory f = project ? projectFactory : launchFactory;
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(launchAsset)), 12_500, 60, IHooks(address(0)));
        f.register(n, k, address(treasury));
        launchAsset.mint(address(this), 950 ether);
        launchAsset.mint(address(treasury), 50 ether);
        vm.prank(Protocol.KEEPER);
        treasury.recordCommission(1, n, "job-1");
    }
    receive() external payable {}
}
