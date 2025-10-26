// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {Test, console2} from "forge-std/Test.sol";
import {CoFheUtils} from "./utils/CoFheUtils.sol";
import {TradeManager} from "../src/TradeManager.sol";
import {DynamicInE} from "../src/ITradeManager.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    FHE,
    InEuint64,
    InEuint256,
    InEaddress,
    InEuint32,
    InEuint16,
    InEuint128,
    euint64,
    euint256,
    euint32,
    euint16,
    eaddress
} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

contract TradeManagerTest is CoFheUtils {
    using ECDSA for bytes32;

    TradeManager public tradeManager;

    address public admin;
    address public operator1;
    address public operator2;
    address public trader1;
    address public trader2;
    uint32 public constant DESTINATION_CHAIN_ID = 42161;

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
        operator1 = vm.addr(2); // Private key = 2
        operator2 = vm.addr(3); // Private key = 3
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
        InEuint32 memory chainIdEnc = createInEuint32(DESTINATION_CHAIN_ID, trader1);
        vm.prank(trader1);
        tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs, chainIdEnc);

        // Verify submission
        assertTrue(tradeManager.hasSubmittedStrategy(1, trader1));
        assertEq(tradeManager.currentEpochNumber(), 1);
        uint256 chainIdHandle = tradeManager.getStrategyChainIdHandle(1, trader1);
        assertHashValue(chainIdHandle, DESTINATION_CHAIN_ID);
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

        InEuint32 memory chainIdEnc = createInEuint32(DESTINATION_CHAIN_ID, trader1);
        vm.expectRevert("No active epoch");
        vm.prank(trader1);
        tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs, chainIdEnc);
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

        InEuint32 memory chainIdEnc = createInEuint32(DESTINATION_CHAIN_ID, trader1);
        // Submit once
        vm.prank(trader1);
        tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs, chainIdEnc);

        // Try to submit again
        vm.expectRevert("Strategy already submitted");
        vm.prank(trader1);
        tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs, chainIdEnc);
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

        InEuint32 memory chainIdEnc = createInEuint32(DESTINATION_CHAIN_ID, trader1);
        vm.expectRevert("Strategy must have at least one node");
        vm.prank(trader1);
        tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs, chainIdEnc);
    }

    // ========================================= APY REPORTING TESTS =========================================

    function test_ReportEncryptedAPY() public {
        // Setup: Register operator and start epoch
        vm.prank(operator1);
        tradeManager.registerOperator();

        uint8[] memory weights = new uint8[](2);
        weights[0] = 60;
        weights[1] = 40;
        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        vm.startPrank(admin);
        tradeManager.startEpoch(encSimStart, encSimEnd, 1 days, weights, 100_000e6, 1_000_000e6);
        vm.stopPrank();

        // Submit a strategy
        InEaddress[] memory encoders = new InEaddress[](1);
        InEaddress[] memory targets = new InEaddress[](1);
        InEuint32[] memory selectors = new InEuint32[](1);
        DynamicInE[][] memory nodeArgs = new DynamicInE[][](1);

        encoders[0] = createInEaddress(makeAddr("encoder"), trader1);
        targets[0] = createInEaddress(makeAddr("target"), trader1);
        selectors[0] = createInEuint32(0x12345678, trader1);
        nodeArgs[0] = new DynamicInE[](0);

        InEuint32 memory chainIdEnc = createInEuint32(DESTINATION_CHAIN_ID, trader1);
        vm.prank(trader1);
        tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs, chainIdEnc);

        // Operator reports APY (e.g., 12.34% = 1234 basis points)
        InEuint16 memory encryptedAPY = createInEuint16(1234, operator1);

        vm.prank(operator1);
        tradeManager.reportEncryptedAPY(1, trader1, encryptedAPY);

        // Get the strategy's encrypted APY
        euint16 apy = tradeManager.getEncryptedAPY(1, trader1);

        // Verify trader has decrypt permission
        assertIsAllowed(apy, trader1, "Trader should have decrypt permission for their APY");

        // Verify the encrypted APY value matches what was reported (using mock storage)
        uint16 decryptedAPY = uint16(mockStorage(euint16.unwrap(apy)));
        assertEq(decryptedAPY, 1234, "Decrypted APY should match reported value");
    }

    function test_RevertWhen_ReportAPYNonOperator() public {
        // Setup epoch and strategy submission
        vm.prank(operator1);
        tradeManager.registerOperator();

        uint8[] memory weights = new uint8[](2);
        weights[0] = 60;
        weights[1] = 40;
        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        vm.startPrank(admin);
        tradeManager.startEpoch(encSimStart, encSimEnd, 1 days, weights, 100_000e6, 1_000_000e6);
        vm.stopPrank();

        InEaddress[] memory encoders = new InEaddress[](1);
        InEaddress[] memory targets = new InEaddress[](1);
        InEuint32[] memory selectors = new InEuint32[](1);
        DynamicInE[][] memory nodeArgs = new DynamicInE[][](1);
        encoders[0] = createInEaddress(makeAddr("encoder"), trader1);
        targets[0] = createInEaddress(makeAddr("target"), trader1);
        selectors[0] = createInEuint32(0x12345678, trader1);
        nodeArgs[0] = new DynamicInE[](0);

        InEuint32 memory chainIdEnc = createInEuint32(DESTINATION_CHAIN_ID, trader1);
        vm.prank(trader1);
        tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs, chainIdEnc);

        // Try to report APY as non-operator
        InEuint16 memory encryptedAPY = createInEuint16(1234, trader1);

        vm.expectRevert("Operator must be the caller");
        vm.prank(trader1);
        tradeManager.reportEncryptedAPY(1, trader1, encryptedAPY);
    }

    function test_RevertWhen_ReportAPYNoStrategy() public {
        // Setup epoch but no strategy submission
        vm.prank(operator1);
        tradeManager.registerOperator();

        uint8[] memory weights = new uint8[](2);
        weights[0] = 60;
        weights[1] = 40;
        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        vm.startPrank(admin);
        tradeManager.startEpoch(encSimStart, encSimEnd, 1 days, weights, 100_000e6, 1_000_000e6);
        vm.stopPrank();

        // Try to report APY without strategy submission
        InEuint16 memory encryptedAPY = createInEuint16(1234, operator1);

        vm.expectRevert("No strategy submitted");
        vm.prank(operator1);
        tradeManager.reportEncryptedAPY(1, trader1, encryptedAPY);
    }

    // ========================================= EPOCH CLOSING TESTS =========================================

    function test_CloseEpoch() public {
        // Setup: Register operator, start epoch, submit strategy, report APY
        vm.prank(operator1);
        tradeManager.registerOperator();

        uint8[] memory weights = new uint8[](2);
        weights[0] = 60;
        weights[1] = 40;
        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        vm.startPrank(admin);
        tradeManager.startEpoch(encSimStart, encSimEnd, 1 days, weights, 100_000e6, 1_000_000e6);
        vm.stopPrank();

        // Submit strategy
        InEaddress[] memory encoders = new InEaddress[](1);
        InEaddress[] memory targets = new InEaddress[](1);
        InEuint32[] memory selectors = new InEuint32[](1);
        DynamicInE[][] memory nodeArgs = new DynamicInE[][](1);

        encoders[0] = createInEaddress(makeAddr("encoder"), trader1);
        targets[0] = createInEaddress(makeAddr("target"), trader1);
        selectors[0] = createInEuint32(0x12345678, trader1);
        nodeArgs[0] = new DynamicInE[](0);

        InEuint32 memory chainIdEnc = createInEuint32(DESTINATION_CHAIN_ID, trader1);
        vm.prank(trader1);
        tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs, chainIdEnc);

        // Report APY
        InEuint16 memory encryptedAPY = createInEuint16(1234, operator1);
        vm.prank(operator1);
        tradeManager.reportEncryptedAPY(1, trader1, encryptedAPY);

        // Warp past epoch end time
        vm.warp(block.timestamp + 1 days + 1);

        // Close epoch (can be called by anyone)
        vm.prank(operator1);
        tradeManager.closeEpoch(1);

        // Verify epoch state is CLOSED
        TradeManager.EpochState state = tradeManager.getEpochState(1);
        assertEq(uint256(state), uint256(TradeManager.EpochState.CLOSED));
    }

    // function test_RevertWhen_CloseEpochTooEarly() public {
    //     // Setup epoch
    //     vm.prank(operator1);
    //     tradeManager.registerOperator();

    //     uint8[] memory weights = new uint8[](2);
    //     weights[0] = 60;
    //     weights[1] = 40;
    //     InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
    //     InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

    //     vm.startPrank(admin);
    //     tradeManager.startEpoch(encSimStart, encSimEnd, 1 days, weights, 100_000e6, 1_000_000e6);
    //     vm.stopPrank();

    //     // Try to close epoch before duration passes
    //     vm.expectRevert("Epoch duration not passed");
    //     tradeManager.closeEpoch(1);
    // }

    function test_GetDecryptedAPYs() public {
        // Setup: Register operator, start epoch, submit strategies, report APYs
        vm.prank(operator1);
        tradeManager.registerOperator();

        uint8[] memory weights = new uint8[](2);
        weights[0] = 60;
        weights[1] = 40;
        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        vm.startPrank(admin);
        tradeManager.startEpoch(encSimStart, encSimEnd, 1 days, weights, 100_000e6, 1_000_000e6);
        vm.stopPrank();

        // Submit strategies for two traders
        InEaddress[] memory encoders = new InEaddress[](1);
        InEaddress[] memory targets = new InEaddress[](1);
        InEuint32[] memory selectors = new InEuint32[](1);
        DynamicInE[][] memory nodeArgs = new DynamicInE[][](1);

        encoders[0] = createInEaddress(makeAddr("encoder"), trader1);
        targets[0] = createInEaddress(makeAddr("target"), trader1);
        selectors[0] = createInEuint32(0x12345678, trader1);
        nodeArgs[0] = new DynamicInE[](0);

        InEuint32 memory chainIdEnc1 = createInEuint32(DESTINATION_CHAIN_ID, trader1);
        vm.prank(trader1);
        tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs, chainIdEnc1);

        encoders[0] = createInEaddress(makeAddr("encoder2"), trader2);
        targets[0] = createInEaddress(makeAddr("target2"), trader2);
        selectors[0] = createInEuint32(0x87654321, trader2);

        InEuint32 memory chainIdEnc2 = createInEuint32(DESTINATION_CHAIN_ID, trader2);
        vm.prank(trader2);
        tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs, chainIdEnc2);

        // Report APYs
        InEuint16 memory apy1 = createInEuint16(1234, operator1);
        vm.prank(operator1);
        tradeManager.reportEncryptedAPY(1, trader1, apy1);

        InEuint16 memory apy2 = createInEuint16(5678, operator1);
        vm.prank(operator1);
        tradeManager.reportEncryptedAPY(1, trader2, apy2);

        // Close epoch
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(operator1);
        tradeManager.closeEpoch(1);

        // Wait for decryption to complete (mock requires time delay)
        vm.warp(block.timestamp + 11);

        // Get decrypted APYs
        (address[] memory traders, uint256[] memory decryptedAPYs, bool[] memory decrypted) =
            tradeManager.getDecryptedAPYs(1);

        assertEq(traders.length, 2);
        assertEq(traders[0], trader1);
        assertEq(traders[1], trader2);
        assertEq(decryptedAPYs[0], 1234);
        assertEq(decryptedAPYs[1], 5678);
        assertTrue(decrypted[0]);
        assertTrue(decrypted[1]);
    }

    function test_GetDecryptedSimTimes() public {
        // Setup epoch
        vm.prank(operator1);
        tradeManager.registerOperator();

        uint8[] memory weights = new uint8[](2);
        weights[0] = 60;
        weights[1] = 40;
        uint64 simStart = uint64(block.timestamp - 7 days);
        uint64 simEnd = uint64(block.timestamp - 1 days);
        InEuint64 memory encSimStart = createInEuint64(simStart, admin);
        InEuint64 memory encSimEnd = createInEuint64(simEnd, admin);

        vm.startPrank(admin);
        tradeManager.startEpoch(encSimStart, encSimEnd, 1 days, weights, 100_000e6, 1_000_000e6);
        vm.stopPrank();

        // Close epoch
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(operator1);
        tradeManager.closeEpoch(1);

        // Wait for decryption to complete (mock requires time delay)
        vm.warp(block.timestamp + 11);

        // Get decrypted sim times
        (uint256 decryptedStart, uint256 decryptedEnd, bool startDecrypted, bool endDecrypted) =
            tradeManager.getDecryptedSimTimes(1);

        assertEq(decryptedStart, simStart);
        assertEq(decryptedEnd, simEnd);
        assertTrue(startDecrypted);
        assertTrue(endDecrypted);
    }

    // ========================================= EPOCH FINALIZATION TESTS =========================================

    function test_FinalizeEpoch() public {
        // Setup: Full epoch flow
        vm.prank(operator1);
        tradeManager.registerOperator();

        uint8[] memory weights = new uint8[](2);
        weights[0] = 60;
        weights[1] = 40;
        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        vm.startPrank(admin);
        tradeManager.startEpoch(encSimStart, encSimEnd, 1 days, weights, 100_000e6, 1_000_000e6);
        vm.stopPrank();

        // Submit strategies
        InEaddress[] memory encoders = new InEaddress[](1);
        InEaddress[] memory targets = new InEaddress[](1);
        InEuint32[] memory selectors = new InEuint32[](1);
        DynamicInE[][] memory nodeArgs = new DynamicInE[][](1);

        encoders[0] = createInEaddress(makeAddr("encoder"), trader1);
        targets[0] = createInEaddress(makeAddr("target"), trader1);
        selectors[0] = createInEuint32(0x12345678, trader1);
        nodeArgs[0] = new DynamicInE[](0);

        InEuint32 memory chainIdEnc1 = createInEuint32(DESTINATION_CHAIN_ID, trader1);
        vm.prank(trader1);
        tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs, chainIdEnc1);

        encoders[0] = createInEaddress(makeAddr("encoder2"), trader2);
        targets[0] = createInEaddress(makeAddr("target2"), trader2);
        selectors[0] = createInEuint32(0x87654321, trader2);

        InEuint32 memory chainIdEnc2 = createInEuint32(DESTINATION_CHAIN_ID, trader2);
        vm.prank(trader2);
        tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs, chainIdEnc2);

        // Report APYs
        InEuint16 memory apy1 = createInEuint16(1234, operator1);
        vm.prank(operator1);
        tradeManager.reportEncryptedAPY(1, trader1, apy1);

        InEuint16 memory apy2 = createInEuint16(5678, operator1);
        vm.prank(operator1);
        tradeManager.reportEncryptedAPY(1, trader2, apy2);

        // Close epoch
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(operator1);
        tradeManager.closeEpoch(1);

        // Finalize epoch - operator reports winners (trader2 has higher APY)
        address[] memory winners = new address[](2);
        winners[0] = trader2; // 5678 APY
        winners[1] = trader1; // 1234 APY

        uint256[] memory decryptedAPYs = new uint256[](2);
        decryptedAPYs[0] = 5678;
        decryptedAPYs[1] = 1234;

        vm.prank(operator1);
        tradeManager.finalizeEpoch(1, winners, decryptedAPYs);

        // Verify epoch state is FINALIZED
        TradeManager.EpochState state = tradeManager.getEpochState(1);
        assertEq(uint256(state), uint256(TradeManager.EpochState.FINALIZED));

        // Verify winners
        (address winner1, uint256 apy1Final, uint256 allocation1) = tradeManager.epochWinners(1, 0);
        (address winner2, uint256 apy2Final, uint256 allocation2) = tradeManager.epochWinners(1, 1);

        assertEq(winner1, trader2);
        assertEq(apy1Final, 5678);
        assertEq(allocation1, 600_000e6); // 60% of 1M

        assertEq(winner2, trader1);
        assertEq(apy2Final, 1234);
        assertEq(allocation2, 400_000e6); // 40% of 1M
    }

    function test_RevertWhen_FinalizeEpochNotClosed() public {
        // Setup epoch
        vm.prank(operator1);
        tradeManager.registerOperator();

        uint8[] memory weights = new uint8[](2);
        weights[0] = 60;
        weights[1] = 40;
        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        vm.startPrank(admin);
        tradeManager.startEpoch(encSimStart, encSimEnd, 1 days, weights, 100_000e6, 1_000_000e6);
        vm.stopPrank();

        // Try to finalize without closing
        address[] memory winners = new address[](2);
        winners[0] = trader1;
        winners[1] = trader2;

        uint256[] memory decryptedAPYs = new uint256[](2);
        decryptedAPYs[0] = 1234;
        decryptedAPYs[1] = 5678;

        vm.expectRevert("Epoch not closed");
        vm.prank(operator1);
        tradeManager.finalizeEpoch(1, winners, decryptedAPYs);
    }

    // ========================================= EPOCH EXECUTION TESTS =========================================

    function test_ExecuteEpochTopStrategiesAggregated() public {
        // Setup: Full epoch flow up to finalization
        vm.prank(operator1);
        tradeManager.registerOperator();

        uint8[] memory weights = new uint8[](2);
        weights[0] = 60;
        weights[1] = 40;
        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        vm.startPrank(admin);
        tradeManager.startEpoch(encSimStart, encSimEnd, 1 days, weights, 100_000e6, 1_000_000e6);

        // Deploy and set BoringVault
        address mockVault = address(new MockBoringVault());
        tradeManager.setBoringVault(payable(mockVault));
        vm.stopPrank();

        // Submit strategies
        InEaddress[] memory encoders = new InEaddress[](1);
        InEaddress[] memory targets = new InEaddress[](1);
        InEuint32[] memory selectors = new InEuint32[](1);
        DynamicInE[][] memory nodeArgs = new DynamicInE[][](1);

        encoders[0] = createInEaddress(makeAddr("encoder"), trader1);
        targets[0] = createInEaddress(makeAddr("target"), trader1);
        selectors[0] = createInEuint32(0x12345678, trader1);
        nodeArgs[0] = new DynamicInE[](0);

        InEuint32 memory chainIdEnc1 = createInEuint32(DESTINATION_CHAIN_ID, trader1);
        vm.prank(trader1);
        tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs, chainIdEnc1);

        encoders[0] = createInEaddress(makeAddr("encoder2"), trader2);
        targets[0] = createInEaddress(makeAddr("target2"), trader2);
        selectors[0] = createInEuint32(0x87654321, trader2);

        InEuint32 memory chainIdEnc2 = createInEuint32(DESTINATION_CHAIN_ID, trader2);
        vm.prank(trader2);
        tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs, chainIdEnc2);

        // Report APYs
        InEuint16 memory apy1 = createInEuint16(1234, operator1);
        vm.prank(operator1);
        tradeManager.reportEncryptedAPY(1, trader1, apy1);

        InEuint16 memory apy2 = createInEuint16(5678, operator1);
        vm.prank(operator1);
        tradeManager.reportEncryptedAPY(1, trader2, apy2);

        // Close and finalize epoch
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(operator1);
        tradeManager.closeEpoch(1);

        vm.warp(block.timestamp + 11);

        address[] memory winners = new address[](2);
        winners[0] = trader2;
        winners[1] = trader1;

        uint256[] memory decryptedAPYs = new uint256[](2);
        decryptedAPYs[0] = 5678;
        decryptedAPYs[1] = 1234;

        vm.prank(operator1);
        tradeManager.finalizeEpoch(1, winners, decryptedAPYs);

        // Execute aggregated strategies
        address[] memory execEncoders = new address[](2);
        execEncoders[0] = makeAddr("encoder");
        execEncoders[1] = makeAddr("encoder2");

        address[] memory execTargets = new address[](2);
        execTargets[0] = makeAddr("target");
        execTargets[1] = makeAddr("target2");

        bytes[] memory execCalldatas = new bytes[](2);
        execCalldatas[0] = abi.encodeWithSelector(bytes4(0x12345678));
        execCalldatas[1] = abi.encodeWithSelector(bytes4(0x87654321));

        // Create operator signature
        bytes[] memory signatures = new bytes[](1);
        bytes32 messageHash = keccak256(abi.encode(1, execEncoders, execTargets, execCalldatas));
        bytes32 ethSigned = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));

        // Sign with operator1's private key (2)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(2, ethSigned);
        signatures[0] = abi.encodePacked(r, s, v);

        vm.prank(operator1);
        tradeManager.executeEpochTopStrategiesAggregated(1, execEncoders, execTargets, execCalldatas, signatures);

        // Verify epoch state is EXECUTED
        TradeManager.EpochState state = tradeManager.getEpochState(1);
        assertEq(uint256(state), uint256(TradeManager.EpochState.EXECUTED));
    }

    function test_RevertWhen_ExecuteEpochNotFinalized() public {
        // Setup epoch but don't finalize
        vm.prank(operator1);
        tradeManager.registerOperator();

        uint8[] memory weights = new uint8[](2);
        weights[0] = 60;
        weights[1] = 40;
        InEuint64 memory encSimStart = createInEuint64(uint64(block.timestamp - 7 days), admin);
        InEuint64 memory encSimEnd = createInEuint64(uint64(block.timestamp - 1 days), admin);

        vm.startPrank(admin);
        tradeManager.startEpoch(encSimStart, encSimEnd, 1 days, weights, 100_000e6, 1_000_000e6);
        vm.stopPrank();

        // Try to execute without finalizing
        address[] memory execEncoders = new address[](1);
        execEncoders[0] = makeAddr("encoder");

        address[] memory execTargets = new address[](1);
        execTargets[0] = makeAddr("target");

        bytes[] memory execCalldatas = new bytes[](1);
        execCalldatas[0] = abi.encodeWithSelector(bytes4(0x12345678));

        bytes[] memory signatures = new bytes[](0);

        vm.expectRevert("Epoch not finalized");
        vm.prank(operator1);
        tradeManager.executeEpochTopStrategiesAggregated(1, execEncoders, execTargets, execCalldatas, signatures);
    }
}

// Mock BoringVault for testing
contract MockBoringVault {
    function execute(address target, bytes calldata data, uint256 value) external returns (bytes memory) {
        // Mock successful execution
        return "";
    }
}
