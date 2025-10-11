// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

interface ISwapManager {
    // Events
    event NewSwapTaskCreated(uint32 indexed taskIndex, SwapTask task);
    event SwapTaskResponded(uint32 indexed taskIndex, SwapTask task, address operator, uint256 decryptedAmount);

    // Structs
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

    // View functions
    function latestTaskNum() external view returns (uint32);
    
    function allTaskHashes(uint32 taskIndex) external view returns (bytes32);
    
    function allTaskResponses(address operator, uint32 taskIndex) external view returns (bytes memory);
    
    function getTask(uint32 taskIndex) external view returns (SwapTask memory);
    
    function getOperatorCount() external view returns (uint256);

    // Core functions
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
}