// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture, MockToken, MockHook, MockFactory} from "./helpers/Fixtures.sol";
import {MediciTreasury} from "../src/MediciTreasury.sol";
import {MediciHook} from "../src/MediciHook.sol";
import {MediciFeeRouter} from "../src/MediciFeeRouter.sol";
import {MediciToken} from "../src/MediciToken.sol";
import {Protocol, IMediciHook, IMediciTreasury} from "../src/Protocol.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice Treasury failure paths over a price fixture: wrong callers, wrong states, wrong times,
/// zero and maximum inputs, and the same call twice.
contract TreasuryEdgeTest is Fixture {
    MockHook internal oracle;

    function setUp() public {
        vm.warp(OPEN);
        vm.deal(address(this), 1_000 ether);
        token = new MediciToken();
        oracle = new MockHook(OPEN);
        treasury = new MediciTreasury(IPoolManager(address(this)), address(token), IMediciHook(address(oracle)));
        token.transfer(alice, 300_000_000 ether);
        token.transfer(bob, 300_000_000 ether);
        vm.prank(alice);
        token.approve(address(treasury), type(uint256).max);
        vm.prank(bob);
        token.approve(address(treasury), type(uint256).max);
        _protocolMocks();
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        new MediciTreasury(IPoolManager(address(0)), address(token), IMediciHook(address(oracle)));
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        new MediciTreasury(IPoolManager(address(this)), address(0), IMediciHook(address(oracle)));
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        new MediciTreasury(IPoolManager(address(this)), address(token), IMediciHook(address(0)));
        vm.expectRevert(MediciFeeRouter.InvalidLaunch.selector);
        new MediciFeeRouter(address(0), address(token), IMediciTreasury(address(treasury)));
        vm.expectRevert(MediciFeeRouter.InvalidLaunch.selector);
        new MediciFeeRouter(address(this), address(token), IMediciTreasury(address(0)));
    }

    function test_epochZeroViewsAndWritesRevert() public {
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.proposeDeadline(0);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.epochEnd(0);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.settle(0);
        vm.prank(alice);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.vote(0, 1, 1);
    }

    function test_beforePoolOpenNothingGovernsButIncomeLandsInEpochOne() public {
        MockHook closed = new MockHook(0);
        MediciTreasury early =
            new MediciTreasury(IPoolManager(address(this)), address(token), IMediciHook(address(closed)));
        assertEq(early.currentEpoch(), 0);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        early.proposeCost();
        vm.expectRevert(MediciTreasury.WrongState.selector);
        early.propose("title", bytes("{}"));
        vm.expectRevert(MediciTreasury.WrongState.selector);
        early.proposeDeadline(1);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        early.keeperWithdraw(1);
        (bool ok,) = address(early).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(early.income(1), 1 ether);
        assertEq(early.buybackReserved(), 0.4 ether);
        assertEq(early.freeETH(), 0.6 ether);
    }

    function test_proposeRejectsEmptyTitleAndEmptyBriefAndAcceptsTheMaxima() public {
        vm.prank(alice);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.propose("", bytes("{}"));
        vm.prank(alice);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.propose("title", bytes(""));
        bytes memory brief = new bytes(12_000);
        vm.prank(alice);
        uint256 id = treasury.propose(string(new bytes(80)), brief);
        assertEq(id, 1);
        (, string memory title, bytes32 hash,,,) = treasury.proposalOf(1, 1);
        assertEq(bytes(title).length, 80);
        assertEq(hash, keccak256(brief));
    }

    function test_proposalCostEscalatesAndClampsPerEpoch() public {
        uint256 cost = 0.002 ether;
        for (uint256 i; i < 20; ++i) {
            uint256 expected = cost * 1 ether / 1e10;
            if (expected < 1_000 ether) expected = 1_000 ether;
            if (expected > 50_000_000 ether) expected = 50_000_000 ether;
            assertEq(treasury.proposeCost(), expected);
            _proposal(alice, bytes("{}"));
            cost = cost * 115 / 100;
        }
        // The next epoch starts the ladder again.
        vm.warp(treasury.epochEnd(1));
        assertEq(treasury.currentEpoch(), 2);
        assertEq(treasury.proposeCost(), 200_000 ether);
        assertEq(treasury.proposalCount(2), 0);
    }

    function test_voteRejectsPastAndFutureEpochsAndUnknownProposal() public {
        _proposal(alice, bytes("{}"));
        vm.prank(bob);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.vote(2, 1, 1);
        vm.warp(treasury.epochEnd(1));
        vm.prank(bob);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.vote(1, 1, 1);
        vm.prank(bob);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.vote(2, 1, 1);
        vm.prank(bob);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.vote(2, 0, 1);
    }

    function test_voteBurnsExactlyAndFailsWithoutBalance() public {
        _proposal(alice, bytes("{}"));
        uint256 balance = token.balanceOf(bob);
        vm.prank(bob);
        vm.expectRevert();
        treasury.vote(1, 1, balance + 1);
        assertEq(treasury.votesOf(1, 1, bob), 0);
        _vote(bob, 1, 1, balance);
        assertEq(token.balanceOf(bob), 0);
        assertEq(treasury.votesOf(1, 1, bob), balance);
        (,,,, uint256 burned,) = treasury.proposalOf(1, 1);
        assertEq(burned, balance + 200_000 ether);
    }

    function test_settleRejectsEarlyAndUnknownEpochsAndRanksThree() public {
        _proposal(alice, bytes("a"));
        _proposal(bob, bytes("b"));
        _proposal(alice, bytes("c"));
        _vote(alice, 1, 1, 1_000_000 ether);
        _vote(bob, 1, 2, 3_000_000 ether);
        _vote(alice, 1, 3, 2_000_000 ether);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.settle(1);
        vm.warp(treasury.epochEnd(1) - 1);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.settle(1);
        vm.warp(treasury.epochEnd(1));
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.settle(2);
        treasury.settle(1);
        (uint8 status, uint256 winner, uint256 runner,,,,) = treasury.epochResult(1);
        assertEq(status, 1);
        assertEq(winner, 2);
        assertEq(runner, 3);
    }

    function test_settleThreeWayTieKeepsEarliestOrder() public {
        _proposal(alice, bytes("a"));
        _proposal(bob, bytes("b"));
        _proposal(alice, bytes("c"));
        // Proposal costs escalate (200k, 230k, 264.5k); top every burn up to the same total.
        _vote(alice, 1, 1, 1_064_500 ether);
        _vote(bob, 1, 2, 1_034_500 ether);
        _vote(alice, 1, 3, 1_000_000 ether);
        (,,,, uint256 b1,) = treasury.proposalOf(1, 1);
        (,,,, uint256 b2,) = treasury.proposalOf(1, 2);
        (,,,, uint256 b3,) = treasury.proposalOf(1, 3);
        assertEq(b1, b2);
        assertEq(b2, b3);
        vm.warp(treasury.epochEnd(1));
        treasury.settle(1);
        (, uint256 winner, uint256 runner,,,,) = treasury.epochResult(1);
        assertEq(winner, 1);
        assertEq(runner, 2);
    }

    function test_quorumBoundaryIsInclusiveAtOneHundredthEth() public {
        _proposal(alice, bytes("a"));
        _vote(alice, 1, 1, 800_000 ether); // 1,000,000 MEDICI in total: exactly 0.01 ETH at 1e10
        vm.warp(treasury.epochEnd(1));
        treasury.settle(1);
        (uint8 status,,, uint256 bounty,,,) = treasury.epochResult(1);
        assertEq(status, 1);
        assertEq(bounty, 0); // no ETH in the treasury: a winner, but nothing to escrow
        assertEq(treasury.escrowed(), 0);
    }

    function test_quorumOneWeiShortAtTheEpochTwapHasNoWinner() public {
        _proposal(alice, bytes("a"));
        _vote(alice, 1, 1, 800_000 ether);
        oracle.setPrice(1e10 - 1);
        vm.warp(treasury.epochEnd(1));
        treasury.settle(1);
        (uint8 status, uint256 winner,,,,,) = treasury.epochResult(1);
        assertEq(status, 4);
        assertEq(winner, 0);
    }

    function test_secondSkipClosesTheEpochAndReleasesEscrow() public {
        _twoWinners();
        assertEq(treasury.escrowed(), 0.016 ether);
        (,,, uint256 bounty,,,) = treasury.epochResult(1);
        assertEq(bounty, 0.016 ether);
        vm.warp(OPEN + 7 days + 1);
        _proposal(alice, bytes("{\"idea\":\"three\"}"));
        _vote(alice, 2, 1, 3_000_000 ether);
        vm.prank(Protocol.KEEPER);
        treasury.skip(1, "drop");
        vm.prank(Protocol.KEEPER);
        treasury.skip(1, "drop again");
        (uint8 status,,, uint256 left,,,) = treasury.epochResult(1);
        assertEq(status, 3);
        assertEq(left, 0);
        assertEq(treasury.escrowed(), 0);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.skip(1, "third");
    }

    function test_commissionStateGates() public {
        _twoWinners();
        imd.mint(address(treasury), 1 ether);
        // Not settled epochs, no-winner epochs and future epochs are all refused.
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.commission(2, bytes("{\"idea\":\"one\"}"));
        // After the launch window nothing can be commissioned.
        vm.warp(OPEN + 7 days + 14 days);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.commission(1, bytes("{\"idea\":\"one\"}"));
    }

    function test_commissionWithoutIMDAndWithoutFreeETHReverts() public {
        vm.warp(OPEN + 1 days);
        _proposal(alice, bytes("{\"idea\":\"one\"}"));
        _vote(alice, 1, 1, 3_000_000 ether);
        vm.warp(treasury.epochEnd(1));
        treasury.settle(1);
        assertEq(treasury.freeETH(), 0);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InsufficientFreeETH.selector);
        treasury.commission(1, bytes("{\"idea\":\"one\"}"));
        (bytes32 live,) = treasury.requestOf(1);
        assertEq(live, 0);
    }

    function test_callbacksRefuseWrongSenderUnknownIdAndWrongStatus() public {
        _twoWinners();
        bytes32 id = _commission();
        vm.expectRevert(MediciTreasury.Unauthorized.selector);
        treasury.onFailure(id, 2, bytes32("x"), 0, 0, "");
        vm.prank(Protocol.INTAKE);
        vm.expectRevert(MediciTreasury.UnknownRequest.selector);
        treasury.onResult(bytes32(uint256(1)), bytes32(0), "");
        vm.prank(Protocol.INTAKE);
        vm.expectRevert(MediciTreasury.UnknownRequest.selector);
        treasury.onFailure(bytes32(uint256(1)), 2, bytes32("x"), 0, 0, "");
        // Once the launch is recorded the request is no longer live, so a late result is refused.
        MockToken asset = new MockToken();
        _record(90, asset, false);
        vm.prank(Protocol.INTAKE);
        vm.expectRevert(MediciTreasury.UnknownRequest.selector);
        treasury.onResult(id, bytes32(0), "");
        vm.prank(Protocol.INTAKE);
        vm.expectRevert(MediciTreasury.UnknownRequest.selector);
        treasury.onFailure(id, 2, bytes32("x"), 0, 0, "");
    }

    function test_resultDoesNotUnlockASecondCommissionOrSkip() public {
        _twoWinners();
        bytes32 id = _commission();
        assertTrue(intake.result(address(treasury), id, keccak256("r"), "ipfs://r"));
        imd.mint(address(treasury), 0.5 ether);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.commission(1, bytes("{\"idea\":\"one\"}"));
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.skip(1, "too late to skip");
    }

    function test_recordCommissionGates() public {
        _twoWinners();
        MockToken asset = new MockToken();
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(asset)), 12_500, 60, IHooks(address(0)));
        launchFactory.register(70, k, address(treasury));
        asset.mint(address(this), 950 ether);
        asset.mint(address(treasury), 50 ether);
        // Before commission.
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.recordCommission(1, 70, "job");
        _commission();
        // Wrong caller.
        vm.expectRevert(MediciTreasury.Unauthorized.selector);
        treasury.recordCommission(1, 70, "job");
        // Empty job id.
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.recordCommission(1, 70, "");
        // Unknown launch number on both factories.
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.recordCommission(1, 71, "job");
        // The launch token may not be MEDICI itself.
        PoolKey memory self =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12_500, 60, IHooks(address(0)));
        launchFactory.register(72, self, address(treasury));
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.recordCommission(1, 72, "job");
        // A pool pairing ETH with IMD has no launch token.
        PoolKey memory imdKey =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(Protocol.IMD), 10_000, 200, IHooks(address(0)));
        launchFactory.register(73, imdKey, address(treasury));
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.recordCommission(1, 73, "job");
        // 50 of 1001 is under 5%; 51 of 1002 is enough (the threshold rounds up).
        asset.mint(address(this), 1 ether);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.recordCommission(1, 70, "job");
        asset.mint(address(treasury), 1 ether);
        vm.prank(Protocol.KEEPER);
        treasury.recordCommission(1, 70, "job");
        (uint8 status,,,, uint64 number,,) = treasury.epochResult(1);
        assertEq(status, 2);
        assertEq(number, 70);
        // Lapse and skip no longer apply.
        vm.warp(OPEN + 60 days);
        vm.expectRevert(MediciTreasury.TooEarly.selector);
        treasury.lapse(1);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.skip(1, "x");
    }

    function test_recordCommissionAfterDeadlineRevertsAndLapseStillWorks() public {
        _twoWinners();
        _commission();
        MockToken asset = new MockToken();
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(asset)), 12_500, 60, IHooks(address(0)));
        launchFactory.register(74, k, address(treasury));
        asset.mint(address(this), 950 ether);
        asset.mint(address(treasury), 50 ether);
        (,,,,, uint64 deadline,) = treasury.epochResult(1);
        vm.warp(deadline);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.recordCommission(1, 74, "job");
        treasury.lapse(1);
        (uint8 status, uint256 winner,,,,,) = treasury.epochResult(1);
        assertEq(status, 1);
        assertEq(winner, 2);
    }

    function test_launchNumberRecordedOnceAcrossEpochs() public {
        _twoWinners();
        _commission();
        MockToken asset = new MockToken();
        _record(75, asset, false);
        // Epoch two wins with a fresh proposal and tries to reuse launch 75.
        vm.warp(OPEN + 7 days + 1);
        _proposal(bob, bytes("{\"idea\":\"again\"}"));
        _vote(bob, 2, 1, 3_000_000 ether);
        vm.warp(treasury.epochEnd(2));
        treasury.settle(2);
        imd.mint(address(treasury), 0.5 ether);
        vm.prank(Protocol.KEEPER);
        treasury.commission(2, bytes("{\"idea\":\"again\"}"));
        asset.mint(address(treasury), 100 ether);
        // A recorded (factory, number) is no longer eligible, so there is nothing to record.
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.recordCommission(2, 75, "job-2");
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.recordCommissionAt(2, Protocol.LAUNCH_FACTORY, 75, "job-2");
        (address factory, uint64 number) = treasury.launchOf(1);
        assertEq(factory, Protocol.LAUNCH_FACTORY);
        assertEq(number, 75);
        (factory, number) = treasury.launchOf(2);
        assertEq(factory, address(0));
        assertEq(number, 0);
        assertEq(treasury.launchToken(Protocol.LAUNCH_FACTORY, 75), address(asset));
        assertEq(treasury.launchToken(Protocol.PROJECT_FACTORY, 75), address(0));
    }

    function test_recordCommissionAtGates() public {
        _twoWinners();
        MockToken asset = new MockToken();
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(asset)), 12_500, 60, IHooks(address(0)));
        projectFactory.register(81, k, address(treasury));
        asset.mint(address(this), 950 ether);
        asset.mint(address(treasury), 50 ether);
        (address factory, uint64 number) = treasury.launchOf(1);
        assertEq(factory, address(0));
        assertEq(number, 0);
        // Before commission.
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.recordCommissionAt(1, Protocol.PROJECT_FACTORY, 81, "job");
        _commission();
        // Wrong caller.
        vm.expectRevert(MediciTreasury.Unauthorized.selector);
        treasury.recordCommissionAt(1, Protocol.PROJECT_FACTORY, 81, "job");
        // A factory that is neither of the two is refused before the epoch is even looked at.
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.recordCommissionAt(2, alice, 81, "job");
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.recordCommissionAt(1, address(0), 81, "job");
        // Epoch zero and an unsettled epoch.
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.recordCommissionAt(0, Protocol.PROJECT_FACTORY, 81, "job");
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.recordCommissionAt(2, Protocol.PROJECT_FACTORY, 81, "job");
        // Empty job id.
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.recordCommissionAt(1, Protocol.PROJECT_FACTORY, 81, "");
        // The position lives on the other factory.
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.recordCommissionAt(1, Protocol.LAUNCH_FACTORY, 81, "job");
        // The named factory holds the number but the treasury is not its requester.
        projectFactory.register(82, k, alice);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.recordCommissionAt(1, Protocol.PROJECT_FACTORY, 82, "job");
        // Past the launch deadline nothing can be recorded, even with the factory named.
        (,,,,, uint64 deadline,) = treasury.epochResult(1);
        uint256 now_ = vm.getBlockTimestamp();
        vm.warp(deadline);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.recordCommissionAt(1, Protocol.PROJECT_FACTORY, 81, "job");
        vm.warp(now_);
        uint256 aliceBefore = alice.balance;
        vm.prank(Protocol.KEEPER);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit MediciTreasury.Recorded(1, Protocol.PROJECT_FACTORY, 81, "job");
        treasury.recordCommissionAt(1, Protocol.PROJECT_FACTORY, 81, "job");
        (uint8 status,,, uint256 bounty, uint64 recorded,,) = treasury.epochResult(1);
        assertEq(status, 2);
        assertEq(bounty, 0);
        assertEq(recorded, 81);
        assertEq(alice.balance - aliceBefore, 0.016 ether);
        (factory, number) = treasury.launchOf(1);
        assertEq(factory, Protocol.PROJECT_FACTORY);
        assertEq(number, 81);
        assertEq(treasury.launchToken(Protocol.PROJECT_FACTORY, 81), address(asset));
        assertEq(treasury.reservedToken(address(asset)), 50 ether);
        // The same call twice: the epoch is already launched.
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.recordCommissionAt(1, Protocol.PROJECT_FACTORY, 81, "job");
    }

    function test_harvestOfANumberTouchesOnlyRecordedPositions() public {
        _twoWinners();
        _commission();
        MockToken asset = new MockToken();
        _record(83, asset, false);
        // A second, unrelated position with the same number on the other factory is not recorded,
        // so harvest(83) touches only the recorded one.
        MockToken other = new MockToken();
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(other)), 12_500, 60, IHooks(address(0)));
        projectFactory.register(83, k, address(treasury));
        other.mint(address(projectFactory), 5 ether);
        projectFactory.seed(83, 0, 5 ether);
        asset.mint(address(launchFactory), 2 ether);
        launchFactory.seed(83, 0, 2 ether);
        treasury.harvest(83);
        assertEq(launchFactory.claims(), 1);
        assertEq(projectFactory.claims(), 0);
        assertEq(asset.balanceOf(Protocol.DEAD), 2 ether);
        assertEq(other.balanceOf(Protocol.DEAD), 0);
        assertEq(other.balanceOf(address(projectFactory)), 5 ether);
    }

    function test_positionWithInvertedRangeIsNotALaunch() public {
        _twoWinners();
        _commission();
        MockToken asset = new MockToken();
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(asset)), 12_500, 60, IHooks(address(0)));
        launchFactory.register(76, k, address(treasury));
        launchFactory.setRange(76, 60, -60);
        asset.mint(address(this), 950 ether);
        asset.mint(address(treasury), 50 ether);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.recordCommission(1, 76, "job");
    }

    function test_backerClaimsExpireAndUnclaimedBurnIsOneShot() public {
        _twoWinners();
        _commission();
        MockToken asset = new MockToken();
        _record(77, asset, false);
        vm.expectRevert(MediciTreasury.TooEarly.selector);
        treasury.burnUnclaimed(2);
        (,,, uint64 until) = treasury.backerShare(1);
        vm.warp(until - 1);
        assertEq(treasury.claimable(1, alice), 50 ether);
        vm.warp(until);
        assertEq(treasury.claimable(1, alice), 0);
        vm.prank(alice);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.claimBacker(1);
        treasury.burnUnclaimed(1);
        assertEq(asset.balanceOf(Protocol.DEAD), 50 ether);
        assertEq(asset.balanceOf(address(treasury)), 0);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.burnUnclaimed(1);
    }

    function test_rejectedBountyIsNotRetriedAndTheWinnerStillBacks() public {
        // A proposer that cannot take ETH loses the bounty for good: the ETH is free again, the
        // launch stays recorded, and no later call pays it out.
        RejectingReceiver proposer = new RejectingReceiver();
        token.transfer(address(proposer), 5_000_000 ether);
        vm.prank(address(proposer));
        token.approve(address(treasury), type(uint256).max);
        vm.warp(OPEN + 1 days);
        vm.prank(address(proposer));
        uint256 id = treasury.propose("Contract proposer", bytes("{\"idea\":\"one\"}"));
        _vote(address(proposer), 1, id, 3_000_000 ether);
        _donate(10 ether);
        vm.warp(treasury.epochEnd(1));
        treasury.settle(1);
        (,,, uint256 bounty,,,) = treasury.epochResult(1);
        assertEq(bounty, 0.016 ether);
        _commission();
        MockToken asset = new MockToken();
        _record(84, asset, false);
        (uint8 status,,, uint256 left,,,) = treasury.epochResult(1);
        assertEq(status, 2);
        assertEq(left, 0);
        assertEq(address(proposer).balance, 0);
        assertEq(treasury.escrowed(), 0);
        assertEq(treasury.freeETH(), 6 ether);
        // Nothing reopens the payout: a repeated record is refused and the escrow stays released.
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.recordCommission(1, 84, "job-1");
        assertEq(treasury.claimable(1, address(proposer)), 50 ether);
        vm.prank(address(proposer));
        treasury.claimBacker(1);
        assertEq(asset.balanceOf(address(proposer)), 50 ether);
    }

    function test_keeperWithdrawZeroAboveFreeAndRejectingKeeper() public {
        _donate(0.005 ether);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.keeperWithdraw(0);
        // 0.003 ETH is free (60% of 0.005); asking for more fails before the budget is touched.
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InsufficientFreeETH.selector);
        treasury.keeperWithdraw(0.004 ether);
        assertEq(treasury.keeperSpent(1), 0);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.keeperWithdraw(0.01 ether + 1);
        RejectingReceiver rejecting = new RejectingReceiver();
        vm.prank(Protocol.KEEPER);
        treasury.setKeeper(address(rejecting));
        vm.prank(address(rejecting));
        vm.expectRevert(MediciTreasury.TransferFailed.selector);
        treasury.keeperWithdraw(0.001 ether);
        assertEq(treasury.keeperSpent(1), 0);
    }

    function test_roleHandoverRejectsZeroAndOldRoleLosesPower() public {
        vm.prank(Protocol.TEAM);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.setTeam(address(0));
        vm.prank(Protocol.KEEPER);
        treasury.setKeeper(alice);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.Unauthorized.selector);
        treasury.flag(1, 1, "x");
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.Unauthorized.selector);
        treasury.setKeeper(bob);
        vm.prank(alice);
        treasury.setKeeper(bob);
        assertEq(treasury.keeper(), bob);
    }

    function test_buybackWithoutBudgetReverts() public {
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.buyback(0);
        _donate(1 ether);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.buyback(1 ether);
        vm.warp(treasury.epochEnd(1));
        treasury.settle(1);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.buyback(0);
    }

    function test_unlockCallbackOnlyDuringOwnSwap() public {
        vm.expectRevert(MediciTreasury.Unauthorized.selector);
        treasury.unlockCallback("");
        // Even the configured manager cannot drive a swap the treasury did not start.
        vm.expectRevert(MediciTreasury.Unauthorized.selector);
        this.callUnlock();
    }

    function callUnlock() external {
        treasury.unlockCallback("");
    }

    function test_burnDepositedCountsDonatedMedici() public {
        token.transfer(address(treasury), 5 ether);
        uint256 burned = treasury.burnDeposited();
        assertEq(burned, 5 ether);
        assertEq(treasury.totalBurned(), 5 ether);
        assertEq(token.balanceOf(Protocol.DEAD), 5 ether);
        assertEq(treasury.burnDeposited(), 0);
    }

    function test_harvestRequiresRecordedLaunchWithTreasuryRequester() public {
        _twoWinners();
        _commission();
        MockToken asset = new MockToken();
        _record(78, asset, false);
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(asset)), 12_500, 60, IHooks(address(0)));
        // The requester moved away after recording: harvest refuses rather than pulling to a stranger.
        vm.prank(address(treasury));
        launchFactory.setRequester(78, alice);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.harvest(78);
        k;
    }
}

