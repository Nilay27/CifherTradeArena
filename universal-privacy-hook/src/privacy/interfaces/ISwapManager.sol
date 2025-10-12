// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/**
 * @title Interface for SwapManager AVS with batch settlement
 * @notice Used by UniversalPrivacyHook to submit encrypted intents and receive settlement instructions
 */
interface ISwapManager {
    struct TokenTransfer {
        address user;
        address token;
        euint128 amount;
    }
    
    struct NetSwap {
        address tokenIn;
        address tokenOut;
        uint256 netAmount; // Total net amount to swap via pool (already decrypted by AVS)
        bool isZeroForOne; // Direction of the swap
        // Distribution of the swap output to users
        address[] recipients;
        euint128[] recipientAmounts; // Encrypted amounts for each recipient
    }
    
    struct BatchSettlement {
        bytes32 batchId;
        TokenTransfer[] internalizedTransfers; // Direct transfers from matched trades
        NetSwap netSwap; // Single net swap with distribution info
        bool hasNetSwap; // Whether there's a net swap needed
        uint256 totalInternalized; // Total value matched internally
        uint256 totalNet; // Total value going to pool
    }
    
    // Events
    event BatchCreated(bytes32 indexed batchId, uint256 intentCount);
    event BatchSettlementSubmitted(bytes32 indexed batchId, uint256 matchCount, uint256 netCount);
    event BatchSettled(bytes32 indexed batchId, bool success);
    
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
}