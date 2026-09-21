// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {CreatorAccountFactory} from "../src/creator/CreatorAccountFactory.sol";
import {CreatorAccount} from "../src/creator/CreatorAccount.sol";
import {PairPadFeeEscrow} from "../src/v2/PairPadFeeEscrow.sol";
import {IPairPadFeeEscrow} from "../src/v2/interfaces/ILaunchpadV2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract CreatorAccountTest is Test {
    CreatorAccountFactory factory;
    PairPadFeeEscrow escrow;
    MockERC20 usd;

    uint256 attesterKey = 0xA11CE;
    address attester = vm.addr(attesterKey);
    uint256 rogueKey = 0xBAD;
    address admin = makeAddr("admin");
    address creatorWallet = makeAddr("creatorWallet");
    address attacker = makeAddr("attacker");
    address anyone = makeAddr("anyone");

    bytes32 constant X = keccak256("x");
    bytes32 constant GITHUB = keccak256("github");
    bytes32 idX = keccak256(bytes("2095190242215034887"));
    bytes32 idGh = keccak256(bytes("324152240"));

    function setUp() public {
        factory = new CreatorAccountFactory(admin, attester);
        escrow = new PairPadFeeEscrow();
        usd = new MockERC20("USD", "USD", 6);
    }

    // ---------------------------------------------------------- addresses

    function test_accountAddressIsDeterministicAndPlatformScoped() public view {
        address a = factory.accountOf(X, idX);
        assertEq(a, factory.accountFor("x", "2095190242215034887"));
        assertTrue(a != factory.accountOf(GITHUB, idX), "same id on another platform is another account");
        assertTrue(a != factory.accountOf(X, idGh));
    }

    function test_fundsSentBeforeDeployStay() public {
        address a = factory.accountOf(X, idX);
        vm.deal(anyone, 1 ether);
        vm.prank(anyone);
        (bool ok,) = a.call{value: 1 ether}("");
        assertTrue(ok);
        usd.mint(a, 5e6);
        assertEq(a.code.length, 0);
        address deployed = factory.deploy(X, idX);
        assertEq(deployed, a);
        assertEq(a.balance, 1 ether);
        assertEq(usd.balanceOf(a), 5e6);
        assertEq(factory.deploy(X, idX), a, "idempotent");
    }

    // -------------------------------------------------------------- claim

    function test_claimFlow_immediateOwner() public {
        CreatorAccount acct = CreatorAccount(payable(factory.deploy(X, idX)));
        vm.deal(address(acct), 1 ether);
        (bytes32 nonce, uint256 deadline, bytes memory sig) = _attest(attesterKey, X, idX, address(acct), creatorWallet);

        // Nothing moves before the claim.
        vm.prank(creatorWallet);
        vm.expectRevert(CreatorAccount.NotOwner.selector);
        acct.withdraw(address(0), creatorWallet, 1 ether);

        vm.prank(anyone); // whoever relays the claim; the owner is the attested wallet
        acct.claim(creatorWallet, nonce, deadline, sig);
        assertEq(acct.owner(), creatorWallet);

        vm.prank(creatorWallet);
        acct.withdraw(address(0), creatorWallet, 1 ether);
        assertEq(creatorWallet.balance, 1 ether);
    }

    function test_claim_rejectsWrongSigner_expired_replay_wrongAccount() public {
        CreatorAccount acct = CreatorAccount(payable(factory.deploy(X, idX)));
        (bytes32 nonce, uint256 deadline, bytes memory bad) = _attest(rogueKey, X, idX, address(acct), attacker);
        vm.expectRevert(CreatorAccountFactory.BadSignature.selector);
        acct.claim(attacker, nonce, deadline, bad);

        (bytes32 n2, uint256 d2, bytes memory sig) = _attest(attesterKey, X, idX, address(acct), creatorWallet);
        // Signature for creatorWallet cannot be used for another newOwner.
        vm.expectRevert(CreatorAccountFactory.BadSignature.selector);
        acct.claim(attacker, n2, d2, sig);

        // Expired.
        vm.warp(d2 + 1);
        vm.expectRevert(CreatorAccountFactory.Expired.selector);
        acct.claim(creatorWallet, n2, d2, sig);
        vm.warp(d2 - 1);

        // Valid once; the account is then owned and any further claim is
        // rejected outright, attestation or not.
        acct.claim(creatorWallet, n2, d2, sig);
        assertEq(acct.owner(), creatorWallet);
        vm.expectRevert(CreatorAccount.AlreadyOwned.selector);
        acct.claim(creatorWallet, n2, d2, sig);
        // The nonce itself is burned in the factory.
        assertTrue(factory.usedNonce(n2));

        // An attestation for account A cannot be used on account B.
        CreatorAccount other = CreatorAccount(payable(factory.deploy(GITHUB, idGh)));
        (bytes32 n3, uint256 d3, bytes memory sigA) = _attest(attesterKey, X, idX, address(acct), creatorWallet);
        vm.expectRevert(CreatorAccountFactory.BadSignature.selector);
        other.claim(creatorWallet, n3, d3, sigA);
    }

    function test_afterOwnership_attestationIsPowerless() public {
        CreatorAccount acct = _claimed();
        (bytes32 n, uint256 d, bytes memory s) = _attest(attesterKey, X, idX, address(acct), attacker);
        vm.expectRevert(CreatorAccount.AlreadyOwned.selector);
        acct.claim(attacker, n, d, s);

        // Two-step transfer, owner only.
        vm.prank(attacker);
        vm.expectRevert(CreatorAccount.NotOwner.selector);
        acct.transferOwnership(attacker);
        vm.prank(creatorWallet);
        acct.transferOwnership(anyone);
        assertEq(acct.owner(), creatorWallet, "unchanged until accepted");
        vm.prank(attacker);
        vm.expectRevert(CreatorAccount.NotProposedOwner.selector);
        acct.acceptOwnership();
        vm.prank(anyone);
        acct.acceptOwnership();
        assertEq(acct.owner(), anyone);
    }

    function test_rotatedAttester_oldSignaturesFail() public {
        CreatorAccount acct = CreatorAccount(payable(factory.deploy(X, idX)));
        (bytes32 n, uint256 d, bytes memory s) = _attest(attesterKey, X, idX, address(acct), creatorWallet);
        vm.prank(attacker);
        vm.expectRevert();
        factory.setAttester(attacker);
        vm.prank(admin);
        factory.setAttester(vm.addr(0xC0FFEE));
        vm.expectRevert(CreatorAccountFactory.BadSignature.selector);
        acct.claim(creatorWallet, n, d, s);
    }

    // -------------------------------------------------------------- funds

    function test_pullFromEscrow_permissionless_andWithdraw() public {
        address a = factory.accountOf(GITHUB, idGh);
        // Fees credited before the account exists.
        vm.deal(address(this), 2 ether);
        escrow.credit{value: 2 ether}(a);
        usd.mint(address(this), 10e6);
        usd.approve(address(escrow), 10e6);
        escrow.creditToken(a, address(usd), 10e6);

        CreatorAccount acct = CreatorAccount(payable(factory.deploy(GITHUB, idGh)));
        vm.startPrank(anyone);
        assertEq(acct.pull(IPairPadFeeEscrow(address(escrow)), address(0)), 2 ether);
        assertEq(acct.pull(IPairPadFeeEscrow(address(escrow)), address(usd)), 10e6);
        vm.stopPrank();
        assertEq(address(acct).balance, 2 ether);
        assertEq(usd.balanceOf(address(acct)), 10e6);

        // Still nobody can take it out before the claim.
        vm.prank(anyone);
        vm.expectRevert(CreatorAccount.NotOwner.selector);
        acct.withdraw(address(usd), anyone, 10e6);
        vm.prank(anyone);
        vm.expectRevert(CreatorAccount.NotOwner.selector);
        acct.execute(address(usd), 0, abi.encodeCall(usd.transfer, (anyone, 10e6)));

        _claimAccount(acct, GITHUB, idGh);
        vm.startPrank(creatorWallet);
        acct.withdraw(address(usd), creatorWallet, 10e6);
        acct.execute(address(this), 0.5 ether, "");
        vm.stopPrank();
        assertEq(usd.balanceOf(creatorWallet), 10e6);
        assertEq(address(acct).balance, 1.5 ether);
    }

    receive() external payable {}

    // ------------------------------------------------------------ helpers

    function _claimed() private returns (CreatorAccount acct) {
        acct = CreatorAccount(payable(factory.deploy(X, idX)));
        _claimAccount(acct, X, idX);
    }

    function _claimAccount(CreatorAccount acct, bytes32 platform, bytes32 idHash) private {
        (bytes32 n, uint256 d, bytes memory s) = _attest(attesterKey, platform, idHash, address(acct), creatorWallet);
        vm.prank(creatorWallet);
        acct.claim(creatorWallet, n, d, s);
    }

    uint256 private nonceSeed;

    function _attest(uint256 key, bytes32 platform, bytes32 idHash, address account, address newOwner)
        private
        returns (bytes32 nonce, uint256 deadline, bytes memory sig)
    {
        nonce = keccak256(abi.encode("nonce", ++nonceSeed));
        deadline = block.timestamp + 10 minutes;
        bytes32 digest = factory.claimDigest(platform, idHash, account, newOwner, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        sig = abi.encodePacked(r, s, v);
    }
}
