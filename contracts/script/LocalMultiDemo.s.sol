// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PairPadQuotePricer} from "../src/v2/PairPadQuotePricer.sol";
import {PairPadLauncherToken} from "../src/v2/PairPadLauncherToken.sol";
import {Hop} from "../src/v2/libraries/Hop.sol";
import {PairPadMultiLaunchFactory} from "../src/v3/PairPadMultiLaunchFactory.sol";
import {PairPadMultiLaunchLocker} from "../src/v3/PairPadMultiLaunchLocker.sol";
import {PairPadMultiRouter} from "../src/v3/PairPadMultiRouter.sol";

/**
 * @notice Local demo against an anvil fork of Robinhood Chain: launches one
 * token on three markets (ETH, USDG, $par) with an opening buy, trades it a
 * few times through the multi router and collects the fees, so the indexer
 * and the web app have something to show. Never meant for a live chain.
 *
 *   anvil --fork-url <robinhood rpc> --chain-id 4663 --port 8545
 *   PRIVATE_KEY=<anvil key 0> LAUNCH_ENABLED=true forge script script/DeployMulti.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 *   PRIVATE_KEY=... MULTI_FACTORY=... MULTI_ROUTER=... forge script script/LocalMultiDemo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 */
contract LocalMultiDemo is Script {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant PAR = 0x507B6F349a80114097A67B8b4677367acC15b220;
    address internal constant QUOTE_PRICER = 0x9EfC6EFA4c5F31e2BEC6CC174Ba7bB8f0b57d563;

    function run() external {
        require(block.chainid == 4663, "run against an anvil fork of Robinhood Chain (chain id 4663)");
        uint256 key = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(key);
        PairPadMultiLaunchFactory factory = PairPadMultiLaunchFactory(vm.envAddress("MULTI_FACTORY"));
        PairPadMultiRouter router = PairPadMultiRouter(payable(vm.envAddress("MULTI_ROUTER")));
        PairPadMultiLaunchLocker locker = PairPadMultiLaunchLocker(payable(address(factory.locker())));
        PairPadQuotePricer pricer = PairPadQuotePricer(QUOTE_PRICER);

        address[] memory quotes = new address[](3);
        quotes[0] = address(0);
        quotes[1] = USDG;
        quotes[2] = PAR;

        // Routes from the pricer: quote -> ETH order; buys walk them backwards.
        Hop[][] memory sellHops = new Hop[][](3);
        Hop[][] memory buyHops = new Hop[][](3);
        for (uint256 i = 1; i < 3; i++) {
            (Hop[] memory hops,) = pricer.route(quotes[i]);
            require(hops.length > 0, "quote has no route");
            sellHops[i] = hops;
            buyHops[i] = new Hop[](hops.length);
            for (uint256 j = 0; j < hops.length; j++) buyHops[i][j] = hops[hops.length - 1 - j];
        }

        uint256 launchFee = factory.launchFee();
        uint256 openingBuy = vm.envOr("OPENING_BUY", uint256(0.3 ether));

        vm.startBroadcast(key);

        PairPadMultiLaunchFactory.TokenParams memory params = PairPadMultiLaunchFactory.TokenParams({
            name: vm.envOr("TOKEN_NAME", string("Tri Market")),
            symbol: vm.envOr("TOKEN_SYMBOL", string("TRI")),
            logo: "",
            description: "Local multi-market demo: one token, three pools (ETH, USDG, $par).",
            socials: PairPadLauncherToken.Socials("", "", "", "", ""),
            creatorFeeRecipient: me,
            creatorTaxBps: 100,
            expectedEconomics: bytes32(0),
            salt: keccak256(abi.encodePacked("local-demo", block.timestamp))
        });

        (address token, uint256 tokensOut) = router.launchAndBuyWithEth{value: launchFee + openingBuy}(
            params, 0, quotes, _legs(buyHops, openingBuy), 0
        );
        console2.log("Token:", token);
        console2.log("Opening buy tokens:", tokensOut);

        // A second buy, then a sale of a third of the holdings across markets.
        uint256 bought = router.buyWithEth{value: 0.1 ether}(token, _legs(buyHops, 0.1 ether), 0, me);
        console2.log("Second buy tokens:", bought);

        uint256 balance = IERC20(token).balanceOf(me);
        uint256 toSell = balance / 3;
        IERC20(token).approve(address(router), toSell);
        uint256 ethOut = router.sellToEth(token, _legs(sellHops, toSell), 0, me);
        console2.log("Sold tokens:", toSell);
        console2.log("ETH out:", ethOut);

        // One more buy on a single market, paid in ETH directly.
        router.buyWithQuote{value: 0.02 ether}(token, 0, 0.02 ether, 0, me);

        locker.collectFees(token);
        console2.log("Fees collected");

        vm.stopBroadcast();
    }

    /// @dev Equal thirds; the last leg takes the remainder so the sum is exact.
    function _legs(Hop[][] memory hops, uint256 total) internal pure returns (PairPadMultiRouter.Leg[] memory legs) {
        legs = new PairPadMultiRouter.Leg[](3);
        legs[0] = PairPadMultiRouter.Leg({market: 0, hops: hops[0], amountIn: total / 3});
        legs[1] = PairPadMultiRouter.Leg({market: 1, hops: hops[1], amountIn: total / 3});
        legs[2] = PairPadMultiRouter.Leg({market: 2, hops: hops[2], amountIn: total - 2 * (total / 3)});
    }
}
