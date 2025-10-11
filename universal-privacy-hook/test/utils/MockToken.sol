// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Simple token mock to replace the removed Token.sol
contract Token is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 2**255);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}