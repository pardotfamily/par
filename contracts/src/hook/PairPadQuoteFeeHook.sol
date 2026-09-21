// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {BaseHook} from "@uniswap/v4-hooks-public/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IPairPadFeeEscrow} from "../v2/interfaces/ILaunchpadV2.sol";

interface IPairPadHookRegistry {
    function poolManager() external view returns (address);
    function feeEscrow() external view returns (address);
    function isFactory(address factory) external view returns (bool);
}

/**
 * @title PairPadQuoteFeeHook
 * @notice One hook for every par launch pool: the trading fee is always taken
 * in the pool's quote currency, whichever side of the swap it is on.
 *
 * A plain v4 pool charges its LP fee on the input currency, so buys pay in
 * quote and sells pay in the launch token. Pools using this hook set their
 * LP fee to zero and let the hook charge instead:
 *
 *  - when quote is the swap's specified currency (exact-in buy, exact-out
 *    sell) the fee is taken in `beforeSwap` through the specified delta;
 *  - when quote is the unspecified currency (exact-in sell, exact-out buy)
 *    it is taken in `afterSwap` through the unspecified delta.
 *
 * Fees are held as ERC-6909 claims in the PoolManager and moved out by the
 * permissionless `collect`, which pays the protocol share to the protocol
 * recipient and credits the creator share to the par fee escrow, exactly
 * where the position lockers pay it today. Creators, holders vaults and the
 * burn/floor vaults therefore keep their claim flow, only now in quote.
 *
 * The hook has no owner and nothing upgradeable. Pools can only be created
 * by factories the registry allows, each with a configuration fixed at
 * registration. Swaps take no hook data and no caller is ever gated.
 */
