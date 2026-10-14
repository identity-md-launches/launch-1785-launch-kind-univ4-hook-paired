// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Fixture, PoolActor} from "./helpers/Fixtures.sol";
import {MediciHook} from "../src/MediciHook.sol";
import {Protocol} from "../src/Protocol.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Vm} from "forge-std/Vm.sol";

contract HookTest is Fixture {
    function setUp() public {
        _deployReal(true);
    }

    function test_tokenSupplyTransferAndNoMint() public {
        assertEq(token.name(), "Medici");
        assertEq(token.symbol(), "MEDICI");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        uint256 balance = token.balanceOf(address(this));
        token.transfer(bob, 17);
        assertEq(token.balanceOf(address(this)), balance - 17);
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1 ether));
        assertFalse(ok);
    }

    function test_permissionsInitializationAndCallbackAuthentication() public {
        assertEq(uint160(address(hook)) & HookFlags.ALL, HookFlags.MEDICI);
        assertEq(hook.openedAt(), OPEN);
        assertTrue(hook.getHookPermissions().beforeInitialize);
        vm.expectRevert(MediciHook.Unauthorized.selector);
        hook.beforeInitialize(address(this), key, Q96);
        vm.expectRevert(MediciHook.Unauthorized.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, Q96), "");
        vm.expectRevert(MediciHook.Unauthorized.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1 ether, Q96), BalanceDeltaLibrary.ZERO_DELTA, "");
        vm.expectRevert(MediciHook.Unauthorized.selector);
        hook.quoteSwap(key, SwapParams(true, -1 ether, Q96));
        vm.expectRevert(MediciHook.Unauthorized.selector);
        hook.unlockCallback(abi.encode(1));
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        manager.initialize(other, Q96);
        vm.prank(address(manager));
        vm.expectRevert(MediciHook.InvalidPool.selector);
        hook.beforeInitialize(address(this), key, Q96);
    }

    function test_feeDecay() public {
        assertEq(hook.buyFeeBps(), 5000);
        vm.warp(OPEN + 450);
        assertEq(hook.buyFeeBps(), 2600);
        vm.warp(OPEN + 900);
        assertEq(hook.buyFeeBps(), 200);
    }

    function test_oneWeiBuyDoesNotChargeARoundedUpWholeInput() public {
        vm.warp(OPEN + 1 days);
        BalanceDelta d = actor.swap(key, true, -1, TickMath.MIN_SQRT_PRICE + 1);
        assertEq(d.amount0(), -1);
        assertEq(hook.teamOwed(), 0);
        assertEq(address(treasury).balance, 0);
    }

    function _trade(bool buy, bool exactIn, uint256 amount, uint160 limit)
        internal
        returns (BalanceDelta d, uint256 base, uint256 fee)
    {
        uint256 oldTeam = hook.teamOwed();
        uint256 oldTreasury = address(treasury).balance;
        vm.recordLogs();
        d = actor.swap(key, buy, exactIn ? -int256(amount) : int256(amount), limit);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 teamFee;
        uint256 treasuryFee;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(hook)
                    && logs[i].topics[0] == keccak256("FeeAccrued(uint256,uint256,uint256,bool)")
            ) {
                (base, treasuryFee, teamFee,) = abi.decode(logs[i].data, (uint256, uint256, uint256, bool));
            }
        }
        fee = treasuryFee + teamFee;
        uint256 rate = buy ? hook.buyFeeBps() : 200;
        assertApproxEqAbs(fee, base * rate / 10_000, 1);
        assertEq(teamFee, base * 50 / 10_000);
        assertEq(hook.teamOwed() - oldTeam, teamFee);
        assertEq(address(treasury).balance - oldTreasury, treasuryFee);
        if (buy) assertEq(uint256(-int256(d.amount0())), base + fee);
        else assertEq(uint128(d.amount0()), base - fee);
    }

    function test_allFourSwapDirections() public {
        vm.warp(OPEN + 1 days);
        (BalanceDelta d,,) = _trade(true, true, 0.01 ether, TickMath.MIN_SQRT_PRICE + 1);
        assertEq(d.amount0(), -int128(0.01 ether));
        (d,,) = _trade(true, false, 10_000 ether, TickMath.MIN_SQRT_PRICE + 1);
        assertEq(d.amount1(), int128(10_000 ether));
        (d,,) = _trade(false, true, 10_000 ether, TickMath.MAX_SQRT_PRICE - 1);
        assertEq(d.amount1(), -int128(10_000 ether));
        (d,,) = _trade(false, false, 0.001 ether, TickMath.MAX_SQRT_PRICE - 1);
        assertEq(d.amount0(), int128(0.001 ether));
    }

    function test_launchFeeSurplusAndTeamClaim() public {
        _trade(true, true, 0.01 ether, TickMath.MIN_SQRT_PRICE + 1);
        uint256 owed = hook.teamOwed();
        uint256 previous = Protocol.TEAM.balance;
        hook.claimTeam();
        assertEq(Protocol.TEAM.balance - previous, owed);
        assertEq(hook.teamOwed(), 0);
    }

    function test_partialFillsUseActualETH() public {
        vm.warp(OPEN + 1 days);
        (BalanceDelta d, uint256 base,) = _trade(true, true, 1 ether, TickMath.getSqrtPriceAtTick(184200));
        assertLt(uint256(-int256(d.amount0())), 1 ether);
        assertLt(base, 0.01 ether);
        (d, base,) = _trade(false, false, 1 ether, TickMath.getSqrtPriceAtTick(184210));
        assertLt(uint128(d.amount0()), 1 ether);
        assertLt(base, 0.01 ether);
        _trade(true, false, 10_000_000 ether, TickMath.getSqrtPriceAtTick(184190));
        _trade(false, true, 10_000_000 ether, TickMath.getSqrtPriceAtTick(184200));
    }

    function test_twapHistoryExcludesSameBlockManipulation() public {
        vm.warp(OPEN + 1 days);
        assertEq(treasury.price(), 1e10);
        uint256 oldPrice = treasury.price();
        actor.swap(key, true, -int256(0.5 ether), TickMath.MIN_SQRT_PRICE + 1);
        assertEq(treasury.price(), oldPrice);
        (, uint192 spot,) = hook.observations(1);
        vm.warp(OPEN + 36 hours);
        assertEq(treasury.price(), (oldPrice + spot) / 2);
        assertEq(hook.twap(OPEN, OPEN + 1 days), oldPrice);
        vm.warp(OPEN + 3 days);
        assertEq(treasury.price(), spot);
    }

    function test_factoryZeroLiquidityCollectAlwaysWorks() public {
        vm.warp(OPEN + 1 days);
        actor.swap(key, true, -int256(0.1 ether), TickMath.MIN_SQRT_PRICE + 1);
        uint256 teamBefore = hook.teamOwed();
        BalanceDelta d = actor.modify(key, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 0);
        assertGt(d.amount0(), 0);
        assertEq(hook.teamOwed(), teamBefore);
    }

    function testFuzz_launchFeeUsesSettledPartialFill(uint16 elapsed, bool exactInput) public {
        vm.warp(OPEN + bound(elapsed, 0, 899));
        uint256 amount = exactInput ? 1 ether : 10_000_000 ether;
        (BalanceDelta d, uint256 base,) = _trade(true, exactInput, amount, TickMath.getSqrtPriceAtTick(184200));
        assertLt(base, 0.01 ether);
        assertGt(d.amount1(), 0);
    }

    function testFuzz_feeAccounting(bool buy, bool exactIn, uint80 raw) public {
        vm.warp(OPEN + 1 days);
        uint256 amount = (buy == exactIn) ? bound(raw, 1e10, 0.1 ether) : bound(raw, 1 ether, 100_000 ether);
        _trade(buy, exactIn, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }
}

