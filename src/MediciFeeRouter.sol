// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Protocol, ILaunchFactory, IMediciTreasury} from "./Protocol.sol";

contract MediciFeeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable hook;
    address public immutable token;
    IMediciTreasury public immutable treasury;
    uint64 public launchNumber;
    bool public bound;
    event LaunchNumberSet(uint64 indexed launchNumber);
    event Harvested(uint64 indexed launchNumber, uint256 eth, uint256 burned);
    event TeamPaid(address indexed team, uint256 amount);
    event TeamPaymentDeferred(address indexed team, uint256 amount);
    error InvalidLaunch();
    error TransferFailed();

    constructor(address hook_, address token_, IMediciTreasury treasury_) {
        if (hook_ == address(0) || token_ == address(0) || address(treasury_) == address(0)) revert InvalidLaunch();
        hook = hook_;
        token = token_;
        treasury = treasury_;
    }

    function setLaunchNumber(uint64 n) external {
        if (bound) revert InvalidLaunch();
        (PoolKey memory key,,,) = ILaunchFactory(Protocol.LAUNCH_FACTORY).positionOf(n);
        if (address(key.hooks) != hook) revert InvalidLaunch();
        bound = true;
        launchNumber = n;
        emit LaunchNumberSet(n);
    }

    function harvest() external nonReentrant {
        if (!bound) revert InvalidLaunch();
        ILaunchFactory factory = ILaunchFactory(Protocol.LAUNCH_FACTORY);
        (PoolKey memory key,,, address requester) = factory.positionOf(launchNumber);
        if (requester != address(this) || address(key.hooks) != hook) revert InvalidLaunch();
        factory.claimFees(launchNumber);
        factory.withdraw(address(this), key.currency0);
        factory.withdraw(address(this), key.currency1);
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount != 0) {
            IERC20(token).safeTransfer(address(treasury), amount);
            treasury.burnDeposited();
        }
        // A TEAM that rejects ETH must not undo the burn: the ETH waits here for payTeam().
        uint256 eth = _payTeam(false);
        emit Harvested(launchNumber, eth, amount);
    }

    /// @notice Sends every ETH held here to the current TEAM. Anyone may call it.
    function payTeam() external nonReentrant {
        _payTeam(true);
    }

    function _payTeam(bool strict) internal returns (uint256 eth) {
        eth = address(this).balance;
        if (eth == 0) return 0;
        address recipient = treasury.team();
        (bool ok,) = recipient.call{value: eth}("");
        if (ok) {
            emit TeamPaid(recipient, eth);
            return eth;
        }
        if (strict) revert TransferFailed();
        emit TeamPaymentDeferred(recipient, eth);
        return 0;
    }
    receive() external payable {}
}
