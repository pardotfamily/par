// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPairPadFeeEscrow} from "./interfaces/ILaunchpadV2.sol";

/**
 * @title PairPadFeeEscrow
 * @notice Claimable balance ledger every launch's fees are paid into. Fees
 * are credited here rather than pushed to their recipients so a recipient
 * that reverts on receive (or an asset that blocks one address) can never
 * take a fee collection down with it.
 *
 * Crediting is deliberately permissionless: native credits carry their own
 * ETH, and token credits are pulled from the caller's balance, so an
 * uninvited credit only ever gives value away. Token credits record the
 * balance delta actually received, so an asset that under-delivers cannot
 * mint claims against other launches' escrowed funds.
 */
contract PairPadFeeEscrow is IPairPadFeeEscrow, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error NativeValueRequired();
    error InsufficientBalance(uint256 requested, uint256 available);
    error TransferFailed();

    event Credited(address indexed recipient, uint256 amount);
    event CreditedToken(address indexed recipient, address indexed token, uint256 amount);
    event Claimed(address indexed recipient, uint256 amount);
    event ClaimedToken(address indexed recipient, address indexed token, uint256 amount);

    mapping(address recipient => uint256 amount) private _nativeBalances;
    mapping(address recipient => mapping(address token => uint256 amount)) private _tokenBalances;

    /**
     * @notice Credits the attached ETH to `recipient`'s claimable balance.
     */
    function credit(address recipient) external payable {
        if (recipient == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert NativeValueRequired();
        _nativeBalances[recipient] += msg.value;
        emit Credited(recipient, msg.value);
    }

    /**
     * @notice Pulls `amount` of `token` from the caller and credits what
     * actually arrived to `recipient`'s claimable balance.
     */
    function creditToken(address recipient, address token, uint256 amount) external {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        _tokenBalances[recipient][token] += received;
        emit CreditedToken(recipient, token, received);
    }

    /**
     * @notice Claims the caller's entire native balance.
     */
    function claim() external returns (uint256 amount) {
        return _claimNative(_nativeBalances[msg.sender]);
    }

    /**
     * @notice Claims `amount` of the caller's native balance.
     */
    function claim(uint256 amount) external returns (uint256) {
        return _claimNative(amount);
    }

    /**
     * @notice Claims the caller's entire balance of `token`.
     */
    function claimToken(address token) external returns (uint256 amount) {
        return _claimToken(token, _tokenBalances[msg.sender][token]);
    }

    /**
     * @notice Claims `amount` of the caller's balance of `token`.
     */
    function claimToken(address token, uint256 amount) external returns (uint256) {
        return _claimToken(token, amount);
    }

    function balanceOf(address recipient) external view returns (uint256) {
        return _nativeBalances[recipient];
    }

    function balanceOfToken(address recipient, address token) external view returns (uint256) {
        return _tokenBalances[recipient][token];
    }

    function _claimNative(uint256 amount) private nonReentrant returns (uint256) {
        uint256 available = _nativeBalances[msg.sender];
        if (amount > available) revert InsufficientBalance(amount, available);
        if (amount == 0) return 0;

        _nativeBalances[msg.sender] = available - amount;
        (bool sent,) = payable(msg.sender).call{value: amount}("");
        if (!sent) revert TransferFailed();
        emit Claimed(msg.sender, amount);
        return amount;
    }

    function _claimToken(address token, uint256 amount) private nonReentrant returns (uint256) {
        uint256 available = _tokenBalances[msg.sender][token];
        if (amount > available) revert InsufficientBalance(amount, available);
        if (amount == 0) return 0;

        _tokenBalances[msg.sender][token] = available - amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit ClaimedToken(msg.sender, token, amount);
        return amount;
    }
}
