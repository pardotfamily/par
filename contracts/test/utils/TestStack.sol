// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {PairPadFeeEscrow} from "../../src/v2/PairPadFeeEscrow.sol";
import {PairPadQuotePricer, IUniswapV3FactoryMinimal} from "../../src/v2/PairPadQuotePricer.sol";
import {PairPadLaunchLocker} from "../../src/v2/PairPadLaunchLocker.sol";
import {PairPadLaunchFactory} from "../../src/v2/PairPadLaunchFactory.sol";
import {PairPadPositionMinter} from "../../src/v2/PairPadPositionMinter.sol";
import {PairPadLaunchDeployer} from "../../src/v2/PairPadLaunchDeployer.sol";
import {IPairPadFeeEscrow} from "../../src/v2/interfaces/ILaunchpadV2.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Factory} from "../mocks/MockUniswapV3.sol";

contract MockPoolManager {
    // Only its address identity matters to the unit tests.
    function noop() external pure {}
}

contract MockPositionManager {
    address private immutable _poolManager;

    constructor(address poolManager_) {
        _poolManager = poolManager_;
    }

    function poolManager() external view returns (address) {
        return _poolManager;
    }

    function nextTokenId() external pure returns (uint256) {
        return 1;
    }
}

/**
 * @dev Deploys the whole PairPad stack against mocked Uniswap infrastructure
 * for unit tests of configuration and admin paths. Launches themselves need
 * a real PoolManager and PositionManager and are covered by the fork tests.
 */
contract TestStack {
    PairPadFeeEscrow public feeEscrow;
    PairPadQuotePricer public quotePricer;
    PairPadLaunchLocker public locker;
    PairPadLaunchFactory public factory;
    PairPadPositionMinter public minter;
    PairPadLaunchDeployer public launchDeployer;

    MockV3Factory public v3Factory;
    MockERC20 public weth;
    MockERC20 public usdg;
    MockPoolManager public poolManager;
    MockPositionManager public positionManager;

    address public constant PERMIT2 = address(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    constructor(address owner) {
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        v3Factory = new MockV3Factory();
        poolManager = new MockPoolManager();
        positionManager = new MockPositionManager(address(poolManager));

        feeEscrow = new PairPadFeeEscrow();
        quotePricer = new PairPadQuotePricer(
            owner,
            IUniswapV3FactoryMinimal(address(v3Factory)),
            address(weth),
            address(usdg),
            IPoolManager(address(poolManager))
        );
        locker = new PairPadLaunchLocker(
            address(this), IPositionManager(address(positionManager)), IPairPadFeeEscrow(address(feeEscrow))
        );

        factory = new PairPadLaunchFactory(
            owner,
            IPoolManager(address(poolManager)),
            IPositionManager(address(positionManager)),
            locker,
            IPairPadFeeEscrow(address(feeEscrow)),
            quotePricer,
            owner,
            0 // launch fee; tests that need one set it via the factory owner
        );

        minter = new PairPadPositionMinter(
            IPositionManager(address(positionManager)), IAllowanceTransfer(PERMIT2), locker, address(factory)
        );
        launchDeployer = new PairPadLaunchDeployer(address(factory));

        locker.setFactory(address(factory));
    }
}
