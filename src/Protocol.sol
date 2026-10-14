// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

library Protocol {
    address internal constant LAUNCH_FACTORY = 0x12C63b581d07093F6126bc02263c58f7EadaA96F;
    address internal constant PROJECT_FACTORY = 0xfF03410d0Fe5fa8f7F59F743de35E333D9857120;
    address internal constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant TEAM = 0x01670a5CfAEEaEE388cD38085C4ADf1Bad45a1c2;
    address internal constant KEEPER = 0x16578E0dfAFa219f2B0f52095D8206b5c02F8250;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
}

/// @dev ABI verified against both deployed factories, which inherit PoolFees.
interface ILaunchFactory {
    function positionOf(uint64 n)
        external
        view
        returns (PoolKey memory key, int24 lower, int24 upper, address requester);
    function claimFees(uint64 n) external returns (uint256, uint256);
    function withdraw(address account, Currency currency) external;
    function setRequester(uint64 n, address next) external;
}

interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }
    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 failure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32);
}

interface IMediciHook {
    function openedAt() external view returns (uint64);
    function price() external view returns (uint256);
    function twap(uint64 start, uint64 end) external view returns (uint256);
    function poolKey() external view returns (PoolKey memory);
}

interface IMediciTreasury {
    function team() external view returns (address);
    function burnDeposited() external returns (uint256);
}
