// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PairPadFeeEscrow} from "../../src/v2/PairPadFeeEscrow.sol";
import {PairPadLaunchFactory} from "../../src/v2/PairPadLaunchFactory.sol";
import {PairPadLaunchLocker} from "../../src/v2/PairPadLaunchLocker.sol";
import {PairPadRouter} from "../../src/v2/PairPadRouter.sol";
import {PairPadLauncherToken} from "../../src/v2/PairPadLauncherToken.sol";
import {PairPadMultiLaunchFactory} from "../../src/v3/PairPadMultiLaunchFactory.sol";
import {PairPadMultiLaunchLocker} from "../../src/v3/PairPadMultiLaunchLocker.sol";
import {IPairPadFeeEscrow} from "../../src/v2/interfaces/ILaunchpadV2.sol";
import {
    PairPadBurnVault, IPairPadSwapRouter, ISingleLaunchFactory, IMultiLaunchFactory
} from "../../src/fees/PairPadBurnVault.sol";

/**
 * @notice The burn vault against the live mainnet stack: a launch names it
 * as creator recipient, trades happen, a collection credits it through the
 * escrow, and a round buys the token in its own pool and burns it.
 *
 *   forge test --match-path "test/fork/BurnVault*" --fork-url robinhood
 */
contract BurnVaultForkTest is Test {
    using PoolIdLibrary for PoolKey;

    address constant V2_FACTORY = 0x9d33Ba78389c8772bC114Cba47Dc1985E933e76F;
    address constant V2_ROUTER = 0x73d84bdbB1983Fa7eD8FCBcE40bc308997cEd120;
    address constant V2_LOCKER = 0x8a6d37B2E6a2AC7970eF69d2932757F04be0A231;
    address constant MULTI_FACTORY = 0x3ea29975a79900179F3e1aEF93347Ba4210c29C1;
    address constant MULTI_LOCKER = 0x5826FBB6201DaAcD924A3d292841DA9142952D59;
    address constant FEE_ESCROW = 0x1C27e8F0c2a754DB23ab1608fA09c068D54d4386;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    PairPadLaunchFactory factory = PairPadLaunchFactory(V2_FACTORY);
    PairPadRouter router = PairPadRouter(payable(V2_ROUTER));
    PairPadLaunchLocker locker = PairPadLaunchLocker(payable(V2_LOCKER));
    PairPadFeeEscrow escrow = PairPadFeeEscrow(FEE_ESCROW);

    PairPadBurnVault vault;

    address operator = makeAddr("operator");
    address creator = makeAddr("creator");
    address trader = makeAddr("trader");

    modifier onlyFork() {
        if (block.chainid != 4663) vm.skip(true);
        _;
    }

    function setUp() public {
        if (block.chainid != 4663) return;
        vault = new PairPadBurnVault(
            IPairPadFeeEscrow(FEE_ESCROW),
            IPairPadSwapRouter(V2_ROUTER),
            ISingleLaunchFactory(V2_FACTORY),
            IMultiLaunchFactory(MULTI_FACTORY),
            operator
        );
        vm.deal(creator, 10 ether);
        vm.deal(trader, 50 ether);
    }

    function _launchEthQuoted(uint16 taxBps) internal returns (address token, PoolKey memory key) {
        PairPadLaunchFactory.TokenParams memory p = PairPadLaunchFactory.TokenParams({
            name: "Burn",
            symbol: "BURN",
            logo: "",
            description: "buyback and burn e2e",
            socials: PairPadLauncherToken.Socials("", "", "", "", ""),
            creatorFeeRecipient: address(vault),
            creatorTaxBps: taxBps,
            expectedEconomics: bytes32(0),
            salt: keccak256(abi.encode(address(vault), taxBps, block.number))
        });
        uint256 fee = factory.launchFee();
        vm.prank(creator);
        (token,) = factory.launchToken{value: fee}(p, 0, address(0));
        key = factory.poolKeyFor(token);
    }

    function test_fork_singleMarket_roundBuysInOwnPoolAndBurns() public onlyFork {
        (address token, PoolKey memory key) = _launchEthQuoted(0);
        assertEq(factory.getLaunchedToken(token).creatorFeeRecipient, address(vault));

        // A buy (fee in ETH) and a sell (fee in the token).
        vm.startPrank(trader);
        uint256 got = router.swapExactIn{value: 5 ether}(key, true, 5 ether, 0, trader);
        IERC20(token).approve(address(router), got);
        router.swapExactIn(key, false, got / 2, 0, trader);
        vm.stopPrank();

        locker.collectFees(token);
        uint256 vaultEth = escrow.balanceOf(address(vault));
        uint256 vaultTok = escrow.balanceOfToken(address(vault), token);
        assertGt(vaultEth, 0, "creator ETH credited to vault");
        assertGt(vaultTok, 0, "creator token credited to vault");
        assertEq(vault.pending(address(0)), vaultEth);

        // The vault's pool lookup matches the factory's record.
        PoolKey memory k = vault.poolKeyFor(token, address(0));
        assertEq(PoolId.unwrap(k.toId()), PoolId.unwrap(key.toId()));

        uint256 supplyBefore = IERC20(token).totalSupply();
        uint256 poolEthBefore = _poolEth(key);

        vm.prank(operator);
        (uint256 out, uint256 burnedNow) = vault.buyback(token, address(0), vaultEth, 1);

        assertGt(out, 0, "bought something");
        assertEq(burnedNow, out + vaultTok, "burned the buy and the token share");
        assertEq(IERC20(token).totalSupply(), supplyBefore - burnedNow, "supply shrank by exactly that");
        assertEq(IERC20(token).balanceOf(address(vault)), 0);
        assertEq(address(vault).balance, 0, "all ETH spent");
        assertEq(vault.pending(address(0)), 0);
        assertEq(vault.pending(token), 0);
        assertEq(vault.burned(token), burnedNow);
        assertEq(vault.spent(token, address(0)), vaultEth);
        assertGt(_poolEth(key), poolEthBefore, "the ETH went into the token's pool");

        console2.log("creator ETH spent", vaultEth);
        console2.log("tokens bought", out);
        console2.log("tokens burned", burnedNow);
    }

    function test_fork_multiMarket_usdgRoundUsesTheUsdgPool() public onlyFork {
        PairPadMultiLaunchFactory mf = PairPadMultiLaunchFactory(MULTI_FACTORY);
        PairPadMultiLaunchFactory.TokenParams memory p = PairPadMultiLaunchFactory.TokenParams({
            name: "Burn Multi",
            symbol: "BURNM",
            logo: "",
            description: "buyback and burn multi e2e",
            socials: PairPadLauncherToken.Socials("", "", "", "", ""),
            creatorFeeRecipient: address(vault),
            creatorTaxBps: 0,
            expectedEconomics: bytes32(0),
            salt: keccak256(abi.encode("multi", address(vault), block.number))
        });
        address[] memory quotes = new address[](2);
        quotes[0] = address(0);
        quotes[1] = USDG;
        uint256 fee = mf.launchFee();
        vm.prank(creator);
        address token = mf.launchToken{value: fee}(p, 0, quotes);
        assertEq(mf.getLaunchedToken(token).creatorFeeRecipient, address(vault));

        PoolKey memory usdgKey = mf.poolKeyFor(token, 1);
        PoolKey memory viaVault = vault.poolKeyFor(token, USDG);
        assertEq(PoolId.unwrap(viaVault.toId()), PoolId.unwrap(usdgKey.toId()), "vault finds the USDG market");
        PoolKey memory ethViaVault = vault.poolKeyFor(token, address(0));
        assertEq(PoolId.unwrap(ethViaVault.toId()), PoolId.unwrap(mf.poolKeyFor(token, 0).toId()));

        // Trade the USDG market directly: buy with USDG, sell half back.
        deal(USDG, trader, 20_000e6);
        bool usdgIs0 = USDG < token;
        vm.startPrank(trader);
        IERC20(USDG).approve(address(router), type(uint256).max);
        uint256 got = router.swapExactIn(usdgKey, usdgIs0, 10_000e6, 0, trader);
        IERC20(token).approve(address(router), got);
        router.swapExactIn(usdgKey, !usdgIs0, got / 2, 0, trader);
        vm.stopPrank();

        PairPadMultiLaunchLocker(payable(MULTI_LOCKER)).collectFees(token);
        uint256 vaultUsdg = escrow.balanceOfToken(address(vault), USDG);
        uint256 vaultTok = escrow.balanceOfToken(address(vault), token);
        assertGt(vaultUsdg, 0, "creator USDG credited to vault");
        assertGt(vaultTok, 0, "creator token credited to vault");

        uint256 supplyBefore = IERC20(token).totalSupply();
        vm.prank(operator);
        (uint256 out, uint256 burnedNow) = vault.buyback(token, USDG, vaultUsdg, 1);
        assertGt(out, 0);
        assertEq(burnedNow, out + vaultTok);
        assertEq(IERC20(token).totalSupply(), supplyBefore - burnedNow);
        assertEq(IERC20(USDG).balanceOf(address(vault)), 0, "all USDG spent");
        assertEq(IERC20(USDG).allowance(address(vault), address(router)), 0);
        assertEq(vault.spent(token, USDG), vaultUsdg);

        console2.log("creator USDG spent", vaultUsdg);
        console2.log("tokens burned", burnedNow);
    }

    function test_fork_vaultCannotChangeRecipient() public onlyFork {
        (address token,) = _launchEthQuoted(0);
        vm.prank(creator);
        vm.expectRevert(PairPadLaunchFactory.NotCreatorFeeRecipient.selector);
        factory.transferCreatorFeeRecipient(token, creator);
        vm.prank(operator);
        vm.expectRevert(PairPadLaunchFactory.NotCreatorFeeRecipient.selector);
        factory.transferCreatorFeeRecipient(token, operator);
    }

    function test_fork_onlyOperatorRunsRounds_anyoneBurnsTokenSide() public onlyFork {
        (address token, PoolKey memory key) = _launchEthQuoted(0);
        vm.startPrank(trader);
        uint256 got = router.swapExactIn{value: 1 ether}(key, true, 1 ether, 0, trader);
        IERC20(token).approve(address(router), got);
        router.swapExactIn(key, false, got / 2, 0, trader);
        vm.stopPrank();
        locker.collectFees(token);

        uint256 tok = escrow.balanceOfToken(address(vault), token);
        assertGt(tok, 0);
        uint256 supply = IERC20(token).totalSupply();
        vm.prank(trader);
        assertEq(vault.burnToken(token), tok);
        assertEq(IERC20(token).totalSupply(), supply - tok);

        vm.prank(trader);
        vm.expectRevert(PairPadBurnVault.NotOperator.selector);
        vault.buyback(token, address(0), 1, 0);
    }

    /// @dev ETH held by the PoolManager on behalf of the pool is not directly
    /// readable, so use the price: more ETH in means a higher token price,
    /// i.e. a larger buy quote is needed for the same token amount. Cheaper:
    /// compare the manager's total ETH balance, which only this test moves.
    function _poolEth(PoolKey memory) internal view returns (uint256) {
        return address(router.manager()).balance;
    }
}
