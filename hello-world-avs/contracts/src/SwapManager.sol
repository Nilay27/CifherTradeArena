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
import {SimpleBoringVault} from "./SimpleBoringVault.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@eigenlayer/contracts/interfaces/IRewardsCoordinator.sol";
import {IAllocationManager} from "@eigenlayer/contracts/interfaces/IAllocationManager.sol";
import "forge-std/console.sol";

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

    // ========================================= UEI STATE VARIABLES =========================================

    // UEI (Universal Encrypted Intent) management
    mapping(bytes32 => UEITask) public ueiTasks;
    mapping(bytes32 => UEIExecution) public ueiExecutions;

    // SimpleBoringVault for executing trades
    address payable public boringVault;

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
        (bytes32[] memory intentIds, ) = abi.decode(batchData, (bytes32[], address));
        
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
        
        // Log internalized transfers with encrypted amounts for debugging
        for (uint256 i = 0; i < settlement.internalizedTransfers.length; i++) {
            TokenTransfer memory transfer = settlement.internalizedTransfers[i];
            console.log("Internalized Transfer", i);
            console.log("  Intent A:", uint256(transfer.intentIdA));
            console.log("  Intent B:", uint256(transfer.intentIdB));
            console.log("  User A:", transfer.userA);
            console.log("  User B:", transfer.userB);
            console.log("  Token A:", transfer.tokenA);
            console.log("  Token B:", transfer.tokenB);
            console.log("  Encrypted Amount A length:", transfer.encryptedAmountA.length);
            console.log("  Encrypted Amount B length:", transfer.encryptedAmountB.length);
            // Log first 32 bytes of encrypted data as uint256 for visibility
            if (transfer.encryptedAmountA.length >= 32) {
                bytes memory encDataA = transfer.encryptedAmountA;
                uint256 encAmountA;
                assembly {
                    encAmountA := mload(add(encDataA, 0x20))
                }
                console.log("  Encrypted Amount A (first 32 bytes as uint):", encAmountA);
            }
            if (transfer.encryptedAmountB.length >= 32) {
                bytes memory encDataB = transfer.encryptedAmountB;
                uint256 encAmountB;
                assembly {
                    encAmountB := mload(add(encDataB, 0x20))
                }
                console.log("  Encrypted Amount B (first 32 bytes as uint):", encAmountB);
            }
        }
        
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
    
    // ============ LEGACY SINGLE TASK SYSTEM - Stub implementations for test compatibility ============
    uint32 private _taskCounter;
    mapping(uint32 => bytes32) public override allTaskHashes;
    mapping(address => mapping(uint32 => bytes)) public override allTaskResponses;
    mapping(uint32 => ISwapManager.SwapTask) private _tasks;
    
    function latestTaskNum() external view override returns (uint32) {
        return _taskCounter;
    }
    
    function getTask(uint32 taskIndex) external view override returns (SwapTask memory) {
        return _tasks[taskIndex];
    }
    
    function createNewSwapTask(
        address user,
        address tokenIn,
        address tokenOut,
        bytes calldata encryptedAmount,
        uint64 deadline
    ) external override returns (SwapTask memory) {
        // Stub implementation - real functionality in batch system
        SwapTask memory task = SwapTask({
            hook: msg.sender,
            user: user,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            encryptedAmount: encryptedAmount,
            deadline: deadline,
            taskCreatedBlock: uint32(block.number),
            selectedOperators: new address[](0)
        });
        
        _tasks[_taskCounter] = task;
        allTaskHashes[_taskCounter] = keccak256(abi.encode(task));
        emit NewSwapTaskCreated(_taskCounter, task);
        _taskCounter++;
        
        return task;
    }
    
    function respondToSwapTask(
        SwapTask calldata task,
        uint32 referenceTaskIndex,
        uint256 decryptedAmount,
        bytes calldata signature
    ) external override {
        // Stub - just emit event for compatibility
        allTaskResponses[msg.sender][referenceTaskIndex] = signature;
        emit SwapTaskResponded(referenceTaskIndex, task, msg.sender, decryptedAmount);
    }
    
    function slashOperator(
        SwapTask calldata,
        uint32,
        address
    ) external override {
        revert("Slashing not implemented");
    }
    
    // Test compatibility functions
    function createNewTask(string memory name) external override returns (ISwapManager.Task memory) {
        return ISwapManager.Task({
            name: name,
            taskCreatedBlock: uint32(block.number)
        });
    }
    
    function respondToTask(
        ISwapManager.Task calldata, 
        uint32, 
        bytes calldata
    ) external override {
        // Stub for test compatibility
    }
    
    function slashOperator(
        ISwapManager.Task calldata,
        uint32,
        address
    ) external override {
        revert("Slashing not implemented");
    }

    // ========================================= UEI (Universal Encrypted Intent) FUNCTIONALITY =========================================

    /**
     * @notice Submit a Universal Encrypted Intent for trade execution
     * @param ctBlob Encrypted blob containing decoder, target, selector, and arguments
     * @param deadline Expiration timestamp for the intent
     * @return intentId Unique identifier for the submitted intent
     */
    function submitUEI(
        bytes calldata ctBlob,
        uint256 deadline
    ) external onlyAuthorizedHook returns (bytes32 intentId) {
        // Generate unique intent ID
        intentId = keccak256(abi.encode(msg.sender, ctBlob, deadline, block.number));

        // Select operators for this UEI (reuse batch selection logic)
        address[] memory selectedOps = new address[](COMMITTEE_SIZE);
        uint256 seed = uint256(intentId);

        for (uint256 i = 0; i < COMMITTEE_SIZE && i < registeredOperators.length; i++) {
            uint256 index = (seed + i) % registeredOperators.length;
            selectedOps[i] = registeredOperators[index];
        }

        // Create UEI task
        UEITask memory task = UEITask({
            intentId: intentId,
            submitter: msg.sender,
            ctBlob: ctBlob,
            deadline: deadline,
            blockSubmitted: block.number,
            selectedOperators: selectedOps,
            status: UEIStatus.Pending
        });

        // Store the task
        ueiTasks[intentId] = task;

        emit UEISubmitted(intentId, msg.sender, ctBlob, deadline, selectedOps);
        return intentId;
    }

    /**
     * @notice Process a decrypted UEI by executing the trade
     * @param intentId The ID of the intent to process
     * @param decoder The decrypted decoder/sanitizer address
     * @param target The decrypted target protocol address
     * @param reconstructedData The reconstructed calldata from decrypted components
     * @param operatorSignatures Signatures from operators attesting to the decryption
     */
    function processUEI(
        bytes32 intentId,
        address decoder,
        address target,
        bytes calldata reconstructedData,
        bytes[] calldata operatorSignatures
    ) external onlyOperator {
        UEITask storage task = ueiTasks[intentId];

        // Validate task
        require(task.status == UEIStatus.Pending, "UEI not pending");
        require(block.timestamp <= task.deadline, "UEI expired");

        // Verify operator is selected for this task
        bool isSelected = false;
        for (uint256 i = 0; i < task.selectedOperators.length; i++) {
            if (task.selectedOperators[i] == msg.sender) {
                isSelected = true;
                break;
            }
        }
        require(isSelected, "Operator not selected for this UEI");

        // Verify consensus signatures
        uint256 validSignatures = 0;
        bytes32 dataHash = keccak256(abi.encode(intentId, decoder, target, reconstructedData));

        for (uint256 i = 0; i < operatorSignatures.length && i < task.selectedOperators.length; i++) {
            address signer = dataHash.toEthSignedMessageHash().recover(operatorSignatures[i]);

            // Check if signer is a selected operator
            for (uint256 j = 0; j < task.selectedOperators.length; j++) {
                if (task.selectedOperators[j] == signer) {
                    validSignatures++;
                    break;
                }
            }
        }

        require(validSignatures >= MIN_ATTESTATIONS, "Insufficient consensus");

        // Update status
        task.status = UEIStatus.Processing;

        // Store the processing details
        UEIExecution memory execution = UEIExecution({
            intentId: intentId,
            decoder: decoder,
            target: target,
            callData: reconstructedData,  // Fixed field name
            executor: msg.sender,
            executedAt: block.timestamp,
            success: false,
            result: ""
        });

        // Execute through vault (vault address should be set)
        if (boringVault != address(0)) {
            try SimpleBoringVault(boringVault).execute(target, reconstructedData, 0) returns (bytes memory result) {
                execution.success = true;
                execution.result = result;
                task.status = UEIStatus.Executed;
            } catch Error(string memory reason) {
                execution.result = bytes(reason);
                task.status = UEIStatus.Failed;
            } catch (bytes memory reason) {
                execution.result = reason;
                task.status = UEIStatus.Failed;
            }
        } else {
            // If vault not set, just mark as executed for testing
            task.status = UEIStatus.Executed;
            execution.success = true;
        }

        // Store execution record
        ueiExecutions[intentId] = execution;

        emit UEIProcessed(intentId, execution.success, execution.result);
    }

    /**
     * @notice Set the BoringVault address for UEI execution
     * @param _vault The address of the SimpleBoringVault
     */
    function setBoringVault(address payable _vault) external onlyOwner {
        boringVault = _vault;
        emit BoringVaultSet(_vault);
    }

    /**
     * @notice Get UEI task details
     * @param intentId The ID of the UEI task
     * @return The UEI task struct
     */
    function getUEITask(bytes32 intentId) external view returns (UEITask memory) {
        return ueiTasks[intentId];
    }

    /**
     * @notice Get UEI execution details
     * @param intentId The ID of the UEI execution
     * @return The UEI execution struct
     */
    function getUEIExecution(bytes32 intentId) external view returns (UEIExecution memory) {
        return ueiExecutions[intentId];
    }
}