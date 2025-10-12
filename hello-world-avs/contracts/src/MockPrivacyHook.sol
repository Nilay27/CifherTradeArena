// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./ISwapManager.sol";

/**
 * @title MockPrivacyHook
 * @notice Mock contract to simulate the UniversalPrivacyHook for testing encrypted swap intents
 * @dev This contract allows us to test the AVS operator's ability to decrypt and respond to swap tasks
 */
contract MockPrivacyHook {
    ISwapManager public immutable swapManager;
    
    // Track submitted intents
    mapping(address => uint256) public userIntentCount;
    mapping(uint256 => IntentData) public intents;
    uint256 public nextIntentId = 1;
    
    struct IntentData {
        address user;
        address tokenIn;
        address tokenOut;
        bytes encryptedAmount;
        uint256 taskIndex;
        uint256 timestamp;
    }
    
    event IntentSubmitted(
        uint256 indexed intentId,
        address indexed user,
        address tokenIn,
        address tokenOut,
        bytes encryptedAmount
    );
    
    event TaskCreated(
        uint256 indexed intentId,
        uint256 indexed taskIndex,
        address[] selectedOperators
    );
    
    constructor(address _swapManager) {
        swapManager = ISwapManager(_swapManager);
    }
    
    /**
     * @notice Submit an encrypted swap intent
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param encryptedAmount The encrypted swap amount (as bytes)
     * @return intentId The ID of the submitted intent
     */
    function submitEncryptedIntent(
        address tokenIn,
        address tokenOut,
        bytes calldata encryptedAmount
    ) external returns (uint256 intentId) {
        intentId = nextIntentId++;
        
        // Store intent data
        intents[intentId] = IntentData({
            user: msg.sender,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            encryptedAmount: encryptedAmount,
            taskIndex: 0, // Will be set when task is created
            timestamp: block.timestamp
        });
        
        userIntentCount[msg.sender]++;
        
        // Create a new swap task in the SwapManager with a deadline (1 hour from now)
        uint64 deadline = uint64(block.timestamp + 3600);
        
        // Get the current task index before creating the new task
        uint32 taskIndex = swapManager.latestTaskNum();
        
        ISwapManager.SwapTask memory task = swapManager.createNewSwapTask(
            msg.sender,
            tokenIn,
            tokenOut,
            encryptedAmount,
            deadline
        );
        
        // Update the intent with the task index
        intents[intentId].taskIndex = taskIndex;
        
        emit IntentSubmitted(intentId, msg.sender, tokenIn, tokenOut, encryptedAmount);
        emit TaskCreated(intentId, taskIndex, task.selectedOperators);
        
        return intentId;
    }
    
    /**
     * @notice Submit a test intent with a pre-encoded encrypted amount
     * @dev This simulates what would happen when a user submits via the UniversalPrivacyHook
     * @param tokenIn The input token address
     * @param tokenOut The output token address
     * @param amount The amount to encrypt (will be encoded as if it were an encrypted handle)
     */
    function submitTestIntent(
        address tokenIn,
        address tokenOut,
        uint256 amount
    ) external returns (uint256 intentId) {
        // Encode the amount as if it were an encrypted handle
        // In real scenario, this would be an actual FHE encrypted value
        bytes memory encryptedAmount = abi.encode(amount);
        
        return this.submitEncryptedIntent(tokenIn, tokenOut, encryptedAmount);
    }
    
    /**
     * @notice Get intent details
     * @param intentId The ID of the intent
     * @return The intent data
     */
    function getIntent(uint256 intentId) external view returns (IntentData memory) {
        return intents[intentId];
    }
    
    /**
     * @notice Get the number of intents submitted by a user
     * @param user The user address
     * @return The number of intents
     */
    function getUserIntentCount(address user) external view returns (uint256) {
        return userIntentCount[user];
    }
}