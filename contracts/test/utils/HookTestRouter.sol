// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/**
 * @dev Minimal swap / liquidity router for tests and smoke scripts: one
 * operation per unlock, deltas settled from and to the caller. Stands in
 * for v4-core's PoolSwapTest, which the trimmed dependency does not ship.
 */
contract HookTestRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable manager;

    error NotManager();

    struct Call {
        bool isSwap;
        PoolKey key;
        SwapParams swap;
        ModifyLiquidityParams liq;
        address payer;
    }

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    receive() external payable {}

    function swap(PoolKey calldata key, SwapParams calldata params) external payable returns (BalanceDelta delta) {
        bytes memory out = manager.unlock(
            abi.encode(Call({isSwap: true, key: key, swap: params, liq: ModifyLiquidityParams(0, 0, 0, 0), payer: msg.sender}))
        );
        delta = abi.decode(out, (BalanceDelta));
        _refund();
    }

    function modifyLiquidity(PoolKey calldata key, ModifyLiquidityParams calldata params)
        external
        payable
        returns (BalanceDelta delta)
    {
        bytes memory out = manager.unlock(
            abi.encode(Call({isSwap: false, key: key, swap: SwapParams(false, 0, 0), liq: params, payer: msg.sender}))
        );
        delta = abi.decode(out, (BalanceDelta));
        _refund();
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        Call memory c = abi.decode(raw, (Call));
        BalanceDelta delta;
        if (c.isSwap) {
            delta = manager.swap(c.key, c.swap, "");
        } else {
            (delta,) = manager.modifyLiquidity(c.key, c.liq, "");
        }
        _settle(c.key.currency0, delta.amount0(), c.payer);
        _settle(c.key.currency1, delta.amount1(), c.payer);
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount, address payer) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(currency);
                IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), owed);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, payer, uint256(uint128(amount)));
        }
    }

    function _refund() private {
        uint256 left = address(this).balance;
        if (left > 0) {
            (bool ok,) = msg.sender.call{value: left}("");
            require(ok, "refund");
        }
    }
}
