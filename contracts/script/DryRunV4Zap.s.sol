// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {PairPadLaunchFactory} from "../src/v2/PairPadLaunchFactory.sol";
import {PairPadQuotePricer} from "../src/v2/PairPadQuotePricer.sol";
import {PairPadRouter} from "../src/v2/PairPadRouter.sol";
import {PairPadLauncherToken} from "../src/v2/PairPadLauncherToken.sol";

/**
 * @notice Exercises the deployed router against a quote that only trades on
 * Uniswap V4: launch with an ETH-paid dev buy, buy again, sell back to ETH.
 * Meant to run as a simulation (no --broadcast) against the live RPC:
 *
 *   FACTORY=... ROUTER=... QUOTE=0x66e7...2c68 forge script script/DryRunV4Zap.s.sol --rpc-url robinhood
 */
contract DryRunV4Zap is Script {
    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(key);
        PairPadLaunchFactory factory = PairPadLaunchFactory(payable(vm.envAddress("FACTORY")));
        PairPadRouter router = PairPadRouter(payable(vm.envAddress("ROUTER")));
        address quote = vm.envAddress("QUOTE");
        PairPadQuotePricer pricer = factory.quotePricer();

        (PairPadQuotePricer.Reference memory direct,,) = pricer.describe(quote);
        require(direct.qualifies, "quote not priceable");
        require(direct.kind == PairPadQuotePricer.ReferenceKind.V4 && direct.anchor == address(0), "not a V4 ETH ref");
        PoolKey[] memory hops = new PoolKey[](1);
        hops[0] = direct.v4Key;
        PairPadRouter.EthLeg memory leg = PairPadRouter.EthLeg("", hops);
        console2.log("reference V4 pool depth (wei):", direct.anchorDepth);

        PairPadLaunchFactory.TokenParams memory params = PairPadLaunchFactory.TokenParams({
            name: "Dry Run",
            symbol: "DRY",
            logo: "",
            description: "",
            socials: PairPadLauncherToken.Socials("", "", "", "", ""),
            creatorFeeRecipient: address(0),
            creatorTaxBps: 0,
            expectedEconomics: bytes32(0),
            salt: keccak256(abi.encode("dry", block.timestamp))
        });

        vm.startBroadcast(key);
        uint256 quoteBefore = IERC20(quote).balanceOf(me);
        (address token, PoolId poolId, uint256 opening) = router.launchAndBuyWithEth{
            value: factory.launchFee() + 0.002 ether
        }(params, 0, quote, leg, 0);
        console2.log("token", token);
        console2.log("poolId", vm.toString(PoolId.unwrap(poolId)));
        console2.log("dev buy tokens out", opening);
        require(IERC20(quote).balanceOf(me) == quoteBefore, "quote balance moved");
        require(IERC20(quote).balanceOf(address(router)) == 0, "router kept quote");

        PoolKey memory poolKey = factory.poolKeyFor(token);
        uint256 out2 = router.buyWithEth{value: 0.001 ether}(poolKey, leg, 0, me);
        console2.log("second buy tokens out", out2);

        bool tokenIs0 = Currency.unwrap(poolKey.currency0) == token;
        IERC20(token).approve(address(router), out2);
        uint256 ethOut = router.sellToEth(poolKey, tokenIs0, out2, leg, 0, me);
        console2.log("sold second buy, ETH out", ethOut);
        vm.stopBroadcast();

        require(IERC20(quote).balanceOf(address(router)) == 0, "router kept quote after sell");
        require(address(router).balance == 0, "router kept ETH");
    }
}
