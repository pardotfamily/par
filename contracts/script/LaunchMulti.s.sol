// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {PairPadLauncherToken} from "../src/v2/PairPadLauncherToken.sol";
import {PairPadMultiLaunchFactory} from "../src/v3/PairPadMultiLaunchFactory.sol";
import {IPairPadMultiLaunchFactory} from "../src/v3/interfaces/ILaunchpadV3.sol";

/**
 * @notice Launches one multi-market token from the command line, the same
 * call the launch form makes: previews the economics digest so the launch
 * refuses to go through on terms other than the ones previewed, pays the
 * launch fee, and prints every market's pool id.
 *
 *   PRIVATE_KEY=<launcher> MULTI_FACTORY=0x... \
 *   TOKEN_NAME="Index" TOKEN_SYMBOL="INDEX" TOKEN_LOGO="ipfs://..." TOKEN_DESCRIPTION="..." \
 *   TOKEN_WEBSITE="" TOKEN_TWITTER="" PAIR_TOKENS=0xa,0xb,0xc \
 *     forge script script/LaunchMulti.s.sol --rpc-url $RPC_URL --broadcast
 */
contract LaunchMulti is Script {
    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address launcher = vm.addr(key);
        PairPadMultiLaunchFactory factory = PairPadMultiLaunchFactory(vm.envAddress("MULTI_FACTORY"));
        address[] memory pairTokens = vm.envAddress("PAIR_TOKENS", ",");
        uint256 configId = vm.envOr("LAUNCH_CONFIG_ID", uint256(0));

        require(factory.canLaunch(launcher), "launcher not allowed");
        // Same rule as the launch form: a pool-priced quote (anything the
        // owner has not curated) moves between preview and execution, so the
        // digest guard would trip on every price tick; it is waived then.
        bytes32 economics = _poolPriced(factory, pairTokens) ? bytes32(0) : factory.previewLaunchEconomics(configId, pairTokens);
        uint256 fee = factory.launchFee();

        PairPadMultiLaunchFactory.TokenParams memory params = PairPadMultiLaunchFactory.TokenParams({
            name: vm.envString("TOKEN_NAME"),
            symbol: vm.envString("TOKEN_SYMBOL"),
            logo: vm.envOr("TOKEN_LOGO", string("")),
            description: vm.envOr("TOKEN_DESCRIPTION", string("")),
            socials: PairPadLauncherToken.Socials({
                twitter: vm.envOr("TOKEN_TWITTER", string("")),
                telegram: vm.envOr("TOKEN_TELEGRAM", string("")),
                discord: vm.envOr("TOKEN_DISCORD", string("")),
                website: vm.envOr("TOKEN_WEBSITE", string("")),
                farcaster: vm.envOr("TOKEN_FARCASTER", string(""))
            }),
            creatorFeeRecipient: vm.envOr("CREATOR_FEE_RECIPIENT", address(0)),
            creatorTaxBps: uint16(vm.envOr("CREATOR_TAX_BPS", uint256(0))),
            expectedEconomics: economics,
            salt: vm.envOr("TOKEN_SALT", keccak256(abi.encode(launcher, block.timestamp, pairTokens)))
        });

        console2.log("launcher:      ", launcher);
        console2.log("launch fee:    ", fee);
        console2.log("markets:       ", pairTokens.length);
        console2.logBytes32(economics);

        vm.startBroadcast(key);
        address token = factory.launchToken{value: fee}(params, configId, pairTokens);
        vm.stopBroadcast();

        console2.log("TOKEN:", token);
        IPairPadMultiLaunchFactory.Market[] memory markets = factory.getMarkets(token);
        PoolKey[] memory keys = factory.poolKeysFor(token);
        for (uint256 i = 0; i < markets.length; i++) {
            console2.log("market", i, markets[i].pairToken);
            console2.logBytes32(PoolId.unwrap(PoolIdLibrary.toId(keys[i])));
        }
    }

    function _poolPriced(PairPadMultiLaunchFactory factory, address[] memory pairTokens) internal view returns (bool) {
        for (uint256 i = 0; i < pairTokens.length; i++) {
            if (pairTokens[i] == address(0)) continue;
            (uint256 curatedPhantom,) = factory.pairTokenEconomics(pairTokens[i]);
            if (curatedPhantom == 0) return true;
        }
        return false;
    }
}
