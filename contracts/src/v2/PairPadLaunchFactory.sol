// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {PairPadLauncherToken} from "./PairPadLauncherToken.sol";
import {PairPadLaunchLocker} from "./PairPadLaunchLocker.sol";
import {PairPadPositionMinter} from "./PairPadPositionMinter.sol";
import {LaunchDeployment, PairPadLaunchDeployer} from "./PairPadLaunchDeployer.sol";
import {PairPadQuotePricer} from "./PairPadQuotePricer.sol";
import {PairPadPositionMath} from "./libraries/PairPadPositionMath.sol";
import {IPairPadFeeEscrow, IPairPadLaunchFactory} from "./interfaces/ILaunchpadV2.sol";

/**
 * @title PairPadLaunchFactory
 * @notice Deploys a launch token and, in the same transaction, opens its
 * Uniswap V4 pool: a plain pool with no hook and a static LP fee, where the
 * whole supply goes into one permanently locked position ranged from the
 * opening price upward. That position trades exactly like a constant-product
 * bonding curve with a phantom quote reserve, and because it is a hookless
 * pool every router, aggregator and terminal that speaks Uniswap V4 can
 * trade it from the first block without any allowlisting.
 *
 * The pool's LP fee is the launch's whole trading fee: the protocol's base
 * fee plus whatever creator tax the creator chose. It accrues to the locked
 * position, and PairPadLaunchLocker collects and splits it.
 */
