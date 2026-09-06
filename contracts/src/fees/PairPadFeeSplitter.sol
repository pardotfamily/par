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
 * There is no owner and nothing to configure: the two addresses and the
 * proportion are fixed at deployment. Changing the split means deploying a
 * new splitter and pointing the factories at it, which is visible on chain
 * as `ProtocolFeeRecipientUpdated`.
 *
 * Receiving is kept trivial so the lockers' 50k-gas native transfer never
 * fails; the split itself happens in `flush`, paid by whoever calls it.
 */
contract PairPadFeeSplitter {
    using SafeERC20 for IERC20;

    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Receives `buybackBps` of every asset; buys back and burns $par.
    address public immutable buyback;
    /// @notice Receives the remainder; protocol operations.
    address public immutable treasury;
    /// @notice Share of every flush that goes to `buyback`, in basis points.
    uint16 public immutable buybackBps;

    event Flushed(address indexed asset, uint256 toBuyback, uint256 toTreasury);

    error ZeroAddress();
    error InvalidShare();
    error NativeTransferFailed(address to);

    constructor(address buyback_, address treasury_, uint16 buybackBps_) {
        if (buyback_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (buybackBps_ == 0 || buybackBps_ > BASIS_POINTS) revert InvalidShare();
        buyback = buyback_;
        treasury = treasury_;
        buybackBps = buybackBps_;
    }

    receive() external payable {}

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
