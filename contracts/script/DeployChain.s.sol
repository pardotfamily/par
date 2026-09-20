// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {PairPadFeeEscrow} from "../src/v2/PairPadFeeEscrow.sol";
import {PairPadQuotePricer, IUniswapV3FactoryMinimal} from "../src/v2/PairPadQuotePricer.sol";
import {PairPadReferenceRegistry, IPairPadFactoryPoolKeys} from "../src/v2/PairPadReferenceRegistries.sol";
import {PairPadLaunchLocker} from "../src/v2/PairPadLaunchLocker.sol";
import {PairPadLaunchFactory} from "../src/v2/PairPadLaunchFactory.sol";
import {PairPadPositionMinter} from "../src/v2/PairPadPositionMinter.sol";
import {PairPadLaunchDeployer} from "../src/v2/PairPadLaunchDeployer.sol";
import {PairPadRouter, ISwapRouter02, IWETH9} from "../src/v2/PairPadRouter.sol";
import {IPairPadFeeEscrow} from "../src/v2/interfaces/ILaunchpadV2.sol";
import {PairPadMultiLaunchLocker} from "../src/v3/PairPadMultiLaunchLocker.sol";
import {PairPadMultiLaunchFactory} from "../src/v3/PairPadMultiLaunchFactory.sol";
import {PairPadMultiPositionMinter} from "../src/v3/PairPadMultiPositionMinter.sol";
import {PairPadMultiRouter} from "../src/v3/PairPadMultiRouter.sol";
import {PairPadMultiReferenceRegistry} from "../src/v3/PairPadMultiReferenceRegistry.sol";
import {IPairPadMultiLaunchFactory} from "../src/v3/interfaces/ILaunchpadV3.sol";
import {PairPadFeeSplitter} from "../src/fees/PairPadFeeSplitter.sol";
import {PairPadHolderVault} from "../src/fees/PairPadHolderVault.sol";
import {PairPadDisperseV2} from "../src/fees/PairPadDisperseV2.sol";
import {
    PairPadBurnVault, IPairPadSwapRouter, ISingleLaunchFactory, IMultiLaunchFactory
} from "../src/fees/PairPadBurnVault.sol";
import {
    PairPadFloorVault, IFloorSingleFactory, IFloorSingleLocker, IFloorMultiFactory, IFloorMultiLocker
} from "../src/fees/PairPadFloorVault.sol";

/**
 * @notice Deploys the whole par stack on a chain whose gas token is the
 * reference asset (ETH on Base, BNB on BNB Chain): the Robinhood Chain
 * shape, where native (address zero) is the reference market and the
 * wrapped native sits in the pricer's `weth` slot for V3 hops. Both the
 * single-market and the multi-market factories launch, as on Robinhood
 * Chain. The chain table below carries the canonical Uniswap addresses per
 * chain id; env overrides exist for forks only and are refused on mainnet.
 *
 * Amounts in env are in the reference (18 decimals) unless noted:
 *   MIN_REFERENCE     pricer depth floor per hop (default: chain table)
 *   LAUNCH_PHANTOM    opening reserve = opening market cap (default: chain table)
 *   LAUNCH_FEE        paid in native (default: chain table)
 *   BUYBACK_WALLET, TREASURY, DISTRIBUTOR  fee routing wallets (required)
 *   BUYBACK_BPS       splitter share to buyback (default 6000)
 *   FINAL_OWNER       optional multisig to hand ownership to
 *
 * Usage:
 *   forge script script/DeployChain.s.sol --rpc-url $RPC --broadcast
 */
