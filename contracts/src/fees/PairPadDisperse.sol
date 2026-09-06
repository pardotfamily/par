// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PairPadDisperse
 * @notice Sends one ERC-20 to many recipients in a single transaction,
 * pulled from the caller's balance and approval. Used by the holder-rewards
 * distributor for its rounds; the event is what the indexer and the site
 * read to show "X tokens sent to N holders" under a token.
 *
 * Stateless and permissionless: anyone may use it for anything.
 */
contract PairPadDisperse {
    using SafeERC20 for IERC20;

    /// @param round Caller-chosen tag (e.g. the round's timestamp) so one logical round split over several transactions can be grouped.
    event Dispersed(address indexed token, address indexed sender, uint256 indexed round, uint256 total, uint256 recipients);

    error LengthMismatch();
    error NothingToSend();

    function disperseToken(IERC20 token, address[] calldata recipients, uint256[] calldata amounts, uint256 round)
        external
        returns (uint256 total)
    {
        if (recipients.length != amounts.length) revert LengthMismatch();
        if (recipients.length == 0) revert NothingToSend();
        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            token.safeTransferFrom(msg.sender, recipients[i], amount);
            total += amount;
        }
        if (total == 0) revert NothingToSend();
        emit Dispersed(address(token), msg.sender, round, total, recipients.length);
    }
}
