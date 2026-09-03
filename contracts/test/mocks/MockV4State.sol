// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/**
 * @dev A PoolManager stand-in that only answers `extsload`, laid out the way
 * StateLibrary expects, so the pricer's V4 path can be unit tested with
 * pools set to an arbitrary tick and liquidity.
 */
contract MockV4State {
    using PoolIdLibrary for PoolKey;

    mapping(bytes32 => bytes32) private _slots;

    function setPool(PoolKey memory key, int24 tick, uint128 liquidity) external {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), StateLibrary.POOLS_SLOT));
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        _slots[stateSlot] = bytes32(uint256(sqrtPriceX96) | (uint256(uint24(tick)) << 160));
        _slots[bytes32(uint256(stateSlot) + StateLibrary.LIQUIDITY_OFFSET)] = bytes32(uint256(liquidity));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return _slots[slot];
    }

    function extsload(bytes32 startSlot, uint256 nSlots) external view returns (bytes32[] memory out) {
        out = new bytes32[](nSlots);
        for (uint256 i = 0; i < nSlots; ++i) {
            out[i] = _slots[bytes32(uint256(startSlot) + i)];
        }
    }

    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory out) {
        out = new bytes32[](slots.length);
        for (uint256 i = 0; i < slots.length; ++i) {
            out[i] = _slots[slots[i]];
        }
    }
}
