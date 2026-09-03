// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title PairPadLauncherToken
 * @notice Fixed-supply ERC-20 deployed by PairPadLaunchFactory for a launch.
 * The entire supply is minted in the launch transaction and, in that same
 * transaction, placed into the launch's Uniswap V4 pool as one permanently
 * locked position. Anyone, the deployer included, may buy any amount from
 * the pool at any time; price impact is the only limit on a large buy.
 * `deployer` is carried here as immutable reference data for off-chain
 * attribution only, and confers no privileges over the token.
 * `ERC20Burnable` lets any holder voluntarily burn their own balance; the
 * protocol itself never burns anything.
 */
contract PairPadLauncherToken is ERC20, ERC20Burnable {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    error ZeroAddress();

    address public immutable deployer;
    address public immutable launchFactory;

    string public logo;
    string public description;

    Socials private _socials;

    /**
     * @notice Creates a launch token and mints its entire supply to
     * `supplyRecipient`, the factory helper that seeds the pool position.
     */
    constructor(
        string memory name_,
        string memory symbol_,
        string memory logo_,
        string memory description_,
        Socials memory socials_,
        address deployer_,
        address launchFactory_,
        address supplyRecipient_,
        uint256 supply_
    ) ERC20(name_, symbol_) {
        if (deployer_ == address(0) || supplyRecipient_ == address(0) || launchFactory_ == address(0)) {
            revert ZeroAddress();
        }

        deployer = deployer_;
        // Passed explicitly rather than read from msg.sender: PairPadLaunchFactory
        // deploys this token indirectly through PairPadLaunchDeployer to keep its
        // own bytecode under EIP-170's size limit, so msg.sender at construction
        // time would otherwise resolve to that deployer helper, not the factory.
        launchFactory = launchFactory_;
        logo = logo_;
        description = description_;
        _socials = socials_;

        _mint(supplyRecipient_, supply_);
    }

    /**
     * @notice Returns the launch token's five social metadata fields.
     */
    function socials()
        external
        view
        returns (
            string memory twitter,
            string memory telegram,
            string memory discord,
            string memory website,
            string memory farcaster
        )
    {
        Socials memory values = _socials;
        return (values.twitter, values.telegram, values.discord, values.website, values.farcaster);
    }

    /**
     * @notice Returns creator and metadata in the launcher-compatible tuple.
     */
    function getTokenInfo()
        external
        view
        returns (
            address tokenDeployer,
            string memory tokenLogo,
            string memory tokenDescription,
            Socials memory tokenSocials
        )
    {
        return (deployer, logo, description, _socials);
    }

    /**
     * @notice Contract-level metadata per ERC-7572, assembled on the fly from
     * the fields stored at launch and returned as an inline JSON data URI.
     * Terminals that know nothing about this launchpad read the token's
     * image and links from here, so the JSON carries the keys they look for:
     * `image`, `description`, `external_url`, and each social under its own
     * name, repeated under `extensions` for readers that expect it there.
     * Every launch field is immutable, so the URI never changes and no
     * `ContractURIUpdated` is ever emitted.
     */
    function contractURI() external view returns (string memory) {
        return _metadata();
    }

    /**
     * @notice Same document as `contractURI`, under the name some readers try
     * first (Zora-style coins expose their metadata as `tokenURI`).
     */
    function tokenURI() external view returns (string memory) {
        return _metadata();
    }

    /**
     * @notice Nothing controls this token: no owner, no mint, no pause. The
     * function exists so scanners that test for a renounced owner find one.
     */
    function owner() external pure returns (address) {
        return address(0);
    }

    function _metadata() private view returns (string memory) {
        string memory links = _links();
        return string.concat(
            "data:application/json;utf8,",
            '{"name":"',
            _jsonEscape(name()),
            '","symbol":"',
            _jsonEscape(symbol()),
            '","description":"',
            _jsonEscape(description),
            '","image":"',
            _jsonEscape(logo),
            '"',
            _field("external_url", _socials.website),
            _field("external_link", _socials.website),
            links,
            ',"extensions":{',
            bytes(links).length == 0 ? "" : _stripLeadingComma(links),
            "}}"
        );
    }

    function _links() private view returns (string memory) {
        return string.concat(
            _field("website", _socials.website),
            _field("twitter", _socials.twitter),
            _field("telegram", _socials.telegram),
            _field("discord", _socials.discord),
            _field("farcaster", _socials.farcaster)
        );
    }

    /// @dev `,"key":"value"`, or nothing when the value is empty.
    function _field(string memory key, string memory value) private pure returns (string memory) {
        if (bytes(value).length == 0) return "";
        return string.concat(',"', key, '":"', _jsonEscape(value), '"');
    }

    function _stripLeadingComma(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(b.length - 1);
        for (uint256 i = 1; i < b.length; ++i) {
            out[i - 1] = b[i];
        }
        return string(out);
    }

    /**
     * @dev Escapes `s` for use inside a JSON string literal: quotes,
     * backslashes and control characters. Metadata is bounded by the
     * deployer, so the byte-by-byte pass stays cheap even for a full
     * description.
     */
    function _jsonEscape(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 extra;
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == '"' || c == "\\" || c == "\n" || c == "\r" || c == "\t") extra += 1;
            else if (uint8(c) < 0x20) extra += 5;
        }
        if (extra == 0) return s;
        bytes memory out = new bytes(b.length + extra);
        bytes16 hexChars = "0123456789abcdef";
        uint256 j;
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == '"' || c == "\\") {
                out[j++] = "\\";
                out[j++] = c;
            } else if (c == "\n") {
                out[j++] = "\\";
                out[j++] = "n";
            } else if (c == "\r") {
                out[j++] = "\\";
                out[j++] = "r";
            } else if (c == "\t") {
                out[j++] = "\\";
                out[j++] = "t";
            } else if (uint8(c) < 0x20) {
                out[j++] = "\\";
                out[j++] = "u";
                out[j++] = "0";
                out[j++] = "0";
                out[j++] = hexChars[uint8(c) >> 4];
                out[j++] = hexChars[uint8(c) & 0x0f];
            } else {
                out[j++] = c;
            }
        }
        return string(out);
    }
}
