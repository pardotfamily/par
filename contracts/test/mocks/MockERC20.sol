// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Takes a 1% cut on every transfer, to exercise the curve's strict
/// quote-receipt check.
contract MockFeeOnTransferERC20 is MockERC20 {
    constructor() MockERC20("FeeOnTransfer", "FOT", 18) {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 burn = value / 100;
            super._update(from, address(0xdead), burn);
            value -= burn;
        }
        super._update(from, to, value);
    }
}

/// @dev Reverts on decimals(), to exercise the factory's unreadable-scale rejection.
contract MockNoDecimalsERC20 {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function decimals() external pure returns (uint8) {
        revert("no decimals");
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}
