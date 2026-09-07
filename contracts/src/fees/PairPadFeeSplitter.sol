// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PairPadFeeSplitter
 * @notice The protocol fee recipient for launches created after it was set on
 * the factories. Every launch snapshots the recipient at creation, so the
 * lockers pay this contract the protocol's quote share of those launches'
 * fees (native ETH and ERC-20s alike), and anyone may split what has
 * arrived: `buybackBps` to the buyback wallet, the rest to the treasury.
 *
 * The factories also send the launch fee to the protocol fee recipient. That
 * fee is the treasury's whole: when the sender of native ETH is one of the
 * factories, `receive` forwards it straight to the treasury instead of
 * leaving it for the split. Should the forward fail, the ETH simply stays
 * and goes out with the next flush; a launch never reverts because of it.
 *
 * There is no owner and nothing to configure: the addresses and the
 * proportion are fixed at deployment. Changing the split means deploying a
 * new splitter and pointing the factories at it, which is visible on chain
 * as `ProtocolFeeRecipientUpdated`.
 *
 * Receiving from the lockers stays trivial (two address compares) so their
 * 50k-gas native transfer never fails; the split itself happens in `flush`,
 * paid by whoever calls it.
 */
contract PairPadFeeSplitter {
    using SafeERC20 for IERC20;

    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Receives `buybackBps` of every flushed asset; buys back and burns $par.
    address public immutable buyback;
    /// @notice Receives the remainder of every flush and the launch fees; protocol operations.
    address public immutable treasury;
    /// @notice Share of every flush that goes to `buyback`, in basis points.
    uint16 public immutable buybackBps;
    /// @notice The single-market factory; its native transfers are launch fees.
    address public immutable factory;
    /// @notice The multi-market factory; its native transfers are launch fees.
    address public immutable multiFactory;

    event Flushed(address indexed asset, uint256 toBuyback, uint256 toTreasury);
    /// @notice A launch fee from a factory passed through to the treasury.
    event LaunchFeeForwarded(address indexed factory, uint256 amount);

    error ZeroAddress();
    error InvalidShare();
    error NativeTransferFailed(address to);

    constructor(address buyback_, address treasury_, uint16 buybackBps_, address factory_, address multiFactory_) {
        if (buyback_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (factory_ == address(0) || multiFactory_ == address(0)) revert ZeroAddress();
        if (buybackBps_ == 0 || buybackBps_ > BASIS_POINTS) revert InvalidShare();
        buyback = buyback_;
        treasury = treasury_;
        buybackBps = buybackBps_;
        factory = factory_;
        multiFactory = multiFactory_;
    }

    receive() external payable {
        if (msg.sender == factory || msg.sender == multiFactory) {
            // Launch fee: the treasury's, whole. The factories call with full
            // gas, so the forward fits; if it fails the ETH waits for a flush.
            (bool ok,) = treasury.call{value: msg.value}("");
            if (ok) emit LaunchFeeForwarded(msg.sender, msg.value);
        }
    }

    /**
     * @notice Splits this contract's whole balance of `asset` (address zero
     * for native ETH). Anyone may call; a no-op when the balance is zero.
     */
    function flush(address asset) external returns (uint256 toBuyback, uint256 toTreasury) {
        return _flush(asset);
    }

    /// @notice `flush` for several assets in one transaction.
    function flushMany(address[] calldata assets) external {
        for (uint256 i = 0; i < assets.length; i++) {
            _flush(assets[i]);
        }
    }

    function _flush(address asset) private returns (uint256 toBuyback, uint256 toTreasury) {
        if (asset == address(0)) {
            uint256 balance = address(this).balance;
            if (balance == 0) return (0, 0);
            toBuyback = (balance * buybackBps) / BASIS_POINTS;
            toTreasury = balance - toBuyback;
            _sendNative(buyback, toBuyback);
            _sendNative(treasury, toTreasury);
        } else {
            IERC20 token = IERC20(asset);
            uint256 balance = token.balanceOf(address(this));
            if (balance == 0) return (0, 0);
            toBuyback = (balance * buybackBps) / BASIS_POINTS;
            toTreasury = balance - toBuyback;
            if (toBuyback > 0) token.safeTransfer(buyback, toBuyback);
            if (toTreasury > 0) token.safeTransfer(treasury, toTreasury);
        }
        emit Flushed(asset, toBuyback, toTreasury);
    }

    function _sendNative(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed(to);
    }
}
