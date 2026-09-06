// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {PairPadFeeEscrow} from "../src/v2/PairPadFeeEscrow.sol";
import {IPairPadFeeEscrow} from "../src/v2/interfaces/ILaunchpadV2.sol";
import {PairPadFeeSplitter} from "../src/fees/PairPadFeeSplitter.sol";
import {PairPadHolderVault} from "../src/fees/PairPadHolderVault.sol";
import {PairPadDisperse} from "../src/fees/PairPadDisperse.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RejectsEth {
    receive() external payable {
        revert("no");
    }
}

contract FeesTest is Test {
    PairPadFeeEscrow internal escrow;
    MockERC20 internal usdg;
    MockERC20 internal launchToken;

    address internal buybackWallet = makeAddr("buyback");
    address internal treasury = makeAddr("treasury");
    address internal distributor = makeAddr("distributor");

    PairPadFeeSplitter internal splitter;
    PairPadHolderVault internal vault;
    PairPadDisperse internal disperse;

    function setUp() public {
        escrow = new PairPadFeeEscrow();
        usdg = new MockERC20("USDG", "USDG", 6);
        launchToken = new MockERC20("Launch", "LNCH", 18);
        splitter = new PairPadFeeSplitter(buybackWallet, treasury, 8000);
        vault = new PairPadHolderVault(IPairPadFeeEscrow(address(escrow)), distributor);
        disperse = new PairPadDisperse();
        vm.deal(address(this), 100 ether);
    }

    // ---------------------------------------------------------------- splitter

    function test_splitter_constructorGuards() public {
        vm.expectRevert(PairPadFeeSplitter.ZeroAddress.selector);
        new PairPadFeeSplitter(address(0), treasury, 8000);
        vm.expectRevert(PairPadFeeSplitter.InvalidShare.selector);
        new PairPadFeeSplitter(buybackWallet, treasury, 0);
        vm.expectRevert(PairPadFeeSplitter.InvalidShare.selector);
        new PairPadFeeSplitter(buybackWallet, treasury, 10_001);
    }

    function test_splitter_receivesUnder50kGasAndFlushesEth() public {
        // The lockers send native fees with a 50k gas stipend; receiving must fit.
        (bool ok,) = address(splitter).call{value: 1 ether, gas: 50_000}("");
        assertTrue(ok);
        assertEq(address(splitter).balance, 1 ether);

        (uint256 a, uint256 b) = splitter.flush(address(0));
        assertEq(a, 0.8 ether);
        assertEq(b, 0.2 ether);
        assertEq(buybackWallet.balance, 0.8 ether);
        assertEq(treasury.balance, 0.2 ether);
        assertEq(address(splitter).balance, 0);
    }

    function test_splitter_flushesErc20AndRounding() public {
        usdg.mint(address(splitter), 1_000_001);
        splitter.flush(address(usdg));
        assertEq(usdg.balanceOf(buybackWallet), 800_000); // floor of 80%
        assertEq(usdg.balanceOf(treasury), 200_001); // remainder, nothing stranded
        assertEq(usdg.balanceOf(address(splitter)), 0);
    }

    function test_splitter_flushEmptyIsNoop() public {
        (uint256 a, uint256 b) = splitter.flush(address(usdg));
        assertEq(a + b, 0);
        (a, b) = splitter.flush(address(0));
        assertEq(a + b, 0);
    }

    function test_splitter_flushMany() public {
        usdg.mint(address(splitter), 500);
        (bool ok,) = address(splitter).call{value: 10}("");
        assertTrue(ok);
        address[] memory assets = new address[](2);
        assets[0] = address(0);
        assets[1] = address(usdg);
        splitter.flushMany(assets);
        assertEq(buybackWallet.balance, 8);
        assertEq(treasury.balance, 2);
        assertEq(usdg.balanceOf(buybackWallet), 400);
        assertEq(usdg.balanceOf(treasury), 100);
    }

    function test_splitter_revertsIfRecipientRejectsEth() public {
        RejectsEth bad = new RejectsEth();
        PairPadFeeSplitter s = new PairPadFeeSplitter(address(bad), treasury, 8000);
        (bool ok,) = address(s).call{value: 1 ether}("");
        assertTrue(ok);
        vm.expectRevert(abi.encodeWithSelector(PairPadFeeSplitter.NativeTransferFailed.selector, address(bad)));
        s.flush(address(0));
    }

    // ------------------------------------------------------------------- vault

    function test_vault_harvestsNativeAndTokenFromEscrow() public {
        // A locker credits the creator share to the escrow under the vault.
        escrow.credit{value: 2 ether}(address(vault));
        launchToken.mint(address(this), 5e18);
        launchToken.approve(address(escrow), 5e18);
        escrow.creditToken(address(vault), address(launchToken), 5e18);

        assertEq(vault.pending(address(0)), 2 ether);
        assertEq(vault.pending(address(launchToken)), 5e18);

        address[] memory assets = new address[](3);
        assets[0] = address(0);
        assets[1] = address(launchToken);
        assets[2] = address(usdg); // nothing there: skipped, no revert
        vm.prank(makeAddr("anyone"));
        vault.harvest(assets);

        assertEq(distributor.balance, 2 ether);
        assertEq(launchToken.balanceOf(distributor), 5e18);
        assertEq(vault.pending(address(0)), 0);
        assertEq(vault.pending(address(launchToken)), 0);
        assertEq(address(vault).balance, 0);
    }

    function test_vault_forwardsDirectDepositsToo() public {
        // Anything sent straight to the vault (not via escrow) is forwarded as well.
        usdg.mint(address(vault), 123);
        address[] memory assets = new address[](1);
        assets[0] = address(usdg);
        vault.harvest(assets);
        assertEq(usdg.balanceOf(distributor), 123);
    }

    function test_vault_hasNoWayToChangeAnything() public view {
        // Immutable wiring: there is no owner and no setter, by construction.
        assertEq(vault.distributor(), distributor);
        assertEq(address(vault.escrow()), address(escrow));
    }

    // ---------------------------------------------------------------- disperse

    function test_disperse_sendsToManyAndEmits() public {
        launchToken.mint(address(this), 100e18);
        launchToken.approve(address(disperse), type(uint256).max);
        address[] memory to = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        to[0] = makeAddr("h1");
        to[1] = makeAddr("h2");
        to[2] = makeAddr("h3");
        amounts[0] = 10e18;
        amounts[1] = 0; // skipped
        amounts[2] = 30e18;

        vm.expectEmit(true, true, true, true);
        emit PairPadDisperse.Dispersed(address(launchToken), address(this), 42, 40e18, 3);
        uint256 total = disperse.disperseToken(IERC20(address(launchToken)), to, amounts, 42);

        assertEq(total, 40e18);
        assertEq(launchToken.balanceOf(to[0]), 10e18);
        assertEq(launchToken.balanceOf(to[1]), 0);
        assertEq(launchToken.balanceOf(to[2]), 30e18);
        assertEq(launchToken.balanceOf(address(this)), 60e18);
        assertEq(launchToken.balanceOf(address(disperse)), 0);
    }

    function test_disperse_guards() public {
        address[] memory to = new address[](1);
        uint256[] memory amounts = new uint256[](2);
        vm.expectRevert(PairPadDisperse.LengthMismatch.selector);
        disperse.disperseToken(IERC20(address(launchToken)), to, amounts, 1);

        uint256[] memory one = new uint256[](1);
        to[0] = makeAddr("h");
        vm.expectRevert(PairPadDisperse.NothingToSend.selector);
        disperse.disperseToken(IERC20(address(launchToken)), to, one, 1);
    }

    function test_disperse_failsWithoutApproval() public {
        launchToken.mint(address(this), 1e18);
        address[] memory to = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        to[0] = makeAddr("h");
        amounts[0] = 1e18;
        vm.expectRevert();
        disperse.disperseToken(IERC20(address(launchToken)), to, amounts, 1);
    }
}
