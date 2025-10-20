// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {InEaddress, InEuint32, InEuint256} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/**
 * @notice Dynamic encrypted input - supports any FHE type based on utype
 * @dev Allows flexible argument encoding for UEI where args can be addresses, uint128, etc.
 */
struct DynamicInE {
    uint256 ctHash;
    uint8 securityZone;
    uint8 utype;
    bytes signature;
}

interface ITradeManager {
    // ============ OPERATOR MANAGEMENT ============

    function getOperatorCount() external view returns (uint256);
    function isOperatorRegistered(address operator) external view returns (bool);
    function registerOperator() external;

    // ============ UEI (Universal Encrypted Intent) SYSTEM ============

    // UEI status tracking
    enum UEIStatus {
        Pending,
        Processing,
        Executed,
        Failed,
        Expired
    }

    // UEI task structure (minimal storage - ctBlob emitted in events only)
    struct UEITask {
        bytes32 intentId;
        address submitter;
        bytes32 batchId;         // Which batch this trade belongs to
        uint256 deadline;
        UEIStatus status;
    }

    // Trade batch structure for batching similar trades
    struct TradeBatch {
        bytes32[] intentIds;     // Trade IDs in this batch
        uint256 createdAt;       // Timestamp when batch created
        uint256 finalizedAt;     // Timestamp when finalized
        bool finalized;          // Whether finalized
        bool executed;           // Whether executed
        address[] selectedOperators; // Operators for this batch
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
    event TradeSubmitted(
        bytes32 indexed tradeId,
        address indexed submitter,
        bytes32 indexed batchId,
        bytes ctBlob,           // Operators decode this off-chain
        uint256 deadline
    );

    event UEIBatchFinalized(
        bytes32 indexed batchId,
        address[] selectedOperators,
        uint256 finalizedAt
    );

    event UEIProcessed(
        bytes32 indexed intentId,
        bool success,
        bytes result
    );

    event BoringVaultSet(address indexed vault);

    // UEI functions
    // Note: Import FHE types from @fhenixprotocol/cofhe-contracts/FHE.sol
    function submitEncryptedUEI(
        InEaddress calldata decoder,
        InEaddress calldata target,
        InEuint32 calldata selector,
        DynamicInE[] calldata args,
        uint256 deadline
    ) external returns (bytes32 intentId);

    function finalizeUEIBatch() external;

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
    function getTradeBatch(bytes32 batchId) external view returns (TradeBatch memory);
}