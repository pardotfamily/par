// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {PairPadHookRegistry} from "../src/hook/PairPadHookRegistry.sol";
import {PairPadQuoteFeeHook, IPairPadHookRegistry} from "../src/hook/PairPadQuoteFeeHook.sol";

/**
 * @notice Deploys the hook registry and the quote-fee hook through the
 * canonical CREATE2 deployer, so both land on the same address on every
 * chain. The registry takes only the owner, the hook only the registry, and
 * the hook's flag bits are satisfied by a mined salt shared across chains.
 *
 * Nothing here touches the live launch factories: the hook is deployed for
 * review and for test pools. Wiring it into launches is a later step.
 *
 * Env:  PRIVATE_KEY, POOL_MANAGER, FEE_ESCROW, HOOK_SALT (from MineHookSalt)
 * Run:  forge script script/DeployQuoteFeeHook.s.sol --rpc-url ... --broadcast
 */
contract DeployQuoteFeeHook is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant REGISTRY_SALT = keccak256("par.hook.registry.v1");
    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address poolManager = vm.envAddress("POOL_MANAGER");
        address feeEscrow = vm.envAddress("FEE_ESCROW");
        bytes32 hookSalt = vm.envBytes32("HOOK_SALT");
        require(CREATE2_DEPLOYER.code.length != 0, "no CREATE2 deployer on this chain");
        require(poolManager.code.length != 0, "no PoolManager");
        require(feeEscrow.code.length != 0, "no fee escrow");

        bytes memory registryCode = abi.encodePacked(type(PairPadHookRegistry).creationCode, abi.encode(deployer));
        bytes memory hookCode;

        vm.startBroadcast(pk);
        address registry = _create2(REGISTRY_SALT, registryCode);
        PairPadHookRegistry reg = PairPadHookRegistry(registry);
        if (reg.poolManager() == address(0)) reg.configure(poolManager, feeEscrow);
        require(reg.poolManager() == poolManager && reg.feeEscrow() == feeEscrow, "registry points elsewhere");

        hookCode = abi.encodePacked(type(PairPadQuoteFeeHook).creationCode, abi.encode(IPairPadHookRegistry(registry)));
        address hook = _create2(hookSalt, hookCode);
        vm.stopBroadcast();

        require(uint160(hook) & Hooks.ALL_HOOK_MASK == FLAGS, "hook address flags mismatch");
        require(address(PairPadQuoteFeeHook(payable(hook)).registry()) == registry, "hook registry mismatch");

        console2.log("chain id:               ", block.chainid);
        console2.log("PairPadHookRegistry:    ", registry);
        console2.log("PairPadQuoteFeeHook:    ", hook);
        console2.log("registry owner:         ", reg.owner());
        console2.log("pool manager:           ", poolManager);
        console2.log("fee escrow:             ", feeEscrow);
    }

    function _create2(bytes32 salt, bytes memory initCode) private returns (address predicted) {
        predicted = vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_DEPLOYER);
        if (predicted.code.length != 0) {
            console2.log("already deployed:       ", predicted);
            return predicted;
        }
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok && predicted.code.length != 0, "create2 failed");
    }
}

/**
 * @notice Finds a salt that puts the hook's CREATE2 address on the required
 * flag bits. Pure computation, no broadcast:
 *   PRIVATE_KEY=... forge script script/DeployQuoteFeeHook.s.sol:MineHookSalt
 * The result depends only on the deployer (registry owner) and the compiled
 * bytecode, so it holds on every chain.
 */
contract MineHookSalt is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 constant REGISTRY_SALT = keccak256("par.hook.registry.v1");
    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external view {
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        address registry = vm.computeCreate2Address(
            REGISTRY_SALT,
            keccak256(abi.encodePacked(type(PairPadHookRegistry).creationCode, abi.encode(deployer))),
            CREATE2_DEPLOYER
        );
        bytes32 initHash =
            keccak256(abi.encodePacked(type(PairPadQuoteFeeHook).creationCode, abi.encode(IPairPadHookRegistry(registry))));
        for (uint256 i = 0;; i++) {
            bytes32 salt = bytes32(i);
            address predicted = vm.computeCreate2Address(salt, initHash, CREATE2_DEPLOYER);
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == FLAGS) {
                console2.log("registry (predicted):   ", registry);
                console2.log("hook (predicted):       ", predicted);
                console2.log("HOOK_SALT:");
                console2.logBytes32(salt);
                return;
            }
        }
    }
}
