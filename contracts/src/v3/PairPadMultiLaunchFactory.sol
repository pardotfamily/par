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
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {PairPadLauncherToken} from "../v2/PairPadLauncherToken.sol";
import {LaunchDeployment, PairPadLaunchDeployer} from "../v2/PairPadLaunchDeployer.sol";
import {PairPadQuotePricer} from "../v2/PairPadQuotePricer.sol";
import {PairPadPositionMath} from "../v2/libraries/PairPadPositionMath.sol";
import {IPairPadFeeEscrow} from "../v2/interfaces/ILaunchpadV2.sol";
import {PairPadMultiLaunchLocker} from "./PairPadMultiLaunchLocker.sol";
import {PairPadMultiPositionMinter} from "./PairPadMultiPositionMinter.sol";
import {IPairPadMultiLaunchFactory} from "./interfaces/ILaunchpadV3.sol";

/**
 * @title PairPadMultiLaunchFactory
 * @notice Deploys a launch token and, in the same transaction, opens one
 * Uniswap V4 pool per quote asset the creator chose (up to MAX_MARKETS): plain
 * pools with no hook and a static LP fee, each seeded with an equal slice of
 * the supply in a permanently locked single-sided position ranged from the
 * opening price upward.
 *
 * Every market opens at the same ETH-denominated price: the quote pricer
 * converts the launch config's phantom reserve into each quote asset, and each
 * pool gets 1/N of the supply against 1/N of that reserve, so the curves are
 * scaled copies of one another and there is nothing to arbitrage at the open.
 * Afterwards the markets are kept in line by arbitrage like any two venues
 * for the same asset.
 *
 * Lives beside PairPadLaunchFactory (single-market launches), with its own
 * locker and minter; the fee escrow and the quote pricer are shared.
 */
