// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

interface ISwapManager {
    // ============ ORIGINAL SINGLE TASK SYSTEM (for backward compatibility) ============
    
    // Events
    event NewSwapTaskCreated(uint32 indexed taskIndex, SwapTask task);
    event SwapTaskResponded(uint32 indexed taskIndex, SwapTask task, address operator, uint256 decryptedAmount);

    // Original SwapTask struct - KEPT for test compatibility
    struct SwapTask {
        address hook;           // Privacy hook contract address
        address user;           // User submitting the swap
        address tokenIn;        // Token being swapped from
        address tokenOut;       // Token being swapped to
        bytes encryptedAmount;  // FHE encrypted swap amount
        uint64 deadline;        // Swap deadline
        uint32 taskCreatedBlock;
        address[] selectedOperators; // Operators selected for decryption
    }
    
    // Legacy Task struct that tests use
    struct Task {
        string name;
        uint32 taskCreatedBlock;
    }

    // Original view functions
    function latestTaskNum() external view returns (uint32);
    function allTaskHashes(uint32 taskIndex) external view returns (bytes32);
    function allTaskResponses(address operator, uint32 taskIndex) external view returns (bytes memory);
    function getTask(uint32 taskIndex) external view returns (SwapTask memory);
    
    // Original core functions
    function createNewSwapTask(
        address user,
        address tokenIn,
        address tokenOut,
        bytes calldata encryptedAmount,
        uint64 deadline
    ) external returns (SwapTask memory);

    function respondToSwapTask(
        SwapTask calldata task,
        uint32 referenceTaskIndex,
        uint256 decryptedAmount,
        bytes calldata signature
    ) external;

    function slashOperator(
        SwapTask calldata task,
        uint32 referenceTaskIndex,
        address operator
    ) external;
    
    // Test compatibility functions (HelloWorldServiceManager tests use these)
    function createNewTask(string memory name) external returns (Task memory);
    function respondToTask(Task calldata task, uint32 referenceTaskIndex, bytes calldata signature) external;
    function slashOperator(Task calldata task, uint32 referenceTaskIndex, address operator) external;
    
    // ============ NEW BATCH SYSTEM (added functionality) ============
    
    // Batch structures
    struct TokenTransfer {
        bytes32 intentIdA;
        bytes32 intentIdB;
        address userA;
        address userB;
        address tokenA;
        address tokenB;
        bytes encryptedAmountA;  // FHE encrypted amount
        bytes encryptedAmountB;  // FHE encrypted amount
    }
    
    struct NetSwap {
        address tokenIn;
        address tokenOut;
        uint256 netAmount;
        bytes32[] remainingIntents;
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
    
    enum BatchStatus {
        Collecting,
        Processing,
        Settled,
        Failed
    }

    // Batch events
    event BatchFinalized(bytes32 indexed batchId, bytes batchData);
    event BatchSettlementSubmitted(bytes32 indexed batchId, uint256 internalizedCount, uint256 netSwapCount);
    event BatchSettled(bytes32 indexed batchId, bool success);
    event OperatorSelectedForBatch(bytes32 indexed batchId, address indexed operator);

    // Batch functions
    function finalizeBatch(
        bytes32 batchId,
        bytes calldata batchData
    ) external;
    
    function submitBatchSettlement(
        BatchSettlement calldata settlement,
        bytes[] calldata operatorSignatures
    ) external;
    
    // Batch view functions
    function getBatch(bytes32 batchId) external view returns (Batch memory);
    function getOperatorCount() external view returns (uint256);
    function isOperatorSelectedForBatch(bytes32 batchId, address operator) external view returns (bool);
    function isOperatorRegistered(address operator) external view returns (bool);
    function registerOperatorForBatches() external;

    // ============ UEI (Universal Encrypted Intent) SYSTEM ============

    // UEI status tracking
    enum UEIStatus {
        Pending,
        Processing,
        Executed,
        Failed,
        Expired
    }

    // UEI task structure
    struct UEITask {
        bytes32 intentId;
        address submitter;
        bytes ctBlob;  // Contains encrypted decoder, target, selector, args
        uint256 deadline;
        uint256 blockSubmitted;
        address[] selectedOperators;
        UEIStatus status;
    }

    // UEI execution record
    struct UEIExecution {
        bytes32 intentId;
        address decoder;
        address target;
        bytes callData;  // Renamed from calldata (reserved keyword)
        address executor;
        uint256 executedAt;
        bool success;
        bytes result;
    }

    // UEI events
    event UEISubmitted(
        bytes32 indexed intentId,
        address indexed submitter,
        bytes ctBlob,
        uint256 deadline,
        address[] selectedOperators
    );

    event UEIProcessed(
        bytes32 indexed intentId,
        bool success,
        bytes result
    );

    event BoringVaultSet(address indexed vault);

    // UEI functions
    function submitUEI(
        bytes calldata ctBlob,
        uint256 deadline
    ) external returns (bytes32 intentId);

    function processUEI(
        bytes32 intentId,
        address decoder,
        address target,
        bytes calldata reconstructedData,
        bytes[] calldata operatorSignatures
    ) external;

    function setBoringVault(address payable _vault) external;

    // UEI view functions
    function getUEITask(bytes32 intentId) external view returns (UEITask memory);
    function getUEIExecution(bytes32 intentId) external view returns (UEIExecution memory);
}