// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

interface ISwapManager {
    // Structures matching the hook's interface
    struct TokenTransfer {
        address user;
        address token;
        bytes encryptedAmount; // Still encrypted for AVS to handle
    }
    
    struct NetSwap {
        address tokenIn;
        address tokenOut;
        uint256 netAmount; // Decrypted by AVS
        bool isZeroForOne;
        address[] recipients;
        bytes[] encryptedRecipientAmounts; // Still encrypted
    }
    
    struct BatchSettlement {
        bytes32 batchId;
        TokenTransfer[] internalizedTransfers;
        NetSwap netSwap;
        bool hasNetSwap;
        uint256 totalInternalized;
        uint256 totalNet;
    }
    
    struct Batch {
        bytes32 batchId;
        bytes32[] intentIds;
        address poolId;
        address hook;
        uint32 createdBlock;
        uint32 finalizedBlock;
        BatchStatus status;
    }
    
    struct Intent {
        address user;
        address tokenIn;
        address tokenOut;
        bytes encryptedAmount;
        uint64 deadline;
    }
    
    enum BatchStatus {
        Collecting,
        Processing,
        Settled,
        Failed
    }

    // Events
    event BatchCreated(bytes32 indexed batchId, uint256 intentCount);
    event BatchFinalized(bytes32 indexed batchId, bytes batchData);
    event BatchSettlementSubmitted(bytes32 indexed batchId, uint256 matchCount, uint256 netCount);
    event BatchSettled(bytes32 indexed batchId, bool success);
    event OperatorSelectedForBatch(bytes32 indexed batchId, address operator);

    // Called by hook when batch is ready for processing
    function finalizeBatch(
        bytes32 batchId,
        bytes calldata batchData // Encoded intent data for operators
    ) external;
    
    // Called by operators after matching
    function submitBatchSettlement(
        BatchSettlement calldata settlement,
        bytes[] calldata operatorSignatures
    ) external;
    
    // View functions
    function getBatch(bytes32 batchId) external view returns (Batch memory);
    function getOperatorCount() external view returns (uint256);
    function isOperatorSelectedForBatch(bytes32 batchId, address operator) external view returns (bool);
}