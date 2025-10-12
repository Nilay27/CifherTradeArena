// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Minimal interface for SwapManager AVS integration
 * @notice Used by UniversalPrivacyHook to submit encrypted intents to AVS
 */
interface ISwapManager {
    struct SwapTask {
        address hook;
        address user;
        address tokenIn;
        address tokenOut;
        bytes encryptedAmount;
        uint64 deadline;
        uint32 taskCreatedBlock;
    }
    
    function createNewSwapTask(
        address user,
        address tokenIn,
        address tokenOut,
        bytes calldata encryptedAmount,
        uint64 deadline
    ) external returns (SwapTask memory);
}