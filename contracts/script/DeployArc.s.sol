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
 * @notice Deploys the whole par stack on Arc (chain 5042, testnet 5042002),
 * where USDC is the gas token and its ERC-20 face at 0x3600...0000 (six
 * decimals) is the reference asset: what launches are priced in and what
 * buyers pay with. Native (address zero) is never paired, so the pricer and
 * the multi factory run with `nativeIsReference = false` and the multi
 * router's `*WithReference` entry points carry the trades.
 *
 * The single-market (v2) stack is deployed for the fee vaults, which read
 * both factories, but its public launches stay disabled: it only knows
 * native quotes, which on Arc would mean the eighteen-decimal view of USDC.
 *
 * Amounts in env are in the reference's units unless noted:
 *   MIN_REFERENCE     pricer depth floor per hop, 6-dec USDC (default 2,500 USDC)
 *   LAUNCH_PHANTOM    opening reserve = opening market cap, 6-dec USDC (default 5,000 USDC)
 *   LAUNCH_FEE        paid in native, 18-dec USDC (default 2 USDC)
 *   SECOND_ANCHOR     a second stable the pricer may route through (EURC);
 *                     required on mainnet, defaults to testnet EURC on 5042002
 *   BUYBACK_WALLET, TREASURY, DISTRIBUTOR  fee routing wallets (required)
 *   FINAL_OWNER       optional multisig to hand ownership to
 *
 * Usage:
 *   forge script script/DeployArc.s.sol --rpc-url $ARC_RPC --broadcast
 */
contract DeployArc is Script {
    // Uniswap on Arc mainnet (Uniswap/contracts deployments/5042.md).
    address internal constant ARC_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant ARC_POSITION_MANAGER = 0x6049c9a0e26405C0985f9E3685C87d0aE917f82B;
    address internal constant ARC_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant ARC_V3_FACTORY = 0xf0db7b58379503491d857dB50AC9ece64c653918;
    address internal constant ARC_SWAP_ROUTER_02 = 0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77;
    /// @dev The ERC-20 interface of native USDC, six decimals; same on testnet.
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    /// @dev EURC on Arc testnet; the mainnet address is published with mainnet.
    address internal constant ARC_TESTNET_EURC = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;

    struct Infra {
        address poolManager;
        address positionManager;
        address permit2;
        address v3Factory;
        address swapRouter02;
        address usdc;
        address secondAnchor;
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

    function run() external {
        require(block.chainid == 5042 || block.chainid == 5042002, "DeployArc: not Arc");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        Infra memory infra = Infra({
            poolManager: vm.envOr("POOL_MANAGER", ARC_POOL_MANAGER),
            positionManager: vm.envOr("POSITION_MANAGER", ARC_POSITION_MANAGER),
            permit2: vm.envOr("PERMIT2", ARC_PERMIT2),
            v3Factory: vm.envOr("V3_FACTORY", ARC_V3_FACTORY),
            swapRouter02: vm.envOr("SWAP_ROUTER_02", ARC_SWAP_ROUTER_02),
            usdc: vm.envOr("USDC", ARC_USDC),
            secondAnchor: block.chainid == 5042
                ? vm.envAddress("SECOND_ANCHOR")
                : vm.envOr("SECOND_ANCHOR", ARC_TESTNET_EURC)
        });
        Params memory p = Params({
            owner: vm.addr(deployerKey),
            protocolFeeRecipient: address(0),
            launchFee: vm.envOr("LAUNCH_FEE", uint256(2 ether)),
            minReference: vm.envOr("MIN_REFERENCE", uint256(2_500e6)),
            supply: vm.envOr("LAUNCH_SUPPLY", uint256(1_000_000_000 ether)),
            phantom: vm.envOr("LAUNCH_PHANTOM", uint256(5_000e6)),
            buyback: vm.envAddress("BUYBACK_WALLET"),
            treasury: vm.envAddress("TREASURY"),
            distributor: vm.envAddress("DISTRIBUTOR"),
            buybackBps: uint16(vm.envOr("BUYBACK_BPS", uint256(6000)))
        });
        p.protocolFeeRecipient = vm.envOr("PROTOCOL_FEE_RECIPIENT", p.owner);

        if (block.chainid == 5042) {
            require(infra.poolManager == ARC_POOL_MANAGER, "mainnet: POOL_MANAGER override");
            require(infra.positionManager == ARC_POSITION_MANAGER, "mainnet: POSITION_MANAGER override");
            require(infra.v3Factory == ARC_V3_FACTORY, "mainnet: V3_FACTORY override");
            require(infra.swapRouter02 == ARC_SWAP_ROUTER_02, "mainnet: SWAP_ROUTER_02 override");
            require(infra.usdc == ARC_USDC, "mainnet: USDC override");
        }
        require(infra.poolManager.code.length != 0, "no PoolManager at address");
        require(infra.positionManager.code.length != 0, "no PositionManager at address");
        require(infra.v3Factory.code.length != 0, "no V3 factory at address");
        require(infra.usdc.code.length != 0, "no USDC at address");

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
        console2.log("reference (USDC ERC-20):       ", infra.usdc);
    }

    /// @dev Escrow, pricer and the single-market stack (launches disabled).
    function _deployCore(Infra memory infra, Params memory p) internal returns (Core memory c) {
        c.feeEscrow = new PairPadFeeEscrow();

        c.pricer = new PairPadQuotePricer(
            p.owner,
            IUniswapV3FactoryMinimal(infra.v3Factory),
            infra.usdc,
            infra.secondAnchor,
            IPoolManager(infra.poolManager),
            false
        );
        c.pricer.setMinReferenceEth(p.minReference);

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
            IPoolManager(infra.poolManager), c.factory, ISwapRouter02(infra.swapRouter02), IWETH9(infra.usdc)
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
        // Native quotes only: stays closed on Arc.
        c.factory.setLaunchEnabled(false);
    }

    /// @dev The multi-market stack, the one the interface launches through.
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
            infra.usdc,
            false,
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
            IPoolManager(infra.poolManager), c.multiFactory, ISwapRouter02(infra.swapRouter02), IWETH9(infra.usdc)
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
        // Multi-market tokens may serve as quotes for later launches.
        c.pricer.addRegistry(c.multiRegistry);
    }

    /// @dev Fee routing: splitter as protocol recipient, the three creator-fee vaults, disperser.
    function _deployFees(Params memory p, Core memory c) internal {
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
