// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The entire immutable launch supply is minted to the launch factory.
contract MediciToken is ERC20 {
    constructor() ERC20("Medici", "MEDICI") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
