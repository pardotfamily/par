// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PairPadQuotePricer} from "../src/v2/PairPadQuotePricer.sol";
import {Hop} from "../src/v2/libraries/Hop.sol";
import {PairPadMultiLaunchFactory} from "../src/v3/PairPadMultiLaunchFactory.sol";
import {PairPadMultiRouter} from "../src/v3/PairPadMultiRouter.sol";
import {IPairPadMultiLaunchFactory} from "../src/v3/interfaces/ILaunchpadV3.sol";

/**
 * @notice Trades an existing multi-market token from the command line, split
 * evenly over every market: BUY_ETH of ETH in (each ERC-20 market's leg is
 * the pricer's route for its quote), then, when SELL_BPS is set, that share
 * of the wallet's balance back to ETH. The last leg takes any rounding
 * remainder so the sum is exact.
 *
 *   PRIVATE_KEY=... MULTI_FACTORY=0x... MULTI_ROUTER=0x... TOKEN=0x... \
 *   BUY_ETH=0.05ether [SELL_BPS=3000] forge script script/TradeMulti.s.sol --rpc-url $RPC_URL --broadcast
 */
contract TradeMulti is Script {
    address internal constant RH_QUOTE_PRICER = 0x9EfC6EFA4c5F31e2BEC6CC174Ba7bB8f0b57d563;

    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(key);
        PairPadMultiLaunchFactory factory = PairPadMultiLaunchFactory(vm.envAddress("MULTI_FACTORY"));
        PairPadMultiRouter router = PairPadMultiRouter(payable(vm.envAddress("MULTI_ROUTER")));
        PairPadQuotePricer pricer = PairPadQuotePricer(vm.envOr("QUOTE_PRICER", RH_QUOTE_PRICER));
        address token = vm.envAddress("TOKEN");
        uint256 buyEth = vm.envOr("BUY_ETH", uint256(0));
        uint256 sellBps = vm.envOr("SELL_BPS", uint256(0));

        IPairPadMultiLaunchFactory.Market[] memory markets = factory.getMarkets(token);
        uint256 n = markets.length;
        require(n > 0, "not a multi-market token");

        // Routes quote -> ETH from the pricer; buys walk them backwards.
        Hop[][] memory sellHops = new Hop[][](n);
        Hop[][] memory buyHops = new Hop[][](n);
        for (uint256 i = 0; i < n; i++) {
            if (markets[i].pairToken == address(0)) continue;
            (Hop[] memory hops,) = pricer.route(markets[i].pairToken);
            require(hops.length > 0, "quote has no route to ETH");
            sellHops[i] = hops;
            buyHops[i] = new Hop[](hops.length);
            for (uint256 j = 0; j < hops.length; j++) buyHops[i][j] = hops[hops.length - 1 - j];
        }

        vm.startBroadcast(key);

        if (buyEth > 0) {
            uint256 got = router.buyWithEth{value: buyEth}(token, _legs(buyHops, buyEth), 0, me);
            console2.log("bought tokens:", got);
        }
        if (sellBps > 0) {
            uint256 toSell = IERC20(token).balanceOf(me) * sellBps / 10_000;
            IERC20(token).approve(address(router), toSell);
            uint256 ethOut = router.sellToEth(token, _legs(sellHops, toSell), 0, me);
            console2.log("sold tokens:", toSell);
            console2.log("eth out:    ", ethOut);
        }

        vm.stopBroadcast();
        console2.log("balance now:", IERC20(token).balanceOf(me));
    }

    function _legs(Hop[][] memory hops, uint256 total) internal pure returns (PairPadMultiRouter.Leg[] memory legs) {
        uint256 n = hops.length;
        legs = new PairPadMultiRouter.Leg[](n);
        uint256 assigned;
        for (uint256 i = 0; i < n; i++) {
            uint256 slice = i == n - 1 ? total - assigned : total / n;
            assigned += slice;
            legs[i] = PairPadMultiRouter.Leg({market: uint8(i), hops: hops[i], amountIn: slice});
        }
    }
}
