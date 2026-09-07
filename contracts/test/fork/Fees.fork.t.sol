// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PairPadFeeEscrow} from "../../src/v2/PairPadFeeEscrow.sol";
import {PairPadLaunchFactory} from "../../src/v2/PairPadLaunchFactory.sol";
import {PairPadLaunchLocker} from "../../src/v2/PairPadLaunchLocker.sol";
import {PairPadRouter} from "../../src/v2/PairPadRouter.sol";
import {PairPadLauncherToken} from "../../src/v2/PairPadLauncherToken.sol";
import {PairPadMultiLaunchFactory} from "../../src/v3/PairPadMultiLaunchFactory.sol";
import {Hop} from "../../src/v2/libraries/Hop.sol";
import {IPairPadFeeEscrow} from "../../src/v2/interfaces/ILaunchpadV2.sol";
import {PairPadFeeSplitter} from "../../src/fees/PairPadFeeSplitter.sol";
import {PairPadHolderVault} from "../../src/fees/PairPadHolderVault.sol";
import {PairPadDisperse} from "../../src/fees/PairPadDisperse.sol";

/**
 * @notice The fee-routing add-ons against the live mainnet stack: the real
 * v2 factory, locker, escrow and router. The factories' owner points the
 * protocol recipient at a splitter; a launch names the holder vault as its
 * creator recipient; trades happen; a collection pays the splitter directly
 * and the vault through the escrow; flush and harvest move everything on.
 *
 *   forge test --match-path "test/fork/Fees*" --fork-url robinhood
 */