contract PairPadQuoteFeeHook is BaseHook, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @dev Fee cap; matches the launch factory's total trade fee ceiling.
    uint16 public constant MAX_FEE_BPS = 2_000;
    uint16 public constant BPS = 10_000;

    struct PoolConfig {
        /// The pool currency the fee is charged in.
        Currency quote;
        /// Fee on every swap, in basis points of the quote amount.
        uint16 feeBps;
        /// Share of each fee that goes to the protocol; the rest is the creator's.
        uint16 protocolShareBps;
        /// Credited in the fee escrow with the creator share (a wallet or a par vault).
        address creator;
        /// Paid the protocol share directly.
        address protocol;
    }

    error NotFactory();
    error NotRegistered();
    error AlreadyRegistered();
    error WrongHook();
    error QuoteNotInPool();
    error FeeTooHigh();
    error ZeroAddress();
    error NotSelf();
    error NothingToCollect();

    event PoolRegistered(
        PoolId indexed poolId,
        address indexed factory,
        Currency quote,
        uint16 feeBps,
        uint16 protocolShareBps,
        address creator,
        address protocol
    );
    event FeeAccrued(PoolId indexed poolId, uint256 quoteAmount);
    event FeesCollected(PoolId indexed poolId, uint256 protocolAmount, uint256 creatorAmount);

    IPairPadHookRegistry public immutable registry;
    IPairPadFeeEscrow public immutable feeEscrow;

    mapping(PoolId => PoolConfig) private _configs;
    /// @notice Quote fees taken and not yet collected, per pool.
    mapping(PoolId => uint256) public accrued;

    constructor(IPairPadHookRegistry registry_) BaseHook(IPoolManager(registry_.poolManager())) {
        registry = registry_;
        address escrow = registry_.feeEscrow();
        if (escrow == address(0)) revert ZeroAddress();
        feeEscrow = IPairPadFeeEscrow(escrow);
    }

    receive() external payable {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function config(PoolId poolId) external view returns (PoolConfig memory) {
        return _configs[poolId];
    }

    /**
     * @notice Fixes a pool's fee configuration ahead of its initialization.
     * Only an allowed factory may call this, and only once per pool; the
     * same factory must then be the one initializing the pool.
     */
    function register(PoolKey calldata key, PoolConfig calldata cfg) external {
        if (!registry.isFactory(msg.sender)) revert NotFactory();
        if (address(key.hooks) != address(this)) revert WrongHook();
        if (!(cfg.quote == key.currency0 || cfg.quote == key.currency1)) revert QuoteNotInPool();
        if (cfg.feeBps == 0 || cfg.feeBps > MAX_FEE_BPS || cfg.protocolShareBps > BPS) revert FeeTooHigh();
        if (cfg.creator == address(0) || cfg.protocol == address(0)) revert ZeroAddress();
        PoolId id = key.toId();
        if (_configs[id].feeBps != 0) revert AlreadyRegistered();
        _configs[id] = cfg;
        emit PoolRegistered(id, msg.sender, cfg.quote, cfg.feeBps, cfg.protocolShareBps, cfg.creator, cfg.protocol);
    }

    // ---------------------------------------------------------------- hooks

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (!registry.isFactory(sender)) revert NotFactory();
        if (_configs[key.toId()].feeBps == 0) revert NotRegistered();
        return BaseHook.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        PoolConfig storage cfg = _configs[id];
        if (!_quoteIsSpecified(key, params, cfg.quote)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 amount = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 fee = (amount * cfg.feeBps) / BPS;
        if (fee == 0) return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        _accrue(id, cfg.quote, fee);
        // Positive specified delta: the hook takes `fee` of the specified
        // currency. Exact-in swaps trade `amount - fee`; exact-out swaps
        // pull `amount + fee` from the pool so the trader still gets `amount`.
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        PoolConfig storage cfg = _configs[id];
        if (_quoteIsSpecified(key, params, cfg.quote)) return (BaseHook.afterSwap.selector, 0);
        int128 quoteDelta = cfg.quote == key.currency0 ? delta.amount0() : delta.amount1();
        uint256 amount = quoteDelta < 0 ? uint256(uint128(-quoteDelta)) : uint256(uint128(quoteDelta));
        uint256 fee = (amount * cfg.feeBps) / BPS;
        if (fee == 0) return (BaseHook.afterSwap.selector, 0);
        _accrue(id, cfg.quote, fee);
        // Positive unspecified delta: the trader receives `fee` less quote
        // (exact-in sell) or pays `fee` more quote (exact-out buy).
        return (BaseHook.afterSwap.selector, int128(uint128(fee)));
    }

    /// @dev The specified currency is the input on exact-in swaps and the
    /// output on exact-out swaps; the input is currency0 when zeroForOne.
    function _quoteIsSpecified(PoolKey calldata key, SwapParams calldata params, Currency quote)
        private
        pure
        returns (bool)
    {
        bool exactIn = params.amountSpecified < 0;
        bool specifiedIs0 = params.zeroForOne == exactIn;
        bool quoteIs0 = quote == key.currency0;
        return specifiedIs0 == quoteIs0;
    }

    /// @dev Books the fee as a claim on the PoolManager; the claim settles the
    /// delta the hook's return creates for it within the same unlock.
    function _accrue(PoolId id, Currency quote, uint256 fee) private {
        poolManager.mint(address(this), quote.toId(), fee);
        accrued[id] += fee;
        emit FeeAccrued(id, fee);
    }

    // -------------------------------------------------------------- collect

    /**
     * @notice Moves a pool's accrued quote fees out of the PoolManager: the
     * protocol share to the protocol recipient, the creator share into the
     * fee escrow for the creator (or vault) to claim. Anyone may call.
     */
    function collect(PoolKey calldata key) external nonReentrant returns (uint256 protocolAmount, uint256 creatorAmount) {
        PoolId id = key.toId();
        uint256 amount = accrued[id];
        if (amount == 0) revert NothingToCollect();
        accrued[id] = 0;
        bytes memory out = poolManager.unlock(abi.encode(id, amount));
        (protocolAmount, creatorAmount) = abi.decode(out, (uint256, uint256));
        emit FeesCollected(id, protocolAmount, creatorAmount);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (PoolId id, uint256 amount) = abi.decode(data, (PoolId, uint256));
        PoolConfig storage cfg = _configs[id];
        Currency quote = cfg.quote;
        uint256 protocolAmount = (amount * cfg.protocolShareBps) / BPS;
        uint256 creatorAmount = amount - protocolAmount;

        poolManager.burn(address(this), quote.toId(), amount);
        poolManager.take(quote, address(this), amount);
        _payProtocol(quote, cfg.protocol, protocolAmount);
        _credit(quote, cfg.creator, creatorAmount);
        return abi.encode(protocolAmount, creatorAmount);
    }

    /// @dev The protocol's share goes straight to its wallet, as the position
    /// lockers do it: ETH with a bounded stipend, falling back to the escrow
    /// if the send fails, so no recipient can hold a collection hostage.
    function _payProtocol(Currency currency, address recipient, uint256 amount) private {
        if (amount == 0) return;
        if (currency.isAddressZero()) {
            (bool ok,) = recipient.call{value: amount, gas: 50_000}("");
            if (!ok) feeEscrow.credit{value: amount}(recipient);
            return;
        }
        IERC20(Currency.unwrap(currency)).safeTransfer(recipient, amount);
    }

    /// @dev The creator's share is credited to the escrow for the recipient
    /// (a wallet or a par vault) to claim.
    function _credit(Currency currency, address recipient, uint256 amount) private {
        if (amount == 0) return;
        if (currency.isAddressZero()) {
            feeEscrow.credit{value: amount}(recipient);
            return;
        }
        IERC20 token = IERC20(Currency.unwrap(currency));
        token.forceApprove(address(feeEscrow), amount);
        feeEscrow.creditToken(recipient, address(token), amount);
    }
}
