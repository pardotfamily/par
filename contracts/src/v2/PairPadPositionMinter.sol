// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {PairPadLaunchLocker} from "./PairPadLaunchLocker.sol";
import {PairPadPositionMath} from "./libraries/PairPadPositionMath.sol";

/**
 * @title PairPadPositionMinter
 * @notice Lays out and mints the single locked position that is a PairPad
 * launch's whole market, on PairPadLaunchFactory's behalf. Split out of the
 * factory purely so its bytecode stays under EIP-170's size limit: the tick
 * math, the Permit2 approval dance and the PositionManager action encoding
 * are large.
 *
 * The launch token mints its entire supply straight to this contract, the
 * factory then calls `mintLaunchPosition` in the same transaction, and the
 * PositionManager pulls the supply from here into the pool. Nothing is held
 * between transactions: whatever the pool's rounding leaves behind is sent
 * to the locker, so supply that did not reach the pool never circulates.
 */
contract PairPadPositionMinter {
    using SafeERC20 for IERC20;

    uint256 private constant MINT_DEADLINE_WINDOW = 300;

    error NotFactory();
    error ZeroAddress();
    error SupplyNotReceived(uint256 expected, uint256 held);

    event LaunchDustLocked(address indexed launchToken, uint256 amount);

    IPositionManager public immutable positionManager;
    IAllowanceTransfer public immutable permit2;
    PairPadLaunchLocker public immutable locker;
    address public immutable factory;

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    constructor(
        IPositionManager positionManager_,
        IAllowanceTransfer permit2_,
        PairPadLaunchLocker locker_,
        address factory_
    ) {
        if (address(positionManager_) == address(0) || address(permit2_) == address(0)) revert ZeroAddress();
        if (address(locker_) == address(0) || factory_ == address(0)) revert ZeroAddress();
        positionManager = positionManager_;
        permit2 = permit2_;
        locker = locker_;
        factory = factory_;
    }

    /**
     * @notice The opening price, tick range and liquidity a launch with these
     * terms gets. Pure math, exposed so the factory (and anyone previewing a
     * launch) reads it from one place.
     */
    function plan(bool tokenIsCurrency0, uint256 supply, uint256 phantomQuote, int24 tickSpacing)
        external
        pure
        returns (PairPadPositionMath.Plan memory)
    {
        return PairPadPositionMath.plan(tokenIsCurrency0, supply, phantomQuote, tickSpacing);
    }

    /**
     * @notice Mints the launch position to the locker from the token supply
     * this contract holds. The pool must already be initialized at
     * `p.sqrtPriceX96`, so the position is one-sided and no quote is needed.
     * @return positionId The PositionManager token id of the new position.
     * @return tokenAmount The supply actually placed in the pool.
     */
    function mintLaunchPosition(
        address launchToken,
        PoolKey calldata key,
        PairPadPositionMath.Plan calldata p,
        uint256 supply
    ) external onlyFactory returns (uint256 positionId, uint256 tokenAmount) {
        uint256 held = IERC20(launchToken).balanceOf(address(this));
        if (held < supply) revert SupplyNotReceived(supply, held);

        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == launchToken;
        _approvePermit2(launchToken, supply);

        positionId = positionManager.nextTokenId();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            p.tickLower,
            p.tickUpper,
            uint256(p.liquidity),
            // The quote side must come out to exactly zero at the boundary
            // price; a nonzero quote requirement means the pool was not
            // initialized where the plan expects.
            // forge-lint: disable-next-line(unsafe-typecast)
            tokenIsCurrency0 ? uint128(supply) : uint128(0),
            // forge-lint: disable-next-line(unsafe-typecast)
            tokenIsCurrency0 ? uint128(0) : uint128(supply),
            address(locker),
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + MINT_DEADLINE_WINDOW);

        uint256 left = IERC20(launchToken).balanceOf(address(this));
        tokenAmount = held - left;
        if (left != 0) {
            // The locker has no way to move tokens out, so a plain transfer
            // is as locked as the position itself.
            IERC20(launchToken).safeTransfer(address(locker), left);
            emit LaunchDustLocked(launchToken, left);
        }
    }

    function _approvePermit2(address token, uint256 amount) private {
        IERC20(token).forceApprove(address(permit2), amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2.approve(token, address(positionManager), uint160(amount), uint48(block.timestamp + MINT_DEADLINE_WINDOW));
    }
}
