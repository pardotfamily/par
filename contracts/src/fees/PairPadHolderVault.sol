// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPairPadFeeEscrow} from "../v2/interfaces/ILaunchpadV2.sol";

/**
 * @title PairPadHolderVault
 * @notice The creator fee recipient of launches whose creator chose, at
 * creation, to give the creator's share of trading fees to the token's
 * holders instead of keeping it. The factories snapshot the recipient and
 * only the recipient itself may ever change it; this contract has no such
 * function, so the choice is permanent for the life of the token.
 *
 * The lockers credit the creator share to the fee escrow under this
 * address. `harvest` claims it and forwards everything to the distributor,
 * an operator wallet that buys the launch token back with the quote share,
 * adds the share already paid in the token, and sends the total to holders
 * in proportion to their balances. The distribution rounds are visible on
 * chain through PairPadDisperse.
 *
 * One vault serves every opted-in launch; which launch each amount came from
 * is exact from the lockers' FeesCollected events, so pooling costs nothing.
 */
contract PairPadHolderVault {
    using SafeERC20 for IERC20;

    IPairPadFeeEscrow public immutable escrow;
    address public immutable distributor;

    event Harvested(address indexed asset, uint256 amount);

    error ZeroAddress();
    error NativeTransferFailed();

    constructor(IPairPadFeeEscrow escrow_, address distributor_) {
        if (address(escrow_) == address(0) || distributor_ == address(0)) revert ZeroAddress();
        escrow = escrow_;
        distributor = distributor_;
    }

    /// @dev The escrow pays claimed ETH here.
    receive() external payable {}

    /**
     * @notice Claims every listed asset from the escrow (address zero for
     * native ETH) and forwards this contract's full balance of each to the
     * distributor. Anyone may call; assets with nothing to move are skipped.
     */
    function harvest(address[] calldata assets) external {
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            if (asset == address(0)) {
                if (escrow.balanceOf(address(this)) > 0) escrow.claim();
                uint256 balance = address(this).balance;
                if (balance == 0) continue;
                (bool ok,) = distributor.call{value: balance}("");
                if (!ok) revert NativeTransferFailed();
                emit Harvested(asset, balance);
            } else {
                if (escrow.balanceOfToken(address(this), asset) > 0) escrow.claimToken(asset);
                uint256 balance = IERC20(asset).balanceOf(address(this));
                if (balance == 0) continue;
                IERC20(asset).safeTransfer(distributor, balance);
                emit Harvested(asset, balance);
            }
        }
    }

    /// @notice What the escrow holds for holders in `asset`, not yet harvested.
    function pending(address asset) external view returns (uint256) {
        return asset == address(0) ? escrow.balanceOf(address(this)) : escrow.balanceOfToken(address(this), asset);
    }
}
