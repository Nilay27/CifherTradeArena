// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISwapManager} from "../../src/privacy/interfaces/ISwapManager.sol";

/**
 * @title MockSwapManager
 * @notice Mock implementation of SwapManager for testing with Uniswap v4 (Solidity 0.8.26)
 * @dev This mock simulates the AVS SwapManager without requiring Solidity 0.8.27
 */
contract MockSwapManager is ISwapManager {
    uint256 private taskCounter;
    mapping(uint256 => SwapTask) public tasks;
    mapping(uint256 => bytes32) public allTaskHashes;
    
    address public immutable avsDirectory;
    address public immutable stakeRegistry;
    address public immutable delegationManager;
    address public immutable allocationManager;
    uint256 public immutable maxResponseIntervalBlocks;
    
    address public owner;
    address public taskCreator;
    
    constructor(
        address _avsDirectory,
        address _stakeRegistry,
        address _delegationManager,
        address _allocationManager,
        uint256 _maxResponseIntervalBlocks
    ) {
        avsDirectory = _avsDirectory;
        stakeRegistry = _stakeRegistry;
        delegationManager = _delegationManager;
        allocationManager = _allocationManager;
        maxResponseIntervalBlocks = _maxResponseIntervalBlocks;
    }
    
    function initialize(address _owner, address _taskCreator) external {
        require(owner == address(0), "Already initialized");
        owner = _owner;
        taskCreator = _taskCreator;
    }
    
    function createNewSwapTask(
        address user,
        address tokenIn,
        address tokenOut,
        bytes calldata encryptedAmount,
        uint64 deadline
    ) external override returns (SwapTask memory) {
        taskCounter++;
        
        SwapTask memory newTask = SwapTask({
            hook: msg.sender,
            user: user,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            encryptedAmount: encryptedAmount,
            deadline: deadline,
            taskCreatedBlock: uint32(block.number)
        });
        
        tasks[taskCounter] = newTask;
        
        // Store task hash (simulating AVS behavior)
        bytes32 taskHash = keccak256(abi.encode(newTask));
        allTaskHashes[taskCounter] = taskHash;
        
        return newTask;
    }
    
    // Additional helper methods for testing
    function getTask(uint256 taskId) external view returns (SwapTask memory) {
        return tasks[taskId];
    }
    
    function getTaskCount() external view returns (uint256) {
        return taskCounter;
    }
}