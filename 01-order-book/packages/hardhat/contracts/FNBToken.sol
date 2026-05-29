// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FNBToken - FNB eBucks-style reward token
contract FNBToken is ERC20 {
    /// @notice Creates FNBT and gives the full supply to whoever deploys the contract.
    /// @param initialSupply How many tokens to create (tests use 1,000,000 with 18 decimals).
    constructor(uint256 initialSupply) ERC20("FNB Token", "FNBT") {
        _mint(msg.sender, initialSupply);
    }
}