contract FreshManagerTest is Fixture {
    function test_exactOutputBuyWithNoInitialNativeBalance() public {
        _deployReal(false);
        actor.modify(key, 180000, 184200, 1e22);
        assertEq(address(manager).balance, 0);
        vm.warp(OPEN + 1 days);
        BalanceDelta d = actor.swap(key, true, int256(10_000 ether), TickMath.MIN_SQRT_PRICE + 1);
        assertEq(d.amount1(), int128(10_000 ether));
        assertGt(manager.balanceOf(address(hook), 0), 0);
        hook.claimTeam();
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertGt(address(treasury).balance, 0);
        assertGt(Protocol.TEAM.balance, 0);
    }

    function test_buyWithNoETHInManagerMintsAndRedeemsClaims() public {
        _deployReal(false);
        // Upper tick below the current price: the position initially contains only token1.
        actor.modify(key, 180000, 184200, 1e22);
        assertEq(address(manager).balance, 0);
        vm.warp(OPEN + 1 days);
        actor.swap(key, true, -int256(0.01 ether), TickMath.MIN_SQRT_PRICE + 1);
        uint256 claims = manager.balanceOf(address(hook), 0);
        assertGt(claims, 0);
        assertEq(address(treasury).balance, 0);
        assertEq(claims, hook.teamOwed() + hook.treasuryOwed());
        hook.redeemFees();
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertGt(address(treasury).balance, 0);
        uint256 owed = hook.teamOwed();
        hook.claimTeam();
        assertEq(Protocol.TEAM.balance, owed);
    }
}