contract FeesForkTest is Test {
    address constant V2_FACTORY = 0x9d33Ba78389c8772bC114Cba47Dc1985E933e76F;
    address constant V2_ROUTER = 0x73d84bdbB1983Fa7eD8FCBcE40bc308997cEd120;
    address constant V2_LOCKER = 0x8a6d37B2E6a2AC7970eF69d2932757F04be0A231;
    address constant MULTI_FACTORY = 0x3ea29975a79900179F3e1aEF93347Ba4210c29C1;
    address constant FEE_ESCROW = 0x1C27e8F0c2a754DB23ab1608fA09c068D54d4386;

    PairPadLaunchFactory factory = PairPadLaunchFactory(V2_FACTORY);
    PairPadRouter router = PairPadRouter(payable(V2_ROUTER));
    PairPadLaunchLocker locker = PairPadLaunchLocker(payable(V2_LOCKER));
    PairPadFeeEscrow escrow = PairPadFeeEscrow(FEE_ESCROW);

    PairPadFeeSplitter splitter;
    PairPadHolderVault vault;
    PairPadDisperse disperse;

    address buybackWallet = makeAddr("buyback");
    address treasury = makeAddr("treasury");
    address distributor = makeAddr("distributor");
    address creator = makeAddr("creator");
    address trader = makeAddr("trader");

    modifier onlyFork() {
        if (block.chainid != 4663) vm.skip(true);
        _;
    }

    function setUp() public {
        if (block.chainid != 4663) return;
        splitter = new PairPadFeeSplitter(buybackWallet, treasury, 6000, address(factory), MULTI_FACTORY);
        vault = new PairPadHolderVault(IPairPadFeeEscrow(FEE_ESCROW), distributor);
        disperse = new PairPadDisperse();
        vm.deal(creator, 10 ether);
        vm.deal(trader, 50 ether);
    }

    function _setRecipient() internal {
        address owner = factory.owner();
        vm.prank(owner);
        factory.setProtocolFeeRecipient(address(splitter));
        assertEq(factory.protocolFeeRecipient(), address(splitter));
        // Same owner on the multi factory; the call shape is identical.
        address multiOwner = PairPadMultiLaunchFactory(MULTI_FACTORY).owner();
        vm.prank(multiOwner);
        PairPadMultiLaunchFactory(MULTI_FACTORY).setProtocolFeeRecipient(address(splitter));
    }

    function _launchEthQuoted(address creatorRecipient, uint16 taxBps) internal returns (address token, PoolKey memory key) {
        PairPadLaunchFactory.TokenParams memory p = PairPadLaunchFactory.TokenParams({
            name: "Holders",
            symbol: "HODL",
            logo: "",
            description: "fees to holders e2e",
            socials: PairPadLauncherToken.Socials("", "", "", "", ""),
            creatorFeeRecipient: creatorRecipient,
            creatorTaxBps: taxBps,
            expectedEconomics: bytes32(0),
            salt: keccak256(abi.encode(creatorRecipient, taxBps, block.number))
        });
        uint256 fee = factory.launchFee();
        vm.prank(creator);
        (token,) = factory.launchToken{value: fee}(p, 0, address(0));
        key = factory.poolKeyFor(token);
    }

    function test_fork_existingLaunchesKeepTheirSnapshottedRecipient() public onlyFork {
        // An older launch: its protocol recipient is frozen at launch time.
        address par = 0x507B6F349a80114097A67B8b4677367acC15b220;
        address before = factory.getLaunchedToken(par).protocolFeeRecipient;
        _setRecipient();
        assertEq(factory.getLaunchedToken(par).protocolFeeRecipient, before);
        assertTrue(before != address(splitter));
    }

    function test_fork_newLaunchPaysSplitterAndVault_flushAndHarvest() public onlyFork {
        _setRecipient();
        (address token, PoolKey memory key) = _launchEthQuoted(address(vault), 0);

        PairPadLaunchFactory.LaunchedToken memory l = factory.getLaunchedToken(token);
        assertEq(l.protocolFeeRecipient, address(splitter), "protocol recipient snapshot");
        assertEq(l.creatorFeeRecipient, address(vault), "creator recipient is the vault");

        // Trades: a buy (fee in ETH) and a sell (fee in the token).
        vm.startPrank(trader);
        uint256 got = router.swapExactIn{value: 5 ether}(key, true, 5 ether, 0, trader);
        IERC20(token).approve(address(router), got);
        router.swapExactIn(key, false, got / 2, 0, trader);
        vm.stopPrank();

        uint256 splitterEthBefore = address(splitter).balance;
        (uint256 amount0, uint256 amount1) = locker.collectFees(token);
        assertGt(amount0 + amount1, 0, "something collected");

        // Protocol ETH landed on the splitter directly (no escrow fallback needed).
        uint256 protocolEth = address(splitter).balance - splitterEthBefore;
        assertGt(protocolEth, 0, "splitter got protocol ETH");
        assertEq(escrow.balanceOf(address(splitter)), 0, "splitter never needed the escrow fallback");

        // Creator ETH and creator token share sit in the escrow under the vault.
        uint256 vaultEth = escrow.balanceOf(address(vault));
        uint256 vaultTok = escrow.balanceOfToken(address(vault), token);
        assertGt(vaultEth, 0, "vault credited ETH");
        assertGt(vaultTok, 0, "vault credited token");
        // 50/50 split: creator's ETH equals protocol's ETH (within rounding).
        assertApproxEqAbs(vaultEth, protocolEth, 2);

        // The launch fee the factory paid at creation went straight through
        // to the treasury; only protocol trading fees wait for the flush.
        assertEq(treasury.balance, factory.launchFee(), "launch fee forwarded to treasury");
        uint256 held = address(splitter).balance;
        assertEq(held, protocolEth);
        splitter.flush(address(0));
        assertEq(buybackWallet.balance, (held * 6000) / 10_000);
        assertEq(treasury.balance, factory.launchFee() + held - (held * 6000) / 10_000);
        assertEq(address(splitter).balance, 0);

        // Harvest to the distributor.
        address[] memory assets = new address[](2);
        assets[0] = address(0);
        assets[1] = token;
        vault.harvest(assets);
        assertEq(distributor.balance, vaultEth);
        assertEq(IERC20(token).balanceOf(distributor), vaultTok);
        assertEq(vault.pending(address(0)), 0);
        assertEq(vault.pending(token), 0);

        // The distributor sends the token share to holders in one transaction.
        address[] memory holders = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        holders[0] = makeAddr("h1");
        holders[1] = makeAddr("h2");
        amounts[0] = (vaultTok * 7) / 10;
        amounts[1] = vaultTok - amounts[0];
        vm.startPrank(distributor);
        IERC20(token).approve(address(disperse), type(uint256).max);
        disperse.disperseToken(IERC20(token), holders, amounts, block.timestamp);
        vm.stopPrank();
        assertEq(IERC20(token).balanceOf(holders[0]), amounts[0]);
        assertEq(IERC20(token).balanceOf(holders[1]), amounts[1]);
        assertEq(IERC20(token).balanceOf(distributor), 0);

        console2.log("protocol ETH to splitter", protocolEth);
        console2.log("creator ETH to vault", vaultEth);
        console2.log("creator token to vault", vaultTok);
    }

    function test_fork_creatorTaxAlsoGoesToHolders() public onlyFork {
        _setRecipient();
        (address token, PoolKey memory key) = _launchEthQuoted(address(vault), 500); // 5% creator tax
        vm.prank(trader);
        router.swapExactIn{value: 1 ether}(key, true, 1 ether, 0, trader);
        locker.collectFees(token);
        uint256 vaultEth = escrow.balanceOf(address(vault));
        uint256 protocolEth = address(splitter).balance;
        // With a 5% tax on top of the 1% base, the creator side is far larger than the protocol's.
        assertGt(vaultEth, protocolEth * 5);
    }

    function test_fork_vaultCannotChangeRecipient() public onlyFork {
        _setRecipient();
        (address token,) = _launchEthQuoted(address(vault), 0);
        // Only the recipient may propose a change, and the vault has no code path to do so.
        vm.prank(creator);
        vm.expectRevert(PairPadLaunchFactory.NotCreatorFeeRecipient.selector);
        factory.transferCreatorFeeRecipient(token, creator);
        vm.prank(distributor);
        vm.expectRevert(PairPadLaunchFactory.NotCreatorFeeRecipient.selector);
        factory.transferCreatorFeeRecipient(token, distributor);
    }
}
