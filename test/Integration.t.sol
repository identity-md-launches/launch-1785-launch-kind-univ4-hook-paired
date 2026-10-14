// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Fixture, MockToken, PoolActor} from "./helpers/Fixtures.sol";
import {MediciTreasury} from "../src/MediciTreasury.sol";
import {MediciFeeRouter} from "../src/MediciFeeRouter.sol";
import {Protocol} from "../src/Protocol.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract RejectETH {
    receive() external payable {
        revert("reject");
    }
}

contract IntegrationTest is Fixture {
    function setUp() public {
        _deployReal(true);
    }

    function _imdPool(uint160 sqrtPrice) internal {
        PoolKey memory k =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(Protocol.IMD), 10000, 200, IHooks(address(0)));
        manager.initialize(k, sqrtPrice);
        imd.mint(address(actor), 10_000 ether);
        actor.modify(k, TickMath.minUsableTick(200), TickMath.maxUsableTick(200), 10 ether);
    }

    function test_commissionBuysExactlyHalfIMDThenPaysIntake() public {
        _imdPool(Q96 * 10);
        _twoWinners();
        imd.mint(address(treasury), 0.1 ether);
        uint256 ethBefore = address(treasury).balance;
        uint256 teamOwed = hook.teamOwed();
        vm.prank(Protocol.KEEPER);
        treasury.commission(1, bytes("{\"idea\":\"one\"}"));
        assertEq(imd.balanceOf(address(treasury)), 0.1 ether);
        assertEq(imd.balanceOf(Protocol.INTAKE), 0.5 ether);
        assertGt(ethBefore - address(treasury).balance, 0);
        assertLe(ethBefore - address(treasury).balance, 0.03 ether);
        assertEq(hook.teamOwed(), teamOwed);
        assertEq(treasury.buybackReserved(), 4 ether);
    }

    function test_commissionIMDPriceCeilingRevertsAtomically() public {
        _imdPool(Q96);
        _twoWinners();
        uint256 beforeBalance = address(treasury).balance;
        vm.prank(Protocol.KEEPER);
        vm.expectRevert(MediciTreasury.Slippage.selector);
        treasury.commission(1, bytes("{\"idea\":\"one\"}"));
        assertEq(address(treasury).balance, beforeBalance);
        assertEq(imd.balanceOf(address(treasury)), 0);
        (bytes32 request,) = treasury.requestOf(1);
        assertEq(request, 0);
    }

    function test_commissionUsesSmallFreeBalanceWithoutTouchingEscrow() public {
        _imdPool(Q96 * 10);
        vm.warp(OPEN + 1 days);
        _proposal(alice, bytes("{\"idea\":\"one\"}"));
        _vote(alice, 1, 1, 3_000_000 ether);
        _donate(0.02 ether);
        vm.warp(treasury.epochEnd(1));
        treasury.settle(1);
        assertLt(treasury.freeETH(), 0.03 ether);
        vm.prank(Protocol.KEEPER);
        treasury.commission(1, bytes("{\"idea\":\"one\"}"));
        assertGe(address(treasury).balance, treasury.escrowed() + treasury.buybackReserved());
    }

    function test_buybackUsesOnlyUnlockedBudgetBurnsAndExemptsHookFee() public {
        _twoWinners();
        vm.warp(OPEN + 7 days + 12 hours);
        (uint256 unlocked,) = treasury.buybackChunk();
        assertEq(unlocked, 2 ether);
        uint256 oldBurned = treasury.totalBurned();
        uint256 oldTeam = hook.teamOwed();
        uint256 oldCaller = bob.balance;
        uint256 oldEth = address(treasury).balance;
        vm.prank(bob);
        treasury.buyback(0.01 ether);
        assertEq(oldEth - address(treasury).balance, 0.01 ether);
        assertEq(bob.balance - oldCaller, 0.00005 ether);
        assertEq(hook.teamOwed(), oldTeam);
        uint256 burned = treasury.totalBuybackBurned();
        assertGt(burned, 0);
        assertEq(treasury.totalBurned(), oldBurned + burned);
        assertEq(token.balanceOf(address(treasury)), 0);
        (unlocked,) = treasury.buybackChunk();
        assertEq(unlocked, 1.99 ether);
        assertEq(treasury.buybackReserved(), 3.99 ether);
    }

    function test_buybackBeforeUnlockAndManipulatedSpotRefuse() public {
        _twoWinners();
        vm.expectRevert(MediciTreasury.InvalidInput.selector);
        treasury.buyback(0.01 ether);
        vm.warp(OPEN + 8 days);
        actor.swap(key, true, -int256(0.5 ether), TickMath.MIN_SQRT_PRICE + 1);
        uint256 spentBefore = treasury.buybackSpent();
        uint256 burnedBefore = treasury.totalBuybackBurned();
        vm.expectRevert(MediciTreasury.Slippage.selector);
        treasury.buyback(0.01 ether);
        assertEq(treasury.buybackSpent(), spentBefore);
        assertEq(treasury.totalBuybackBurned(), burnedBefore);
    }

    function test_routerBindsOnceOnlyMatchingHookAndRequiresRequester() public {
        vm.expectRevert(MediciFeeRouter.InvalidLaunch.selector);
        router.harvest();
        vm.expectRevert(MediciFeeRouter.InvalidLaunch.selector);
        router.setLaunchNumber(44);
        launchFactory.register(44, key, alice);
        router.setLaunchNumber(44);
        assertEq(router.launchNumber(), 44);
        vm.expectRevert(MediciFeeRouter.InvalidLaunch.selector);
        router.setLaunchNumber(44);
        vm.expectRevert(MediciFeeRouter.InvalidLaunch.selector);
        router.harvest();
        vm.prank(alice);
        launchFactory.setRequester(44, address(router));
        vm.deal(address(launchFactory), 1 ether);
        token.transfer(address(launchFactory), 1_000 ether);
        launchFactory.seed(44, 0.1 ether, 1_000 ether);
        uint256 beforeTeam = Protocol.TEAM.balance;
        router.harvest();
        assertEq(Protocol.TEAM.balance - beforeTeam, 0.1 ether);
        assertEq(treasury.totalBurned(), 1_000 ether);
        assertEq(token.balanceOf(Protocol.DEAD), 1_000 ether);
        assertEq(launchFactory.withdrawals(), 2);
    }

    function test_teamRotationAffectsHookAndRouter() public {
        vm.warp(OPEN + 1 days);
        actor.swap(key, true, -int256(0.01 ether), TickMath.MIN_SQRT_PRICE + 1);
        uint256 owed = hook.teamOwed();
        vm.prank(Protocol.TEAM);
        treasury.setTeam(bob);
        hook.claimTeam();
        assertEq(bob.balance, owed);
        assertEq(Protocol.TEAM.balance, 0);
        launchFactory.register(45, key, address(router));
        router.setLaunchNumber(45);
        vm.deal(address(router), 0.1 ether);
        router.harvest();
        assertEq(bob.balance, owed + 0.1 ether);
    }

    function test_rejectingTeamCannotBlockTradingAndClaimRemainsOwed() public {
        RejectETH receiver = new RejectETH();
        vm.prank(Protocol.TEAM);
        treasury.setTeam(address(receiver));
        vm.warp(OPEN + 1 days);
        actor.swap(key, true, -int256(0.01 ether), TickMath.MIN_SQRT_PRICE + 1);
        uint256 owed = hook.teamOwed();
        assertGt(owed, 0);
        vm.expectRevert();
        hook.claimTeam();
        assertEq(hook.teamOwed(), owed);
        actor.swap(key, false, -int256(1_000 ether), TickMath.MAX_SQRT_PRICE - 1);
        assertGt(hook.teamOwed(), owed);
    }

    function test_factoryHarvestKeepsIMDAndOnlyBurnsSurplusLaunchTokens() public {
        _twoWinners();
        _commission();
        MockToken asset = new MockToken();
        PoolKey memory k =
            PoolKey(Currency.wrap(address(asset)), Currency.wrap(Protocol.IMD), 12500, 60, IHooks(address(0)));
        projectFactory.register(81, k, address(treasury));
        asset.mint(address(this), 950 ether);
        asset.mint(address(treasury), 50 ether);
        vm.prank(Protocol.KEEPER);
        treasury.recordCommission(1, 81, "job-81");
        asset.mint(address(projectFactory), 10 ether);
        imd.mint(address(projectFactory), 0.5 ether);
        projectFactory.seed(81, 10 ether, 0.5 ether);
        treasury.harvest(81);
        assertEq(asset.balanceOf(address(treasury)), 50 ether);
        assertEq(asset.balanceOf(Protocol.DEAD), 10 ether);
        assertEq(imd.balanceOf(address(treasury)), 0.5 ether);
    }
}
