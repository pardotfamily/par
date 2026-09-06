// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {PairPadQuotePricer, IQuoteReferenceRegistry} from "../src/v2/PairPadQuotePricer.sol";
import {PairPadMultiLaunchFactory} from "../src/v3/PairPadMultiLaunchFactory.sol";
import {PairPadMultiLaunchLocker} from "../src/v3/PairPadMultiLaunchLocker.sol";

/**
 * @notice The owner-side half of a multi-market deployment, run by the
 * FINAL_OWNER (the fee wallet) after DeployMulti handed ownership over:
 * accepts ownership of the factory and locker, registers the multi reference
 * registry with the live quote pricer so multi-market tokens can serve as
 * quotes, and optionally whitelists one launcher while public launches stay
 * closed. Every step is skipped when already done, so it is safe to rerun.
 *
 *   PRIVATE_KEY=<owner> MULTI_FACTORY=... MULTI_REGISTRY=... [WHITELIST=0x...] \
 *     forge script script/WireMulti.s.sol --rpc-url $RPC_URL --broadcast
 */
contract WireMulti is Script {
    address internal constant RH_QUOTE_PRICER = 0x9EfC6EFA4c5F31e2BEC6CC174Ba7bB8f0b57d563;

    function run() external {
        uint256 ownerKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(ownerKey);
        PairPadMultiLaunchFactory factory = PairPadMultiLaunchFactory(vm.envAddress("MULTI_FACTORY"));
        PairPadMultiLaunchLocker locker = PairPadMultiLaunchLocker(payable(address(factory.locker())));
        IQuoteReferenceRegistry registry = IQuoteReferenceRegistry(vm.envAddress("MULTI_REGISTRY"));
        PairPadQuotePricer pricer = PairPadQuotePricer(vm.envOr("QUOTE_PRICER", RH_QUOTE_PRICER));
        address whitelist = vm.envOr("WHITELIST", address(0));

        require(address(factory.quotePricer()) == address(pricer), "factory uses another pricer");

        vm.startBroadcast(ownerKey);

        if (factory.pendingOwner() == owner) {
            factory.acceptOwnership();
            console2.log("factory ownership accepted");
        }
        if (locker.pendingOwner() == owner) {
            locker.acceptOwnership();
            console2.log("locker ownership accepted");
        }
        require(factory.owner() == owner && locker.owner() == owner, "not the owner");

        if (!_hasRegistry(pricer, registry)) {
            pricer.addRegistry(registry);
            console2.log("registry added to pricer");
        }
        if (whitelist != address(0) && !factory.whitelistedLaunchers(whitelist)) {
            factory.setWhitelistedLauncher(whitelist, true);
            console2.log("launcher whitelisted:", whitelist);
        }

        vm.stopBroadcast();

        console2.log("factory owner:", factory.owner());
        console2.log("locker owner: ", locker.owner());
        console2.log("launchEnabled:", factory.launchEnabled());
    }

    function _hasRegistry(PairPadQuotePricer pricer, IQuoteReferenceRegistry registry) internal view returns (bool) {
        for (uint256 i = 0;; i++) {
            try pricer.registries(i) returns (IQuoteReferenceRegistry r) {
                if (r == registry) return true;
            } catch {
                return false;
            }
        }
    }
}
