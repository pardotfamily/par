// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPairPadFeeEscrow} from "../v2/interfaces/ILaunchpadV2.sol";

interface ICreatorAccountFactory {
    function checkClaim(
        bytes32 platform,
        bytes32 idHash,
        address account,
        address newOwner,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external;
}

/**
 * @title CreatorAccount
 * @notice The wallet of a social account (an X user id, a GitHub user id)
 * on this chain. Its address is fixed by (platform, id) through the
 * factory's CREATE2, so every launch that names the same account pays into
 * the same place, before or after this code exists here.
 *
 * Until the account holder claims it, nobody can move anything out: there
 * is no owner, no key, no operator. The claim is proven with the factory's
 * attestation of a login and takes effect at once. From then on only the
 * owner can act, and ownership moves only by the owner's own two-step
 * transfer; an attestation can no longer touch it.
 *
 * Fees reach the account two ways: paid straight to this address (native or
 * ERC-20), or credited to it in the par fee escrow, from where anyone may
 * `pull` them here (the escrow pays its caller, so the account has to call).
 */
contract CreatorAccount is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotOwner();
    error AlreadyOwned();
    error NotProposedOwner();
    error ZeroAddress();
    error CallFailed(bytes returndata);

    event Claimed(address indexed owner);
    event OwnerSet(address indexed owner);
    event OwnershipProposed(address indexed proposed);
    event Pulled(address indexed escrow, address indexed token, uint256 amount);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event Executed(address indexed to, uint256 value, bytes data);

    ICreatorAccountFactory public immutable factory;
    bytes32 public immutable platform;
    bytes32 public immutable idHash;

    address public owner;
    address public proposedOwner;

    modifier onlyOwner() {
        if (msg.sender != owner || owner == address(0)) revert NotOwner();
        _;
    }

    constructor(ICreatorAccountFactory factory_, bytes32 platform_, bytes32 idHash_) {
        factory = factory_;
        platform = platform_;
        idHash = idHash_;
    }

    receive() external payable {}

    // ----------------------------------------------------------------- claim

    /**
     * @notice Claims this account for `newOwner`, on the factory's
     * attestation that the caller logged in as the account holder. Only
     * possible while the account has no owner; afterwards ownership moves
     * only through `transferOwnership`.
     */
    function claim(address newOwner, bytes32 nonce, uint256 deadline, bytes calldata signature) external {
        if (owner != address(0)) revert AlreadyOwned();
        if (newOwner == address(0)) revert ZeroAddress();
        factory.checkClaim(platform, idHash, address(this), newOwner, nonce, deadline, signature);
        owner = newOwner;
        emit Claimed(newOwner);
        emit OwnerSet(newOwner);
    }

    // ------------------------------------------------------------- ownership

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        proposedOwner = newOwner;
        emit OwnershipProposed(newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != proposedOwner || proposedOwner == address(0)) revert NotProposedOwner();
        owner = proposedOwner;
        proposedOwner = address(0);
        emit OwnerSet(owner);
    }

    // ----------------------------------------------------------------- funds

    /**
     * @notice Moves fees credited to this account in a par fee escrow into
     * the account. Permissionless: the money only ever comes here.
     * @param token address(0) for the native balance, else the ERC-20.
     */
    function pull(IPairPadFeeEscrow escrow, address token) external nonReentrant returns (uint256 amount) {
        amount = token == address(0) ? escrow.claim() : escrow.claimToken(token);
        emit Pulled(address(escrow), token, amount);
    }

    /// @notice Sends `amount` of `token` (address(0) = native) to `to`.
    function withdraw(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) {
            (bool ok, bytes memory ret) = to.call{value: amount}("");
            if (!ok) revert CallFailed(ret);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Withdrawn(token, to, amount);
    }

    /// @notice Arbitrary call from the account, for anything the owner needs
    /// (claiming from a new escrow, approving, swapping).
    function execute(address to, uint256 value, bytes calldata data)
        external
        onlyOwner
        nonReentrant
        returns (bytes memory)
    {
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        if (!ok) revert CallFailed(ret);
        emit Executed(to, value, data);
        return ret;
    }
}