contract PairPadLaunchFactory is Ownable2Step, ReentrancyGuard, IPairPadLaunchFactory {
    using StateLibrary for IPoolManager;

    uint256 private constant BASIS_POINTS = 10_000;
    uint256 private constant MAX_BASE_FEE_BPS = 1_000; // 10%
    uint256 private constant MAX_CREATOR_TAX_CEILING_BPS = 1_000; // 10%
    uint256 private constant MAX_TOTAL_TRADE_FEE_BPS = 2_000; // 20%
    // V4 expresses the LP fee in hundredths of a bip.
    uint24 private constant PIPS_PER_BP = 100;
    uint8 private constant MIN_PAIR_TOKEN_DECIMALS = 6;
    uint256 private constant MIN_LAUNCH_SUPPLY = 1 ether;
    // V4 settles pool balance changes through a BalanceDelta of two int128
    // halves, so the supply has to fit the signed maximum.
    uint256 private constant MAX_SUPPLY = uint256(uint128(type(int128).max));
    int24 private constant MAX_TICK_SPACING = 32767;
    // Advance notice the protocol owner's creator-fee-recipient override must
    // wait out before it can be executed.
    uint256 public constant CREATOR_FEE_RECIPIENT_TIMELOCK = 3 days;
    uint256 public constant CREATOR_FEE_RECIPIENT_EXECUTION_WINDOW = 3 days;

    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        PairPadLauncherToken.Socials socials;
        address creatorFeeRecipient;
        // Additional trade fee the creator charges on top of the protocol's
        // base fee, capped by maxCreatorTaxBps at launch time. Paid
        // entirely to the creator, never split with the protocol.
        uint16 creatorTaxBps;
        // Optional guard on the economics this launch will lock in. Zero
        // waives the check. Obtain it from previewLaunchEconomics.
        bytes32 expectedEconomics;
        // CREATE2 salt for the launch token, namespaced per initiating
        // account. PairPadLaunchDeployer.predictTokenAddress gives the
        // resulting address in advance.
        bytes32 salt;
    }

    /**
     * @notice Native-quote launch economics. `phantomQuote` is in wei here; a
     * launch against an ERC-20 quote asset derives it from the quote pricer
     * (or a curated override) so every launch opens at the same market cap.
     */
    struct LaunchConfig {
        uint256 supply;
        uint256 phantomQuote;
        int24 tickSpacing;
        bool enabled;
    }

    /**
     * @notice Optional owner-curated phantom reserve for one ERC-20 quote
     * asset, in that asset's own decimals. Takes precedence over the pricer.
     */
    struct PairTokenEconomics {
        uint256 phantomQuote;
        uint8 decimals;
    }

    struct PendingCreatorFeeRecipient {
        address newRecipient;
        uint256 effectiveAt;
        uint256 expiresAt;
    }

    error InvalidLaunchConfigId();
    error LaunchConfigDisabled();
    error InvalidBasisPoints();
    error CreatorTaxTooHigh();
    error CombinedFeeTooHigh();
    error SupplyTooLow();
    error SupplyTooHigh();
    error InvalidTickSpacing();
    error LaunchFeeNotPaid();
    error NotWhitelisted();
    error FeeTransferFailed();
    error ZeroAddress();
    error AlreadySet();
    error OwnershipCannotBeRenounced();
    error InvalidTokenParams();
    error TokenNotFound();
    error NotLaunchForwarder();
    error NotCreatorFeeRecipient();
    error NoPendingChange();
    error TimelockNotElapsed(uint256 effectiveAt);
    error TimelockExpired(uint256 expiresAt);
    error LaunchDependenciesNotWired();
    error PairTokenValidationFailed();
    error InvalidPhantomQuote();
    error PairTokenEconomicsInvalid();
    error PairTokenDecimalsMismatch(uint8 expected, uint8 actual);
    error PairTokenDecimalsUnavailable();
    error LaunchEconomicsMismatch(bytes32 expected, bytes32 actual);
    /// @dev Someone initialized this exact pool key ahead of the launch. Pick
    /// a different salt; the token address, and with it the key, changes.
    error PoolAlreadyExists();

    event TokenLaunched(
        address indexed token,
        bytes32 indexed poolId,
        address indexed deployer,
        address pairToken,
        uint256 launchConfigId,
        uint24 poolFee
    );
    /**
     * @notice The locked position behind a launch, emitted alongside
     * TokenLaunched. `tokenAmount` is the supply actually in the pool.
     */
    event LaunchPositionMinted(
        address indexed token,
        uint256 positionId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 tokenAmount,
        uint256 phantomQuote
    );
    event CreatorFeeRecipientUpdated(
        address indexed token, address indexed previousRecipient, address indexed newRecipient
    );
    event CreatorFeeRecipientChangeProposed(
        address indexed token,
        address indexed currentRecipient,
        address indexed proposedRecipient,
        uint256 effectiveAt,
        uint256 expiresAt
    );
    event CreatorFeeRecipientChangeCancelled(address indexed token, address indexed proposedRecipient);
    event LaunchConfigAdded(uint256 indexed id);
    event LaunchConfigUpdated(uint256 indexed id);
    event LaunchFeeUpdated(uint256 launchFee);
    event LaunchEnabledUpdated(bool enabled);
    event WhitelistedLauncherUpdated(address indexed launcher, bool enabled);
    event MaxCreatorTaxUpdated(uint256 bps);
    event BaseFeeUpdated(uint256 bps);
    event ProtocolFeeShareUpdated(uint256 bps);
    event ProtocolFeeRecipientUpdated(address recipient);
    event PositionMinterSet(address minter);
    event LaunchDeployerSet(address deployer);
    event LaunchForwarderSet(address forwarder);
    event PairTokenEconomicsUpdated(address indexed pairToken, uint256 phantomQuote, uint8 decimals);
    event PairTokenEconomicsCleared(address indexed pairToken);

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    PairPadLaunchLocker public immutable locker;
    IPairPadFeeEscrow public immutable feeEscrow;
    PairPadQuotePricer public immutable quotePricer;

    // Not immutable: each helper's constructor needs this factory's
    // already-deployed address, so they are deployed afterward and wired once.
    PairPadPositionMinter public positionMinter;
    PairPadLaunchDeployer public launchDeployer;
    address public launchForwarder;

    // Fee terms new launches snapshot. Changing them never touches a pool
    // that already exists: the LP fee is part of its key.
    uint256 public baseFeeBps = 100; // 1%
    uint256 public protocolFeeShareBps = 5_000; // half of the base fee
    address public protocolFeeRecipient;
    uint256 public maxCreatorTaxBps = 1_000; // 10%

    uint256 public launchFee;
    bool public launchEnabled;

    mapping(address launcher => bool enabled) public whitelistedLaunchers;
    mapping(address pairToken => PairTokenEconomics economics) public pairTokenEconomics;
    mapping(address token => LaunchedToken launched) private _launchedTokens;
    mapping(address token => PendingCreatorFeeRecipient) public pendingCreatorFeeRecipient;
    LaunchConfig[] private _launchConfigs;

    constructor(
        address initialOwner,
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        PairPadLaunchLocker locker_,
        IPairPadFeeEscrow feeEscrow_,
        PairPadQuotePricer quotePricer_,
        address protocolFeeRecipient_,
        uint256 initialLaunchFee
    ) Ownable(initialOwner) {
        if (address(poolManager_) == address(0) || address(positionManager_) == address(0)) revert ZeroAddress();
        if (address(locker_) == address(0) || address(feeEscrow_) == address(0)) revert ZeroAddress();
        if (address(quotePricer_) == address(0) || protocolFeeRecipient_ == address(0)) revert ZeroAddress();
        if (address(positionManager_.poolManager()) != address(poolManager_)) revert LaunchDependenciesNotWired();

        poolManager = poolManager_;
        positionManager = positionManager_;
        locker = locker_;
        feeEscrow = feeEscrow_;
        quotePricer = quotePricer_;
        protocolFeeRecipient = protocolFeeRecipient_;
        launchFee = initialLaunchFee;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function launchConfigCount() external view returns (uint256) {
        return _launchConfigs.length;
    }

    function getLaunchConfig(uint256 id) external view returns (LaunchConfig memory) {
        if (id >= _launchConfigs.length) revert InvalidLaunchConfigId();
        return _launchConfigs[id];
    }

    function getLaunchedToken(address token) external view override returns (LaunchedToken memory) {
        return _launchedTokens[token];
    }

    /**
     * @notice The pool key of a launched token's pool.
     */
    function poolKeyFor(address token) public view returns (PoolKey memory) {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        return _poolKey(token, launch.pairToken, launch.poolFee, launch.tickSpacing);
    }

    function poolIdFor(address token) external view returns (PoolId) {
        return poolKeyFor(token).toId();
    }

    /**
     * @notice Whether `launcher` may launch right now: true while the public
     * gate is open, and true for whitelisted addresses while it is closed.
     */
    function canLaunch(address launcher) public view returns (bool) {
        return launchEnabled || whitelistedLaunchers[launcher];
    }

    /**
     * @notice The LP fee a launch with `creatorTaxBps` gets right now, in
     * V4's hundredths of a bip.
     */
    function poolFeeFor(uint16 creatorTaxBps) public view returns (uint24) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24((baseFeeBps + creatorTaxBps) * PIPS_PER_BP);
    }

    // ---------------------------------------------------------------------
    // Owner-only configuration
    // ---------------------------------------------------------------------

    function addLaunchConfig(LaunchConfig calldata config) external onlyOwner returns (uint256 id) {
        _validateLaunchConfig(config);
        id = _launchConfigs.length;
        _launchConfigs.push(config);
        emit LaunchConfigAdded(id);
    }

    /**
     * @notice Replaces an existing launch configuration. Already-launched
     * tokens are unaffected since their pool parameters were snapshotted.
     */
    function updateLaunchConfig(uint256 id, LaunchConfig calldata config) external onlyOwner {
        if (id >= _launchConfigs.length) revert InvalidLaunchConfigId();
        _validateLaunchConfig(config);
        _launchConfigs[id] = config;
        emit LaunchConfigUpdated(id);
    }

    function setLaunchFee(uint256 newLaunchFee) external onlyOwner {
        launchFee = newLaunchFee;
        emit LaunchFeeUpdated(newLaunchFee);
    }

    function setLaunchEnabled(bool enabled) external onlyOwner {
        launchEnabled = enabled;
        emit LaunchEnabledUpdated(enabled);
    }

    function setWhitelistedLauncher(address launcher, bool enabled) external onlyOwner {
        if (launcher == address(0)) revert ZeroAddress();
        whitelistedLaunchers[launcher] = enabled;
        emit WhitelistedLauncherUpdated(launcher, enabled);
    }

    /**
     * @notice Sets the phantom reserve a quote asset's launches use, in that
     * asset's own decimals, overriding the pricer. Existing launches are
     * unaffected.
     * @param expectedDecimals The scale the caller sized the figure against,
     * checked against the asset's own report so an 18-decimal configuration
     * can never land on a 6-decimal asset.
     */
    function setPairTokenEconomics(address pairToken, uint256 phantomQuote, uint8 expectedDecimals)
        external
        onlyOwner
    {
        if (pairToken == address(0) || phantomQuote == 0) revert PairTokenEconomicsInvalid();
        // Fees are integer basis points of the quote leg; below six decimals
        // small trades would round their fee to zero.
        if (expectedDecimals < MIN_PAIR_TOKEN_DECIMALS) revert PairTokenEconomicsInvalid();
        _requireDecimals(pairToken, expectedDecimals, false);
        pairTokenEconomics[pairToken] = PairTokenEconomics({phantomQuote: phantomQuote, decimals: expectedDecimals});
        emit PairTokenEconomicsUpdated(pairToken, phantomQuote, expectedDecimals);
    }

    function clearPairTokenEconomics(address pairToken) external onlyOwner {
        delete pairTokenEconomics[pairToken];
        emit PairTokenEconomicsCleared(pairToken);
    }

    function setMaxCreatorTaxBps(uint256 bps) external onlyOwner {
        if (bps > MAX_CREATOR_TAX_CEILING_BPS) revert InvalidBasisPoints();
        maxCreatorTaxBps = bps;
        emit MaxCreatorTaxUpdated(bps);
    }

    /**
     * @notice Sets the protocol's base trading fee for launches created from
     * now on. Pools already open keep the fee in their key.
     */
    function setBaseFeeBps(uint256 bps) external onlyOwner {
        if (bps > MAX_BASE_FEE_BPS) revert InvalidBasisPoints();
        baseFeeBps = bps;
        emit BaseFeeUpdated(bps);
    }

    /**
     * @notice Sets the protocol's share of the base fee for launches created
     * from now on. The creator gets the rest of the base fee and the whole
     * creator tax.
     */
    function setProtocolFeeShareBps(uint256 bps) external onlyOwner {
        if (bps > BASIS_POINTS) revert InvalidBasisPoints();
        protocolFeeShareBps = bps;
        emit ProtocolFeeShareUpdated(bps);
    }

    /**
     * @notice Where the protocol's fee share and the launch fee go, for
     * launches created from now on.
     */
    function setProtocolFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientUpdated(recipient);
    }

    function setPositionMinter(PairPadPositionMinter minter) external onlyOwner {
        if (address(positionMinter) != address(0)) revert AlreadySet();
        if (address(minter) == address(0)) revert ZeroAddress();
        positionMinter = minter;
        emit PositionMinterSet(address(minter));
    }

    function setLaunchDeployer(PairPadLaunchDeployer deployer) external onlyOwner {
        if (address(launchDeployer) != address(0)) revert AlreadySet();
        if (address(deployer) == address(0)) revert ZeroAddress();
        launchDeployer = deployer;
        emit LaunchDeployerSet(address(deployer));
    }

    /**
     * @notice Sets the router allowed to launch on behalf of another account
     * (the atomic launch-and-buy path). Rotatable when the router is upgraded.
     */
    function setLaunchForwarder(address forwarder) external onlyOwner {
        if (forwarder == address(0)) revert ZeroAddress();
        launchForwarder = forwarder;
        emit LaunchForwarderSet(forwarder);
    }

    /**
     * @notice Permanently disabled. Ownership can still be handed to a new
     * owner via the two-step transfer.
     */
    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    // ---------------------------------------------------------------------
    // Launch
    // ---------------------------------------------------------------------

    /**
     * @notice The economics digest a launch of `launchConfigId` in
     * `pairToken` would produce right now, for TokenParams.expectedEconomics.
     */
    function previewLaunchEconomics(uint256 launchConfigId, address pairToken) external view returns (bytes32) {
        if (launchConfigId >= _launchConfigs.length) revert InvalidLaunchConfigId();
        LaunchConfig memory config = _launchConfigs[launchConfigId];
        return _economicsDigest(config, _quoteEconomics(config, pairToken));
    }

    /**
     * @notice The phantom reserve a launch against `pairToken` would open
     * with right now, in the asset's own units.
     */
    function previewQuoteEconomics(uint256 launchConfigId, address pairToken)
        external
        view
        returns (uint256 phantomQuote)
    {
        if (launchConfigId >= _launchConfigs.length) revert InvalidLaunchConfigId();
        return _quoteEconomics(_launchConfigs[launchConfigId], pairToken);
    }

    /**
     * @notice Deploys a launch token and opens its pool.
     */
    function launchToken(TokenParams calldata params, uint256 launchConfigId, address pairToken)
        external
        payable
        nonReentrant
        returns (address token, PoolId poolId)
    {
        return _launchToken(params, launchConfigId, pairToken, msg.sender);
    }

    /**
     * @notice Launches for the initiating user of the trusted launch-and-buy
     * router. Only the configured `launchForwarder` may supply
     * `originalDeployer`; this preserves the real caller without `tx.origin`.
     */
    function launchTokenFor(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address originalDeployer
    ) external payable nonReentrant returns (address token, PoolId poolId) {
        if (msg.sender != launchForwarder) revert NotLaunchForwarder();
        return _launchToken(params, launchConfigId, pairToken, originalDeployer);
    }

    function _launchToken(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address originalDeployer
    ) private returns (address token, PoolId poolId) {
        _requireLaunchDependenciesWired();
        if (!canLaunch(originalDeployer)) revert NotWhitelisted();
        if (msg.value != launchFee) revert LaunchFeeNotPaid();
        if (launchConfigId >= _launchConfigs.length) revert InvalidLaunchConfigId();
        if (bytes(params.name).length == 0 || bytes(params.symbol).length == 0) revert InvalidTokenParams();
        if (params.creatorTaxBps > maxCreatorTaxBps) revert CreatorTaxTooHigh();
        if (baseFeeBps + params.creatorTaxBps > MAX_TOTAL_TRADE_FEE_BPS) revert CombinedFeeTooHigh();

        LaunchConfig memory config = _launchConfigs[launchConfigId];
        if (!config.enabled) revert LaunchConfigDisabled();

        uint256 phantomQuote = _quoteEconomics(config, pairToken);
        bytes32 economics = _economicsDigest(config, phantomQuote);
        if (params.expectedEconomics != bytes32(0) && params.expectedEconomics != economics) {
            revert LaunchEconomicsMismatch(params.expectedEconomics, economics);
        }

        address creatorFeeRecipient =
            params.creatorFeeRecipient == address(0) ? originalDeployer : params.creatorFeeRecipient;

        // The token first: the pool key's currency order depends on its
        // address. Its whole supply lands on the minter.
        token = launchDeployer.deployToken(
            LaunchDeployment({
                originalDeployer: originalDeployer,
                supplyRecipient: address(positionMinter),
                supply: config.supply,
                salt: params.salt,
                name: params.name,
                symbol: params.symbol,
                logo: params.logo,
                description: params.description,
                socials: params.socials
            })
        );

        uint24 poolFee = poolFeeFor(params.creatorTaxBps);
        PoolKey memory key = _poolKey(token, pairToken, poolFee, config.tickSpacing);
        poolId = key.toId();
        // Nothing stops a third party from initializing a hookless pool for
        // an address that does not exist yet. A launch onto such a pool
        // would open at their price, so it is refused instead.
        (uint160 existingPrice,,,) = poolManager.getSlot0(poolId);
        if (existingPrice != 0) revert PoolAlreadyExists();

        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == token;
        PairPadPositionMath.Plan memory p =
            positionMinter.plan(tokenIsCurrency0, config.supply, phantomQuote, config.tickSpacing);

        poolManager.initialize(key, p.sqrtPriceX96);
        (uint256 positionId, uint256 tokenAmount) = positionMinter.mintLaunchPosition(token, key, p, config.supply);
        locker.lockPosition(token, positionId);

        _launchedTokens[token] = LaunchedToken({
            token: token,
            deployer: originalDeployer,
            creatorFeeRecipient: creatorFeeRecipient,
            pairToken: pairToken,
            phantomQuote: phantomQuote,
            poolFee: poolFee,
            tickSpacing: config.tickSpacing,
            tickLower: p.tickLower,
            tickUpper: p.tickUpper,
            liquidity: p.liquidity,
            positionId: positionId,
            baseFeeBps: uint16(baseFeeBps),
            creatorTaxBps: params.creatorTaxBps,
            protocolFeeShareBps: uint16(protocolFeeShareBps),
            protocolFeeRecipient: protocolFeeRecipient,
            launchedAt: uint64(block.timestamp),
            exists: true
        });

        // Last, after the launch is fully recorded: this forwards ETH to the
        // protocol recipient, which may be a contract that calls back in.
        _payLaunchFee();

        emit TokenLaunched(token, PoolId.unwrap(poolId), originalDeployer, pairToken, launchConfigId, poolFee);
        emit LaunchPositionMinted(
            token, positionId, p.tickLower, p.tickUpper, p.liquidity, tokenAmount, phantomQuote
        );
    }

    // ---------------------------------------------------------------------
    // Creator fee recipient
    // ---------------------------------------------------------------------

    /**
     * @notice Lets the current creator fee recipient hand off future creator
     * fees for `token` to a new address. The locker reads the recipient at
     * collection time, so fees not yet collected follow the change.
     * @dev Does not clear a pending protocol-owner override; see
     * `setCreatorFeeRecipient`.
     */
    function transferCreatorFeeRecipient(address token, address newRecipient) external {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        if (msg.sender != launch.creatorFeeRecipient) revert NotCreatorFeeRecipient();
        _setCreatorFeeRecipient(token, launch, newRecipient);
    }

    /**
     * @notice Proposes a protocol-owner override of a launch's creator fee
     * recipient (the lost-wallet recovery path). Takes effect only after
     * `CREATOR_FEE_RECIPIENT_TIMELOCK` has elapsed and someone calls
     * `executeCreatorFeeRecipientChange`. A matured proposal supersedes any
     * creator transfer made while it was pending; the timelock is a notice
     * period, not a veto window.
     */
    function setCreatorFeeRecipient(address token, address newRecipient) external onlyOwner {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        if (newRecipient == address(0)) revert ZeroAddress();

        uint256 effectiveAt = block.timestamp + CREATOR_FEE_RECIPIENT_TIMELOCK;
        uint256 expiresAt = effectiveAt + CREATOR_FEE_RECIPIENT_EXECUTION_WINDOW;
        pendingCreatorFeeRecipient[token] =
            PendingCreatorFeeRecipient({newRecipient: newRecipient, effectiveAt: effectiveAt, expiresAt: expiresAt});
        emit CreatorFeeRecipientChangeProposed(token, launch.creatorFeeRecipient, newRecipient, effectiveAt, expiresAt);
    }

    function executeCreatorFeeRecipientChange(address token) external {
        PendingCreatorFeeRecipient memory pending = pendingCreatorFeeRecipient[token];
        if (pending.newRecipient == address(0)) revert NoPendingChange();
        if (block.timestamp < pending.effectiveAt) revert TimelockNotElapsed(pending.effectiveAt);
        if (block.timestamp > pending.expiresAt) revert TimelockExpired(pending.expiresAt);

        LaunchedToken storage launch = _launchedTokens[token];
        delete pendingCreatorFeeRecipient[token];
        _setCreatorFeeRecipient(token, launch, pending.newRecipient);
    }

    function cancelCreatorFeeRecipientChange(address token) external onlyOwner {
        PendingCreatorFeeRecipient memory pending = pendingCreatorFeeRecipient[token];
        if (pending.newRecipient == address(0)) revert NoPendingChange();
        delete pendingCreatorFeeRecipient[token];
        emit CreatorFeeRecipientChangeCancelled(token, pending.newRecipient);
    }

    function _setCreatorFeeRecipient(address token, LaunchedToken storage launch, address newRecipient) private {
        if (newRecipient == address(0)) revert ZeroAddress();
        address previousRecipient = launch.creatorFeeRecipient;
        launch.creatorFeeRecipient = newRecipient;
        emit CreatorFeeRecipientUpdated(token, previousRecipient, newRecipient);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /**
     * @dev Resolves the phantom reserve for any quote asset. Native ETH
     * takes the config's own figure; a curated ERC-20 takes its owner-set
     * override; every other ERC-20 derives it from the quote pricer at the
     * reference pool's current price, so the opening market cap is the same
     * whatever the quote.
     */
    function _quoteEconomics(LaunchConfig memory config, address pairToken) private view returns (uint256) {
        if (pairToken == address(0)) return config.phantomQuote;

        PairTokenEconomics memory curated = pairTokenEconomics[pairToken];
        if (curated.phantomQuote != 0) {
            _requireDecimals(pairToken, curated.decimals, true);
            return curated.phantomQuote;
        }

        if (pairToken.code.length == 0) revert PairTokenValidationFailed();
        if (_readDecimals(pairToken) < MIN_PAIR_TOKEN_DECIMALS) revert PairTokenValidationFailed();
        return quotePricer.quoteEconomics(pairToken, config.phantomQuote);
    }

    function _requireDecimals(address pairToken, uint8 expectedDecimals, bool required) private view {
        if (!required && pairToken.code.length == 0) return;
        try IERC20Metadata(pairToken).decimals() returns (uint8 actual) {
            if (actual != expectedDecimals) revert PairTokenDecimalsMismatch(expectedDecimals, actual);
        } catch {
            if (required) revert PairTokenDecimalsUnavailable();
        }
    }

    function _readDecimals(address pairToken) private view returns (uint8) {
        try IERC20Metadata(pairToken).decimals() returns (uint8 actual) {
            return actual;
        } catch {
            revert PairTokenDecimalsUnavailable();
        }
    }

    /**
     * @dev Covers every owner-controlled term that fixes what a creator is
     * buying: the curve's shape, the pool's tick spacing and the fee terms.
     */
    function _economicsDigest(LaunchConfig memory config, uint256 phantomQuote) private view returns (bytes32) {
        return keccak256(
            abi.encode(phantomQuote, config.supply, config.tickSpacing, baseFeeBps, protocolFeeShareBps)
        );
    }

    /**
     * @dev Prevents launches until every helper points back to this factory
     * and to the same core dependencies.
     */
    function _requireLaunchDependenciesWired() private view {
        if (address(positionMinter) == address(0) || address(launchDeployer) == address(0)) {
            revert LaunchDependenciesNotWired();
        }
        if (launchDeployer.factory() != address(this) || positionMinter.factory() != address(this)) {
            revert LaunchDependenciesNotWired();
        }
        if (address(locker.factory()) != address(this)) revert LaunchDependenciesNotWired();
        if (
            address(locker.positionManager()) != address(positionManager)
                || address(locker.feeEscrow()) != address(feeEscrow)
        ) {
            revert LaunchDependenciesNotWired();
        }
        if (
            address(positionMinter.positionManager()) != address(positionManager)
                || address(positionMinter.locker()) != address(locker)
        ) {
            revert LaunchDependenciesNotWired();
        }
    }

    function _poolKey(address token, address pairToken, uint24 fee, int24 tickSpacing)
        private
        pure
        returns (PoolKey memory)
    {
        (Currency currency0, Currency currency1) = pairToken < token
            ? (Currency.wrap(pairToken), Currency.wrap(token))
            : (Currency.wrap(token), Currency.wrap(pairToken));
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    function _payLaunchFee() private {
        if (launchFee == 0) return;
        (bool sent,) = payable(protocolFeeRecipient).call{value: launchFee}("");
        if (!sent) revert FeeTransferFailed();
    }

    function _validateLaunchConfig(LaunchConfig calldata config) private view {
        if (config.supply < MIN_LAUNCH_SUPPLY) revert SupplyTooLow();
        if (config.supply > MAX_SUPPLY) revert SupplyTooHigh();
        if (config.phantomQuote == 0) revert InvalidPhantomQuote();
        if (config.tickSpacing <= 0 || config.tickSpacing > MAX_TICK_SPACING) revert InvalidTickSpacing();
        // Terms the position math cannot lay out are refused here rather
        // than at every launch. Both currency orders are checked because the
        // token's address decides which one a launch gets.
        if (address(positionMinter) != address(0)) {
            positionMinter.plan(true, config.supply, config.phantomQuote, config.tickSpacing);
            positionMinter.plan(false, config.supply, config.phantomQuote, config.tickSpacing);
        }
    }
}