contract RejectingReceiver {
    receive() external payable {
        revert("no");
    }
}

/// @notice Hook and router failure paths on the real PoolManager.
contract HookEdgeTest is Fixture {
    function setUp() public {
        _deployReal(true);
    }

    function _mine(address deployer, bytes memory code) internal pure returns (bytes32 salt) {
        bytes32 hash = keccak256(code);
        // Start past the fixture's own salt range so the second hook lands on a fresh address.
        for (uint256 i = 1_000_000; i < 1_200_000; ++i) {
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), hash)))));
            if (HookFlags.matches(predicted, HookFlags.MEDICI)) return bytes32(i);
        }
        revert("no salt");
    }

    function test_constructorRejectsZeroArgumentsAndWrongAddressFlags() public {
        vm.expectRevert(MediciHook.InvalidPool.selector);
        new MediciHook(IPoolManager(address(0)), address(token));
        vm.expectRevert(MediciHook.InvalidPool.selector);
        new MediciHook(manager, address(0));
        // A plain CREATE lands on an address without the mined flags: the hook refuses to exist there.
        vm.expectRevert();
        new MediciHook(manager, address(token));
    }

    function test_unopenedHookRefusesPriceAndPoolReads() public {
        bytes memory code = abi.encodePacked(type(MediciHook).creationCode, abi.encode(manager, address(token)));
        bytes32 salt = _mine(address(this), code);
        address at;
        assembly ("memory-safe") {
            at := create2(0, add(code, 32), mload(code), salt)
        }
        require(at != address(0), "second hook deployment failed");
        MediciHook fresh = MediciHook(payable(at));
        assertEq(fresh.openedAt(), 0);
        vm.expectRevert(MediciHook.NotOpen.selector);
        fresh.poolKey();
        vm.expectRevert(MediciHook.NotOpen.selector);
        fresh.buyFeeBps();
        vm.expectRevert(MediciHook.NotOpen.selector);
        fresh.price();
        vm.expectRevert(MediciHook.NotOpen.selector);
        fresh.cumulativeAt(uint64(block.timestamp));
        MediciTreasury freshTreasury = fresh.treasury();
        assertEq(freshTreasury.currentEpoch(), 0);
        vm.expectRevert(MediciHook.NotOpen.selector);
        freshTreasury.price();
        // Wrong pools are refused before the hook ever opens.
        PoolKey memory wrongSpacing =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12_500, 200, IHooks(at));
        vm.expectRevert();
        manager.initialize(wrongSpacing, Q96);
        MockToken other = new MockToken();
        (address c0, address c1) =
            address(other) < address(token) ? (address(other), address(token)) : (address(token), address(other));
        PoolKey memory wrongPair = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 12_500, 60, IHooks(at));
        vm.expectRevert();
        manager.initialize(wrongPair, Q96);
        assertEq(fresh.openedAt(), 0);
        // The right pool opens it, once.
        PoolKey memory right = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12_500, 60, IHooks(at));
        manager.initialize(right, Q96);
        assertEq(fresh.openedAt(), uint64(block.timestamp));
        vm.prank(address(manager));
        vm.expectRevert(MediciHook.InvalidPool.selector);
        fresh.beforeInitialize(address(this), right, Q96);
    }

    function test_twapWindowValidation() public {
        vm.warp(OPEN + 1 days);
        vm.expectRevert(MediciHook.NotOpen.selector);
        hook.twap(OPEN + 10, OPEN + 10);
        vm.expectRevert(MediciHook.NotOpen.selector);
        hook.twap(OPEN + 20, OPEN + 10);
        vm.expectRevert(MediciHook.NotOpen.selector);
        hook.cumulativeAt(OPEN - 1);
        vm.expectRevert(MediciHook.NotOpen.selector);
        hook.cumulativeAt(uint64(block.timestamp + 1));
        assertEq(hook.cumulativeAt(OPEN), 0);
        assertEq(hook.twap(OPEN, OPEN + 1 days), 1e10);
    }

    function test_openingSecondPriceIsTheSpotAndCanBeMovedWithinThatSecond() public {
        // In the opening second there is no elapsed window: price() is the spot, so governance
        // works from the first block, but a swap in that same second moves it at once.
        assertEq(block.timestamp, OPEN);
        assertEq(hook.price(), 1e10);
        assertEq(treasury.proposeCost(), 200_000 ether);
        vm.prank(alice);
        uint256 id = treasury.propose("first block", bytes("{}"));
        assertEq(id, 1);
        assertEq(treasury.totalBurned(), 200_000 ether);
        actor.swap(key, true, -int256(0.5 ether), TickMath.MIN_SQRT_PRICE + 1);
        (, uint192 spot,) = hook.observations(0);
        assertGt(spot, 1e10);
        assertEq(hook.price(), spot);
        assertLt(treasury.proposeCost(), 230_000 ether);
        // One second later the average over the elapsed second is that final spot.
        vm.warp(OPEN + 1);
        assertEq(hook.price(), spot);
        assertEq(hook.twap(OPEN, OPEN + 1), spot);
        vm.expectRevert(MediciHook.NotOpen.selector);
        hook.twap(OPEN, OPEN);
    }

    function test_swapOnAnotherPoolWithThisHookIsRefused() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.prank(address(manager));
        vm.expectRevert(MediciHook.InvalidPool.selector);
        hook.afterSwap(address(this), other, SwapParams(true, -1, 0), BalanceDelta.wrap(0), "");
        vm.prank(address(manager));
        vm.expectRevert(MediciHook.InvalidPool.selector);
        hook.beforeSwap(address(this), other, SwapParams(true, -1, 0), "");
    }

    function test_redeemWithoutClaimsIsANoOpAndClaimTeamWithNothingOwedPaysZero() public {
        assertEq(manager.balanceOf(address(hook), 0), 0);
        hook.redeemFees();
        uint256 before = Protocol.TEAM.balance;
        hook.claimTeam();
        assertEq(Protocol.TEAM.balance, before);
    }

    function test_exactOutputBuysAcrossTheDecayWindowPayTheDecayedRate(uint16 elapsed, uint64 raw) public {
        vm.warp(OPEN + bound(elapsed, 0, 899));
        uint256 amount = bound(raw, 1 ether, 1_000_000 ether);
        uint256 rate = hook.buyFeeBps();
        assertGe(rate, 200);
        assertLe(rate, 5000);
        uint256 treasuryBefore = address(treasury).balance;
        uint256 teamBefore = hook.teamOwed();
        BalanceDelta d = actor.swap(key, true, int256(amount), TickMath.MIN_SQRT_PRICE + 1);
        assertEq(d.amount1(), int128(int256(amount)));
        uint256 paidIn = uint256(-int256(d.amount0()));
        uint256 total = address(treasury).balance - treasuryBefore + hook.teamOwed() - teamBefore;
        // fee == base * rate / 10_000 where base + fee == paidIn
        uint256 base = paidIn - total;
        assertEq(total, base * rate / 10_000);
        assertEq(hook.teamOwed() - teamBefore, base * 50 / 10_000);
    }

    function test_sellFeeIsAlwaysTwoPercentEvenDuringLaunch() public {
        vm.warp(OPEN + 10);
        uint256 treasuryBefore = address(treasury).balance;
        uint256 teamBefore = hook.teamOwed();
        BalanceDelta d = actor.swap(key, false, -int256(1_000_000 ether), TickMath.MAX_SQRT_PRICE - 1);
        uint256 received = uint256(int256(d.amount0()));
        uint256 total = address(treasury).balance - treasuryBefore + hook.teamOwed() - teamBefore;
        uint256 base = received + total;
        assertEq(total, base * 200 / 10_000);
        assertEq(hook.teamOwed() - teamBefore, base * 50 / 10_000);
    }

    function test_hookDataCannotImpersonateTheTreasury() public {
        vm.warp(OPEN + 1 days);
        uint256 before = address(treasury).balance;
        actor.swapWithData(key, true, -int256(0.01 ether), TickMath.MIN_SQRT_PRICE + 1, abi.encode(address(treasury)));
        assertGt(address(treasury).balance, before);
    }

    function test_routerRejectsHarvestWhenPositionHookChanged() public {
        launchFactory.register(50, key, address(router));
        router.setLaunchNumber(50);
        PoolKey memory other = key;
        other.hooks = IHooks(address(0));
        launchFactory.register(50, other, address(router));
        vm.expectRevert(MediciFeeRouter.InvalidLaunch.selector);
        router.harvest();
    }

    function test_routerHarvestWithNothingOwedAndDeferredTeamPaymentsAccumulate() public {
        launchFactory.register(51, key, address(router));
        router.setLaunchNumber(51);
        vm.expectEmit(true, true, true, true, address(router));
        emit MediciFeeRouter.Harvested(51, 0, 0);
        router.harvest();
        assertEq(launchFactory.claims(), 1);
        // Nothing to pay is not a failure.
        router.payTeam();
        RejectingReceiver rejecting = new RejectingReceiver();
        vm.prank(Protocol.TEAM);
        treasury.setTeam(address(rejecting));
        vm.deal(address(launchFactory), 1 ether);
        launchFactory.seed(51, 0.1 ether, 0);
        vm.expectEmit(true, true, true, true, address(router));
        emit MediciFeeRouter.TeamPaymentDeferred(address(rejecting), 0.1 ether);
        router.harvest();
        assertEq(address(router).balance, 0.1 ether);
        // A second harvest while TEAM still rejects retries the whole deferred balance, not just the new fees.
        launchFactory.seed(51, 0.2 ether, 0);
        vm.expectEmit(true, true, true, true, address(router));
        emit MediciFeeRouter.TeamPaymentDeferred(address(rejecting), 0.3 ether);
        router.harvest();
        assertEq(address(router).balance, 0.3 ether);
        vm.expectRevert(MediciFeeRouter.TransferFailed.selector);
        router.payTeam();
        assertEq(address(router).balance, 0.3 ether);
        // Hand the role to an account that accepts ETH: the next harvest flushes everything deferred.
        vm.prank(address(rejecting));
        treasury.setTeam(bob);
        vm.expectEmit(true, true, true, true, address(router));
        emit MediciFeeRouter.TeamPaid(bob, 0.3 ether);
        router.harvest();
        assertEq(bob.balance, 0.3 ether);
        assertEq(address(router).balance, 0);
        assertEq(address(rejecting).balance, 0);
    }
}
