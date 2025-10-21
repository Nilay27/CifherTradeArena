// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {Test, console2} from "forge-std/Test.sol";
import {CoFheUtils} from "./utils/CoFheUtils.sol";
import {TradeManager} from "../src/TradeManager.sol";
import {DynamicInE} from "../src/ITradeManager.sol";
import {
    FHE,
    InEuint64,
    InEuint256,
    InEaddress,
    InEuint32,
    euint64,
    euint256,
    euint32,
    eaddress
} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

contract TradeManagerTest is CoFheUtils {
    TradeManager public tradeManager;

    address public admin;
    address public operator1;
    address public operator2;
    address public trader1;
    address public trader2;

    // Mock addresses for EigenLayer contracts
    address public avsDirectory;
    address public stakeRegistry;
    address public rewardsCoordinator;
    address public delegationManager;
    address public allocationManager;

    function setUp() public {
        // Warp to a reasonable timestamp to avoid underflow in tests
        vm.warp(30 days);

        // Setup test accounts
        admin = makeAddr("admin");
        operator1 = makeAddr("operator1");
        operator2 = makeAddr("operator2");
        trader1 = makeAddr("trader1");
        trader2 = makeAddr("trader2");

        // Setup mock EigenLayer contracts
        avsDirectory = makeAddr("avsDirectory");
        stakeRegistry = makeAddr("stakeRegistry");
        rewardsCoordinator = makeAddr("rewardsCoordinator");
        delegationManager = makeAddr("delegationManager");
        allocationManager = makeAddr("allocationManager");

        // Deploy TradeManager
        vm.prank(admin);
        tradeManager = new TradeManager(
            avsDirectory,
            stakeRegistry,
            rewardsCoordinator,
            delegationManager,
            allocationManager,
            admin
        );
    }

    // ========================================= OPERATOR TESTS =========================================

    function test_RegisterOperator() public {
        vm.prank(operator1);
        tradeManager.registerOperator();

        assertTrue(tradeManager.isOperatorRegistered(operator1));
        assertEq(tradeManager.getOperatorCount(), 1);
    }

    function test_RegisterMultipleOperators() public {
        vm.prank(operator1);
        tradeManager.registerOperator();

        vm.prank(operator2);
        tradeManager.registerOperator();

        assertTrue(tradeManager.isOperatorRegistered(operator1));
        assertTrue(tradeManager.isOperatorRegistered(operator2));
        assertEq(tradeManager.getOperatorCount(), 2);
    }

    function test_RevertWhen_RegisterOperatorTwice() public {
        vm.startPrank(operator1);
        tradeManager.registerOperator();

        vm.expectRevert("Operator already registered");
        tradeManager.registerOperator();
        vm.stopPrank();
    }

    // ========================================= EPOCH LIFECYCLE TESTS =========================================

    function test_StartEpoch() public {
        // Register operator first
        vm.prank(operator1);
        tradeManager.registerOperator();

        // Prepare epoch parameters
        uint64 epochDuration = 1 days;
        uint8[] memory weights = new uint8[](3);
        weights[0] = 50; // 50%
        weights[1] = 30; // 30%
        weights[2] = 20; // 20%
        uint256 notionalPerTrader = 100_000e6; // 100k USDC (6 decimals)
        uint256 allocatedCapital = 1_000_000e6; // 1M USDC

        // Create encrypted simulation times using CoFHE
        uint64 simStart = uint64(block.timestamp - 7 days);
        uint64 simEnd = uint64(block.timestamp - 1 days);

        InEuint64 memory encSimStart = createInEuint64(simStart, admin);
        InEuint64 memory encSimEnd = createInEuint64(simEnd, admin);

        // Start epoch as admin
        vm.prank(admin);
        tradeManager.startEpoch(
            encSimStart,
            encSimEnd,
            epochDuration,
            weights,
            notionalPerTrader,
            allocatedCapital
        );

        // Verify epoch was created
        assertEq(tradeManager.currentEpochNumber(), 1);
    }

    function test_RevertWhen_StartEpochWithInvalidWeights() public {
        uint64 epochDuration = 1 days;
        uint8[] memory weights = new uint8[](3);
        weights[0] = 50;
        weights[1] = 30;
        weights[2] = 10; // Sum = 90, not 100

        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        vm.expectRevert("Weights must sum to 100");
        vm.prank(admin);
        tradeManager.startEpoch(
            encSimStart,
            encSimEnd,
            epochDuration,
            weights,
            100_000e6,
            1_000_000e6
        );
    }

    function test_RevertWhen_NonAdminStartsEpoch() public {
        uint64 epochDuration = 1 days;
        uint8[] memory weights = new uint8[](3);
        weights[0] = 50;
        weights[1] = 30;
        weights[2] = 20;

        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        // Try to start epoch as non-admin
        vm.expectRevert("Only admin can call this function");
        vm.prank(trader1);
        tradeManager.startEpoch(
            encSimStart,
            encSimEnd,
            epochDuration,
            weights,
            100_000e6,
            1_000_000e6
        );
    }

    function test_StartMultipleEpochs() public {
        // Register operator first
        vm.prank(operator1);
        tradeManager.registerOperator();

        uint64 epochDuration = 1 days;
        uint8[] memory weights = new uint8[](2);
        weights[0] = 60;
        weights[1] = 40;

        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        vm.startPrank(admin);

        // Start epoch 1
        tradeManager.startEpoch(
            encSimStart,
            encSimEnd,
            epochDuration,
            weights,
            100_000e6,
            1_000_000e6
        );
        assertEq(tradeManager.currentEpochNumber(), 1);

        // Advance time
        vm.warp(block.timestamp + epochDuration + 1);

        // Start epoch 2
        tradeManager.startEpoch(
            encSimStart,
            encSimEnd,
            epochDuration,
            weights,
            100_000e6,
            1_000_000e6
        );
        assertEq(tradeManager.currentEpochNumber(), 2);

        vm.stopPrank();
    }

    function test_RevertWhen_StartEpochWithZeroDuration() public {
        uint8[] memory weights = new uint8[](2);
        weights[0] = 50;
        weights[1] = 50;

        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        vm.expectRevert("Duration must be positive");
        vm.prank(admin);
        tradeManager.startEpoch(
            encSimStart,
            encSimEnd,
            0, // Zero duration
            weights,
            100_000e6,
            1_000_000e6
        );
    }

    function test_RevertWhen_StartEpochWithZeroNotional() public {
        uint8[] memory weights = new uint8[](2);
        weights[0] = 50;
        weights[1] = 50;

        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        vm.expectRevert("Notional must be positive");
        vm.prank(admin);
        tradeManager.startEpoch(
            encSimStart,
            encSimEnd,
            1 days,
            weights,
            0, // Zero notional
            1_000_000e6
        );
    }

    function test_RevertWhen_StartEpochWithZeroAllocatedCapital() public {
        uint8[] memory weights = new uint8[](2);
        weights[0] = 50;
        weights[1] = 50;

        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        vm.expectRevert("Allocated capital must be positive");
        vm.prank(admin);
        tradeManager.startEpoch(
            encSimStart,
            encSimEnd,
            1 days,
            weights,
            100_000e6,
            0 // Zero allocated capital
        );
    }

    function test_RevertWhen_StartEpochWithNoOperators() public {
        // Try to start epoch without any operators registered
        uint8[] memory weights = new uint8[](2);
        weights[0] = 50;
        weights[1] = 50;

        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        vm.expectRevert("No operators registered");
        vm.prank(admin);
        tradeManager.startEpoch(
            encSimStart,
            encSimEnd,
            1 days,
            weights,
            100_000e6,
            1_000_000e6
        );
    }

    function test_EpochEvent() public {
        // Register operator first
        vm.prank(operator1);
        tradeManager.registerOperator();

        uint64 epochDuration = 1 days;
        uint8[] memory weights = new uint8[](2);
        weights[0] = 60;
        weights[1] = 40;

        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        // Expect EpochStarted event
        vm.expectEmit(true, false, false, false);
        emit TradeManager.EpochStarted(
            1,
            uint64(block.timestamp),
            uint64(block.timestamp + epochDuration),
            weights,
            100_000e6,
            1_000_000e6
        );

        vm.prank(admin);
        tradeManager.startEpoch(
            encSimStart,
            encSimEnd,
            epochDuration,
            weights,
            100_000e6,
            1_000_000e6
        );
    }

    // ========================================= STRATEGY SUBMISSION TESTS =========================================

    function test_SubmitEncryptedStrategy() public {
        // Register operator first
        vm.prank(operator1);
        tradeManager.registerOperator();

        // Start an epoch
        uint64 epochDuration = 1 days;
        uint8[] memory weights = new uint8[](2);
        weights[0] = 60;
        weights[1] = 40;

        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        vm.prank(admin);
        tradeManager.startEpoch(
            encSimStart,
            encSimEnd,
            epochDuration,
            weights,
            100_000e6,
            1_000_000e6
        );

        // Create a simple strategy with 2 nodes
        InEaddress[] memory encoders = new InEaddress[](2);
        InEaddress[] memory targets = new InEaddress[](2);
        InEuint32[] memory selectors = new InEuint32[](2);
        DynamicInE[][] memory nodeArgs = new DynamicInE[][](2);

        // Node 1: deposit to Aave
        encoders[0] = createInEaddress(makeAddr("aaveEncoder"), trader1);
        targets[0] = createInEaddress(makeAddr("aavePool"), trader1);
        selectors[0] = createInEuint32(0x12345678, trader1);

        // Node 1 args: [token, amount]
        nodeArgs[0] = new DynamicInE[](2);
        nodeArgs[0][0] = DynamicInE({
            ctHash: uint256(keccak256("usdc")),
            securityZone: 0,
            utype: 7, // eaddress
            signature: ""
        });
        nodeArgs[0][1] = DynamicInE({
            ctHash: uint256(keccak256("1000e6")),
            securityZone: 0,
            utype: 6, // euint128 (not euint256 - deprecated!)
            signature: ""
        });

        // Node 2: swap on Uniswap
        encoders[1] = createInEaddress(makeAddr("uniEncoder"), trader1);
        targets[1] = createInEaddress(makeAddr("uniRouter"), trader1);
        selectors[1] = createInEuint32(0x87654321, trader1);

        // Node 2 args: [tokenIn, tokenOut, amountIn]
        nodeArgs[1] = new DynamicInE[](3);
        nodeArgs[1][0] = DynamicInE({
            ctHash: uint256(keccak256("usdc")),
            securityZone: 0,
            utype: 7, // eaddress
            signature: ""
        });
        nodeArgs[1][1] = DynamicInE({
            ctHash: uint256(keccak256("weth")),
            securityZone: 0,
            utype: 7, // eaddress
            signature: ""
        });
        nodeArgs[1][2] = DynamicInE({
            ctHash: uint256(keccak256("500e6")),
            securityZone: 0,
            utype: 6, // euint128 (not euint256 - deprecated!)
            signature: ""
        });

        // Submit strategy as trader1
        vm.prank(trader1);
        tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs);

        // Verify submission
        assertTrue(tradeManager.hasSubmittedStrategy(1, trader1));
        assertEq(tradeManager.currentEpochNumber(), 1);
    }

    function test_RevertWhen_SubmitStrategyNoEpoch() public {
        // Try to submit without starting an epoch
        InEaddress[] memory encoders = new InEaddress[](1);
        InEaddress[] memory targets = new InEaddress[](1);
        InEuint32[] memory selectors = new InEuint32[](1);
        DynamicInE[][] memory nodeArgs = new DynamicInE[][](1);

        encoders[0] = createInEaddress(makeAddr("encoder"), trader1);
        targets[0] = createInEaddress(makeAddr("target"), trader1);
        selectors[0] = createInEuint32(0x12345678, trader1);
        nodeArgs[0] = new DynamicInE[](0);

        vm.expectRevert("No active epoch");
        vm.prank(trader1);
        tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs);
    }

    function test_RevertWhen_SubmitStrategyTwice() public {
        // Register operator first
        vm.prank(operator1);
        tradeManager.registerOperator();

        // Start epoch
        uint8[] memory weights = new uint8[](2);
        weights[0] = 60;
        weights[1] = 40;

        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        vm.prank(admin);
        tradeManager.startEpoch(encSimStart, encSimEnd, 1 days, weights, 100_000e6, 1_000_000e6);

        // Create simple strategy
        InEaddress[] memory encoders = new InEaddress[](1);
        InEaddress[] memory targets = new InEaddress[](1);
        InEuint32[] memory selectors = new InEuint32[](1);
        DynamicInE[][] memory nodeArgs = new DynamicInE[][](1);

        encoders[0] = createInEaddress(makeAddr("encoder"), trader1);
        targets[0] = createInEaddress(makeAddr("target"), trader1);
        selectors[0] = createInEuint32(0x12345678, trader1);
        nodeArgs[0] = new DynamicInE[](0);

        // Submit once
        vm.prank(trader1);
        tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs);

        // Try to submit again
        vm.expectRevert("Strategy already submitted");
        vm.prank(trader1);
        tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs);
    }

    function test_RevertWhen_SubmitEmptyStrategy() public {
        // Register operator first
        vm.prank(operator1);
        tradeManager.registerOperator();

        // Start epoch
        uint8[] memory weights = new uint8[](2);
        weights[0] = 60;
        weights[1] = 40;

        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        vm.prank(admin);
        tradeManager.startEpoch(encSimStart, encSimEnd, 1 days, weights, 100_000e6, 1_000_000e6);

        // Create empty strategy
        InEaddress[] memory encoders = new InEaddress[](0);
        InEaddress[] memory targets = new InEaddress[](0);
        InEuint32[] memory selectors = new InEuint32[](0);
        DynamicInE[][] memory nodeArgs = new DynamicInE[][](0);

        vm.expectRevert("Strategy must have at least one node");
        vm.prank(trader1);
        tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs);
    }
}
