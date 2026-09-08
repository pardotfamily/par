// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PairPadDisperseV2
 * @notice Sends one asset (ETH or an ERC-20) to many recipients in a single
 * transaction, tagged with the launch the payout belongs to. Used by the
 * holder-rewards distributor: the creator share of a "fees to holders"
 * launch is paid to its holders in the asset it was earned in (the quote on
 * buys, the token on sells), so one round is one call per asset.
 *
 * The launch tag is what lets the indexer and the site attribute an ETH or
 * USDG payout to a token: an asset address alone says nothing about which
 * launch it came from. `Paid` is emitted per recipient so a holder's own
 * rewards can be read from the chain without tracking the asset's transfers.
 *
 * ETH is pushed with a bounded gas stipend; a recipient that refuses it
 * (a contract without a payable fallback) is skipped, reported with `Unpaid`
 * and its amount is returned to the caller, so one such address cannot hold
 * up everyone else's payout.
 *
 * Stateless and permissionless: anyone may use it for anything.
 */
contract PairPadDisperseV2 {
    using SafeERC20 for IERC20;

    /// @dev `asset` is address(0) for ETH. `round` is a caller-chosen tag so one logical round split over several transactions can be grouped.
    event Dispersed(
        address indexed launch, address indexed asset, address indexed sender, uint256 round, uint256 total, uint256 recipients
    );
    event Paid(address indexed launch, address indexed asset, address indexed to, uint256 amount);
    /// @dev An ETH recipient that reverted; the amount went back to the sender.
    event Unpaid(address indexed launch, address indexed to, uint256 amount);

    error LengthMismatch();
    error NothingToSend();
    error InsufficientValue();
    error RefundFailed();

    /// @dev Enough for a Safe or a simple smart wallet to accept ETH, not enough to do anything interesting with the call.
    uint256 internal constant SEND_GAS = 50_000;

    /// @notice Pulls `amounts` of `asset` from the caller (balance and approval) and sends them to `recipients`.
    function disperseToken(address launch, IERC20 asset, address[] calldata recipients, uint256[] calldata amounts, uint256 round)
        external
        returns (uint256 total)
    {
        if (recipients.length != amounts.length) revert LengthMismatch();
        if (recipients.length == 0) revert NothingToSend();
        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            asset.safeTransferFrom(msg.sender, recipients[i], amount);
            emit Paid(launch, address(asset), recipients[i], amount);
            total += amount;
        }
        if (total == 0) revert NothingToSend();
        emit Dispersed(launch, address(asset), msg.sender, round, total, recipients.length);
    }

    /// @notice Sends `amounts` of the attached ETH to `recipients`; whatever could not be delivered is returned to the caller.
    function disperseEth(address launch, address[] calldata recipients, uint256[] calldata amounts, uint256 round)
        external
        payable
        returns (uint256 total)
    {
        if (recipients.length != amounts.length) revert LengthMismatch();
        if (recipients.length == 0) revert NothingToSend();
        uint256 needed;
        for (uint256 i = 0; i < amounts.length; i++) needed += amounts[i];
        if (needed == 0) revert NothingToSend();
        if (msg.value < needed) revert InsufficientValue();

        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            (bool ok,) = recipients[i].call{value: amount, gas: SEND_GAS}("");
            if (ok) {
                emit Paid(launch, address(0), recipients[i], amount);
                total += amount;
            } else {
                emit Unpaid(launch, recipients[i], amount);
            }
        }
        if (total == 0) revert NothingToSend();
        emit Dispersed(launch, address(0), msg.sender, round, total, recipients.length);

        uint256 back = msg.value - total;
        if (back > 0) {
            (bool ok,) = msg.sender.call{value: back}("");
            if (!ok) revert RefundFailed();
        }
    }
}