contract DeployChain is Script {
    struct Infra {
        address poolManager;
        address positionManager;
        address permit2;
        address v3Factory;
        address swapRouter02;
        address weth;
        address secondAnchor;
    }

    struct Defaults {
        uint256 launchFee;
        uint256 minReference;
        uint256 phantom;
        string name;
    }

    struct Params {
        address owner;
        address protocolFeeRecipient;
        uint256 launchFee;
        uint256 minReference;
        uint256 supply;
        uint256 phantom;
        address buyback;
        address treasury;
        address distributor;
        uint16 buybackBps;
    }

    struct Fees {
        PairPadFeeSplitter splitter;
        PairPadHolderVault holderVault;
        PairPadDisperseV2 disperse;
        PairPadBurnVault burnVault;
        PairPadFloorVault floorVault;
    }

    struct Core {
        PairPadFeeEscrow feeEscrow;
        PairPadQuotePricer pricer;
        PairPadLaunchLocker locker;
        PairPadLaunchFactory factory;
        PairPadRouter router;
        PairPadMultiLaunchLocker multiLocker;
        PairPadMultiLaunchFactory multiFactory;
        PairPadMultiRouter multiRouter;
        PairPadMultiReferenceRegistry multiRegistry;
    }

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev Canonical infra per chain (Uniswap deployments pages, verified on chain 2026-09-18).
    function _table(uint256 chainId) internal pure returns (Infra memory infra, Defaults memory d) {
        if (chainId == 8453) {
            // Base. Second anchor: native USDC (6 decimals).
            infra = Infra({
                poolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
                positionManager: 0x7C5f5A4bBd8fD63184577525326123B519429bDc,
                permit2: PERMIT2,
                v3Factory: 0x33128a8fC17869897dcE68Ed026d694621f6FDfD,
                swapRouter02: 0x2626664c2603336E57B271c5C0b26F421741e481,
                weth: 0x4200000000000000000000000000000000000006,
                secondAnchor: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
            });
            // About $5k opening cap and a $5k depth floor at ETH ~$2,600.
            d = Defaults({launchFee: 0.0005 ether, minReference: 2 ether, phantom: 1.36 ether, name: "Base"});
        } else if (chainId == 56) {
            // BNB Chain. Second anchor: USDT (18 decimals on BNB). The V3 side is
            // PancakeSwap's, not Uniswap's: that is where BNB Chain's liquidity is
            // (stocks, memes, stables). Pancake V3 is a Uniswap V3 fork with the
            // same pool and factory interfaces; its SmartRouter is SwapRouter02's
            // exactInputSingle. Only the fee tiers differ (100/500/2500/10000),
            // set on the pricer after deploy. The par pools themselves stay in
            // Uniswap's V4 PoolManager.
            infra = Infra({
                poolManager: 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF,
                positionManager: 0x7A4a5c919aE2541AeD11041A1AEeE68f1287f95b,
                permit2: PERMIT2,
                v3Factory: 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865,
                swapRouter02: 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4,
                weth: 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,
                secondAnchor: 0x55d398326f99059fF775485246999027B3197955
            });
            // Opening cap matched to Robinhood Chain's 1.36 ETH; depth floor 2.5 BNB (~$1.9k).
            d = Defaults({launchFee: 0.002 ether, minReference: 2.5 ether, phantom: 4.7 ether, name: "BNB Chain"});
        } else {
            revert("DeployChain: chain not in table");
        }
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        (Infra memory table, Defaults memory d) = _table(block.chainid);

        // Overrides are for anvil forks with a different infra; a mainnet run must match the table.
        bool fork = vm.envOr("FORK", false);
        Infra memory infra = Infra({
            poolManager: fork ? vm.envOr("POOL_MANAGER", table.poolManager) : table.poolManager,
            positionManager: fork ? vm.envOr("POSITION_MANAGER", table.positionManager) : table.positionManager,
            permit2: fork ? vm.envOr("PERMIT2", table.permit2) : table.permit2,
            v3Factory: fork ? vm.envOr("V3_FACTORY", table.v3Factory) : table.v3Factory,
            swapRouter02: fork ? vm.envOr("SWAP_ROUTER_02", table.swapRouter02) : table.swapRouter02,
            weth: fork ? vm.envOr("WETH", table.weth) : table.weth,
            secondAnchor: fork ? vm.envOr("SECOND_ANCHOR", table.secondAnchor) : table.secondAnchor
        });
        Params memory p = Params({
            owner: vm.addr(deployerKey),
            protocolFeeRecipient: address(0),
            launchFee: vm.envOr("LAUNCH_FEE", d.launchFee),
            minReference: vm.envOr("MIN_REFERENCE", d.minReference),
            supply: vm.envOr("LAUNCH_SUPPLY", uint256(1_000_000_000 ether)),
            phantom: vm.envOr("LAUNCH_PHANTOM", d.phantom),
            buyback: vm.envAddress("BUYBACK_WALLET"),
            treasury: vm.envAddress("TREASURY"),
            distributor: vm.envAddress("DISTRIBUTOR"),
            buybackBps: uint16(vm.envOr("BUYBACK_BPS", uint256(6000)))
        });
        p.protocolFeeRecipient = vm.envOr("PROTOCOL_FEE_RECIPIENT", p.owner);

        require(infra.poolManager.code.length != 0, "no PoolManager at address");
        require(infra.positionManager.code.length != 0, "no PositionManager at address");
        require(infra.v3Factory.code.length != 0, "no V3 factory at address");
        require(infra.swapRouter02.code.length != 0, "no SwapRouter02 at address");
        require(infra.weth.code.length != 0, "no wrapped native at address");
        require(infra.secondAnchor.code.length != 0, "no second anchor at address");

        console2.log("Deploying par on", d.name);
        vm.startBroadcast(deployerKey);
        Core memory c = _deployCore(infra, p);
        _deployMulti(infra, p, c);
        _deployFees(p, c);
        _handOver(c);
        vm.stopBroadcast();

        console2.log("PairPadFeeEscrow:              ", address(c.feeEscrow));
        console2.log("PairPadQuotePricer:            ", address(c.pricer));
        console2.log("PairPadLaunchLocker:           ", address(c.locker));
        console2.log("PairPadLaunchFactory:          ", address(c.factory));
        console2.log("PairPadRouter:                 ", address(c.router));
        console2.log("PairPadMultiLaunchLocker:      ", address(c.multiLocker));
        console2.log("PairPadMultiLaunchFactory:     ", address(c.multiFactory));
        console2.log("PairPadMultiRouter:            ", address(c.multiRouter));
        console2.log("PairPadMultiReferenceRegistry: ", address(c.multiRegistry));
        console2.log("wrapped native (pricer weth):  ", infra.weth);
        console2.log("second anchor:                 ", infra.secondAnchor);
    }

    /// @dev Escrow, pricer and the single-market stack (native quotes, enabled).
    function _deployCore(Infra memory infra, Params memory p) internal returns (Core memory c) {
        c.feeEscrow = new PairPadFeeEscrow();

        c.pricer = new PairPadQuotePricer(
            p.owner,
            IUniswapV3FactoryMinimal(infra.v3Factory),
            infra.weth,
            infra.secondAnchor,
            IPoolManager(infra.poolManager),
            true
        );
        c.pricer.setMinReferenceEth(p.minReference);
        if (block.chainid == 56) {
            uint24[] memory tiers = new uint24[](4);
            tiers[0] = 100;
            tiers[1] = 500;
            tiers[2] = 2_500;
            tiers[3] = 10_000;
            c.pricer.setV3FeeTiers(tiers);
        }

        c.locker = new PairPadLaunchLocker(
            p.owner, IPositionManager(infra.positionManager), IPairPadFeeEscrow(address(c.feeEscrow))
        );
        c.factory = new PairPadLaunchFactory(
            p.owner,
            IPoolManager(infra.poolManager),
            IPositionManager(infra.positionManager),
            c.locker,
            IPairPadFeeEscrow(address(c.feeEscrow)),
            c.pricer,
            p.protocolFeeRecipient,
            p.launchFee
        );
        PairPadPositionMinter minter = new PairPadPositionMinter(
            IPositionManager(infra.positionManager), IAllowanceTransfer(infra.permit2), c.locker, address(c.factory)
        );
        PairPadLaunchDeployer launchDeployer = new PairPadLaunchDeployer(address(c.factory));
        c.router = new PairPadRouter(
            IPoolManager(infra.poolManager), c.factory, ISwapRouter02(infra.swapRouter02), IWETH9(infra.weth)
        );

        c.pricer.addRegistry(new PairPadReferenceRegistry(IPairPadFactoryPoolKeys(address(c.factory))));
        c.locker.setFactory(address(c.factory));
        c.factory.setPositionMinter(minter);
        c.factory.setLaunchDeployer(launchDeployer);
        c.factory.setLaunchForwarder(address(c.router));
        c.factory.addLaunchConfig(
            PairPadLaunchFactory.LaunchConfig({
                supply: p.supply, phantomQuote: p.phantom, tickSpacing: 10, enabled: true
            })
        );
        c.factory.setLaunchEnabled(vm.envOr("LAUNCH_ENABLED", true));
    }

    /// @dev The multi-market stack.
    function _deployMulti(Infra memory infra, Params memory p, Core memory c) internal {
        c.multiLocker = new PairPadMultiLaunchLocker(
            p.owner, IPositionManager(infra.positionManager), IPairPadFeeEscrow(address(c.feeEscrow))
        );
        c.multiFactory = new PairPadMultiLaunchFactory(
            p.owner,
            IPoolManager(infra.poolManager),
            IPositionManager(infra.positionManager),
            c.multiLocker,
            IPairPadFeeEscrow(address(c.feeEscrow)),
            c.pricer,
            infra.weth,
            true,
            p.protocolFeeRecipient,
            p.launchFee
        );
        PairPadMultiPositionMinter minter = new PairPadMultiPositionMinter(
            IPositionManager(infra.positionManager),
            IAllowanceTransfer(infra.permit2),
            address(c.multiLocker),
            address(c.multiFactory)
        );
        PairPadLaunchDeployer launchDeployer = new PairPadLaunchDeployer(address(c.multiFactory));
        c.multiRouter = new PairPadMultiRouter(
            IPoolManager(infra.poolManager), c.multiFactory, ISwapRouter02(infra.swapRouter02), IWETH9(infra.weth)
        );
        c.multiRegistry = new PairPadMultiReferenceRegistry(IPairPadMultiLaunchFactory(address(c.multiFactory)));

        c.multiLocker.setFactory(address(c.multiFactory));
        c.multiFactory.setPositionMinter(minter);
        c.multiFactory.setLaunchDeployer(launchDeployer);
        c.multiFactory.setLaunchForwarder(address(c.multiRouter));
        c.multiFactory.addLaunchConfig(
            PairPadMultiLaunchFactory.LaunchConfig({
                supply: p.supply, phantomQuote: p.phantom, tickSpacing: 10, enabled: true
            })
        );
        c.multiFactory.setLaunchEnabled(vm.envOr("LAUNCH_ENABLED", true));
        c.pricer.addRegistry(c.multiRegistry);
    }

    /// @dev Fee routing: splitter as protocol recipient, the three creator-fee vaults, disperser.
    function _deployFees(Params memory p, Core memory c) internal returns (Fees memory f) {
        require(p.buyback != p.treasury, "buyback and treasury must differ");
        require(p.buyback != p.distributor, "buyback and distributor must differ");

        PairPadFeeSplitter splitter = new PairPadFeeSplitter(
            p.buyback, p.treasury, p.buybackBps, address(c.factory), address(c.multiFactory)
        );
        PairPadHolderVault holderVault = new PairPadHolderVault(IPairPadFeeEscrow(address(c.feeEscrow)), p.distributor);
        PairPadDisperseV2 disperse = new PairPadDisperseV2();
        PairPadBurnVault burnVault = new PairPadBurnVault(
            IPairPadFeeEscrow(address(c.feeEscrow)),
            IPairPadSwapRouter(address(c.router)),
            ISingleLaunchFactory(address(c.factory)),
            IMultiLaunchFactory(address(c.multiFactory)),
            p.distributor
        );
        PairPadFloorVault floorVault = new PairPadFloorVault(
            IPoolManager(address(c.factory.poolManager())),
            IPairPadFeeEscrow(address(c.feeEscrow)),
            IFloorSingleFactory(address(c.factory)),
            IFloorSingleLocker(address(c.locker)),
            IFloorMultiFactory(address(c.multiFactory)),
            IFloorMultiLocker(address(c.multiLocker)),
            p.distributor
        );
        c.factory.setProtocolFeeRecipient(address(splitter));
        c.multiFactory.setProtocolFeeRecipient(address(splitter));
        f = Fees({splitter: splitter, holderVault: holderVault, disperse: disperse, burnVault: burnVault, floorVault: floorVault});

        console2.log("PairPadFeeSplitter:            ", address(splitter));
        console2.log("PairPadHolderVault:            ", address(holderVault));
        console2.log("PairPadDisperseV2:             ", address(disperse));
        console2.log("PairPadBurnVault:              ", address(burnVault));
        console2.log("PairPadFloorVault:             ", address(floorVault));
    }

    /// @dev Optional two-step ownership handover to a multisig.
    function _handOver(Core memory c) internal {
        address finalOwner = vm.envOr("FINAL_OWNER", address(0));
        if (finalOwner == address(0) || finalOwner == c.factory.owner()) return;
        c.factory.transferOwnership(finalOwner);
        c.pricer.transferOwnership(finalOwner);
        c.locker.transferOwnership(finalOwner);
        c.multiFactory.transferOwnership(finalOwner);
        c.multiLocker.transferOwnership(finalOwner);
        console2.log("Ownership transfer started to:", finalOwner);
        console2.log("FINAL_OWNER must call acceptOwnership() on factory, pricer, locker, multi factory, multi locker.");
    }
}
