// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISwapManager} from "../interfaces/ISwapManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {FHE, InEuint128, euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

// Interface for calling settleBatch on hook (with loaded euint128)
interface IHookSettlement {
    struct InternalTransfer {
        address to;
        address encToken;
        euint128 encAmount;  // Hook receives loaded euint128 (not InEuint128!)
    }

    struct UserShare {
        address user;
        uint128 shareNumerator;
        uint128 shareDenominator;
    }

    function settleBatch(
        bytes32 batchId,
        InternalTransfer[] calldata internalTransfers,
        uint128 netAmountIn,
        Currency tokenIn,
        Currency tokenOut,
        address outputToken,
        UserShare[] calldata userShares
    ) external;
}

// Struct for tests to submit InternalTransfers with InEuint128 (before loading)
struct InternalTransferInput {
    address to;
    address encToken;
    InEuint128 encAmount;  // Tests provide InEuint128 with signature
}

/**
 * @title MockSwapManager
 * @dev Mock implementation of ISwapManager for testing
 * @notice This mock allows testing batch finalization and settlement without deploying the full AVS
 */
contract MockSwapManager is ISwapManager {
    address public hook;

    // Store finalized batches
    mapping(bytes32 => bool) public finalizedBatches;

    event BatchFinalized(bytes32 indexed batchId);
    event BatchSettled(bytes32 indexed batchId);

    constructor() {}

    /**
     * @dev Set the hook address for testing
     */
    function setHook(address _hook) external {
        hook = _hook;
    }

    /**
     * @inheritdoc ISwapManager
     */
    function createBatch(
        bytes32 batchId,
        address,
        PoolId,
        bytes[] calldata,
        address[] calldata
    ) external override {
        // Mock implementation - just mark as created
        finalizedBatches[batchId] = false;
    }

    /**
     * @inheritdoc ISwapManager
     */
    function selectOperatorsForBatch(bytes32) external pure override returns (address[] memory) {
        // Mock implementation - return empty array
        address[] memory operators = new address[](0);
        return operators;
    }

    /**
     * @inheritdoc ISwapManager
     */
    function finalizeBatch(bytes32 batchId, bytes calldata batchData) external override {
        // Mark batch as finalized
        finalizedBatches[batchId] = true;
        emit BatchFinalized(batchId);
    }

    /**
     * @dev Mock function to call settleBatch on the hook
     * @notice Mimics real SwapManager behavior: loads InEuint128 to euint128 before forwarding to hook
     * @param internalTransfersInput Array of InternalTransferInput with InEuint128 values from tests
     */
    function mockSettleBatch(
        bytes32 batchId,
        InternalTransferInput[] calldata internalTransfersInput,
        uint128 netAmountIn,
        Currency tokenIn,
        Currency tokenOut,
        address outputToken,
        IHookSettlement.UserShare[] calldata userShares
    ) external {
        require(hook != address(0), "Hook not set");
        require(finalizedBatches[batchId], "Batch not finalized");

        // Load InEuint128 to euint128 in MockSwapManager (msg.sender context)
        // This mimics the real SwapManager's behavior
        IHookSettlement.InternalTransfer[] memory internalTransfers =
            new IHookSettlement.InternalTransfer[](internalTransfersInput.length);

        for (uint256 i = 0; i < internalTransfersInput.length; i++) {
            euint128 loadedAmount = FHE.asEuint128(internalTransfersInput[i].encAmount);

            // Allow Hook to use and grant permissions further (like Hook does for SwapManager in _finalizeBatch)
            FHE.allowTransient(loadedAmount, hook);

            internalTransfers[i] = IHookSettlement.InternalTransfer({
                to: internalTransfersInput[i].to,
                encToken: internalTransfersInput[i].encToken,
                encAmount: loadedAmount
            });
        }

        // Call settleBatch on the hook with loaded euint128 values
        IHookSettlement(hook).settleBatch(
            batchId,
            internalTransfers,
            netAmountIn,
            tokenIn,
            tokenOut,
            outputToken,
            userShares
        );

        emit BatchSettled(batchId);
    }
}
