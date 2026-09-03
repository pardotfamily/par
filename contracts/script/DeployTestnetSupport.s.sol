// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/**
 * @notice Robinhood Chain testnet (46630) has the real Uniswap V4 stack but
 * no official Uniswap V3, no WETH and no USDG. This script deploys the
 * support surface PairPad needs there so the whole protocol can be exercised
 * end to end:
 *
 *  - TestWETH / TestUSDG: freely mintable stand-ins for the canonical assets.
 *  - TestnetV3Factory / TestnetV3Pool: the minimal V3 reference-pool surface
 *    the QuotePricer consults (observe/slot0/liquidity + a token balance),
 *    with a pre-registered WETH/USDG pool so USDG launches TWAP-price out of
 *    the box. `registerReference` is open, so testers can make ANY test
 *    token priceable - which is exactly the differentiator being rehearsed.
 *  - TestnetSwapRouterStub: keeps the ZapRouter deployable; zap swaps
 *    revert with a clear message (there is no V3 liquidity to swap against
 *    on testnet - the zap legs are covered by the mainnet fork tests).
 *
 * Run before Deploy.s.sol and feed its output into the env:
 *
 *   forge script script/DeployTestnetSupport.s.sol --rpc-url robinhood_testnet --broadcast
 */
contract TestToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Open faucet mint, capped per call to keep balances sane.
    function mint(address to, uint256 amount) external {
        require(amount <= 1_000_000 * 10 ** _decimals, "mint capped at 1M per call");
        _mint(to, amount);
    }
}

/// @dev The pricer-facing slice of a V3 pool: a settable tick observed as a
/// flat TWAP since creation, plus a liquidity figure. The pricer's depth
/// floor reads the pool's WETH (or USDG) balance, so registration funds it.
contract TestnetV3Pool {
    address public immutable creator;
    int24 public tick;
    uint128 private immutable _liquidity;
    uint32 private immutable _createdAt;

    constructor(address creator_, int24 tick_, uint128 liquidity_) {
        creator = creator_;
        tick = tick_;
        _liquidity = liquidity_;
        // Backdated so the pricer's observation-history requirement (a full
        // TWAP window, up to 6 hours) is satisfied the moment a testnet
        // reference is registered: the stub reports a flat tick since
        // "creation" anyway, so the extra history is the same flat line.
        _createdAt = uint32(block.timestamp - 7 hours);
    }

    function setTick(int24 tick_) external {
        require(msg.sender == creator, "only pool creator");
        tick = tick_;
    }

    function liquidity() external view returns (uint128) {
        return _liquidity;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (TickMath.getSqrtPriceAtTick(tick), tick, 0, 1, 1, 0, true);
    }

    function observations(uint256) external view returns (uint32, int56, uint160, bool) {
        return (_createdAt, 0, 0, true);
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; ++i) {
            uint256 age = block.timestamp - secondsAgos[i] - _createdAt;
            tickCumulatives[i] = int56(tick) * int56(uint56(age));
        }
    }
}

interface IMintableTestToken {
    function mint(address to, uint256 amount) external;
}

contract TestnetV3Factory {
    event ReferenceRegistered(address indexed tokenA, address indexed tokenB, uint24 fee, address pool);

    address public immutable weth;

    mapping(address => mapping(address => mapping(uint24 => address))) private _pools;

    constructor(address weth_) {
        weth = weth_;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return _pools[tokenA][tokenB][fee];
    }

    /**
     * @notice Registers a reference pool for `token` against `anchor` (WETH
     * or the USDG hop) at a flat `tick`, and mints test-anchor depth onto the
     * pool so it clears the pricer's liquidity floor. Open to everyone:
     * making an arbitrary test token TWAP-priceable is the point of the
     * testnet rehearsal.
     */
    function registerReference(address token, address anchor, uint24 fee, int24 tick, uint256 anchorDepth)
        external
        returns (address pool)
    {
        require(token != anchor, "identical tokens");
        require(_pools[token][anchor][fee] == address(0), "pool exists");
        pool = address(new TestnetV3Pool(msg.sender, tick, 1e24));
        _pools[token][anchor][fee] = pool;
        _pools[anchor][token][fee] = pool;
        IMintableTestToken(anchor).mint(pool, anchorDepth);
        emit ReferenceRegistered(token, anchor, fee, pool);
    }
}

/// @dev Nonzero address for the ZapRouter constructor on a chain with no V3
/// liquidity; any zap attempt reverts with a readable reason.
contract TestnetSwapRouterStub {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata) external payable returns (uint256) {
        revert("no Uniswap V3 on Robinhood testnet - zap works on mainnet only");
    }
}

contract DeployTestnetSupport is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        TestToken weth = new TestToken("Test Wrapped Ether", "WETH", 18);
        TestToken usdg = new TestToken("Test Global Dollar", "USDG", 6);
        TestnetV3Factory v3Factory = new TestnetV3Factory(address(weth));
        TestnetSwapRouterStub routerStub = new TestnetSwapRouterStub();

        // WETH/USDG reference at a flat ~4,500 USDG per ETH so two-hop
        // pricing behaves like mainnet. In raw units (6 vs 18 decimals) that
        // ratio is 4.5e-9; tick = ln(price)/ln(1.0001), sign depending on
        // address order, computed off-chain: ln(4.5e-9) = -19.219 -> tick
        // -192,190 when USDG is token1 (price = token1/token0 raw).
        int24 tick = address(weth) < address(usdg) ? int24(-192190) : int24(192190);
        address wethUsdgPool = v3Factory.registerReference(address(usdg), address(weth), 500, tick, 1_000 ether);

        vm.stopBroadcast();

        console2.log("Test WETH:             ", address(weth));
        console2.log("Test USDG:             ", address(usdg));
        console2.log("TestnetV3Factory:      ", address(v3Factory));
        console2.log("TestnetSwapRouterStub: ", address(routerStub));
        console2.log("WETH/USDG reference:   ", wethUsdgPool);
    }
}
