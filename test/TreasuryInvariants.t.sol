// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture, MockToken, MockIntake, MockFactory, PoolActor} from "./helpers/Fixtures.sol";
import {MediciTreasury} from "../src/MediciTreasury.sol";
import {MediciHook} from "../src/MediciHook.sol";
import {MediciToken} from "../src/MediciToken.sol";
import {Protocol} from "../src/Protocol.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Drives the treasury, the hook's pool and the mocked protocol in random order with bounded
/// inputs. Every entry point guards its own preconditions, so a revert here is a real defect
/// (`fail_on_revert` is on), except where a call is explicitly allowed to fail and is wrapped.
contract TreasuryHandler is Test {
    MediciTreasury public immutable treasury;
    MediciHook public immutable hook;
    MediciToken public immutable token;
    PoolActor public immutable actor;
    MockIntake public immutable intake;
    MockFactory public immutable factory;
    PoolKey internal key;

    address[3] public actors;
    uint64 public nextLaunch = 100;
    uint256 public ghostIncome;
    uint256 public ghostTipsPaid;
    uint256 public ghostBountiesPaid;
    uint256 public ghostKeeperPaid;
    uint256 public ghostIMDSpent;
    uint256 public maxEpochTouched;
    mapping(uint256 => mapping(uint256 => bytes)) public briefs;
    mapping(uint256 => uint8) public finalStatus;
    mapping(uint256 => uint64) public finalLaunch;
    mapping(uint256 => address) public assetOf;
    mapping(uint256 => bool) public swept;
    address[] public assets;
    uint256[] public recordedEpochs;

    constructor(
        MediciTreasury treasury_,
        MediciHook hook_,
        MediciToken token_,
        PoolActor actor_,
        MockIntake intake_,
        MockFactory factory_,
        PoolKey memory key_,
        address[3] memory actors_
    ) {
        treasury = treasury_;
        hook = hook_;
        token = token_;
        actor = actor_;
        intake = intake_;
        factory = factory_;
        key = key_;
        actors = actors_;
    }

    function recordedCount() external view returns (uint256) {
        return recordedEpochs.length;
    }

    function assetCount() external view returns (uint256) {
        return assets.length;
    }

    function _actor(uint8 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function _touch(uint256 e) internal {
        if (e > maxEpochTouched) maxEpochTouched = e;
    }

    function _status(uint256 e) internal view returns (uint8 s) {
        (s,,,,,,) = treasury.epochResult(e);
    }

    function _snapshotFinal(uint256 e) internal {
        (uint8 s,,,, uint64 n,,) = treasury.epochResult(e);
        if (s >= 2 && finalStatus[e] == 0) {
            finalStatus[e] = s;
            finalLaunch[e] = n;
        }
    }

    // ---- governance ----

    function propose(uint8 who, uint32 briefSeed) external {
        uint256 e = treasury.currentEpoch();
        if (e == 0 || block.timestamp >= treasury.proposeDeadline(e) || treasury.proposalCount(e) >= 20) return;
        if (block.timestamp == hook.openedAt()) return;
        address a = _actor(who);
        uint256 cost = treasury.proposeCost();
        if (token.balanceOf(a) < cost) return;
        bytes memory brief = abi.encodePacked("{\"idea\":", vm.toString(uint256(briefSeed)), "}");
        vm.prank(a);
        uint256 id = treasury.propose("proposal", brief);
        briefs[e][id] = brief;
        _touch(e);
    }

    function vote(uint8 who, uint8 idSeed, uint96 raw) external {
        uint256 e = treasury.currentEpoch();
        if (e == 0) return;
        uint256 count = treasury.proposalCount(e);
        if (count == 0) return;
        address a = _actor(who);
        uint256 balance = token.balanceOf(a);
        if (balance == 0) return;
        uint256 amount = bound(raw, 1, balance < 2_000_000 ether ? balance : 2_000_000 ether);
        uint256 id = bound(idSeed, 1, count);
        vm.prank(a);
        treasury.vote(e, id, amount);
    }

    function donate(uint96 raw) external {
        uint256 amount = bound(raw, 1, 3 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(treasury).call{value: amount}("");
        require(ok, "donate failed");
        ghostIncome += amount;
        _touch(treasury.currentEpoch() == 0 ? 1 : treasury.currentEpoch());
    }

    function warp(uint32 raw) external {
        vm.warp(vm.getBlockTimestamp() + bound(raw, 1, 2 days));
        _touch(treasury.currentEpoch());
    }

    function settle(uint8 seed) external {
        uint256 current = treasury.currentEpoch();
        if (current == 0) return;
        uint256 e = bound(seed, 1, current);
        if (_status(e) != 0 || block.timestamp < treasury.epochEnd(e)) return;
        treasury.settle(e);
        _touch(e);
        _snapshotFinal(e);
    }

    function commission(uint8 seed, bool preloadIMD) external {
        if (maxEpochTouched == 0) return;
        uint256 e = bound(seed, 1, maxEpochTouched);
        (uint8 s, uint256 winner,,,, uint64 deadline,) = treasury.epochResult(e);
        if (s != 1 || block.timestamp >= deadline) return;
        (bytes32 live,) = treasury.requestOf(e);
        if (live != 0) return;
        bytes memory brief = briefs[e][winner];
        if (preloadIMD) MockToken(Protocol.IMD).mint(address(treasury), 0.5 ether);
        uint256 ethBefore = address(treasury).balance;
        vm.prank(Protocol.KEEPER);
        // Already commissioned once for this candidate, or the IMD purchase failed its price ceiling.
        try treasury.commission(e, brief) {
            ghostIMDSpent += ethBefore - address(treasury).balance;
        } catch {}
    }

    function deliverResult(uint8 seed) external {
        if (maxEpochTouched == 0) return;
        uint256 e = bound(seed, 1, maxEpochTouched);
        (bytes32 live,) = treasury.requestOf(e);
        if (live == 0) return;
        assertTrue(intake.result(address(treasury), live, keccak256(abi.encode(e)), "ipfs://result"));
    }

    function deliverFailure(uint8 seed) external {
        if (maxEpochTouched == 0) return;
        uint256 e = bound(seed, 1, maxEpochTouched);
        (bytes32 live,) = treasury.requestOf(e);
        if (live == 0) return;
        assertTrue(intake.failure(address(treasury), live));
        _snapshotFinal(e);
    }

    function lapse(uint8 seed) external {
        if (maxEpochTouched == 0) return;
        uint256 e = bound(seed, 1, maxEpochTouched);
        (uint8 s,,,,, uint64 deadline,) = treasury.epochResult(e);
        if (s != 1 || block.timestamp < deadline) return;
        treasury.lapse(e);
        _snapshotFinal(e);
    }

    function skip(uint8 seed) external {
        if (maxEpochTouched == 0) return;
        uint256 e = bound(seed, 1, maxEpochTouched);
        if (_status(e) != 1) return;
        vm.prank(Protocol.KEEPER);
        // Refused once a request was commissioned for the current candidate.
        try treasury.skip(e, "skipped") {} catch {}
        _snapshotFinal(e);
    }

    function record(uint8 seed, uint8 extraSeed) external {
        if (maxEpochTouched == 0) return;
        uint256 e = bound(seed, 1, maxEpochTouched);
        (uint8 s,,,,, uint64 deadline,) = treasury.epochResult(e);
        if (s != 1 || block.timestamp >= deadline) return;
        (bytes32 live,) = treasury.requestOf(e);
        // A commission must have happened for this candidate; the live id or a stored result shows it.
        (bytes32 last,,) = treasury.resultOf(e);
        if (live == 0 && last == 0) return;
        MockToken asset = new MockToken();
        uint64 n = nextLaunch++;
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(asset)), 12_500, 60, IHooks(address(0)));
        factory.register(n, k, address(treasury));
        asset.mint(address(this), 950 ether);
        asset.mint(address(treasury), 50 ether + bound(extraSeed, 0, 50) * 1 ether);
        (, uint256 winner,, uint256 bounty,,,) = treasury.epochResult(e);
        (address proposer,,,,,) = treasury.proposalOf(e, winner);
        uint256 before = proposer.balance;
        vm.prank(Protocol.KEEPER);
        treasury.recordCommission(e, n, "job");
        ghostBountiesPaid += proposer.balance - before;
        assertEq(proposer.balance - before, bounty, "bounty paid in full to the proposer");
        assetOf[e] = address(asset);
        assets.push(address(asset));
        recordedEpochs.push(e);
        _snapshotFinal(e);
    }

    function claimBacker(uint8 seed, uint8 who) external {
        if (recordedEpochs.length == 0) return;
        uint256 e = recordedEpochs[bound(seed, 0, recordedEpochs.length - 1)];
        address a = _actor(who);
        uint256 amount = treasury.claimable(e, a);
        if (amount == 0) return;
        uint256 before = MockToken(assetOf[e]).balanceOf(a);
        vm.prank(a);
        treasury.claimBacker(e);
        assertEq(MockToken(assetOf[e]).balanceOf(a) - before, amount, "claim pays exactly claimable");
        assertEq(treasury.claimable(e, a), 0, "a second claim is worth nothing");
    }

    function burnUnclaimed(uint8 seed) external {
        if (recordedEpochs.length == 0) return;
        uint256 e = recordedEpochs[bound(seed, 0, recordedEpochs.length - 1)];
        (,,, uint64 until) = treasury.backerShare(e);
        if (swept[e] || block.timestamp < until) return;
        treasury.burnUnclaimed(e);
        swept[e] = true;
    }

    function harvest(uint8 seed, uint96 raw) external {
        if (recordedEpochs.length == 0) return;
        uint256 e = recordedEpochs[bound(seed, 0, recordedEpochs.length - 1)];
        (,,,, uint64 n,,) = treasury.epochResult(e);
        uint256 fees = bound(raw, 0, 10 ether);
        MockToken(assetOf[e]).mint(address(factory), fees);
        factory.seed(n, 0, fees);
        treasury.harvest(n);
    }

    function keeperWithdraw(uint96 raw) external {
        uint256 e = treasury.currentEpoch();
        if (e == 0) return;
        uint256 spent = treasury.keeperSpent(e);
        if (spent >= 0.01 ether) return;
        uint256 amount = bound(raw, 1, 0.01 ether - spent);
        if (amount > treasury.freeETH()) return;
        uint256 before = Protocol.KEEPER.balance;
        vm.prank(Protocol.KEEPER);
        treasury.keeperWithdraw(amount);
        ghostKeeperPaid += Protocol.KEEPER.balance - before;
    }

    function claimBounty(uint8 seed) external {
        if (recordedEpochs.length == 0) return;
        uint256 e = recordedEpochs[bound(seed, 0, recordedEpochs.length - 1)];
        treasury.claimBounty(e);
    }

    // ---- market ----

    function trade(bool buy, bool exactIn, uint64 raw) external {
        uint256 amount = buy == exactIn ? bound(raw, 1e10, 0.05 ether) : bound(raw, 1 ether, 5_000_000 ether);
        // A fill may fail on the hook's own quote tolerance or on liquidity; that is the hook suite's
        // business, the treasury invariants must hold either way.
        try actor.swap(
            key,
            buy,
            exactIn ? -int256(amount) : int256(amount),
            buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        ) {}
            catch {}
    }

    function buyback(uint96 raw) external {
        (uint256 unlocked,) = treasury.buybackChunk();
        if (unlocked == 0) return;
        // The fixture pool holds about one virtual ETH; larger chunks hit the 5% TWAP bound by design.
        uint256 maxEth = bound(raw, 1, unlocked < 0.02 ether ? unlocked : 0.02 ether);
        uint256 before = address(this).balance;
        uint256 burnedBefore = treasury.totalBuybackBurned();
        // Slippage against the TWAP after trades moved the price is a legitimate refusal.
        try treasury.buyback(maxEth) {
            ghostTipsPaid += address(this).balance - before;
            assertGt(treasury.totalBuybackBurned(), burnedBefore, "a buyback burns something");
        } catch {}
    }

    function redeemHookFees() external {
        hook.redeemFees();
    }

    receive() external payable {}
}

