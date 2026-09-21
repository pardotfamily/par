// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title PairPadHookRegistry
 * @notice Says which contracts may create pools with the par quote-fee hook,
 * and where the hook finds the PoolManager and the fee escrow on this chain.
 *
 * The hook takes only this registry as a constructor argument, so its init
 * code, and with it its CREATE2 address, is identical on every chain. The
 * registry itself takes only the owner, for the same reason.
 *
 * Nothing here touches swaps: the registry gates pool creation and nothing
 * else, and `configure` is one-shot so the hook's dependencies cannot be
 * repointed after deployment.
 */
contract PairPadHookRegistry is Ownable2Step {
    error ZeroAddress();
    error AlreadyConfigured();

    event FactorySet(address indexed factory, bool allowed);
    event Configured(address indexed poolManager, address indexed feeEscrow);

    /// @notice The Uniswap v4 PoolManager on this chain. Set once.
    address public poolManager;
    /// @notice The par fee escrow creator fees are credited to. Set once.
    address public feeEscrow;
    /// @notice Contracts allowed to register and initialize hooked pools.
    mapping(address factory => bool allowed) public isFactory;

    constructor(address owner_) Ownable(owner_) {}

    /**
     * @notice Points the registry at this chain's PoolManager and fee escrow.
     * Can only be done once; the hook reads both at its own construction.
     */
    function configure(address poolManager_, address feeEscrow_) external onlyOwner {
        if (poolManager != address(0)) revert AlreadyConfigured();
        if (poolManager_ == address(0) || feeEscrow_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        feeEscrow = feeEscrow_;
        emit Configured(poolManager_, feeEscrow_);
    }

    /**
     * @notice Allows or disallows `factory` to create pools with the hook.
     */
    function setFactory(address factory, bool allowed) external onlyOwner {
        if (factory == address(0)) revert ZeroAddress();
        isFactory[factory] = allowed;
        emit FactorySet(factory, allowed);
    }
}
