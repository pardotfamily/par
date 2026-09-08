// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {PairPadFeeEscrow} from "../src/v2/PairPadFeeEscrow.sol";
import {IPairPadFeeEscrow} from "../src/v2/interfaces/ILaunchpadV2.sol";
import {
    PairPadBurnVault, IPairPadSwapRouter, ISingleLaunchFactory, IMultiLaunchFactory
} from "../src/fees/PairPadBurnVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract BurnableMock is ERC20, ERC20Burnable {
    constructor() ERC20("Launch", "LNCH") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Fixed-rate "pool": 1 quote unit buys RATE token units, minted on the spot.
contract MockSwapRouter is IPairPadSwapRouter {
    uint256 public constant RATE = 1000;
    PoolKey public lastKey;
    bool public lastZeroForOne;

    function swapExactIn(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint256 minAmountOut, address recipient)
        external
        payable
        returns (uint256 amountOut)
    {
        lastKey = key;
        lastZeroForOne = zeroForOne;
        Currency cIn = zeroForOne ? key.currency0 : key.currency1;
        Currency cOut = zeroForOne ? key.currency1 : key.currency0;
        if (Currency.unwrap(cIn) == address(0)) {
            require(msg.value == amountIn, "value");
        } else {
            require(msg.value == 0, "no value");
            IERC20(Currency.unwrap(cIn)).transferFrom(msg.sender, address(this), amountIn);
        }
        amountOut = amountIn * RATE;
        require(amountOut >= minAmountOut, "slippage");
        BurnableMock(Currency.unwrap(cOut)).mint(recipient, amountOut);
    }
}

contract MockSingleFactory is ISingleLaunchFactory {
    mapping(address => PoolKey) internal keys;
    mapping(address => bool) internal known;

    error TokenNotFound();

    function set(address token, PoolKey memory key) external {
        keys[token] = key;
        known[token] = true;
    }

    function poolKeyFor(address token) external view returns (PoolKey memory) {
        if (!known[token]) revert TokenNotFound();
        return keys[token];
    }
}

contract MockMultiFactory is IMultiLaunchFactory {
    mapping(address => PoolKey[]) internal keys;
    mapping(address => bool) internal known;

    error TokenNotFound();

    function add(address token, PoolKey memory key) external {
        keys[token].push(key);
        known[token] = true;
    }

    function poolKeysFor(address token) external view returns (PoolKey[] memory) {
        if (!known[token]) revert TokenNotFound();
        return keys[token];
    }
}

