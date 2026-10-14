// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Fixture, PoolActor} from "./helpers/Fixtures.sol";
import {MediciHook} from "../src/MediciHook.sol";
import {Protocol} from "../src/Protocol.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";

contract FeeHandler is Test {
    PoolActor public immutable actor;
    MediciHook public immutable hook;
    PoolKey private key;
    uint256 public swaps;

    constructor(PoolActor actor_, MediciHook hook_, PoolKey memory key_) {
        actor = actor_;
        hook = hook_;
        key = key_;
    }

    function trade(bool buy, bool exactIn, uint64 raw) external {
        uint256 amount = buy == exactIn ? bound(raw, 1e10, 0.001 ether) : bound(raw, 1 ether, 1_000 ether);
        actor.swap(
            key,
            buy,
            exactIn ? -int256(amount) : int256(amount),
            buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        swaps++;
    }

    function redeem() external {
        hook.redeemFees();
    }

    function claimTeam() external {
        hook.claimTeam();
    }

    function advance(uint32 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1, 1 hours));
    }
}

contract FeeInvariantTest is Fixture {
    FeeHandler internal handler;
    uint256 internal ethTotal;

    function setUp() public {
        _deployReal(true);
        vm.warp(OPEN + 1 days);
        handler = new FeeHandler(actor, hook, key);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.redeem.selector;
        selectors[2] = handler.claimTeam.selector;
        selectors[3] = handler.advance.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
        ethTotal = address(actor).balance + address(manager).balance + address(hook).balance + address(treasury).balance
            + Protocol.TEAM.balance;
    }

    function invariant_ETHIsConservedAndFeeClaimsFullyBacked() public view {
        assertEq(
            address(actor).balance + address(manager).balance + address(hook).balance + address(treasury).balance
                + Protocol.TEAM.balance,
            ethTotal
        );
        assertEq(address(hook).balance + manager.balanceOf(address(hook), 0), hook.teamOwed() + hook.treasuryOwed());
        assertLe(treasury.buybackReserved() + treasury.escrowed(), address(treasury).balance);
    }

    function invariant_TokenSupplyAndBalancesAreConserved() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        uint256 sum = token.balanceOf(address(this)) + token.balanceOf(address(actor))
            + token.balanceOf(address(manager)) + token.balanceOf(alice) + token.balanceOf(bob);
        assertEq(sum, token.totalSupply());
    }
}

contract BytecodeTest is Fixture {
    function setUp() public {
        _deployReal(false);
    }

    function test_allProductionContractsAreImmutableAndFitDeploymentLimits() public view {
        _check(address(token));
        _check(address(hook));
        _check(address(treasury));
        _check(address(router));
    }

    function _check(address at) internal view {
        bytes memory code = at.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xff && op != 0xf4 && op != 0xf2, "escape opcode");
        }
    }
}
