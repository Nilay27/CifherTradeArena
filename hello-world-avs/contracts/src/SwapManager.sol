// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {ECDSAServiceManagerBase} from
    "@eigenlayer-middleware/src/unaudited/ECDSAServiceManagerBase.sol";
import {ECDSAStakeRegistry} from "@eigenlayer-middleware/src/unaudited/ECDSAStakeRegistry.sol";
import {IServiceManager} from "@eigenlayer-middleware/src/interfaces/IServiceManager.sol";
import {ECDSAUpgradeable} from
    "@openzeppelin-upgrades/contracts/utils/cryptography/ECDSAUpgradeable.sol";
import {IERC1271Upgradeable} from
    "@openzeppelin-upgrades/contracts/interfaces/IERC1271Upgradeable.sol";
import {ISwapManager} from "./ISwapManager.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@eigenlayer/contracts/interfaces/IRewardsCoordinator.sol";
import {IAllocationManager} from "@eigenlayer/contracts/interfaces/IAllocationManager.sol";

/**
 * @title SwapManager - AVS for batch processing of encrypted swap intents
 * @notice Manages operator selection, FHE decryption, and batch settlement
 * @dev Operators decrypt intents, match orders off-chain, and submit consensus-based settlements
 */
contract SwapManager is ECDSAServiceManagerBase, ISwapManager {
    using ECDSAUpgradeable for bytes32;

    // Committee configuration
    uint256 public constant COMMITTEE_SIZE = 5; // Number of operators per batch
    uint256 public constant MIN_ATTESTATIONS = 3; // Minimum signatures for consensus
    
    // Track registered operators for selection
    address[] public registeredOperators;
    mapping(address => bool) public isOperatorRegistered;
    mapping(address => uint256) public operatorIndex;

    // Batch management
    mapping(bytes32 => Batch) public batches;
    mapping(bytes32 => mapping(address => bool)) public operatorSelectedForBatch;
    mapping(bytes32 => BatchSettlement) public batchSettlements;
    mapping(bytes32 => uint256) public settlementSignatureCount;
    
    // Hook authorization
    mapping(address => bool) public authorizedHooks;

    // Max time for operators to respond with settlement
    uint32 public immutable MAX_RESPONSE_INTERVAL_BLOCKS;

    modifier onlyOperator() {
        require(
            ECDSAStakeRegistry(stakeRegistry).operatorRegistered(msg.sender),
            "Operator must be the caller"
        );
        _;
    }
    
    modifier onlyAuthorizedHook() {
        require(authorizedHooks[msg.sender], "Unauthorized hook");
        _;
    }

    constructor(
        address _avsDirectory,
        address _stakeRegistry,
        address _rewardsCoordinator,
        address _delegationManager,
        address _allocationManager,
        uint32 _maxResponseIntervalBlocks
    )
        ECDSAServiceManagerBase(
            _avsDirectory,
            _stakeRegistry,
            _rewardsCoordinator,
            _delegationManager,
            _allocationManager
        )
    {
        MAX_RESPONSE_INTERVAL_BLOCKS = _maxResponseIntervalBlocks;
    }

    function initialize(address initialOwner, address _rewardsInitiator) external initializer {
        __ServiceManagerBase_init(initialOwner, _rewardsInitiator);
    }
    
    /**
     * @notice Authorize a hook to submit batches
     */
    function authorizeHook(address hook) external onlyOwner {
        authorizedHooks[hook] = true;
    }
    
    /**
     * @notice Revoke hook authorization
     */
    function revokeHook(address hook) external onlyOwner {
        authorizedHooks[hook] = false;
    }

    /**
     * @notice Register an operator for batch processing
     */
    function registerOperatorForBatches() external {
        require(
            ECDSAStakeRegistry(stakeRegistry).operatorRegistered(msg.sender),
            "Must be registered with stake registry first"
        );
        require(!isOperatorRegistered[msg.sender], "Operator already registered");
        
        isOperatorRegistered[msg.sender] = true;
        operatorIndex[msg.sender] = registeredOperators.length;
        registeredOperators.push(msg.sender);
    }
    
    /**
     * @notice Deregister an operator from batch processing
     */
    function deregisterOperatorFromBatches() external {
        require(isOperatorRegistered[msg.sender], "Operator not registered");
        
        uint256 index = operatorIndex[msg.sender];
        uint256 lastIndex = registeredOperators.length - 1;
        
        if (index != lastIndex) {
            address lastOperator = registeredOperators[lastIndex];
            registeredOperators[index] = lastOperator;
            operatorIndex[lastOperator] = index;
        }
        
        registeredOperators.pop();
        delete operatorIndex[msg.sender];
        isOperatorRegistered[msg.sender] = false;
    }

    /**
     * @notice Called by hook when batch is ready for processing
     * @param batchId The unique batch identifier
     * @param batchData Encoded intent data (intentIds, poolKey, etc.)
     */
    function finalizeBatch(
        bytes32 batchId,
        bytes calldata batchData
    ) external override onlyAuthorizedHook {
        require(batches[batchId].status == BatchStatus.Collecting || 
                batches[batchId].batchId == bytes32(0), "Invalid batch status");
        
        // Decode batch data to get intent count
        (bytes32[] memory intentIds, ) = abi.decode(batchData, (bytes32[], bytes));
        
        // Select operators for this batch
        address[] memory selectedOps = _selectOperatorsForBatch(batchId);
        
        // Create batch record
        batches[batchId] = Batch({
            batchId: batchId,
            intentIds: intentIds,
            poolId: address(0), // Could decode from batchData if needed
            hook: msg.sender,
            createdBlock: uint32(block.number),
            finalizedBlock: uint32(block.number),
            status: BatchStatus.Processing
        });
        
        // Mark selected operators
        for (uint256 i = 0; i < selectedOps.length; i++) {
            operatorSelectedForBatch[batchId][selectedOps[i]] = true;
            emit OperatorSelectedForBatch(batchId, selectedOps[i]);
        }
        
        emit BatchFinalized(batchId, batchData);
    }
    
    /**
     * @notice Submit batch settlement after off-chain matching
     * @param settlement The settlement instructions
     * @param operatorSignatures Signatures from consensus operators
     */
    function submitBatchSettlement(
        BatchSettlement calldata settlement,
        bytes[] calldata operatorSignatures
    ) external override {
        Batch storage batch = batches[settlement.batchId];
        require(batch.status == BatchStatus.Processing, "Batch not processing");
        require(
            block.number <= batch.finalizedBlock + MAX_RESPONSE_INTERVAL_BLOCKS,
            "Settlement window expired"
        );
        
        // Verify we have enough signatures
        require(operatorSignatures.length >= MIN_ATTESTATIONS, "Insufficient signatures");
        
        // Create message hash from settlement data
        bytes32 messageHash = keccak256(abi.encode(settlement));
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        
        // Verify each signature is from a selected operator
        uint256 validSignatures = 0;
        for (uint256 i = 0; i < operatorSignatures.length; i++) {
            address signer = ethSignedMessageHash.recover(operatorSignatures[i]);
            
            // Check if signer was selected for this batch
            if (operatorSelectedForBatch[settlement.batchId][signer]) {
                validSignatures++;
            }
        }
        
        require(validSignatures >= MIN_ATTESTATIONS, "Insufficient valid signatures");
        
        // Store settlement
        batchSettlements[settlement.batchId] = settlement;
        batch.status = BatchStatus.Settled;
        
        // Call back to hook to execute settlement
        // In production, this would be done through the hook's settleBatch function
        // For now, we just emit an event
        emit BatchSettlementSubmitted(
            settlement.batchId,
            settlement.internalizedTransfers.length,
            settlement.hasNetSwap ? 1 : 0
        );
        
        // TODO: Call hook.settleBatch() with the settlement data
        // IPrivacyHook(batch.hook).settleBatch(
        //     settlement.batchId,
        //     settlement.internalizedTransfers,
        //     settlement.netSwap,
        //     settlement.hasNetSwap
        // );
        
        emit BatchSettled(settlement.batchId, true);
    }
    
    /**
     * @notice Deterministically select operators for a batch
     */
    function _selectOperatorsForBatch(bytes32 batchId) internal view returns (address[] memory) {
        uint256 operatorCount = registeredOperators.length;
        
        // If not enough operators, return all available
        if (operatorCount <= COMMITTEE_SIZE) {
            return registeredOperators;
        }
        
        // Use batch ID and block data for deterministic randomness
        uint256 seed = uint256(keccak256(abi.encode(block.prevrandao, block.number, batchId)));
        
        address[] memory selectedOps = new address[](COMMITTEE_SIZE);
        bool[] memory selected = new bool[](operatorCount);
        
        for (uint256 i = 0; i < COMMITTEE_SIZE; i++) {
            uint256 randomIndex = uint256(keccak256(abi.encode(seed, i))) % operatorCount;
            
            // Linear probing to avoid duplicates
            while (selected[randomIndex]) {
                randomIndex = (randomIndex + 1) % operatorCount;
            }
            
            selected[randomIndex] = true;
            selectedOps[i] = registeredOperators[randomIndex];
        }
        
        return selectedOps;
    }
    
    // View functions
    function getBatch(bytes32 batchId) external view override returns (Batch memory) {
        return batches[batchId];
    }
    
    function getOperatorCount() external view override returns (uint256) {
        return registeredOperators.length;
    }
    
    function isOperatorSelectedForBatch(
        bytes32 batchId, 
        address operator
    ) external view override returns (bool) {
        return operatorSelectedForBatch[batchId][operator];
    }
    
    // IServiceManager compliance functions (unused but required)
    function addPendingAdmin(address admin) external onlyOwner {}
    function removePendingAdmin(address pendingAdmin) external onlyOwner {}
    function removeAdmin(address admin) external onlyOwner {}
    function setAppointee(address appointee, address target, bytes4 selector) external onlyOwner {}
    function removeAppointee(address appointee, address target, bytes4 selector) external onlyOwner {}
    function deregisterOperatorFromOperatorSets(address operator, uint32[] memory operatorSetIds) external {}
}