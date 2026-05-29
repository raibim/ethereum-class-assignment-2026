// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title PNPToken - Pick n Pay reward points
contract PNPToken is ERC20 {
    /// @notice Creates PNPT and gives the full supply to whoever deploys the contract.
    /// @param initialSupply How many tokens to create (tests use 1,000,000 with 18 decimals).
    constructor(uint256 initialSupply) ERC20("PNP Token", "PNPT") {
        _mint(msg.sender, initialSupply);
    }
}