// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {PairPadLaunchFactory} from "../src/v2/PairPadLaunchFactory.sol";
import {PairPadLauncherToken} from "../src/v2/PairPadLauncherToken.sol";
import {PairPadPositionMath} from "../src/v2/libraries/PairPadPositionMath.sol";

import {TestStack} from "./utils/TestStack.sol";

/**
 * @notice Unit coverage for the parts of the stack that do not need a live
 * Uniswap V4: the position math that makes a single V4 position behave as
 * the bonding curve, factory configuration and admin paths, and the token's
 * on-chain metadata. Launch, trade and fee flows run against a mainnet fork
 * in test/fork/Lifecycle.fork.t.sol.
 */
contract LaunchpadTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant PHANTOM = 1.68 ether;
    uint256 constant THRESHOLD = 4.2 ether;

    TestStack internal stack;
    PairPadLaunchFactory internal factory;

    receive() external payable {}

    function setUp() public {
        stack = new TestStack(address(this));
        factory = stack.factory();
        factory.setPositionMinter(stack.minter());
        factory.setLaunchDeployer(stack.launchDeployer());
        factory.setLaunchForwarder(makeAddr("forwarder"));
        factory.addLaunchConfig(_config(10));
        factory.setLaunchEnabled(true);
    }

    function _config(int24 tickSpacing) internal pure returns (PairPadLaunchFactory.LaunchConfig memory) {
        return PairPadLaunchFactory.LaunchConfig({
            supply: SUPPLY, phantomQuote: PHANTOM, tickSpacing: tickSpacing, enabled: true
        });
    }

    // -------------------------------------------------------------------
    // Position math: one position == the bonding curve
    // -------------------------------------------------------------------

    /// @dev Both currency orders must open at the configured price (within
    /// half a tick spacing) and fit the whole supply into the position.
    function test_plan_bothOrders_openAtConfiguredPriceAndFitSupply() public pure {
        for (uint256 i = 0; i < 2; ++i) {
            bool tokenIs0 = i == 0;
            PairPadPositionMath.Plan memory p = PairPadPositionMath.plan(tokenIs0, SUPPLY, PHANTOM, 10);

            // quote per token, computed from the pool's sqrt price.
            uint256 priceX96 = (uint256(p.sqrtPriceX96) * uint256(p.sqrtPriceX96)) >> 96;
            uint256 quotePerTokenX96 = tokenIs0 ? priceX96 : ((1 << 192) / priceX96);
            uint256 expectedX96 = (PHANTOM << 96) / SUPPLY;
            // 10 ticks = 0.1%; nearest rounding keeps it within 0.05%.
            assertApproxEqRel(quotePerTokenX96, expectedX96, 0.0005e18, "opening price");

            uint256 needed = PairPadPositionMath.tokenAmountFor(tokenIs0, p);
            assertLe(needed, SUPPLY, "position must not need more than the supply");
            assertGt(needed, SUPPLY - SUPPLY / 1e9, "dust must be negligible");

            // The position's liquidity is sqrt(P * S), the curve's invariant.
            uint256 lSquared = uint256(p.liquidity) * uint256(p.liquidity);
            assertApproxEqRel(lSquared, PHANTOM * SUPPLY, 0.001e18, "liquidity squared");
        }
    }

    /// @dev Reading the position at the price where it holds the threshold in
    /// quote must leave exactly the curve's share of tokens in it: with
    /// threshold = 2.5x phantom, 1 / 3.5 of the supply stays, 71.4% is sold.
    function test_plan_thresholdPriceLeavesCurveShareOfSupply() public pure {
        PairPadPositionMath.Plan memory p = PairPadPositionMath.plan(true, SUPPLY, PHANTOM, 10);
        // Along the curve: quote in position q  =>  tokens left t = P*S / (P + q).
        // Position: q = L * (sqrtP - sqrtP0)  =>  sqrtP = sqrtP0 + q / L.
        uint256 sqrtAtThreshold = uint256(p.sqrtPriceX96) + (THRESHOLD << 96) / p.liquidity;
        (uint256 tokensLeft, uint256 quoteHeld) = PairPadPositionMath.amountsForLiquidity(
            uint160(sqrtAtThreshold), p.tickLower, p.tickUpper, p.liquidity
        );
        assertApproxEqRel(quoteHeld, THRESHOLD, 0.0001e18, "quote at threshold");
        assertApproxEqRel(tokensLeft, (SUPPLY * 10) / 35, 0.001e18, "tokens left at threshold");
    }

    /// @dev A six-decimal quote (USDG-like: 5000 phantom, 12500 threshold)
    /// must still lay out, in either currency order.
    function test_plan_sixDecimalQuote() public pure {
        PairPadPositionMath.Plan memory a = PairPadPositionMath.plan(true, SUPPLY, 5_000e6, 10);
        PairPadPositionMath.Plan memory b = PairPadPositionMath.plan(false, SUPPLY, 5_000e6, 10);
        assertGt(a.liquidity, 0);
        assertGt(b.liquidity, 0);
        assertLe(PairPadPositionMath.tokenAmountFor(true, a), SUPPLY);
        assertLe(PairPadPositionMath.tokenAmountFor(false, b), SUPPLY);
        assertGt(a.tickLower, TickMath.MIN_TICK);
        assertLt(b.tickUpper, TickMath.MAX_TICK);
    }

    function test_plan_priceCannotGoBelowOpening() public pure {
        PairPadPositionMath.Plan memory p = PairPadPositionMath.plan(true, SUPPLY, PHANTOM, 10);
        // Below the range the position is all token: nothing to sell into.
        (uint256 amount0, uint256 amount1) = PairPadPositionMath.amountsForLiquidity(
            p.sqrtPriceX96 - 1, p.tickLower, p.tickUpper, p.liquidity
        );
        assertEq(amount1, 0);
        assertApproxEqRel(amount0, SUPPLY, 1e9);
    }

    // -------------------------------------------------------------------
    // Factory configuration
    // -------------------------------------------------------------------

    function test_addLaunchConfig_rejectsBadTerms() public {
        PairPadLaunchFactory.LaunchConfig memory bad = _config(10);
        bad.supply = 0.5 ether;
        vm.expectRevert(PairPadLaunchFactory.SupplyTooLow.selector);
        factory.addLaunchConfig(bad);

        bad = _config(0);
        vm.expectRevert(PairPadLaunchFactory.InvalidTickSpacing.selector);
        factory.addLaunchConfig(bad);

        bad = _config(10);
        bad.phantomQuote = 0;
        vm.expectRevert(PairPadLaunchFactory.InvalidPhantomQuote.selector);
        factory.addLaunchConfig(bad);
    }

    function test_addLaunchConfig_acceptsMicroTerms() public {
        PairPadLaunchFactory.LaunchConfig memory micro = _config(10);
        micro.phantomQuote = 0.0004 ether;
        uint256 id = factory.addLaunchConfig(micro);
        assertEq(id, 1);
    }

    function test_launchEconomics_pinCoversFeePolicy() public {
        bytes32 before = factory.previewLaunchEconomics(0, address(0));
        factory.setBaseFeeBps(50);
        assertTrue(factory.previewLaunchEconomics(0, address(0)) != before);
        bytes32 afterFee = factory.previewLaunchEconomics(0, address(0));
        factory.setProtocolFeeShareBps(2_500);
        assertTrue(factory.previewLaunchEconomics(0, address(0)) != afterFee);
    }

    function test_feeSettings_bounds() public {
        vm.expectRevert(PairPadLaunchFactory.InvalidBasisPoints.selector);
        factory.setBaseFeeBps(1_001);
        factory.setBaseFeeBps(1_000);
        vm.expectRevert(PairPadLaunchFactory.InvalidBasisPoints.selector);
        factory.setProtocolFeeShareBps(10_001);
        factory.setProtocolFeeShareBps(10_000);
        vm.expectRevert(PairPadLaunchFactory.InvalidBasisPoints.selector);
        factory.setMaxCreatorTaxBps(1_001);
        vm.expectRevert(PairPadLaunchFactory.ZeroAddress.selector);
        factory.setProtocolFeeRecipient(address(0));
    }

    /// @dev V4 counts the LP fee in hundredths of a bip: 1% base + 2% tax is 30_000.
    function test_poolFeeFor_pips() public {
        assertEq(factory.poolFeeFor(0), 10_000);
        assertEq(factory.poolFeeFor(200), 30_000);
        factory.setBaseFeeBps(50);
        assertEq(factory.poolFeeFor(0), 5_000);
    }

    function test_setPairTokenEconomics_rejectsCoarseDecimals() public {
        address usdg = address(stack.usdg());
        vm.expectRevert(PairPadLaunchFactory.PairTokenEconomicsInvalid.selector);
        factory.setPairTokenEconomics(usdg, 5_000e6, 4);
        factory.setPairTokenEconomics(usdg, 5_000e6, 6);
        assertEq(factory.previewQuoteEconomics(0, usdg), 5_000e6);
    }

    function test_launchTokenFor_onlyForwarder() public {
        vm.expectRevert(PairPadLaunchFactory.NotLaunchForwarder.selector);
        factory.launchTokenFor(_params("x"), 0, address(0), address(this));
    }

    function test_launch_requiresWiredDependencies() public {
        // The stack is wired, but the mocked PoolManager has no code path for
        // initialize, so a launch here can only get as far as the wiring
        // checks pass and the deploy itself. Check the gate that runs first.
        factory.setLaunchEnabled(false);
        vm.prank(makeAddr("nobody"));
        vm.expectRevert(PairPadLaunchFactory.NotWhitelisted.selector);
        factory.launchToken(_params("x"), 0, address(0));
    }

    function _params(bytes32 salt) internal pure returns (PairPadLaunchFactory.TokenParams memory) {
        return PairPadLaunchFactory.TokenParams({
            name: "Test Meme",
            symbol: "MEME",
            logo: "",
            description: "test",
            socials: PairPadLauncherToken.Socials("", "", "", "", ""),
            creatorFeeRecipient: address(0),
            creatorTaxBps: 0,
            expectedEconomics: bytes32(0),
            salt: salt
        });
    }

    // -------------------------------------------------------------------
    // ERC-7572 contract metadata
    // -------------------------------------------------------------------

    function _token(string memory name, string memory description, string memory logo, string memory website)
        internal
        returns (PairPadLauncherToken)
    {
        return new PairPadLauncherToken(
            name,
            "MEME",
            logo,
            description,
            PairPadLauncherToken.Socials("", "", "", website, ""),
            address(this),
            address(factory),
            address(this),
            SUPPLY
        );
    }

    function test_contractURI_inlineJsonFromLaunchFields() public {
        PairPadLauncherToken token = _token(
            "Test Meme",
            "A token.",
            "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi",
            "https://example.com/meme"
        );
        string memory expected = string.concat(
            "data:application/json;utf8,",
            '{"name":"Test Meme","symbol":"MEME","description":"A token.",',
            '"image":"ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi",',
            '"external_url":"https://example.com/meme","external_link":"https://example.com/meme",',
            '"website":"https://example.com/meme",',
            '"extensions":{"website":"https://example.com/meme"}}'
        );
        assertEq(token.contractURI(), expected);
        assertEq(token.tokenURI(), expected);
        assertEq(token.owner(), address(0));
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_contractURI_allSocialsInOrder() public {
        PairPadLauncherToken token = new PairPadLauncherToken(
            "Full",
            "FULL",
            "ipfs://x",
            "d",
            PairPadLauncherToken.Socials("https://x.com/a", "https://t.me/b", "https://discord.gg/c", "https://d.io", "https://warpcast.com/e"),
            address(this),
            address(factory),
            address(this),
            SUPPLY
        );
        assertEq(
            token.contractURI(),
            string.concat(
                "data:application/json;utf8,",
                '{"name":"Full","symbol":"FULL","description":"d","image":"ipfs://x",',
                '"external_url":"https://d.io","external_link":"https://d.io",',
                '"website":"https://d.io","twitter":"https://x.com/a","telegram":"https://t.me/b",',
                '"discord":"https://discord.gg/c","farcaster":"https://warpcast.com/e",',
                '"extensions":{"website":"https://d.io","twitter":"https://x.com/a","telegram":"https://t.me/b",',
                '"discord":"https://discord.gg/c","farcaster":"https://warpcast.com/e"}}'
            )
        );
    }

    function test_contractURI_escapesJsonAndOmitsEmptyLinks() public {
        PairPadLauncherToken token = _token('Say "hi"', "line1\nback\\slash\ttab\x01", "", "");
        assertEq(
            token.contractURI(),
            string.concat(
                "data:application/json;utf8,",
                '{"name":"Say \\"hi\\"","symbol":"MEME",',
                '"description":"line1\\nback\\\\slash\\ttab\\u0001","image":"","extensions":{}}'
            )
        );
    }
}
