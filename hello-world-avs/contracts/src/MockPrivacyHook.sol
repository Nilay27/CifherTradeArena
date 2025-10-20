// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ITradeManager} from "./ITradeManager.sol";
import {SimpleBoringVault} from "./SimpleBoringVault.sol";
import {FHE, euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import {Currency} from "./TradeManager.sol";

/**
 * @title MockPrivacyHook
 * @notice Mock contract to simulate the UniversalPrivacyHook with batch processing and UEI support
 * @dev This contract allows testing of batch-based AVS operator decryption, matching, and encrypted trade intents
 */
contract MockPrivacyHook {
    ITradeManager public tradeManager;
    SimpleBoringVault public boringVault;

    // Define types that match UniversalPrivacyHook
    struct InternalTransfer {
        address to;             // User receiving tokens
        address encToken;       // IFHERC20 token address (e.g., eUSDC or eUSDT contract)
        euint128 encAmount;     // TradeManager loads InEuint128 to euint128 before passing here
    }

    struct UserShare {
        address user;           // User address
        uint128 shareNumerator; // User's share numerator (e.g., 4 for 4/5)
        uint128 shareDenominator; // Share denominator (e.g., 5 for 4/5)
    }
    
    // Track submitted intents
    mapping(bytes32 => Intent) public intents;
    mapping(bytes32 => Batch) public batches;
    mapping(bytes32 => mapping(bytes32 => bool)) public batchIntents; // batchId => intentId => exists
    
    bytes32 public currentBatchId;
    uint256 public batchBlockInterval = 5;
    uint256 public lastBatchBlock;
    
    struct Intent {
        address user;
        address tokenIn;
        address tokenOut;
        bytes encryptedAmount;
        uint64 deadline;
        bytes32 batchId;
    }
    
    struct Batch {
        bytes32[] intentIds;
        uint256 createdAt;
        BatchStatus status;
    }
    
    enum BatchStatus {
        Collecting,
        Processing,
        Settled
    }
    
    event IntentSubmitted(
        bytes32 indexed intentId,
        address indexed user,
        address tokenIn,
        address tokenOut,
        bytes encryptedAmount
    );
    
    event BatchCreated(bytes32 indexed batchId, uint256 blockNumber);
    event BatchFinalized(bytes32 indexed batchId, uint256 intentCount);
    event UEISubmitted(bytes32 indexed intentId, address indexed submitter, bytes ctBlob);
    event UEISubmittedWithProof(bytes32 indexed intentId, address indexed submitter, bytes ctBlob, bytes inputProof);

    constructor(address _swapManager) {
        tradeManager = ITradeManager(_swapManager);
    }

    /**
     * @notice Set the SimpleBoringVault address
     * @param _vault The address of the SimpleBoringVault
     */
    function setBoringVault(address payable _vault) external {
        boringVault = SimpleBoringVault(_vault);
    }

    
    /**
     * @notice Submit an encrypted swap intent to the current batch (legacy bytes version)
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param encryptedAmount The encrypted swap amount (as bytes)
     * @return intentId The ID of the submitted intent
     */
    function submitIntent(
        address tokenIn,
        address tokenOut,
        bytes calldata encryptedAmount
    ) external returns (bytes32 intentId) {
        // Create intent ID
        intentId = keccak256(abi.encode(msg.sender, block.timestamp, tokenIn, tokenOut));
        
        // Get or create current batch
        bytes32 batchId = _getOrCreateBatch();
        
        // Store intent
        intents[intentId] = Intent({
            user: msg.sender,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            encryptedAmount: encryptedAmount,
            deadline: uint64(block.timestamp + 3600),
            batchId: batchId
        });
        
        // Add to batch
        batches[batchId].intentIds.push(intentId);
        batchIntents[batchId][intentId] = true;
        
        emit IntentSubmitted(intentId, msg.sender, tokenIn, tokenOut, encryptedAmount);
        
        return intentId;
    }
    
    /**
     * @notice Submit a test intent with a pre-encoded encrypted amount
     * @dev This simulates what would happen when a user submits via the UniversalPrivacyHook
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param amount The amount to encrypt (will be encoded as if it were an encrypted handle)
     * @return intentId The ID of the submitted intent
     */
    function submitTestIntent(
        address tokenIn,
        address tokenOut,
        uint256 amount
    ) external returns (bytes32 intentId) {
        // Encode the amount as if it were an encrypted FHE value
        // In real FHE, this would be a ciphertext, but for testing we just encode the plaintext
        bytes memory encryptedAmount = abi.encode(amount);
        
        return this.submitIntent(tokenIn, tokenOut, encryptedAmount);
    }
    
    /**
     * @notice Finalize the current batch and send to AVS for processing
     */
    function finalizeBatch() external {
        require(currentBatchId != bytes32(0), "No active batch");
        
        Batch storage batch = batches[currentBatchId];
        require(batch.status == BatchStatus.Collecting, "Batch not collecting");
        require(batch.intentIds.length > 0, "Empty batch");
        
        // Mark batch as processing
        batch.status = BatchStatus.Processing;
        
        // Encode batch data for AVS
        bytes memory batchData = abi.encode(
            batch.intentIds,
            address(this) // Mock pool key
        );
        
        // Send to TradeManager AVS
        tradeManager.finalizeBatch(currentBatchId, batchData);
        
        emit BatchFinalized(currentBatchId, batch.intentIds.length);
        
        // Reset for next batch
        currentBatchId = bytes32(0);
    }
    
    /**
     * @notice Simulate batch settlement (called by AVS after consensus)
     * @dev Matches UniversalPrivacyHook.settleBatch signature
     */
    function settleBatch(
        bytes32 batchId,
        InternalTransfer[] calldata internalTransfers,
        uint128 netAmountIn,
        Currency tokenIn,
        Currency tokenOut,
        address outputToken,
        UserShare[] calldata userShares
    ) external {
        require(msg.sender == address(tradeManager), "Only TradeManager");

        // For mock purposes, only mark as settled if batch exists in our tracking
        // This allows tests to call TradeManager.finalizeBatch directly without
        // going through MockPrivacyHook's batch creation flow
        if (batches[batchId].intentIds.length > 0) {
            Batch storage batch = batches[batchId];
            // Only check status if batch was created through MockPrivacyHook
            if (batch.status == BatchStatus.Processing) {
                batch.status = BatchStatus.Settled;
            }
        }

        // In a real implementation, this would:
        // 1. Process internal transfers with encrypted amounts
        // 2. Execute net swap through Uniswap if netAmountIn > 0
        // 3. Distribute AMM outputs to users based on userShares

        // For mock purposes, we just verify the call succeeded
        // Tests can verify this function was called with correct parameters
    }
    
    /**
     * @notice Get or create current batch
     */
    function _getOrCreateBatch() internal returns (bytes32) {
        // Check if we need a new batch
        if (currentBatchId == bytes32(0)) {
            // First batch ever
            _createNewBatch();
        } else if (block.number >= lastBatchBlock + batchBlockInterval) {
            // Close current batch and create new one
            bytes32 oldBatchId = currentBatchId;
            
            // Close the old batch if it has intents
            if (batches[oldBatchId].status == BatchStatus.Collecting && 
                batches[oldBatchId].intentIds.length > 0) {
                _finalizeBatchInternal(oldBatchId);
            }
            
            // Create new batch after closing old one
            _createNewBatch();
        }
        
        return currentBatchId;
    }
    
    function _createNewBatch() internal {
        currentBatchId = keccak256(abi.encode(block.number, block.timestamp));
        batches[currentBatchId] = Batch({
            intentIds: new bytes32[](0),
            createdAt: block.timestamp,
            status: BatchStatus.Collecting
        });
        
        lastBatchBlock = block.number;
        emit BatchCreated(currentBatchId, block.number);
    }
    
    function _finalizeBatchInternal(bytes32 batchId) internal {
        Batch storage batch = batches[batchId];
        
        // Ensure batch is in correct state
        require(batch.status == BatchStatus.Collecting, "Batch not collecting");
        require(batch.intentIds.length > 0, "Empty batch");
        
        // Ensure TradeManager is set
        require(address(tradeManager) != address(0), "TradeManager not set");
        
        // Encode batch data for AVS
        bytes memory batchData = abi.encode(
            batch.intentIds,
            address(this) // Mock pool key
        );
        
        // Send to TradeManager AVS - this should succeed now
        tradeManager.finalizeBatch(batchId, batchData);
        
        // Mark batch as processing AFTER successful external call
        batch.status = BatchStatus.Processing;
        
        emit BatchFinalized(batchId, batch.intentIds.length);
    }
    
    /**
     * @notice Get batch details
     */
    function getBatch(bytes32 batchId) external view returns (Batch memory) {
        return batches[batchId];
    }
    
    /**
     * @notice Get intent details
     */
    function getIntent(bytes32 intentId) external view returns (Intent memory) {
        return intents[intentId];
    }
    
    /**
     * @notice Check if batch is ready for processing
     */
    function isBatchReady() external view returns (bool) {
        if (currentBatchId == bytes32(0)) return false;
        
        Batch memory batch = batches[currentBatchId];
        return batch.status == BatchStatus.Collecting && 
               batch.intentIds.length > 0 &&
               block.number >= lastBatchBlock + batchBlockInterval;
    }
}