contract BurnVaultTest is Test {
    PairPadFeeEscrow internal escrow;
    MockSwapRouter internal router;
    MockSingleFactory internal factory;
    MockMultiFactory internal multiFactory;
    PairPadBurnVault internal vault;

    BurnableMock internal token;
    MockERC20 internal usdg;
    address internal operator = makeAddr("operator");
    address internal rando = makeAddr("rando");

    function setUp() public {
        escrow = new PairPadFeeEscrow();
        router = new MockSwapRouter();
        factory = new MockSingleFactory();
        multiFactory = new MockMultiFactory();
        vault = new PairPadBurnVault(
            IPairPadFeeEscrow(address(escrow)), router, factory, multiFactory, operator
        );
        token = new BurnableMock();
        usdg = new MockERC20("USDG", "USDG", 6);
        vm.deal(address(this), 100 ether);
    }

    function _key(address a, address b) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });
    }

    function test_constructorGuards() public {
        vm.expectRevert(PairPadBurnVault.ZeroAddress.selector);
        new PairPadBurnVault(IPairPadFeeEscrow(address(0)), router, factory, multiFactory, operator);
        vm.expectRevert(PairPadBurnVault.ZeroAddress.selector);
        new PairPadBurnVault(IPairPadFeeEscrow(address(escrow)), router, factory, multiFactory, address(0));
        assertEq(vault.operator(), operator);
        assertEq(address(vault.router()), address(router));
    }

    function test_burnToken_claimsFromEscrowAndBurns_anyoneMayCall() public {
        // A locker credited the creator's token share under the vault.
        token.mint(address(this), 5e18);
        token.approve(address(escrow), 5e18);
        escrow.creditToken(address(vault), address(token), 5e18);
        // Plus something sent straight to the vault.
        token.mint(address(vault), 1e18);
        uint256 supply = token.totalSupply();
        assertEq(vault.pending(address(token)), 5e18);

        vm.prank(rando);
        uint256 amount = vault.burnToken(address(token));
        assertEq(amount, 6e18);
        assertEq(token.totalSupply(), supply - 6e18, "supply shrank");
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.pending(address(token)), 0);
        assertEq(vault.burned(address(token)), 6e18);
    }

    function test_burnToken_nothingToBurnIsANoop() public {
        assertEq(vault.burnToken(address(token)), 0);
        assertEq(vault.burned(address(token)), 0);
    }

    function test_buyback_eth_singleMarket() public {
        factory.set(address(token), _key(address(0), address(token)));
        escrow.credit{value: 2 ether}(address(vault));
        // Token side waiting in the escrow too; the round burns it along.
        token.mint(address(this), 3e18);
        token.approve(address(escrow), 3e18);
        escrow.creditToken(address(vault), address(token), 3e18);

        uint256 supply = token.totalSupply();
        vm.prank(operator);
        (uint256 out, uint256 burnedNow) = vault.buyback(address(token), address(0), 1 ether, 1 ether * 1000);
        assertEq(out, 1 ether * 1000);
        assertEq(burnedNow, out + 3e18);
        // Everything bought was burned, along with the token share: supply is
        // down by the token share (the swap minted `out` and burned it again).
        assertEq(token.totalSupply(), supply - 3e18);
        assertEq(token.balanceOf(address(vault)), 0);
        // Half the ETH is still pooled in the vault for the next round.
        assertEq(address(vault).balance, 1 ether);
        assertEq(vault.pending(address(0)), 0);
        assertEq(vault.spent(address(token), address(0)), 1 ether);
        assertEq(vault.burned(address(token)), burnedNow);
        // Direction: ETH is currency0.
        assertTrue(router.lastZeroForOne());
    }

    function test_buyback_erc20Quote_multiMarket() public {
        // A multi launch with an ETH market and a USDG market.
        multiFactory.add(address(token), _key(address(0), address(token)));
        multiFactory.add(address(token), _key(address(usdg), address(token)));
        usdg.mint(address(this), 500e6);
        usdg.approve(address(escrow), 500e6);
        escrow.creditToken(address(vault), address(usdg), 500e6);

        vm.prank(operator);
        (uint256 out,) = vault.buyback(address(token), address(usdg), 500e6, 0);
        assertEq(out, 500e6 * 1000);
        assertEq(usdg.balanceOf(address(vault)), 0);
        assertEq(usdg.balanceOf(address(router)), 500e6);
        assertEq(usdg.allowance(address(vault), address(router)), 0, "allowance cleared");
        // The router was handed the USDG market, not the ETH one.
        (Currency c0, Currency c1,,,) = router.lastKey();
        address quote = Currency.unwrap(c0) == address(token) ? Currency.unwrap(c1) : Currency.unwrap(c0);
        assertEq(quote, address(usdg));
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_buyback_onlyOperator() public {
        factory.set(address(token), _key(address(0), address(token)));
        vm.deal(address(vault), 1 ether);
        vm.prank(rando);
        vm.expectRevert(PairPadBurnVault.NotOperator.selector);
        vault.buyback(address(token), address(0), 1 ether, 0);
    }

    function test_buyback_revertsBelowFloor() public {
        factory.set(address(token), _key(address(0), address(token)));
        vm.deal(address(vault), 1 ether);
        vm.prank(operator);
        vm.expectRevert(bytes("slippage"));
        vault.buyback(address(token), address(0), 1 ether, 1 ether * 1000 + 1);
    }

    function test_buyback_refusesPairsTheFactoriesDoNotKnow() public {
        // Not launched anywhere.
        vm.deal(address(vault), 1 ether);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PairPadBurnVault.NoMarket.selector, address(token), address(0)));
        vault.buyback(address(token), address(0), 1 ether, 0);

        // Launched against USDG only: buying it with ETH is not a market it has.
        factory.set(address(token), _key(address(usdg), address(token)));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(PairPadBurnVault.NoMarket.selector, address(token), address(0)));
        vault.buyback(address(token), address(0), 1 ether, 0);
    }

    function test_buyback_zeroAmountReverts() public {
        factory.set(address(token), _key(address(0), address(token)));
        vm.prank(operator);
        vm.expectRevert(PairPadBurnVault.ZeroAmount.selector);
        vault.buyback(address(token), address(0), 0, 0);
    }

    function test_poolKeyFor_view() public {
        factory.set(address(token), _key(address(0), address(token)));
        PoolKey memory k = vault.poolKeyFor(address(token), address(0));
        assertEq(Currency.unwrap(k.currency1), address(token));
    }
}