/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 48
contract TreasuryInvariantTest is Fixture {
    TreasuryHandler internal handler;
    address internal carol = address(0xCA501);
    uint256 internal startEth;

    function setUp() public {
        _deployReal(true);
        // IMD pool at 100 IMD per ETH: 0.5 IMD costs well under the 0.03 ETH ceiling.
        PoolKey memory imdKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(Protocol.IMD), 10000, 200, IHooks(address(0)));
        manager.initialize(imdKey, Q96 * 10);
        imd.mint(address(actor), 10_000 ether);
        actor.modify(imdKey, TickMath.minUsableTick(200), TickMath.maxUsableTick(200), 10 ether);
        token.transfer(carol, 100_000_000 ether);
        vm.prank(carol);
        token.approve(address(treasury), type(uint256).max);
        vm.warp(OPEN + 1 days);
        handler = new TreasuryHandler(treasury, hook, token, actor, intake, launchFactory, key, [alice, bob, carol]);
        bytes4[] memory selectors = new bytes4[](19);
        selectors[0] = handler.propose.selector;
        selectors[1] = handler.vote.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.warp.selector;
        selectors[4] = handler.settle.selector;
        selectors[5] = handler.commission.selector;
        selectors[6] = handler.deliverResult.selector;
        selectors[7] = handler.deliverFailure.selector;
        selectors[8] = handler.lapse.selector;
        selectors[9] = handler.skip.selector;
        selectors[10] = handler.record.selector;
        selectors[11] = handler.claimBacker.selector;
        selectors[12] = handler.burnUnclaimed.selector;
        selectors[13] = handler.harvest.selector;
        selectors[14] = handler.keeperWithdraw.selector;
        selectors[15] = handler.claimBounty.selector;
        selectors[16] = handler.trade.selector;
        selectors[17] = handler.buyback.selector;
        selectors[18] = handler.redeemHookFees.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
        startEth = address(treasury).balance;
    }

    /// @dev The treasury always holds what it has promised: unpaid bounties plus the buyback reserve.
    function invariant_treasuryIsSolvent() public view {
        assertGe(address(treasury).balance, treasury.escrowed() + treasury.buybackReserved());
        assertEq(treasury.freeETH(), address(treasury).balance - treasury.escrowed() - treasury.buybackReserved());
    }

    /// @dev Escrow equals the sum of unpaid bounties over every epoch ever touched.
    function invariant_escrowMatchesUnpaidBounties() public view {
        uint256 sum;
        for (uint256 e = 1; e <= handler.maxEpochTouched(); ++e) {
            (uint8 status,,, uint256 bounty,,,) = treasury.epochResult(e);
            if (status == 3 || status == 4) assertEq(bounty, 0, "closed epochs hold no bounty");
            sum += bounty;
        }
        assertEq(treasury.escrowed(), sum);
    }

    /// @dev 40% of every ETH receipt is reserved; what was spent on buybacks plus what remains equals it.
    function invariant_buybackReserveTracksIncome() public view {
        uint256 reserved;
        uint256 current = treasury.currentEpoch();
        for (uint256 e = 1; e <= current + 1; ++e) {
            reserved += treasury.income(e) * 40 / 100;
        }
        assertEq(treasury.buybackReserved() + treasury.buybackSpent(), reserved);
        (uint256 unlocked, uint256 tip) = treasury.buybackChunk();
        assertLe(unlocked, treasury.buybackReserved());
        assertEq(tip, unlocked / 200);
    }

    /// @dev Everything burned through the treasury is at the dead address and nowhere else.
    function invariant_totalBurnedIsAtDead() public view {
        assertEq(token.balanceOf(Protocol.DEAD), treasury.totalBurned());
        assertLe(treasury.totalBuybackBurned(), treasury.totalBurned());
        assertEq(token.balanceOf(address(treasury)), 0);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    /// @dev Finished epochs never reopen and recorded launches never change.
    function invariant_finalStatesAreFinal() public view {
        for (uint256 e = 1; e <= handler.maxEpochTouched(); ++e) {
            uint8 expected = handler.finalStatus(e);
            if (expected == 0) continue;
            (uint8 status,,,, uint64 n,,) = treasury.epochResult(e);
            assertEq(status, expected, "a closed epoch changed status");
            assertEq(n, handler.finalLaunch(e), "a recorded launch changed");
        }
    }

    /// @dev Each backer reserve is fully backed by the treasury's balance of that launch token, and the
    /// reserve of a token equals its share's outstanding amount until the sweep.
    function invariant_backerReservesAreBacked() public view {
        uint256 n = handler.recordedCount();
        for (uint256 i; i < n; ++i) {
            uint256 e = handler.recordedEpochs(i);
            (address asset, uint256 amount, uint256 claimed, uint64 until) = treasury.backerShare(e);
            assertLe(claimed, amount);
            assertGe(MockToken(asset).balanceOf(address(treasury)), treasury.reservedToken(asset));
            uint256 expected = handler.swept(e) ? 0 : amount - claimed;
            assertEq(treasury.reservedToken(asset), expected);
            assertGt(until, 0);
            (uint8 status,,,,,,) = treasury.epochResult(e);
            assertEq(status, 2);
        }
    }

    /// @dev Proposal caps, extension caps and the keeper budget hold for every epoch.
    function invariant_perEpochCaps() public view {
        for (uint256 e = 1; e <= handler.maxEpochTouched(); ++e) {
            assertLe(treasury.proposalCount(e), 20);
            assertLe(treasury.epochEnd(e) - treasury.proposeDeadline(e), 1 days);
            assertLe(treasury.keeperSpent(e), 0.01 ether);
        }
    }

    /// @dev ETH only leaves the treasury through the paths the rules name.
    function invariant_ethOutflowsAreAccountedFor() public view {
        // buybackSpent already includes the caller tips.
        assertLe(handler.ghostTipsPaid(), treasury.buybackSpent());
        uint256 outflows =
            handler.ghostBountiesPaid() + handler.ghostKeeperPaid() + handler.ghostIMDSpent() + treasury.buybackSpent();
        // Hook fees also flow in through receive(), so income is the complete inflow record.
        uint256 income;
        for (uint256 e = 1; e <= treasury.currentEpoch() + 1; ++e) {
            income += treasury.income(e);
        }
        assertEq(address(treasury).balance, startEth + income - outflows);
    }

    /// @dev The hook's fee debts stay fully backed while the treasury trades in the same pool.
    function invariant_hookFeeDebtBacked() public view {
        assertEq(address(hook).balance + manager.balanceOf(address(hook), 0), hook.teamOwed() + hook.treasuryOwed());
    }
}
