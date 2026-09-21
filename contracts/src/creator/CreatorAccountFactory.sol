// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {CreatorAccount, ICreatorAccountFactory} from "./CreatorAccount.sol";

/**
 * @title CreatorAccountFactory
 * @notice One address per social account, on every chain the same: the
 * CREATE2 address of a CreatorAccount for (platform, idHash), where
 * `platform` is keccak256 of the platform name ("x", "github") and `idHash`
 * keccak256 of the platform's immutable user id (never the handle: handles
 * change hands, ids do not).
 *
 * Launches name that address as their creator fee recipient. The account
 * holder later claims the address with an attestation: an EIP-712 message
 * signed by `attester` after the holder logged in on par.family, bound to
 * this chain, this factory, the account, the destination wallet, a
 * single-use nonce and a short deadline. The factory only ever checks
 * attestations for its own accounts, so a signature cannot be replayed
 * against a different account or on another chain.
 *
 * The owner can rotate `attester` (a leaked signer must be replaceable
 * without moving every account's address). That is the whole extent of
 * the owner's power: it cannot claim, move funds or change accounts.
 */
contract CreatorAccountFactory is Ownable2Step, ICreatorAccountFactory {
    error NotAccount();
    error BadSignature();
    error Expired();
    error NonceUsed();
    error ZeroAddress();

    event AccountDeployed(bytes32 indexed platform, bytes32 indexed idHash, address account);
    event AttesterSet(address indexed attester);
    event ClaimChecked(address indexed account, address indexed newOwner, bytes32 nonce);

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant CLAIM_TYPEHASH = keccak256(
        "Claim(bytes32 platform,bytes32 idHash,address account,address newOwner,bytes32 nonce,uint256 deadline)"
    );
    bytes32 public constant PLATFORM_X = keccak256("x");
    bytes32 public constant PLATFORM_GITHUB = keccak256("github");

    address public attester;
    mapping(bytes32 nonce => bool used) public usedNonce;

    constructor(address owner_, address attester_) Ownable(owner_) {
        if (attester_ == address(0)) revert ZeroAddress();
        attester = attester_;
        emit AttesterSet(attester_);
    }

    function setAttester(address attester_) external onlyOwner {
        if (attester_ == address(0)) revert ZeroAddress();
        attester = attester_;
        emit AttesterSet(attester_);
    }

    // -------------------------------------------------------------- accounts

    function salt(bytes32 platform, bytes32 idHash) public pure returns (bytes32) {
        return keccak256(abi.encode(platform, idHash));
    }

    function initCodeHash(bytes32 platform, bytes32 idHash) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(type(CreatorAccount).creationCode, abi.encode(address(this), platform, idHash))
        );
    }

    /// @notice The account's address, whether or not it has been deployed.
    function accountOf(bytes32 platform, bytes32 idHash) public view returns (address) {
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt(platform, idHash), initCodeHash(platform, idHash))))
            )
        );
    }

    /// @notice Convenience: the account for a platform name and raw user id.
    function accountFor(string calldata platformName, string calldata userId) external view returns (address) {
        return accountOf(keccak256(bytes(platformName)), keccak256(bytes(userId)));
    }

    /// @notice Deploys the account if it is not there yet. Anyone may call;
    /// balances already sent to the address are untouched.
    function deploy(bytes32 platform, bytes32 idHash) external returns (address account) {
        account = accountOf(platform, idHash);
        if (account.code.length != 0) return account;
        account = address(new CreatorAccount{salt: salt(platform, idHash)}(this, platform, idHash));
        emit AccountDeployed(platform, idHash, account);
    }

    // ---------------------------------------------------------- attestations

    /**
     * @notice Verifies an attestation and burns its nonce. Only the account
     * the attestation is for may call, so a valid signature is usable exactly
     * once, by exactly one contract.
     */
    function checkClaim(
        bytes32 platform,
        bytes32 idHash,
        address account,
        address newOwner,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (msg.sender != account || account != accountOf(platform, idHash)) revert NotAccount();
        if (block.timestamp > deadline) revert Expired();
        if (usedNonce[nonce]) revert NonceUsed();
        bytes32 digest = claimDigest(platform, idHash, account, newOwner, nonce, deadline);
        if (_recover(digest, signature) != attester) revert BadSignature();
        usedNonce[nonce] = true;
        emit ClaimChecked(account, newOwner, nonce);
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("par CreatorAccountFactory"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function claimDigest(
        bytes32 platform,
        bytes32 idHash,
        address account,
        address newOwner,
        bytes32 nonce,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(CLAIM_TYPEHASH, platform, idHash, account, newOwner, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    /// @dev Strict ECDSA recovery: 65-byte signature, low-s, v in {27, 28}.
    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address) {
        if (signature.length != 65) revert BadSignature();
        bytes32 r = bytes32(signature[0:32]);
        bytes32 s = bytes32(signature[32:64]);
        uint8 v = uint8(signature[64]);
        if (v < 27) v += 27;
        if (v != 27 && v != 28) revert BadSignature();
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) revert BadSignature();
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert BadSignature();
        return signer;
    }
}