contract PairPadMultiLaunchFactory is Ownable2Step, ReentrancyGuard, IPairPadMultiLaunchFactory {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 private constant BASIS_POINTS = 10_000;
    uint256 private constant MAX_BASE_FEE_BPS = 1_000; // 10%
    uint256 private constant MAX_CREATOR_TAX_CEILING_BPS = 1_000; // 10%
    uint256 private constant MAX_TOTAL_TRADE_FEE_BPS = 2_000; // 20%
    // V4 expresses the LP fee in hundredths of a bip.
    uint24 private constant PIPS_PER_BP = 100;
    uint8 private constant MIN_PAIR_TOKEN_DECIMALS = 6;
    uint256 private constant MIN_LAUNCH_SUPPLY = 1 ether;
    uint256 private constant MAX_SUPPLY = uint256(uint128(type(int128).max));
    int24 private constant MAX_TICK_SPACING = 32767;
    /// @notice The most markets one launch may open.
    uint256 public constant MAX_MARKETS = 5;
    uint256 public constant CREATOR_FEE_RECIPIENT_TIMELOCK = 3 days;
    uint256 public constant CREATOR_FEE_RECIPIENT_EXECUTION_WINDOW = 3 days;

    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        PairPadLauncherToken.Socials socials;
        address creatorFeeRecipient;
        uint16 creatorTaxBps;
        // Optional guard on the economics this launch will lock in. Zero
        // waives the check. Obtain it from previewLaunchEconomics.
        bytes32 expectedEconomics;
        bytes32 salt;
    }

    /**
     * @notice Native-quote launch economics for the whole supply.
     * `phantomQuote` is in wei; every market derives its own share from it.
     */
    struct LaunchConfig {
        uint256 supply;
        uint256 phantomQuote;
        int24 tickSpacing;
        bool enabled;
    }

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
    error PoolAlreadyExists();
    /// @dev Zero or more than MAX_MARKETS quote assets.
    error InvalidMarketCount();
    /// @dev The same quote asset twice.
    error DuplicatePairToken();
    /// @dev WETH is never a quote here: native ETH is.
    error WethNotAllowed();
    error MarketNotFound();

    event TokenLaunched(
        address indexed token, address indexed deployer, uint256 launchConfigId, uint24 poolFee, address[] pairTokens
    );
    /**
     * @notice One per market, emitted alongside TokenLaunched in market order.
     * `tokenAmount` is the supply actually in that pool.
     */
    event MarketOpened(
        address indexed token,
        bytes32 indexed poolId,
        uint256 marketIndex,
        address pairToken,
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
    PairPadMultiLaunchLocker public immutable locker;
    IPairPadFeeEscrow public immutable feeEscrow;
    PairPadQuotePricer public immutable quotePricer;
    address public immutable weth;

    PairPadMultiPositionMinter public positionMinter;
    PairPadLaunchDeployer public launchDeployer;
    address public launchForwarder;

    uint256 public baseFeeBps = 100; // 1%
    uint256 public protocolFeeShareBps = 5_000; // half of the base fee
    address public protocolFeeRecipient;
    uint256 public maxCreatorTaxBps = 1_000; // 10%

    uint256 public launchFee;
    bool public launchEnabled;

    mapping(address launcher => bool enabled) public whitelistedLaunchers;
    mapping(address pairToken => PairTokenEconomics economics) public pairTokenEconomics;
    mapping(address token => LaunchedToken launched) private _launchedTokens;
    mapping(address token => Market[] markets) private _markets;
    mapping(address token => PendingCreatorFeeRecipient) public pendingCreatorFeeRecipient;
    LaunchConfig[] private _launchConfigs;

    constructor(
        address initialOwner,
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        PairPadMultiLaunchLocker locker_,
        IPairPadFeeEscrow feeEscrow_,
        PairPadQuotePricer quotePricer_,
        address weth_,
        address protocolFeeRecipient_,
        uint256 initialLaunchFee
    ) Ownable(initialOwner) {
        if (address(poolManager_) == address(0) || address(positionManager_) == address(0)) revert ZeroAddress();
        if (address(locker_) == address(0) || address(feeEscrow_) == address(0)) revert ZeroAddress();
        if (address(quotePricer_) == address(0) || protocolFeeRecipient_ == address(0)) revert ZeroAddress();
        if (weth_ == address(0)) revert ZeroAddress();
        if (address(positionManager_.poolManager()) != address(poolManager_)) revert LaunchDependenciesNotWired();

        poolManager = poolManager_;
        positionManager = positionManager_;
        locker = locker_;
        feeEscrow = feeEscrow_;
        quotePricer = quotePricer_;
        weth = weth_;
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

    function getMarkets(address token) external view override returns (Market[] memory) {
        return _markets[token];
    }

    function getMarket(address token, uint256 index) external view override returns (Market memory) {
        if (index >= _markets[token].length) revert MarketNotFound();
        return _markets[token][index];
    }

    /**
     * @notice The pool key of market `index` of a launched token.
     */
    function poolKeyFor(address token, uint256 index) public view override returns (PoolKey memory) {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        if (index >= _markets[token].length) revert MarketNotFound();
        return _poolKey(token, _markets[token][index].pairToken, launch.poolFee, launch.tickSpacing);
    }

    function poolKeysFor(address token) external view override returns (PoolKey[] memory keys) {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        Market[] storage ms = _markets[token];
        keys = new PoolKey[](ms.length);
        for (uint256 i = 0; i < ms.length; i++) {
            keys[i] = _poolKey(token, ms[i].pairToken, launch.poolFee, launch.tickSpacing);
        }
    }

    function poolIdFor(address token, uint256 index) external view returns (PoolId) {
        return poolKeyFor(token, index).toId();
    }

    function canLaunch(address launcher) public view returns (bool) {
        return launchEnabled || whitelistedLaunchers[launcher];
    }

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

    function setPairTokenEconomics(address pairToken, uint256 phantomQuote, uint8 expectedDecimals)
        external
        onlyOwner
    {
        if (pairToken == address(0) || phantomQuote == 0) revert PairTokenEconomicsInvalid();
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

    function setBaseFeeBps(uint256 bps) external onlyOwner {
        if (bps > MAX_BASE_FEE_BPS) revert InvalidBasisPoints();
        baseFeeBps = bps;
        emit BaseFeeUpdated(bps);
    }

    function setProtocolFeeShareBps(uint256 bps) external onlyOwner {
        if (bps > BASIS_POINTS) revert InvalidBasisPoints();
        protocolFeeShareBps = bps;
        emit ProtocolFeeShareUpdated(bps);
    }

    function setProtocolFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientUpdated(recipient);
    }

    function setPositionMinter(PairPadMultiPositionMinter minter) external onlyOwner {
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

    function setLaunchForwarder(address forwarder) external onlyOwner {
        if (forwarder == address(0)) revert ZeroAddress();
        launchForwarder = forwarder;
        emit LaunchForwarderSet(forwarder);
    }

    function renounceOwnership() public pure override {
        revert OwnershipCannotBeRenounced();
    }

    // ---------------------------------------------------------------------
    // Launch
    // ---------------------------------------------------------------------

    /**
     * @notice The economics digest a launch of `launchConfigId` against
     * `pairTokens` would produce right now, for TokenParams.expectedEconomics.
     */
    function previewLaunchEconomics(uint256 launchConfigId, address[] calldata pairTokens)
        external
        view
        returns (bytes32)
    {
        if (launchConfigId >= _launchConfigs.length) revert InvalidLaunchConfigId();
        LaunchConfig memory config = _launchConfigs[launchConfigId];
        _validatePairTokens(pairTokens);
        return _economicsDigest(config, _phantoms(config, pairTokens));
    }

    /**
     * @notice The phantom reserve each market of a launch against
     * `pairTokens` would open with right now, in each asset's own units, for
     * that market's slice of the supply.
     */
    function previewQuoteEconomics(uint256 launchConfigId, address[] calldata pairTokens)
        external
        view
        returns (uint256[] memory phantomQuotes)
    {
        if (launchConfigId >= _launchConfigs.length) revert InvalidLaunchConfigId();
        _validatePairTokens(pairTokens);
        phantomQuotes = _phantoms(_launchConfigs[launchConfigId], pairTokens);
        for (uint256 i = 0; i < phantomQuotes.length; i++) {
            phantomQuotes[i] /= pairTokens.length;
        }
    }

    /**
     * @notice Deploys a launch token and opens one pool per quote asset.
     * @param pairTokens 1 to MAX_MARKETS distinct quote assets; address(0)
     * is native ETH. The supply is split equally between them.
     */
    function launchToken(TokenParams calldata params, uint256 launchConfigId, address[] calldata pairTokens)
        external
        payable
        nonReentrant
        returns (address token)
    {
        return _launchToken(params, launchConfigId, pairTokens, msg.sender);
    }

    /**
     * @notice Launches for the initiating user of the trusted launch-and-buy
     * router. Only the configured `launchForwarder` may supply
     * `originalDeployer`; this preserves the real caller without `tx.origin`.
     */
    function launchTokenFor(
        TokenParams calldata params,
        uint256 launchConfigId,
        address[] calldata pairTokens,
        address originalDeployer
    ) external payable nonReentrant returns (address token) {
        if (msg.sender != launchForwarder) revert NotLaunchForwarder();
        return _launchToken(params, launchConfigId, pairTokens, originalDeployer);
    }

    function _launchToken(
        TokenParams calldata params,
        uint256 launchConfigId,
        address[] calldata pairTokens,
        address originalDeployer
    ) private returns (address token) {
        _requireLaunchDependenciesWired();
        if (!canLaunch(originalDeployer)) revert NotWhitelisted();
        if (msg.value != launchFee) revert LaunchFeeNotPaid();
        if (launchConfigId >= _launchConfigs.length) revert InvalidLaunchConfigId();
        if (bytes(params.name).length == 0 || bytes(params.symbol).length == 0) revert InvalidTokenParams();
        if (params.creatorTaxBps > maxCreatorTaxBps) revert CreatorTaxTooHigh();
        if (baseFeeBps + params.creatorTaxBps > MAX_TOTAL_TRADE_FEE_BPS) revert CombinedFeeTooHigh();
        _validatePairTokens(pairTokens);

        LaunchConfig memory config = _launchConfigs[launchConfigId];
        if (!config.enabled) revert LaunchConfigDisabled();

        uint256[] memory phantoms = _phantoms(config, pairTokens);
        bytes32 economics = _economicsDigest(config, phantoms);
        if (params.expectedEconomics != bytes32(0) && params.expectedEconomics != economics) {
            revert LaunchEconomicsMismatch(params.expectedEconomics, economics);
        }

        // The token first: every pool key's currency order depends on its
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
        _launchedTokens[token] = LaunchedToken({
            token: token,
            deployer: originalDeployer,
            creatorFeeRecipient: params.creatorFeeRecipient == address(0) ? originalDeployer : params.creatorFeeRecipient,
            poolFee: poolFee,
            tickSpacing: config.tickSpacing,
            baseFeeBps: uint16(baseFeeBps),
            creatorTaxBps: params.creatorTaxBps,
            protocolFeeShareBps: uint16(protocolFeeShareBps),
            protocolFeeRecipient: protocolFeeRecipient,
            launchedAt: uint64(block.timestamp),
            marketCount: uint8(pairTokens.length),
            exists: true
        });

        _openMarkets(token, pairTokens, phantoms, config, poolFee);

        // Last, after the launch is fully recorded: this forwards ETH to the
        // protocol recipient, which may be a contract that calls back in.
        _payLaunchFee();

        emit TokenLaunched(token, originalDeployer, launchConfigId, poolFee, pairTokens);
    }

    /**
     * @dev Initializes every pool at its plan's price, mints the positions
     * and locks them. Each market gets supply / N tokens against
     * phantom_i / N, so all open at one ETH price.
     */
    function _openMarkets(
        address token,
        address[] calldata pairTokens,
        uint256[] memory phantoms,
        LaunchConfig memory config,
        uint24 poolFee
    ) private {
        uint256 n = pairTokens.length;
        uint256 supplyEach = config.supply / n;
        PoolKey[] memory keys = new PoolKey[](n);
        PairPadPositionMath.Plan[] memory plans = new PairPadPositionMath.Plan[](n);

        for (uint256 i = 0; i < n; i++) {
            keys[i] = _poolKey(token, pairTokens[i], poolFee, config.tickSpacing);
            // Nothing stops a third party from initializing a hookless pool
            // for an address that does not exist yet. A launch onto such a
            // pool would open at their price, so it is refused instead.
            (uint160 existingPrice,,,) = poolManager.getSlot0(keys[i].toId());
            if (existingPrice != 0) revert PoolAlreadyExists();

            bool tokenIsCurrency0 = Currency.unwrap(keys[i].currency0) == token;
            plans[i] = positionMinter.plan(tokenIsCurrency0, supplyEach, phantoms[i] / n, config.tickSpacing);
            poolManager.initialize(keys[i], plans[i].sqrtPriceX96);
        }

        (uint256[] memory positionIds, uint256[] memory tokenAmounts) =
            positionMinter.mintLaunchPositions(token, keys, plans, supplyEach);
        locker.lockPositions(token, positionIds);

        for (uint256 i = 0; i < n; i++) {
            _markets[token].push(
                Market({
                    pairToken: pairTokens[i],
                    phantomQuote: phantoms[i] / n,
                    tickLower: plans[i].tickLower,
                    tickUpper: plans[i].tickUpper,
                    liquidity: plans[i].liquidity,
                    positionId: positionIds[i]
                })
            );
            emit MarketOpened(
                token,
                PoolId.unwrap(keys[i].toId()),
                i,
                pairTokens[i],
                positionIds[i],
                plans[i].tickLower,
                plans[i].tickUpper,
                plans[i].liquidity,
                tokenAmounts[i],
                phantoms[i] / n
            );
        }
    }

    // ---------------------------------------------------------------------
    // Creator fee recipient
    // ---------------------------------------------------------------------

    function transferCreatorFeeRecipient(address token, address newRecipient) external {
        LaunchedToken storage launch = _launchedTokens[token];
        if (!launch.exists) revert TokenNotFound();
        if (msg.sender != launch.creatorFeeRecipient) revert NotCreatorFeeRecipient();
        _setCreatorFeeRecipient(token, launch, newRecipient);
    }

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

    /// @dev 1..MAX_MARKETS distinct quote assets, never WETH (native ETH is).
    function _validatePairTokens(address[] calldata pairTokens) private view {
        uint256 n = pairTokens.length;
        if (n == 0 || n > MAX_MARKETS) revert InvalidMarketCount();
        for (uint256 i = 0; i < n; i++) {
            if (pairTokens[i] == weth) revert WethNotAllowed();
            for (uint256 j = i + 1; j < n; j++) {
                if (pairTokens[i] == pairTokens[j]) revert DuplicatePairToken();
            }
        }
    }

    /// @dev The whole-supply phantom reserve of every quote asset.
    function _phantoms(LaunchConfig memory config, address[] calldata pairTokens)
        private
        view
        returns (uint256[] memory phantoms)
    {
        phantoms = new uint256[](pairTokens.length);
        for (uint256 i = 0; i < pairTokens.length; i++) {
            phantoms[i] = _quoteEconomics(config, pairTokens[i]);
        }
    }

    /**
     * @dev Resolves the whole-supply phantom reserve for one quote asset:
     * native ETH takes the config's own figure, a curated ERC-20 its
     * owner-set override, every other ERC-20 the quote pricer's conversion.
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

    /// @dev Every owner-controlled term that fixes what a creator is buying.
    function _economicsDigest(LaunchConfig memory config, uint256[] memory phantoms) private view returns (bytes32) {
        return keccak256(abi.encode(phantoms, config.supply, config.tickSpacing, baseFeeBps, protocolFeeShareBps));
    }

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
                || positionMinter.locker() != address(locker)
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
        // Both currency orders and the smallest slice are checked so a config
        // the position math cannot lay out is refused here, not per launch.
        if (address(positionMinter) != address(0)) {
            uint256 slice = config.supply / MAX_MARKETS;
            uint256 phantom = config.phantomQuote / MAX_MARKETS;
            positionMinter.plan(true, config.supply, config.phantomQuote, config.tickSpacing);
            positionMinter.plan(false, config.supply, config.phantomQuote, config.tickSpacing);
            positionMinter.plan(true, slice, phantom, config.tickSpacing);
            positionMinter.plan(false, slice, phantom, config.tickSpacing);
        }
    }
}
