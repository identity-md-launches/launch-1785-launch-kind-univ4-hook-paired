// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Fixture, MockToken, MockHook, MockFactory} from "./helpers/Fixtures.sol";
import {MediciTreasury} from "../src/MediciTreasury.sol";
import {MediciToken} from "../src/MediciToken.sol";
import {Protocol, IMediciHook} from "../src/Protocol.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Test} from "forge-std/Test.sol";

contract RefusingProposer {
    MediciToken private token;
    MediciTreasury private treasury;
    bool public reject = true;
    bool public reenter;
    bool public reentrySucceeded;

    constructor(MediciToken t, MediciTreasury tr) {
        token = t;
        treasury = tr;
    }

    function proposeAndVote(bytes calldata brief) external {
        token.approve(address(treasury), 10_000_000 ether);
        uint256 id = treasury.propose("Contract proposer", brief);
        treasury.vote(1, id, 3_000_000 ether);
    }

    function acceptAndReenter() external {
        reject = false;
        reenter = true;
    }

    receive() external payable {
        require(!reject, "no ETH");
        if (reenter) (reentrySucceeded,) = address(treasury).call(abi.encodeCall(treasury.claimBacker, (1)));
    }
}

contract TreasuryTest is Fixture {
    MockHook internal oracle;

    function setUp() public {
        vm.warp(OPEN);
        vm.deal(address(this), 1_000 ether);
        token = new MediciToken();
        oracle = new MockHook(OPEN);
        // Governance tests use a price fixture; swap tests below use the real PoolManager.
        treasury = new MediciTreasury(IPoolManager(address(this)), address(token), IMediciHook(address(oracle)));
        token.transfer(alice, 300_000_000 ether);
        token.transfer(bob, 300_000_000 ether);
        vm.prank(alice);
        token.approve(address(treasury), type(uint256).max);
        vm.prank(bob);
        token.approve(address(treasury), type(uint256).max);
        _protocolMocks();
    }

    function test_roleHandoverOnlyByThatRole() public {
        vm.expectRevert(MediciTreasury.Unauthorized.selector);
        treasury.setTeam(alice);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.Unauthorized.selector);
        treasury.setTeam(alice);
        vm.prank(Protocol.TEAM);
        treasury.setTeam(alice);
        assertEq(treasury.team(), alice);
        vm.prank(Protocol.TEAM);
        vm.expectRevert();
        treasury.setTeam(bob);
        vm.prank(Protocol.KEEPER);
        treasury.setKeeper(bob);
        assertEq(treasury.keeper(), bob);
        vm.prank(bob);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.setKeeper(address(0));
    }

    function test_proposalCostBurnAndMetadata() public {
        assertEq(treasury.proposeCost(), 200_000 ether);
        vm.roll(4321);
        uint256 beforeBalance = token.balanceOf(alice);
        _proposal(alice, bytes("{\"idea\":1}"));
        assertEq(treasury.proposeCost(), 230_000 ether);
        (address proposer, string memory title, bytes32 hash, uint64 blockNumber, uint256 burned, string memory flag_) =
            treasury.proposalOf(1, 1);
        assertEq(proposer, alice);
        assertEq(title, "A commissioned launch");
        assertEq(hash, keccak256(bytes("{\"idea\":1}")));
        assertEq(blockNumber, 4321);
        assertEq(burned, 200_000 ether);
        assertEq(flag_, "");
        assertEq(beforeBalance - token.balanceOf(alice), burned);
        assertEq(token.balanceOf(Protocol.DEAD), burned);
        assertEq(treasury.totalBurned(), burned);
        assertEq(treasury.votesOf(1, 1, alice), burned);
        oracle.setPrice(1e18);
        assertEq(treasury.proposeCost(), 1_000 ether);
        oracle.setPrice(1);
        assertEq(treasury.proposeCost(), 50_000_000 ether);
    }

    function test_proposeBoundsCapAndAllowanceFailure() public {
        vm.prank(alice);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.propose(string(new bytes(81)), bytes("{}"));
        vm.prank(alice);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.propose("title", new bytes(12_001));
        vm.prank(alice);
        token.approve(address(treasury), 0);
        vm.prank(alice);
        vm.expectRevert();
        treasury.propose("title", bytes("{}"));
        assertEq(treasury.proposalCount(1), 0);
        assertEq(treasury.totalBurned(), 0);
        vm.prank(alice);
        token.approve(address(treasury), type(uint256).max);
        for (uint256 i; i < 20; i++) {
            _proposal(alice, bytes("{}"));
        }
        assertEq(treasury.proposalCount(1), 20);
        vm.prank(alice);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.propose("21", bytes("{}"));
    }

    function test_epochsAdvanceWithoutSettlementAndKeepStatusZero() public {
        vm.warp(OPEN + 4 * 7 days + 1);
        assertEq(treasury.currentEpoch(), 5);
        (uint8 status,,,,,,) = treasury.epochResult(1);
        assertEq(status, 0);
        treasury.settle(1);
        (status,,,,,,) = treasury.epochResult(1);
        assertEq(status, 4);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.settle(1);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.settle(5);
    }

    function test_extensionsOnlyIncreaseEndAndCapAt24Hours() public {
        _proposal(alice, bytes("{}"));
        uint64 original = treasury.epochEnd(1);
        vm.warp(original - 30 minutes);
        _vote(bob, 1, 1, 1 ether);
        assertEq(treasury.epochEnd(1), original);
        vm.warp(original - 60);
        _vote(bob, 1, 1, 1 ether);
        assertEq(treasury.epochEnd(1), original + 9 minutes);
        vm.warp(original);
        assertEq(treasury.currentEpoch(), 1);
        vm.prank(alice);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.propose("late", bytes("{}"));
        for (uint256 i; i < 200; ++i) {
            uint64 end = treasury.epochEnd(1);
            if (end == original + 1 days) break;
            vm.warp(end - 1);
            _vote(bob, 1, 1, 1);
        }
        assertEq(treasury.epochEnd(1), original + 1 days);
        vm.warp(original + 1 days);
        assertEq(treasury.currentEpoch(), 2);
        assertEq(treasury.proposeDeadline(2), original + 7 days);
        vm.prank(bob);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.vote(1, 1, 1);
        vm.warp(original + 1 days + 21 days);
        assertEq(treasury.currentEpoch(), 5);
    }

    function test_voteAndFlagValidation() public {
        _proposal(alice, bytes("{}"));
        vm.prank(bob);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.vote(1, 2, 1);
        vm.prank(bob);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.vote(1, 1, 0);
        vm.expectRevert(MediciTreasury.Unauthorized.selector);
        treasury.flag(1, 1, "flag");
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.flag(1, 1, string(new bytes(121)));
        vm.prank(Protocol.KEEPER);
        treasury.flag(1, 1, "reviewed");
        (,,,,, string memory note) = treasury.proposalOf(1, 1);
        assertEq(note, "reviewed");
    }

    function test_tieEarlierWinsAndBountyEscrow() public {
        _proposal(alice, bytes("one"));
        _proposal(bob, bytes("two"));
        _vote(alice, 1, 1, 1_800_000 ether);
        _vote(bob, 1, 2, 1_770_000 ether);
        _donate(1 ether);
        vm.warp(treasury.epochEnd(1));
        treasury.settle(1);
        (uint8 status, uint256 winner, uint256 runner, uint256 bounty,, uint64 deadline,) = treasury.epochResult(1);
        assertEq(status, 1);
        assertEq(winner, 1);
        assertEq(runner, 2);
        assertEq(bounty, 0.01 ether);
        assertEq(treasury.escrowed(), bounty);
        assertEq(deadline, block.timestamp + 14 days);
        assertEq(treasury.buybackReserved(), 0.4 ether);
    }

    function test_bountyAbsoluteAndFreeBalanceCaps() public {
        _proposal(alice, bytes("one"));
        _vote(alice, 1, 1, 250_000_000 ether);
        _donate(100 ether);
        vm.warp(treasury.epochEnd(1));
        treasury.settle(1);
        (,,, uint256 bounty,,,) = treasury.epochResult(1);
        assertEq(bounty, 1 ether);
        assertEq(treasury.escrowed(), 1 ether);
        assertEq(treasury.buybackReserved(), 40 ether);
    }

    function test_belowQuorumNoWinner() public {
        _proposal(alice, bytes("{}"));
        vm.warp(treasury.epochEnd(1));
        treasury.settle(1);
        (uint8 status, uint256 winner,,,,,) = treasury.epochResult(1);
        assertEq(status, 4);
        assertEq(winner, 0);
        assertEq(treasury.escrowed(), 0);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert();
        treasury.commission(1, bytes("{}"));
    }

    function test_commissionHashTimingExactApprovalAndDuplicateProtection() public {
        _twoWinners();
        imd.mint(address(treasury), 1 ether);
        vm.expectRevert(MediciTreasury.Unauthorized.selector);
        treasury.commission(1, bytes("{\"idea\":\"one\"}"));
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.commission(1, bytes("wrong"));
        vm.warp(block.timestamp + 1 days);
        treasury.commission(1, bytes("{\"idea\":\"one\"}"));
        (bytes32 id, uint64 opens) = treasury.requestOf(1);
        assertTrue(id != 0);
        assertEq(opens, OPEN + 8 days);
        assertEq(intake.lastAction(), bytes32("launch.open@launch-1"));
        assertEq(intake.lastBody(), bytes("{\"idea\":\"one\"}"));
        assertEq(intake.allowanceSeen(), 0.5 ether);
        assertEq(imd.allowance(address(treasury), Protocol.INTAKE), 0);
        assertEq(imd.balanceOf(address(treasury)), 0.5 ether);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.commission(1, bytes("{\"idea\":\"one\"}"));
    }

    function test_failedRequestRollsBack() public {
        _twoWinners();
        imd.mint(address(treasury), 0.5 ether);
        intake.setReject(true);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert("intake rejected");
        treasury.commission(1, bytes("{\"idea\":\"one\"}"));
        (bytes32 id,) = treasury.requestOf(1);
        assertEq(id, 0);
        assertEq(imd.balanceOf(address(treasury)), 0.5 ether);
        assertEq(imd.allowance(address(treasury), Protocol.INTAKE), 0);
        intake.setReject(false);
        _commission();
    }

    function test_resultAuthenticatedOneShotTruncatedAndUnder200k() public {
        _twoWinners();
        bytes32 id = _commission();
        bytes32 hash = keccak256("result");
        vm.expectRevert(MediciTreasury.Unauthorized.selector);
        treasury.onResult(id, hash, "uri");
        assertFalse(intake.result(address(treasury), bytes32(uint256(3)), hash, "uri"));
        bytes memory uriBytes = new bytes(180);
        for (uint256 i; i < uriBytes.length; ++i) {
            uriBytes[i] = bytes1(uint8(65 + i % 26));
        }
        string memory uri = string(uriBytes);
        vm.cool(address(treasury));
        assertTrue(intake.result(address(treasury), id, hash, uri));
        (bytes32 storedId, bytes32 storedHash, string memory storedUri) = treasury.resultOf(1);
        assertEq(storedId, id);
        assertEq(storedHash, hash);
        assertEq(bytes(storedUri).length, 96);
        (bytes32 live,) = treasury.requestOf(1);
        assertEq(live, 0);
        assertFalse(intake.result(address(treasury), id, hash, "again"));
        assertFalse(intake.failure(address(treasury), id));
    }

    function test_failurePromotesRunnerWithOwnBountyAndUnder200k() public {
        _twoWinners();
        bytes32 id = _commission();
        vm.cool(address(treasury));
        assertTrue(intake.failure(address(treasury), id));
        (uint8 status, uint256 winner, uint256 runner, uint256 bounty,, uint64 deadline,) = treasury.epochResult(1);
        assertEq(status, 1);
        assertEq(winner, 2);
        assertEq(runner, 0);
        assertEq(bounty, 0.01115 ether);
        assertEq(deadline, block.timestamp + 14 days);
        assertEq(treasury.escrowed(), bounty);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.commission(1, bytes("{\"idea\":\"one\"}"));
        imd.mint(address(treasury), 0.5 ether);
        vm.prank(Protocol.KEEPER);
        treasury.commission(1, bytes("{\"idea\":\"two\"}"));
        (bytes32 next,) = treasury.requestOf(1);
        assertTrue(next != id);
        vm.cool(address(treasury));
        assertTrue(intake.failure(address(treasury), next));
        (status,,,,,,) = treasury.epochResult(1);
        assertEq(status, 3);
        assertEq(treasury.escrowed(), 0);
    }

    function test_promotionClearsPreviousResultMetadata() public {
        _twoWinners();
        bytes32 id = _commission();
        assertTrue(intake.result(address(treasury), id, keccak256("old"), "ipfs://old-winner"));
        vm.warp(OPEN + 21 days);
        treasury.lapse(1);
        (bytes32 storedId, bytes32 hash, string memory uri) = treasury.resultOf(1);
        assertEq(storedId, 0);
        assertEq(hash, 0);
        assertEq(uri, "");
    }

    function test_lapseCancelsRequestAndSecondLapseReturnsEscrowWithoutIncome() public {
        _twoWinners();
        bytes32 id = _commission();
        uint256 oldIncome = treasury.income(2);
        vm.expectRevert(MediciTreasury.TooEarly.selector);
        treasury.lapse(1);
        vm.warp(OPEN + 21 days);
        treasury.lapse(1);
        assertFalse(intake.result(address(treasury), id, 0, "late"));
        (uint8 status, uint256 winner,,,, uint64 deadline,) = treasury.epochResult(1);
        assertEq(status, 1);
        assertEq(winner, 2);
        assertEq(deadline, OPEN + 35 days);
        assertEq(treasury.income(2), oldIncome);
        vm.warp(deadline);
        treasury.lapse(1);
        (status,,,,,,) = treasury.epochResult(1);
        assertEq(status, 3);
        assertEq(treasury.escrowed(), 0);
        assertEq(treasury.buybackReserved(), 4 ether);
    }

    function test_skipBeforeCommissionAndRunnerQuorum() public {
        _proposal(alice, bytes("one"));
        _proposal(bob, bytes("two"));
        _vote(alice, 1, 1, 2_000_000 ether);
        _donate(1 ether);
        vm.warp(treasury.epochEnd(1));
        treasury.settle(1);
        vm.expectRevert(MediciTreasury.Unauthorized.selector);
        treasury.skip(1, "reason");
        vm.prank(Protocol.KEEPER);
        treasury.skip(1, "not suitable");
        (uint8 status,,,,,,) = treasury.epochResult(1);
        assertEq(status, 4);
        assertEq(treasury.escrowed(), 0);
    }

    function test_recordLaunchAndBackerDistribution() public {
        _twoWinners();
        _commission();
        MockToken asset = new MockToken();
        uint256 oldBalance = alice.balance;
        _record(77, asset, false);
        (uint8 status,,, uint256 bounty, uint64 number,, string memory jobId) = treasury.epochResult(1);
        assertEq(status, 2);
        assertEq(bounty, 0);
        assertEq(number, 77);
        assertEq(jobId, "job-1");
        assertEq(alice.balance - oldBalance, 0.016 ether);
        assertEq(treasury.claimable(1, alice), 50 ether);
        assertEq(treasury.claimable(1, bob), 0);
        vm.prank(bob);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.claimBacker(1);
        vm.prank(alice);
        treasury.claimBacker(1);
        assertEq(asset.balanceOf(alice), 50 ether);
        assertEq(treasury.reservedToken(address(asset)), 0);
        vm.prank(alice);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.claimBacker(1);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.recordCommission(1, 77, "duplicate");
    }

    function test_projectFactoryAndReserveSurvivesHarvest() public {
        _twoWinners();
        _commission();
        MockToken asset = new MockToken();
        _record(78, asset, true);
        vm.deal(address(projectFactory), 1 ether);
        asset.mint(address(projectFactory), 7 ether);
        projectFactory.seed(78, 0.1 ether, 7 ether);
        treasury.harvest(78);
        assertEq(asset.balanceOf(address(treasury)), 50 ether);
        assertEq(asset.balanceOf(Protocol.DEAD), 7 ether);
        assertEq(treasury.claimable(1, alice), 50 ether);
        assertEq(projectFactory.claims(), 1);
        assertEq(projectFactory.withdrawals(), 2);
        vm.expectRevert(MediciTreasury.TooEarly.selector);
        treasury.burnUnclaimed(1);
        (,,, uint64 until) = treasury.backerShare(1);
        vm.warp(until);
        assertEq(treasury.claimable(1, alice), 0);
        treasury.burnUnclaimed(1);
        assertEq(asset.balanceOf(Protocol.DEAD), 57 ether);
        assertEq(treasury.reservedToken(address(asset)), 0);
        (,, uint256 claimed,) = treasury.backerShare(1);
        assertEq(claimed, 0);
        vm.expectRevert(MediciTreasury.WrongState.selector);
        treasury.burnUnclaimed(1);
    }

    function test_recordRejectsWrongRequesterMissingShareAndUnknownHarvest() public {
        _twoWinners();
        _commission();
        MockToken asset = new MockToken();
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(asset)), 12_500, 60, IHooks(address(0)));
        launchFactory.register(77, k, alice);
        asset.mint(address(this), 1000 ether);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.recordCommission(1, 77, "job");
        launchFactory.register(77, k, address(treasury));
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.recordCommission(1, 77, "job");
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.harvest(77);
    }

    function _contractProposerWins() internal returns (RefusingProposer proposer, uint256 bounty) {
        proposer = new RefusingProposer(token, treasury);
        token.transfer(address(proposer), 5_000_000 ether);
        proposer.proposeAndVote(bytes("{\"idea\":\"one\"}"));
        _donate(1 ether);
        vm.warp(treasury.epochEnd(1));
        treasury.settle(1);
        (,,, bounty,,,) = treasury.epochResult(1);
        assertGt(bounty, 0);
        assertEq(treasury.escrowed(), bounty);
        _commission();
    }

    function test_failedBountyIsKeptByTreasuryAsFreeETH() public {
        (RefusingProposer proposer, uint256 bounty) = _contractProposerWins();
        uint256 freeBefore = treasury.freeETH();
        MockToken asset = new MockToken();
        _eligiblePosition(launchFactory, 79, asset);
        vm.prank(Protocol.KEEPER);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit MediciTreasury.BountyPaid(1, address(proposer), bounty, false);
        treasury.recordCommission(1, 79, "job-1");
        (uint8 status,,, uint256 unpaid,,,) = treasury.epochResult(1);
        assertEq(status, 2);
        assertEq(unpaid, 0);
        assertEq(address(proposer).balance, 0);
        assertEq(treasury.escrowed(), 0);
        assertEq(treasury.freeETH(), freeBefore + bounty);
        assertEq(treasury.claimable(1, address(proposer)), 50 ether);
    }

    function test_bountyPayoutCannotReenter() public {
        (RefusingProposer proposer, uint256 bounty) = _contractProposerWins();
        proposer.acceptAndReenter();
        MockToken asset = new MockToken();
        _record(79, asset, false);
        assertEq(address(proposer).balance, bounty);
        assertEq(treasury.escrowed(), 0);
        assertFalse(proposer.reentrySucceeded());
        assertEq(treasury.claimable(1, address(proposer)), 50 ether);
    }

    function _eligiblePosition(MockFactory f, uint64 n, MockToken asset) internal {
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(asset)), 12_500, 60, IHooks(address(0)));
        f.register(n, k, address(treasury));
        asset.mint(address(this), 950 ether);
        asset.mint(address(treasury), 50 ether);
    }

    function _winEpoch(uint256 e, bytes memory brief) internal {
        _proposal(alice, brief);
        _vote(alice, e, 1, 3_000_000 ether);
        _donate(1 ether);
        vm.warp(treasury.epochEnd(e));
        treasury.settle(e);
        imd.mint(address(treasury), 0.5 ether);
        vm.prank(Protocol.KEEPER);
        treasury.commission(e, brief);
    }

    function test_sameLaunchNumberOnEachFactoryIsRecordedAndHarvestedSeparately() public {
        _winEpoch(1, bytes("one"));
        MockToken assetA = new MockToken();
        _eligiblePosition(launchFactory, 77, assetA);
        vm.prank(Protocol.KEEPER);
        vm.expectEmit(true, true, true, true, address(treasury));
        emit MediciTreasury.Recorded(1, Protocol.LAUNCH_FACTORY, 77, "job-1");
        treasury.recordCommission(1, 77, "job-1");
        (address factory, uint64 number) = treasury.launchOf(1);
        assertEq(factory, Protocol.LAUNCH_FACTORY);
        assertEq(number, 77);

        vm.warp(treasury.epochEnd(1) + 1);
        _winEpoch(2, bytes("two"));
        MockToken assetB = new MockToken();
        _eligiblePosition(projectFactory, 77, assetB);
        vm.prank(Protocol.KEEPER);
        treasury.recordCommission(2, 77, "job-2");
        (uint8 status,,,, uint64 recorded,,) = treasury.epochResult(2);
        assertEq(status, 2);
        assertEq(recorded, 77);
        (factory,) = treasury.launchOf(2);
        assertEq(factory, Protocol.PROJECT_FACTORY);
        assertEq(treasury.launchToken(Protocol.LAUNCH_FACTORY, 77), address(assetA));
        assertEq(treasury.launchToken(Protocol.PROJECT_FACTORY, 77), address(assetB));
        (address shareToken,,,) = treasury.backerShare(2);
        assertEq(shareToken, address(assetB));
        assertEq(treasury.claimable(2, alice), 50 ether);

        // Both positions are harvested by the one number; each burns only its own surplus.
        assetA.mint(address(launchFactory), 3 ether);
        launchFactory.seed(77, 0, 3 ether);
        assetB.mint(address(projectFactory), 4 ether);
        projectFactory.seed(77, 0, 4 ether);
        treasury.harvest(77);
        assertEq(assetA.balanceOf(Protocol.DEAD), 3 ether);
        assertEq(assetB.balanceOf(Protocol.DEAD), 4 ether);
        assertEq(assetA.balanceOf(address(treasury)), 50 ether);
        assertEq(assetB.balanceOf(address(treasury)), 50 ether);

        // A recorded number cannot be recorded again on the same factory.
        vm.warp(treasury.epochEnd(2) + 1);
        _winEpoch(3, bytes("three"));
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.recordCommission(3, 77, "job-3");
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.recordCommissionAt(3, Protocol.PROJECT_FACTORY, 77, "job-3");
    }

    function test_ambiguousNumberNeedsExplicitFactory() public {
        _winEpoch(1, bytes("one"));
        MockToken assetA = new MockToken();
        MockToken assetB = new MockToken();
        _eligiblePosition(launchFactory, 5, assetA);
        _eligiblePosition(projectFactory, 5, assetB);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.AmbiguousLaunch.selector);
        treasury.recordCommission(1, 5, "job");
        vm.expectRevert(MediciTreasury.Unauthorized.selector);
        treasury.recordCommissionAt(1, Protocol.PROJECT_FACTORY, 5, "job");
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.recordCommissionAt(1, alice, 5, "job");
        vm.prank(Protocol.KEEPER);
        treasury.recordCommissionAt(1, Protocol.PROJECT_FACTORY, 5, "job");
        (address factory,) = treasury.launchOf(1);
        assertEq(factory, Protocol.PROJECT_FACTORY);
        (address shareToken,,,) = treasury.backerShare(1);
        assertEq(shareToken, address(assetB));
        // Once one is recorded the other is no longer ambiguous.
        vm.warp(treasury.epochEnd(1) + 1);
        _winEpoch(2, bytes("two"));
        vm.prank(Protocol.KEEPER);
        treasury.recordCommission(2, 5, "job-2");
        (factory,) = treasury.launchOf(2);
        assertEq(factory, Protocol.LAUNCH_FACTORY);
    }

    function test_keeperBudgetFreeETHAndEpochReset() public {
        _donate(1 ether);
        vm.expectRevert(MediciTreasury.Unauthorized.selector);
        treasury.keeperWithdraw(1);
        vm.prank(Protocol.KEEPER);
        treasury.keeperWithdraw(0.006 ether);
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.keeperWithdraw(0.005 ether);
        vm.prank(Protocol.KEEPER);
        treasury.keeperWithdraw(0.004 ether);
        vm.warp(treasury.epochEnd(1));
        vm.prank(Protocol.KEEPER);
        treasury.keeperWithdraw(0.01 ether);
        assertEq(Protocol.KEEPER.balance, 0.02 ether);
        assertEq(treasury.buybackReserved(), 0.4 ether);
    }

    function test_streamsUnlockIndependentlyOutOfOrderAndCarry() public {
        _donate(1 ether);
        vm.warp(OPEN + 7 days);
        _donate(2 ether);
        vm.warp(OPEN + 14 days);
        treasury.settle(2);
        (uint256 unlocked, uint256 tip) = treasury.buybackChunk();
        assertEq(unlocked, 0);
        assertEq(tip, 0);
        vm.warp(block.timestamp + 12 hours);
        (unlocked, tip) = treasury.buybackChunk();
        assertEq(unlocked, 0.4 ether);
        assertEq(tip, 0.002 ether);
        treasury.settle(1);
        vm.warp(OPEN + 15 days);
        (unlocked,) = treasury.buybackChunk();
        assertEq(unlocked, 1 ether);
        vm.warp(OPEN + 15 days + 12 hours);
        (unlocked,) = treasury.buybackChunk();
        assertEq(unlocked, 1.2 ether);
        assertEq(treasury.buybackReserved(), 1.2 ether);
    }

    function testFuzz_backerProRata(uint96 otherVotes) public {
        uint256 amount = bound(otherVotes, 1, 30_000_000 ether);
        _proposal(alice, bytes("{\"idea\":\"one\"}"));
        _vote(alice, 1, 1, 3_000_000 ether);
        _vote(bob, 1, 1, amount);
        vm.warp(treasury.epochEnd(1));
        treasury.settle(1);
        _commission();
        MockToken asset = new MockToken();
        _record(80, asset, false);
        uint256 a = treasury.claimable(1, alice);
        uint256 b = treasury.claimable(1, bob);
        assertLe(a + b, 50 ether);
        assertLe(50 ether - a - b, 1);
        vm.prank(alice);
        treasury.claimBacker(1);
        if (b != 0) {
            vm.prank(bob);
            treasury.claimBacker(1);
        }
        assertEq(treasury.reservedToken(address(asset)), 50 ether - a - b);
    }
}
