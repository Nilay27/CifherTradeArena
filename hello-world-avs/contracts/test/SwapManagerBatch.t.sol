// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import {Test} from "forge-std/Test.sol";
import {CoFheTest} from "@fhenixprotocol/cofhe-mock-contracts/CoFheTest.sol";
import {FHE, InEaddress, InEuint32, InEuint128, euint128, euint256} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {SwapManager, InternalTransferInput, IUniversalPrivacyHook} from "../src/SwapManager.sol";
import {ISwapManager, DynamicInE} from "../src/ISwapManager.sol";
import {MockPrivacyHook} from "../src/MockPrivacyHook.sol";

contract SwapManagerBatchTest is Test, CoFheTest {
    SwapManager public swapManager;
    MockPrivacyHook public mockHook;

    address owner = address(0x1);
    address operator1 = vm.addr(2);
    address operator2 = vm.addr(3);
    address operator3 = vm.addr(4);
    address user1 = address(0x5);
    address tokenA = address(0x10);
    address tokenB = address(0x11);

    function setUp() public {
        // Note: Constructor sets admin, no need for initialize() in tests
        swapManager = new SwapManager(
            address(0x100), // avsDirectory
            address(0x101), // stakeRegistry
            address(0x102), // rewardsCoordinator
            address(0x103), // delegationManager
            address(0x104), // allocationManager
            100, // maxResponseIntervalBlocks
            owner // admin
        );

        // Deploy MockPrivacyHook
        mockHook = new MockPrivacyHook(address(swapManager));

        // Authorize the hook
        vm.prank(owner);
        swapManager.authorizeHook(address(mockHook));

        // Register operators
        vm.prank(operator1);
        swapManager.registerOperatorForBatches();

        vm.prank(operator2);
        swapManager.registerOperatorForBatches();

        vm.prank(operator3);
        swapManager.registerOperatorForBatches();
    }

    // Helper function to create FHE encrypted value and grant SwapManager permission
    function createEncryptedForSwapManager(uint128 value) internal returns (euint128) {
        euint128 encrypted = FHE.asEuint128(value);
        FHE.allow(encrypted, address(swapManager));
        return encrypted;
    }

    function testBatchFinalization() public {
        // Create batch data matching UniversalPrivacyHook format
        bytes32[] memory intentIds = new bytes32[](2);
        intentIds[0] = keccak256("intent1");
        intentIds[1] = keccak256("intent2");

        bytes32 batchId = keccak256("batch1");
        bytes32 poolId = keccak256("pool1");

        // Create encrypted intent data with proper FHE handles
        // Use helper to create euint128 and grant SwapManager permission (mimics Hook behavior)
        euint128 enc1000 = createEncryptedForSwapManager(1000);
        euint128 enc500 = createEncryptedForSwapManager(500);

        bytes[] memory encryptedIntents = new bytes[](2);
        encryptedIntents[0] = abi.encode(
            intentIds[0],
            user1,
            tokenA,
            tokenB,
            euint128.unwrap(enc1000), // Pass the FHE handle
            uint256(block.timestamp + 1 hours)
        );
        encryptedIntents[1] = abi.encode(
            intentIds[1],
            user1,
            tokenB,
            tokenA,
            euint128.unwrap(enc500), // Pass the FHE handle
            uint256(block.timestamp + 1 hours)
        );

        bytes memory batchData = abi.encode(
            batchId,
            intentIds,
            poolId,
            address(mockHook),
            encryptedIntents
        );

        // Finalize batch
        vm.prank(address(mockHook));
        swapManager.finalizeBatch(batchId, batchData);

        // Check batch status
        ISwapManager.Batch memory batch = swapManager.getBatch(batchId);
        assertEq(uint(batch.status), uint(ISwapManager.BatchStatus.Processing));
        assertEq(batch.intentIds.length, 2);
        assertEq(batch.hook, address(mockHook));
        assertEq(batch.poolId, poolId);
    }

    function testBatchFinalizationRevertsIfNotAuthorizedHook() public {
        bytes32 batchId = keccak256("batch1");
        bytes memory batchData = "";

        // Try to finalize from unauthorized address
        vm.prank(address(0x999));
        vm.expectRevert("Unauthorized hook");
        swapManager.finalizeBatch(batchId, batchData);
    }

    function testBatchFinalizationRevertsIfInvalidStatus() public {
        // First finalize a batch
        bytes32 batchId = keccak256("batch1");
        bytes32[] memory intentIds = new bytes32[](1);
        intentIds[0] = keccak256("intent1");
        bytes32 poolId = keccak256("pool1");

        // Create proper FHE handle
        euint128 enc1000 = createEncryptedForSwapManager(1000);

        bytes[] memory encryptedIntents = new bytes[](1);
        encryptedIntents[0] = abi.encode(
            intentIds[0],
            user1,
            tokenA,
            tokenB,
            euint128.unwrap(enc1000),
            uint256(block.timestamp + 1 hours)
        );

        bytes memory batchData = abi.encode(
            batchId,
            intentIds,
            poolId,
            address(mockHook),
            encryptedIntents
        );

        vm.prank(address(mockHook));
        swapManager.finalizeBatch(batchId, batchData);

        // Try to finalize again - should revert
        vm.prank(address(mockHook));
        vm.expectRevert("Invalid batch status");
        swapManager.finalizeBatch(batchId, batchData);
    }

    function testOperatorRegistration() public {
        address newOperator = address(0x99);

        assertFalse(swapManager.isOperatorRegistered(newOperator));

        vm.prank(newOperator);
        swapManager.registerOperatorForBatches();

        assertTrue(swapManager.isOperatorRegistered(newOperator));
    }

    function testGetOperatorCount() public {
        // Already registered 3 operators in setUp
        assertEq(swapManager.getOperatorCount(), 3);

        // Register one more
        address newOperator = address(0x99);
        vm.prank(newOperator);
        swapManager.registerOperatorForBatches();

        assertEq(swapManager.getOperatorCount(), 4);
    }

    function testOperatorSelectionForBatch() public {
        // Create and finalize a batch
        bytes32 batchId = keccak256("batch1");
        bytes32[] memory intentIds = new bytes32[](1);
        intentIds[0] = keccak256("intent1");
        bytes32 poolId = keccak256("pool1");

        // Create proper FHE handle
        euint128 enc1000 = createEncryptedForSwapManager(1000);

        bytes[] memory encryptedIntents = new bytes[](1);
        encryptedIntents[0] = abi.encode(
            intentIds[0],
            user1,
            tokenA,
            tokenB,
            euint128.unwrap(enc1000),
            uint256(block.timestamp + 1 hours)
        );

        bytes memory batchData = abi.encode(
            batchId,
            intentIds,
            poolId,
            address(mockHook),
            encryptedIntents
        );

        vm.prank(address(mockHook));
        swapManager.finalizeBatch(batchId, batchData);

        // Check that an operator was selected
        // With 3 operators registered, at least one should be selected
        bool hasSelectedOperator = swapManager.isOperatorSelectedForBatch(batchId, operator1) ||
                                   swapManager.isOperatorSelectedForBatch(batchId, operator2) ||
                                   swapManager.isOperatorSelectedForBatch(batchId, operator3);

        assertTrue(hasSelectedOperator, "No operator was selected for batch");
    }

    function testHookAuthorization() public {
        address newHook = address(0x200);

        // Authorize new hook
        vm.prank(owner);
        swapManager.authorizeHook(newHook);

        // Should be able to finalize batch
        bytes32 batchId = keccak256("batch1");
        bytes32[] memory intentIds = new bytes32[](1);
        intentIds[0] = keccak256("intent1");
        bytes32 poolId = keccak256("pool1");

        // Create proper FHE handle
        euint128 enc1000 = createEncryptedForSwapManager(1000);

        bytes[] memory encryptedIntents = new bytes[](1);
        encryptedIntents[0] = abi.encode(
            intentIds[0],
            user1,
            tokenA,
            tokenB,
            euint128.unwrap(enc1000),
            uint256(block.timestamp + 1 hours)
        );

        bytes memory batchData = abi.encode(
            batchId,
            intentIds,
            poolId,
            newHook,
            encryptedIntents
        );

        vm.prank(newHook);
        swapManager.finalizeBatch(batchId, batchData);

        // Should succeed
        ISwapManager.Batch memory batch = swapManager.getBatch(batchId);
        assertEq(batch.hook, newHook);
    }

    function testHookRevocation() public {
        // Revoke mockHook
        vm.prank(owner);
        swapManager.revokeHook(address(mockHook));

        // Should not be able to finalize batch
        bytes32 batchId = keccak256("batch1");
        bytes memory batchData = "";

        vm.prank(address(mockHook));
        vm.expectRevert("Unauthorized hook");
        swapManager.finalizeBatch(batchId, batchData);
    }

    function testBatchIdMismatch() public {
        bytes32 batchId = keccak256("batch1");
        bytes32 wrongBatchId = keccak256("batch2");
        bytes32[] memory intentIds = new bytes32[](1);
        intentIds[0] = keccak256("intent1");
        bytes32 poolId = keccak256("pool1");

        // Create proper FHE handle
        euint128 enc1000 = createEncryptedForSwapManager(1000);

        bytes[] memory encryptedIntents = new bytes[](1);
        encryptedIntents[0] = abi.encode(
            intentIds[0],
            user1,
            tokenA,
            tokenB,
            euint128.unwrap(enc1000),
            uint256(block.timestamp + 1 hours)
        );

        // Encode with wrong batch ID
        bytes memory batchData = abi.encode(
            wrongBatchId,  // Wrong ID
            intentIds,
            poolId,
            address(mockHook),
            encryptedIntents
        );

        vm.prank(address(mockHook));
        vm.expectRevert("Batch ID mismatch");
        swapManager.finalizeBatch(batchId, batchData);
    }

    function testHookAddressMismatch() public {
        bytes32 batchId = keccak256("batch1");
        bytes32[] memory intentIds = new bytes32[](1);
        intentIds[0] = keccak256("intent1");
        bytes32 poolId = keccak256("pool1");

        // Create proper FHE handle
        euint128 enc1000 = createEncryptedForSwapManager(1000);

        bytes[] memory encryptedIntents = new bytes[](1);
        encryptedIntents[0] = abi.encode(
            intentIds[0],
            user1,
            tokenA,
            tokenB,
            euint128.unwrap(enc1000),
            uint256(block.timestamp + 1 hours)
        );

        // Encode with wrong hook address
        bytes memory batchData = abi.encode(
            batchId,
            intentIds,
            poolId,
            address(0x999),  // Wrong hook address
            encryptedIntents
        );

        vm.prank(address(mockHook));
        vm.expectRevert("Hook address mismatch");
        swapManager.finalizeBatch(batchId, batchData);
    }

    // ========== submitBatchSettlement Tests ==========

    function testSubmitBatchSettlement() public {
        // Setup: Create and finalize a batch
        bytes32 batchId = keccak256("batch1");
        bytes32[] memory intentIds = new bytes32[](2);
        intentIds[0] = keccak256("intent1");
        intentIds[1] = keccak256("intent2");
        bytes32 poolId = keccak256("pool1");

        // Create proper FHE handles
        euint128 enc1000 = createEncryptedForSwapManager(1000);
        euint128 enc500 = createEncryptedForSwapManager(500);

        bytes[] memory encryptedIntents = new bytes[](2);
        encryptedIntents[0] = abi.encode(
            intentIds[0],
            user1,
            tokenA,
            tokenB,
            euint128.unwrap(enc1000),
            uint256(block.timestamp + 1 hours)
        );
        encryptedIntents[1] = abi.encode(
            intentIds[1],
            user1,
            tokenB,
            tokenA,
            euint128.unwrap(enc500),
            uint256(block.timestamp + 1 hours)
        );

        bytes memory batchData = abi.encode(
            batchId,
            intentIds,
            poolId,
            address(mockHook),
            encryptedIntents
        );

        // Finalize batch as hook
        vm.prank(address(mockHook));
        swapManager.finalizeBatch(batchId, batchData);

        // Get selected operator
        address selectedOp = operator1;
        if (!swapManager.isOperatorSelectedForBatch(batchId, operator1)) {
            selectedOp = operator2;
        }
        if (!swapManager.isOperatorSelectedForBatch(batchId, selectedOp)) {
            selectedOp = operator3;
        }
        assertTrue(swapManager.isOperatorSelectedForBatch(batchId, selectedOp), "No operator selected");

        // Find operator private key
        uint256 operatorPk = selectedOp == operator1 ? 2 : (selectedOp == operator2 ? 3 : 4);

        // Prepare settlement data with InternalTransferInput
        InternalTransferInput[] memory internalTransfers = new InternalTransferInput[](2);
        internalTransfers[0] = InternalTransferInput({
            to: user1,
            encToken: tokenA,
            encAmount: createInEuint128(150e6, selectedOp)
        });
        internalTransfers[1] = InternalTransferInput({
            to: user1,
            encToken: tokenB,
            encAmount: createInEuint128(150e6, selectedOp)
        });

        // Prepare user shares
        IUniversalPrivacyHook.UserShare[] memory userShares = new IUniversalPrivacyHook.UserShare[](1);
        userShares[0] = IUniversalPrivacyHook.UserShare({
            user: user1,
            shareNumerator: 1,
            shareDenominator: 1
        });

        // Create operator signature
        bytes32 messageHash = keccak256(abi.encodePacked(
            batchId,
            uint128(50e6),  // netAmountIn
            tokenA,         // tokenIn
            tokenB,         // tokenOut
            tokenB          // outputToken
        ));
        bytes32 ethSigned = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, ethSigned);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r, s, v);

        // Submit settlement as operator
        vm.startPrank(selectedOp);
        swapManager.submitBatchSettlement(
            batchId,
            internalTransfers,
            50e6,           // netAmountIn
            tokenA,         // tokenIn
            tokenB,         // tokenOut
            tokenB,         // outputToken
            userShares,
            signatures
        );
        vm.stopPrank();

        // Verify batch is settled
        ISwapManager.Batch memory batch = swapManager.getBatch(batchId);
        assertEq(uint(batch.status), uint(ISwapManager.BatchStatus.Settled));
    }

    function testSubmitBatchSettlement_RevertNotOperator() public {
        // Setup batch (simplified)
        bytes32 batchId = keccak256("batch1");
        InternalTransferInput[] memory internalTransfers = new InternalTransferInput[](0);
        IUniversalPrivacyHook.UserShare[] memory userShares = new IUniversalPrivacyHook.UserShare[](0);
        bytes[] memory signatures = new bytes[](0);

        // Try to submit from non-operator
        vm.prank(user1);
        vm.expectRevert("Operator must be the caller");
        swapManager.submitBatchSettlement(
            batchId,
            internalTransfers,
            0,
            tokenA,
            tokenB,
            tokenB,
            userShares,
            signatures
        );
    }

    function testSubmitBatchSettlement_RevertBatchNotProcessing() public {
        bytes32 batchId = keccak256("batch1");
        InternalTransferInput[] memory internalTransfers = new InternalTransferInput[](0);
        IUniversalPrivacyHook.UserShare[] memory userShares = new IUniversalPrivacyHook.UserShare[](0);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = new bytes(65);

        // Try to submit without batch being in Processing state
        vm.prank(operator1);
        vm.expectRevert("Batch not processing");
        swapManager.submitBatchSettlement(
            batchId,
            internalTransfers,
            0,
            tokenA,
            tokenB,
            tokenB,
            userShares,
            signatures
        );
    }

    function testSubmitBatchSettlement_RevertInsufficientSignatures() public {
        // Setup: Create and finalize a batch
        bytes32 batchId = keccak256("batch1");
        bytes32[] memory intentIds = new bytes32[](1);
        intentIds[0] = keccak256("intent1");
        bytes32 poolId = keccak256("pool1");

        // Create proper FHE handle
        euint128 enc1000 = createEncryptedForSwapManager(1000);

        bytes[] memory encryptedIntents = new bytes[](1);
        encryptedIntents[0] = abi.encode(
            intentIds[0],
            user1,
            tokenA,
            tokenB,
            euint128.unwrap(enc1000),
            uint256(block.timestamp + 1 hours)
        );

        bytes memory batchData = abi.encode(
            batchId,
            intentIds,
            poolId,
            address(mockHook),
            encryptedIntents
        );

        vm.prank(address(mockHook));
        swapManager.finalizeBatch(batchId, batchData);

        // Prepare settlement with insufficient signatures (empty array)
        InternalTransferInput[] memory internalTransfers = new InternalTransferInput[](0);
        IUniversalPrivacyHook.UserShare[] memory userShares = new IUniversalPrivacyHook.UserShare[](0);
        bytes[] memory signatures = new bytes[](0);  // No signatures

        vm.prank(operator1);
        vm.expectRevert("Insufficient signatures");
        swapManager.submitBatchSettlement(
            batchId,
            internalTransfers,
            0,
            tokenA,
            tokenB,
            tokenB,
            userShares,
            signatures
        );
    }

    // ========== UEI Tests ==========

    function testSubmitUEI() public {
        // Create encrypted FHE inputs using CoFHE mocks (sender = user1)
        InEaddress memory encDecoder = createInEaddress(address(0x100), user1);
        InEaddress memory encTarget = createInEaddress(address(0x200), user1);
        InEuint32 memory encSelector = createInEuint32(0x12345678, user1);
        DynamicInE[] memory encArgs = new DynamicInE[](0); // Empty args for this test

        uint256 deadline = block.timestamp + 1 hours;

        // Users submit directly (not hooks)
        vm.prank(user1);
        bytes32 intentId = swapManager.submitEncryptedUEI(encDecoder, encTarget, encSelector, encArgs, deadline);

        // Verify intent was created
        assertTrue(intentId != bytes32(0));

        // Get the task
        ISwapManager.UEITask memory task = swapManager.getUEITask(intentId);
        assertEq(task.submitter, user1);
        assertEq(task.deadline, deadline);
        assertEq(uint(task.status), uint(ISwapManager.UEIStatus.Pending));
    }

    function testSubmitUEIWithTransferFunction() public {
        // Test ERC20 transfer(address,uint128) with dynamic typed arguments
        // Simulate: transfer(recipient, amount)

        address recipient = address(0x777);
        uint128 amount = 1000e6; // 1000 USDC

        // Create encrypted inputs
        InEaddress memory encDecoder = createInEaddress(address(0x1), user1); // Decoder address
        InEaddress memory encTarget = createInEaddress(tokenA, user1); // Target = USDC token
        InEuint32 memory encSelector = createInEuint32(0xa9059cbb, user1); // transfer(address,uint256)

        // Create dynamic arguments: [address recipient, uint128 amount]
        DynamicInE[] memory encArgs = new DynamicInE[](2);

        // Arg 0: recipient address (utype 7)
        InEaddress memory encRecipient = createInEaddress(recipient, user1);
        encArgs[0] = DynamicInE({
            ctHash: encRecipient.ctHash,
            securityZone: encRecipient.securityZone,
            utype: 7, // Address type
            signature: encRecipient.signature
        });

        // Arg 1: amount (utype 6 = uint128)
        InEuint128 memory encAmount = createInEuint128(amount, user1);
        encArgs[1] = DynamicInE({
            ctHash: encAmount.ctHash,
            securityZone: encAmount.securityZone,
            utype: 6, // Uint128 type
            signature: encAmount.signature
        });

        uint256 deadline = block.timestamp + 1 hours;

        // Submit UEI
        vm.prank(user1);
        bytes32 intentId = swapManager.submitEncryptedUEI(encDecoder, encTarget, encSelector, encArgs, deadline);

        // Verify intent was created
        assertTrue(intentId != bytes32(0));

        // Get the task
        ISwapManager.UEITask memory task = swapManager.getUEITask(intentId);
        assertEq(task.submitter, user1);
        assertEq(task.deadline, deadline);
        assertEq(uint(task.status), uint(ISwapManager.UEIStatus.Pending));

        // Finalize batch to grant operator permissions
        vm.warp(block.timestamp + 11 minutes);
        swapManager.finalizeUEIBatch();

        // Verify batch was finalized
        ISwapManager.TradeBatch memory batch = swapManager.getTradeBatch(task.batchId);
        assertTrue(batch.finalized);
        assertEq(batch.intentIds.length, 1);
        assertEq(batch.intentIds[0], intentId);
    }

    // Test removed - submitEncryptedUEI is now public (users submit directly, not hooks)
    // Anyone can submit UEI, no authorization check needed

    // testSubmitUEIWithProof skipped - requires FHE.fromExternal which needs proper FHE setup
    // This would require deploying the full FHE precompile contracts
    // Covered by integration tests in operator package

    function testProcessUEI() public {
        // First submit a UEI (user submits directly)
        InEaddress memory encDecoder = createInEaddress(address(0x100), user1);
        InEaddress memory encTarget = createInEaddress(address(0x200), user1);
        InEuint32 memory encSelector = createInEuint32(0x12345678, user1);
        DynamicInE[] memory encArgs = new DynamicInE[](0);
        uint256 deadline = block.timestamp + 1 hours;

        vm.prank(user1);
        bytes32 intentId = swapManager.submitEncryptedUEI(encDecoder, encTarget, encSelector, encArgs, deadline);

        // Finalize the batch first to select operators
        vm.warp(block.timestamp + 11 minutes); // Past MAX_BATCH_IDLE
        swapManager.finalizeUEIBatch();

        // Get selected operators from the batch
        ISwapManager.UEITask memory task = swapManager.getUEITask(intentId);
        ISwapManager.TradeBatch memory batch = swapManager.getTradeBatch(task.batchId);
        address selectedOp = batch.selectedOperators[0];

        // Find the private key for the selected operator
        uint256 operatorPk;
        if (selectedOp == operator1) operatorPk = 2;
        else if (selectedOp == operator2) operatorPk = 3;
        else if (selectedOp == operator3) operatorPk = 4;

        // Prepare process data
        address decoder = address(0x100);
        address target = address(0x200);
        bytes memory reconstructedData = "0x12345678";

        // Create operator signature from selected operator
        bytes32 dataHash = keccak256(abi.encode(intentId, decoder, target, reconstructedData));
        bytes32 ethSigned = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            dataHash
        ));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, ethSigned);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r, s, v);

        // Process UEI from the selected operator
        vm.prank(selectedOp);
        swapManager.processUEI(intentId, decoder, target, reconstructedData, signatures);

        // Verify execution
        ISwapManager.UEIExecution memory execution = swapManager.getUEIExecution(intentId);
        assertEq(execution.decoder, decoder);
        assertEq(execution.target, target);
        assertEq(execution.executor, selectedOp);
    }

    function testProcessUEIRevertsIfNotSelected() public {
        // Submit a UEI (user submits directly)
        InEaddress memory encDecoder = createInEaddress(address(0x100), user1);
        InEaddress memory encTarget = createInEaddress(address(0x200), user1);
        InEuint32 memory encSelector = createInEuint32(0x12345678, user1);
        DynamicInE[] memory encArgs = new DynamicInE[](0);

        vm.prank(user1);
        bytes32 intentId = swapManager.submitEncryptedUEI(encDecoder, encTarget, encSelector, encArgs, block.timestamp + 1 hours);

        // Finalize batch to select operators
        vm.warp(block.timestamp + 11 minutes);
        swapManager.finalizeUEIBatch();

        // Try to process from non-selected operator
        address notSelectedOperator = address(0x999);
        vm.prank(notSelectedOperator);
        vm.expectRevert("Operator must be the caller");
        swapManager.processUEI(intentId, address(0x100), address(0x200), "", new bytes[](0));
    }

    function testRejectUint256Type() public {
        // Verify that utype 8 (euint256) is explicitly rejected
        InEaddress memory encDecoder = createInEaddress(address(0x1), user1);
        InEaddress memory encTarget = createInEaddress(tokenA, user1);
        InEuint32 memory encSelector = createInEuint32(0xa9059cbb, user1);

        // Try to create arg with utype 8 (deprecated euint256)
        DynamicInE[] memory encArgs = new DynamicInE[](1);
        InEuint128 memory encAmount = createInEuint128(1000, user1);
        encArgs[0] = DynamicInE({
            ctHash: encAmount.ctHash,
            securityZone: encAmount.securityZone,
            utype: 8, // euint256 - DEPRECATED
            signature: encAmount.signature
        });

        // Should revert with explicit error
        vm.prank(user1);
        vm.expectRevert("DynamicFHE: euint256 (utype 8) is deprecated and not supported");
        swapManager.submitEncryptedUEI(encDecoder, encTarget, encSelector, encArgs, block.timestamp + 1 hours);
    }
}