// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MediciTreasury} from "./MediciTreasury.sol";
import {MediciFeeRouter} from "./MediciFeeRouter.sol";
import {IMediciHook, IMediciTreasury} from "./Protocol.sol";

/// @notice Native ETH fees, immutable companions and a historical arithmetic price accumulator.
contract MediciHook is ReentrancyGuard {
    using StateLibrary for IPoolManager;
    IPoolManager public immutable poolManager;
    address public immutable token;
    MediciTreasury public immutable treasury;
    MediciFeeRouter public immutable feeRouter;
    uint64 public openedAt;
    uint256 public teamOwed;
    uint256 public treasuryOwed;
    PoolKey private key;
    bool private redeeming;

    struct Observation {
        uint64 at;
        uint192 spot;
        uint256 cumulative;
    }
    Observation[] public observations;
    bytes32 private constant FEE_SLOT = keccak256("medici.fee");
    bytes32 private constant QUOTED_SLOT = keccak256("medici.quoted");
    error Unauthorized();
    error InvalidPool();
    error NotOpen();
    error InvalidQuote();
    error Quote(uint256 eth);
    error TransferFailed();
    error AmountTooLarge();
    event Opened(uint64 at, uint160 sqrtPriceX96);
    event FeeAccrued(uint256 ethBase, uint256 treasuryFee, uint256 teamFee, bool claims);
    event TeamClaimed(address indexed team, uint256 amount);
    event FeesRedeemed(uint256 amount);
    event TreasuryPaid(uint256 amount);

    constructor(IPoolManager manager_, address token_) {
        if (address(manager_) == address(0) || token_ == address(0)) revert InvalidPool();
        poolManager = manager_;
        token = token_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        treasury = new MediciTreasury(manager_, token_, IMediciHook(address(this)));
        feeRouter = new MediciFeeRouter(address(this), token_, IMediciTreasury(address(treasury)));
    }
    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function poolKey() external view returns (PoolKey memory) {
        if (openedAt == 0) revert NotOpen();
        return key;
    }

    function beforeInitialize(address, PoolKey calldata k, uint160 sqrtPriceX96) external onlyManager returns (bytes4) {
        if (
            openedAt != 0 || Currency.unwrap(k.currency0) != address(0) || Currency.unwrap(k.currency1) != token
                || address(k.hooks) != address(this) || k.fee != 12_500 || k.tickSpacing != 60
        ) revert InvalidPool();
        key = k;
        openedAt = uint64(block.timestamp);
        observations.push(Observation(openedAt, _spot(sqrtPriceX96), 0));
        emit Opened(openedAt, sqrtPriceX96);
        return IHooks.beforeInitialize.selector;
    }

    function buyFeeBps() public view returns (uint256) {
        if (openedAt == 0) revert NotOpen();
        uint256 elapsed = block.timestamp - openedAt;
        return elapsed >= 15 minutes ? 200 : 200 + 4_800 * (15 minutes - elapsed) / 15 minutes;
    }

    function _checkPool(PoolKey calldata k) internal view {
        if (openedAt == 0 || PoolId.unwrap(k.toId()) != PoolId.unwrap(key.toId())) revert InvalidPool();
    }

    /// @dev Native ETH can be the specified side. A reverted self-quote observes the actual pool
    /// fill at the caller's limit, without retaining any pool writes, transfers or fee-growth.
    /// We return only that fee; the real trade is executed by PoolManager normally.
    function beforeSwap(address sender, PoolKey calldata k, SwapParams calldata params, bytes calldata)
        external
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(k);
        uint256 fee;
        uint256 quoted;
        if (sender != address(treasury) && (params.amountSpecified < 0) == params.zeroForOne) {
            uint256 rate = params.zeroForOne ? buyFeeBps() : 200;
            uint256 specified =
                params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            if (specified > uint256(uint128(type(int128).max))) revert AmountTooLarge();
            SwapParams memory preview = params;
            uint256 target;
            if (params.zeroForOne) {
                target = FullMath.mulDiv(specified, 10_000, 10_000 + rate);
                // A one-wei input has a zero rounded hook fee; leave it to core.
                if (target == 0 && specified != 0) target = specified;
                fee = specified - target;
                preview.amountSpecified = -int256(target);
            } else {
                target = FullMath.mulDivRoundingUp(specified, 10_000, 10_000 - rate);
                fee = target - specified;
                preview.amountSpecified = int256(target);
            }
            if (target == 0 || target > uint256(uint128(type(int128).max))) revert AmountTooLarge();
            quoted = _quote(k, preview);
            if (quoted < target) fee = quoted * rate / 10_000;
            if (quoted > target || fee > uint256(uint128(type(int128).max))) revert InvalidQuote();
        }
        bytes32 slot = FEE_SLOT;
        bytes32 qslot = QUOTED_SLOT;
        assembly ("memory-safe") {
            tstore(slot, fee)
            tstore(qslot, quoted)
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function _quote(PoolKey calldata k, SwapParams memory params) internal returns (uint256 eth) {
        try this.quoteSwap(k, params) {
            revert InvalidQuote();
        } catch (bytes memory reason) {
            if (reason.length != 36 || bytes4(reason) != Quote.selector) {
                assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
            }
            assembly ("memory-safe") { eth := mload(add(reason, 36)) }
        }
    }

    /// @notice Self-only simulation. Always reverts, including every nested pool write.
    function quoteSwap(PoolKey calldata k, SwapParams calldata params) external {
        if (msg.sender != address(this)) revert Unauthorized();
        BalanceDelta d = poolManager.swap(k, params, "");
        int256 eth = d.amount0();
        revert Quote(uint256(eth < 0 ? -eth : eth));
    }

    function afterSwap(
        address sender,
        PoolKey calldata k,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyManager returns (bytes4, int128) {
        _checkPool(k);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(k.toId());
        _observe(_spot(sqrtPriceX96));
        if (sender == address(treasury)) return (IHooks.afterSwap.selector, 0);
        int256 raw = delta.amount0();
        uint256 ethBase = uint256(raw < 0 ? -raw : raw);
        uint256 rate = params.zeroForOne ? buyFeeBps() : 200;
        bool specified = (params.amountSpecified < 0) == params.zeroForOne;
        uint256 fee;
        if (specified) {
            uint256 quoted;
            bytes32 slot = FEE_SLOT;
            bytes32 qslot = QUOTED_SLOT;
            assembly ("memory-safe") {
                fee := tload(slot)
                quoted := tload(qslot)
                tstore(slot, 0)
                tstore(qslot, 0)
            }
            if (quoted != ethBase) revert InvalidQuote();
            // Specified-side integer budgets may round the fee up by at most two wei: with
            // S * 10_000 = T * (10_000 + rate) + m and m < 10_000 + rate, the budgeted fee
            // (T * rate + m) / 10_000 exceeds floor(T * rate / 10_000) by two whenever
            // m > 10_000, which happens at launch rates above 200 bps. Exact-out sells
            // (m < 10_000 - rate) round up by at most one.
            uint256 exact = ethBase * rate / 10_000;
            if (fee < exact || fee > exact + 2) revert InvalidQuote();
        } else {
            fee = ethBase * rate / 10_000;
        }
        if (fee > uint256(uint128(type(int128).max))) revert AmountTooLarge();
        if (fee != 0) {
            uint256 teamFee = ethBase * 50 / 10_000;
            teamOwed += teamFee;
            treasuryOwed += fee - teamFee;
            bool claims = address(poolManager).balance < fee;
            if (claims) {
                poolManager.mint(address(this), 0, fee);
            } else {
                poolManager.take(Currency.wrap(address(0)), address(this), fee);
                _payTreasury();
            }
            emit FeeAccrued(ethBase, fee - teamFee, teamFee, claims);
        }
        return (IHooks.afterSwap.selector, specified ? int128(0) : int128(int256(fee)));
    }

    function _payTreasury() internal {
        uint256 amount = treasuryOwed;
        if (amount > address(this).balance) amount = address(this).balance;
        if (amount == 0) return;
        treasuryOwed -= amount;
        (bool ok,) = address(treasury).call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit TreasuryPaid(amount);
    }

    /// @notice Converts deferred ERC-6909 ETH claims once the input has been settled.
    function redeemFees() public nonReentrant {
        _redeem();
        _payTreasury();
    }

    function _redeem() internal {
        uint256 amount = poolManager.balanceOf(address(this), 0);
        if (amount == 0) return;
        redeeming = true;
        poolManager.unlock(abi.encode(amount));
        redeeming = false;
        emit FeesRedeemed(amount);
    }

    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        if (!redeeming) revert Unauthorized();
        uint256 amount = abi.decode(data, (uint256));
        poolManager.burn(address(this), 0, amount);
        poolManager.take(Currency.wrap(address(0)), address(this), amount);
        return "";
    }

    function claimTeam() external nonReentrant {
        _redeem();
        _payTreasury();
        uint256 amount = teamOwed;
        teamOwed = 0;
        address recipient = treasury.team();
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit TeamClaimed(recipient, amount);
    }

    function _spot(uint160 sqrtPriceX96) internal pure returns (uint192) {
        uint256 result;
        if (sqrtPriceX96 <= type(uint128).max) {
            result = FullMath.mulDiv(1 ether, 1 << 192, uint256(sqrtPriceX96) * sqrtPriceX96);
        } else {
            uint256 ratioX128 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
            result = FullMath.mulDiv(1 ether, 1 << 128, ratioX128);
        }
        // Sub-wei ETH/token prices have the fixed-point interface's minimum resolution.
        return uint192(result == 0 ? 1 : result);
    }

    function _observe(uint192 spot) internal {
        Observation storage prev = observations[observations.length - 1];
        uint64 now_ = uint64(block.timestamp);
        if (prev.at == now_) {
            prev.spot = spot;
            return;
        }
        uint256 cumulative = prev.cumulative + uint256(prev.spot) * (now_ - prev.at);
        observations.push(Observation(now_, spot, cumulative));
    }

    function cumulativeAt(uint64 at) public view returns (uint256) {
        if (openedAt == 0 || at < openedAt || at > block.timestamp) revert NotOpen();
        uint256 lo;
        uint256 hi = observations.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (observations[mid].at <= at) lo = mid + 1;
            else hi = mid;
        }
        Observation storage o = observations[lo - 1];
        return o.cumulative + uint256(o.spot) * (at - o.at);
    }

    function twap(uint64 start, uint64 end) public view returns (uint256) {
        if (end <= start) revert NotOpen();
        return (cumulativeAt(end) - cumulativeAt(start)) / (end - start);
    }

    function price() external view returns (uint256) {
        if (openedAt == 0) revert NotOpen();
        uint64 end = uint64(block.timestamp);
        // No time has elapsed in the opening second: the average since open is the spot.
        if (end == openedAt) return observations[observations.length - 1].spot;
        uint64 start = end > uint256(openedAt) + 1 days ? end - 1 days : openedAt;
        return twap(start, end);
    }
    receive() external payable {}
}
