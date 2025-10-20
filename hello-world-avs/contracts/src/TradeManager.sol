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
import {ITradeManager, DynamicInE} from "./ITradeManager.sol";
import {SimpleBoringVault} from "./SimpleBoringVault.sol";
import {DynamicFHE} from "./DynamicFHE.sol";
import "@eigenlayer/contracts/interfaces/IRewardsCoordinator.sol";
import {IAllocationManager} from "@eigenlayer/contracts/interfaces/IAllocationManager.sol";
// Fhenix CoFHE imports
import {FHE, InEuint128, InEuint32, InEuint256, InEuint64, InEaddress, euint128, euint256, euint64, euint32, eaddress, ebool} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

// Simple struct for emitting internal FHE handles with type information
struct HandleWithType {
    uint256 handle;
    uint8 utype;
}

/**
 * @title TradeManager - AVS for encrypted strategy tournaments (CipherTradeArena)
 * @notice Manages operator selection, FHE decryption, and strategy simulation
 * @dev Operators decrypt strategies, simulate off-chain, and post encrypted APYs
 */
contract TradeManager is ECDSAServiceManagerBase, ITradeManager {
    using ECDSAUpgradeable for bytes32;

    // Committee configuration
    uint256 public constant COMMITTEE_SIZE = 1; // Number of operators per batch
    uint256 public constant MIN_ATTESTATIONS = 1; // Minimum signatures for consensus
    address public admin;
    
    // Track registered operators for selection
    address[] public registeredOperators;
    mapping(address => bool) public operatorRegistered;
    mapping(address => uint256) public operatorIndex;

    // ========================================= CIPHER TRADE ARENA STATE =========================================

    // Epoch management
    uint256 public currentEpochNumber;
    mapping(uint256 => EpochData) public epochs;
    mapping(uint256 => mapping(address => bool)) public hasSubmittedStrategy;
    mapping(uint256 => address[]) public epochSubmitters; // List of submitters per epoch
    mapping(uint256 => mapping(address => StrategyPerf)) public strategies; // epoch => submitter => strategy

    // Epoch state enum
    enum EpochState {
        OPEN,              // Accepting strategy submissions
        CLOSED,            // Submissions closed, operators simulating
        RESULTS_POSTED,    // Encrypted APYs posted
        FINALIZED,         // APYs decrypted, winners selected
        EXECUTED           // Capital deployed
    }

    // Strategy node: single encrypted DeFi action
    struct StrategyNode {
        eaddress encoder;    // Sanitizer/decoder address (encrypted)
        eaddress target;     // Protocol address: Aave, Compound, etc. (encrypted)
        euint32 selector;    // Function selector as uint (encrypted)
        euint256[] args;     // All function arguments as euint256 (encrypted)
    }

    // Strategy performance tracking
    struct StrategyPerf {
        StrategyNode[] nodes;      // Array of encrypted strategy nodes
        euint256 encryptedAPY;     // Encrypted APY result (set by AVS)
        address submitter;         // Strategy owner
        uint256 submittedAt;       // Submission timestamp
        bool finalized;            // Whether APY has been decrypted
    }

    // Epoch configuration and metadata
    struct EpochData {
        euint64 encSimStartTime;   // Encrypted simulation window start (prevents overfitting)
        euint64 encSimEndTime;     // Encrypted simulation window end
        uint64 epochStartTime;     // Public submission open time
        uint64 epochEndTime;       // Public submission close time
        uint8[] weights;           // Capital allocation weights [50, 30, 20] for top K
        uint256 notionalPerTrader; // Fixed simulation amount (e.g., 100k USDC)
        uint256 allocatedCapital;  // Real capital to deploy (e.g., 1M USDC)
        EpochState state;          // Current epoch state
        address[] selectedOperators; // Operators selected for this epoch
        uint256 createdAt;         // Epoch creation timestamp
    }

    // Winner tracking (after finalization)
    struct Winner {
        address trader;
        uint256 decryptedAPY;      // Decrypted APY value
        uint256 allocation;        // Capital allocation based on weights
    }
    mapping(uint256 => Winner[]) public epochWinners; // epoch => winners array

    // ========================================= UEI STATE VARIABLES =========================================

    // UEI (Universal Encrypted Intent) management
    mapping(bytes32 => UEITask) public ueiTasks;
    mapping(bytes32 => UEIExecution) public ueiExecutions;

    // Store FHE handles for operator permission grants (not exposed publicly)
    struct FHEHandles {
        eaddress decoder;
        eaddress target;
        euint32 selector;
        euint256[] args;
    }
    mapping(bytes32 => FHEHandles) internal ueiHandles;

    // Trade batch management (keeper-triggered batching)
    // NOTE: Off-chain keeper bot should call finalizeUEIBatch() every few minutes
    // or whenever idle time exceeds MAX_BATCH_IDLE to seal batches and grant decrypt permissions
    uint256 public constant MAX_BATCH_IDLE = 1 minutes;
    uint256 public lastTradeBatchExecutionTime;
    uint256 public currentBatchCounter; // Incremental batch counter
    mapping(uint256 => bytes32) public batchCounterToBatchId; // Counter -> BatchId mapping
    mapping(bytes32 => TradeBatch) public tradeBatches; // BatchId -> Batch data

    // SimpleBoringVault for executing trades
    address payable public boringVault;

    modifier onlyOperator() {
        require(
            operatorRegistered[msg.sender],
            "Operator must be the caller"
        );
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }
    
    constructor(
        address _avsDirectory,
        address _stakeRegistry,
        address _rewardsCoordinator,
        address _delegationManager,
        address _allocationManager,
        address _admin
    )
        ECDSAServiceManagerBase(
            _avsDirectory,
            _stakeRegistry,
            _rewardsCoordinator,
            _delegationManager,
            _allocationManager
        )
    {
        admin = _admin;
    }

    function initialize(address initialOwner, address _rewardsInitiator) external initializer {
        __ServiceManagerBase_init(initialOwner, _rewardsInitiator);
        admin = initialOwner;
    }

    /**
     * @notice Check if an operator is registered
     * @param operator The operator address to check
     * @return Whether the operator is registered
     */
    function isOperatorRegistered(address operator) external view returns (bool) {
        return operatorRegistered[operator];
    }

    /**
     * @notice Register an operator for epoch processing
     */
    function registerOperator() external {
        require(!operatorRegistered[msg.sender], "Operator already registered");

        operatorRegistered[msg.sender] = true;
        operatorIndex[msg.sender] = registeredOperators.length;
        registeredOperators.push(msg.sender);

        emit OperatorRegistered(msg.sender);
    }

    /**
     * @notice Get the total number of registered operators
     */
    function getOperatorCount() external view returns (uint256) {
        return registeredOperators.length;
    }

    // IServiceManager compliance functions (unused but required)
    function addPendingAdmin(address newAdmin) external onlyAdmin {}
    function removePendingAdmin(address pendingAdmin) external onlyAdmin {}
    function removeAdmin(address adminToRemove) external onlyAdmin {}
    function setAppointee(address appointee, address target, bytes4 selector) external onlyAdmin {}
    function removeAppointee(address appointee, address target, bytes4 selector) external onlyAdmin {}
    function deregisterOperatorFromOperatorSets(address operator, uint32[] memory operatorSetIds) external {}

    event OperatorRegistered(address indexed operator);

    // ========================================= CIPHER TRADE ARENA EVENTS =========================================

    event EpochStarted(
        uint256 indexed epochNumber,
        uint64 epochStartTime,
        uint64 epochEndTime,
        uint8[] weights,
        uint256 notionalPerTrader,
        uint256 allocatedCapital
    );

    event StrategySubmitted(
        uint256 indexed epochNumber,
        address indexed submitter,
        uint256 nodeCount,
        uint256 submittedAt
    );

    event EpochClosed(
        uint256 indexed epochNumber,
        address[] selectedOperators,
        uint256 submitterCount
    );

    event EncryptedAPYsPosted(
        uint256 indexed epochNumber,
        uint256 strategyCount
    );

    event EpochFinalized(
        uint256 indexed epochNumber,
        address[] winners,
        uint256[] apys,
        uint256[] allocations
    );

    event EpochExecuted(
        uint256 indexed epochNumber,
        uint256 totalDeployed
    );

    /**
     * @notice Deterministically select operators for an epoch
     * @dev Used for epoch-based operator selection in CipherTradeArena
     */
    function _selectOperatorsForEpoch(uint256 epochNumber) internal view returns (address[] memory) {
        uint256 operatorCount = registeredOperators.length;

        // If not enough operators, return all available
        if (operatorCount <= COMMITTEE_SIZE) {
            return registeredOperators;
        }

        // Use epoch number for deterministic randomness
        uint256 seed = uint256(keccak256(abi.encode(block.prevrandao, block.number, epochNumber)));

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

    // ========================================= CIPHER TRADE ARENA FUNCTIONS =========================================

    /**
     * @notice Start a new epoch for strategy submissions
     * @param encSimStartTime Encrypted simulation window start time
     * @param encSimEndTime Encrypted simulation window end time
     * @param epochDuration Duration in seconds for strategy submissions
     * @param weights Capital allocation weights for top K winners (must sum to 100)
     * @param notionalPerTrader Fixed simulation amount (e.g., 100k USDC)
     * @param allocatedCapital Real capital to deploy (e.g., 1M USDC)
     */
    function startEpoch(
        InEuint64 calldata encSimStartTime,
        InEuint64 calldata encSimEndTime,
        uint64 epochDuration,
        uint8[] calldata weights,
        uint256 notionalPerTrader,
        uint256 allocatedCapital
    ) external onlyAdmin {
        // Validate weights sum to 100
        uint256 totalWeight;
        for (uint256 i = 0; i < weights.length; i++) {
            totalWeight += weights[i];
        }
        require(totalWeight == 100, "Weights must sum to 100");
        require(epochDuration > 0, "Duration must be positive");
        require(notionalPerTrader > 0, "Notional must be positive");
        require(allocatedCapital > 0, "Allocated capital must be positive");

        // Increment epoch counter
        currentEpochNumber++;
        uint256 epochNumber = currentEpochNumber;

        // Load encrypted simulation times
        euint64 simStart = FHE.asEuint64(encSimStartTime);
        euint64 simEnd = FHE.asEuint64(encSimEndTime);

        // Grant contract permission to use encrypted times
        FHE.allowThis(simStart);
        FHE.allowThis(simEnd);

        // Create epoch data
        uint64 startTime = uint64(block.timestamp);
        uint64 endTime = startTime + epochDuration;

        epochs[epochNumber] = EpochData({
            encSimStartTime: simStart,
            encSimEndTime: simEnd,
            epochStartTime: startTime,
            epochEndTime: endTime,
            weights: weights,
            notionalPerTrader: notionalPerTrader,
            allocatedCapital: allocatedCapital,
            state: EpochState.OPEN,
            selectedOperators: new address[](0), // Will be set in closeEpoch
            createdAt: block.timestamp
        });

        emit EpochStarted(
            epochNumber,
            startTime,
            endTime,
            weights,
            notionalPerTrader,
            allocatedCapital
        );
    }

    // ============================= UEI FUNCTIONALITY =============================
    
    /*
     * NOTE: Two different FHE handling approaches:
     * 
     * 1. finalizeBatch() - Internal FHE Types:
     *    - Receives data from UniversalPrivacyHook which already has euint128 types
     *    - Uses euint128.unwrap() to get handles and euint128.wrap() to restore
     *    - Hook grants transient permissions with FHE.allowTransient()
     *    - No FHE.fromExternal() needed - data is already internal FHE format
     * 
     * 2. submitUEIWithProof() - External FHE Types:
     *    - Receives encrypted data from client with input proof
     *    - Uses FHE.fromExternal() to convert external handles to internal types
     *    - Requires input proof validation for security
     *    - Grants explicit permissions with FHE.allow()
     */

    /**
     * @notice Submit a Universal Encrypted Intent (UEI) with batching (Dynamic typing support)
     * @param decoder Encrypted decoder address with signature
     * @param target Encrypted target address with signature
     * @param selector Encrypted selector with signature
     * @param args Array of dynamically-typed encrypted arguments
     * @param deadline Expiration timestamp for the intent
     * @return ueiId Unique identifier for the submitted UEI
     */
    function submitEncryptedUEI(
        InEaddress calldata decoder,
        InEaddress calldata target,
        InEuint32 calldata selector,
        DynamicInE[] calldata args,
        uint256 deadline
    ) external returns (bytes32 ueiId) {
        // Generate unique UEI ID (use ctHash from each encrypted input)
        ueiId = keccak256(abi.encode(msg.sender, decoder.ctHash, target.ctHash, selector.ctHash, deadline, block.number));

        // Get or create current UEI batch (keeper-triggered rolling batch)
        bytes32 batchId = batchCounterToBatchId[currentBatchCounter];
        TradeBatch storage batch = tradeBatches[batchId];

        // Create new batch if none exists
        if (batchId == bytes32(0)) {
            currentBatchCounter++; // Increment counter for new batch
            batchId = keccak256(abi.encode("UEI_BATCH", currentBatchCounter, block.number, block.timestamp));
            batchCounterToBatchId[currentBatchCounter] = batchId;
            tradeBatches[batchId] = TradeBatch({
                intentIds: new bytes32[](0),
                createdAt: block.timestamp,
                finalizedAt: 0,
                finalized: false,
                executed: false,
                selectedOperators: new address[](0)
            });
            batch = tradeBatches[batchId];
        }

        // Grant FHE permissions and store handles for later operator access (Fhenix CoFHE)
        _grantFHEPermissions(ueiId, decoder, target, selector, args);

        // Create minimal UEI task (no ctBlob storage - emitted in event!)
        ueiTasks[ueiId] = UEITask({
            intentId: ueiId,
            submitter: msg.sender,
            batchId: batchId,
            deadline: deadline,
            status: UEIStatus.Pending
        });

        // Add to current batch
        batch.intentIds.push(ueiId);

        // Get stored internal handles for event emission
        FHEHandles storage handles = ueiHandles[ueiId];

        // Create HandleWithType structs with internal handles and original utypes
        HandleWithType memory decoderHT = HandleWithType({
            handle: eaddress.unwrap(handles.decoder),
            utype: decoder.utype
        });

        HandleWithType memory targetHT = HandleWithType({
            handle: eaddress.unwrap(handles.target),
            utype: target.utype
        });

        HandleWithType memory selectorHT = HandleWithType({
            handle: euint32.unwrap(handles.selector),
            utype: selector.utype
        });

        HandleWithType[] memory argsHT = new HandleWithType[](handles.args.length);
        for (uint256 i = 0; i < handles.args.length; i++) {
            argsHT[i] = HandleWithType({
                handle: euint256.unwrap(handles.args[i]),
                utype: args[i].utype
            });
        }

        // Emit event with internal handles + utypes (operators can now decrypt!)
        emit TradeSubmitted(ueiId, msg.sender, batchId, abi.encode(decoderHT, targetHT, selectorHT, argsHT), deadline);

        return ueiId;
    }

    /**
     * @notice Verify and internalize FHE handles (Fhenix CoFHE version with dynamic typing)
     * @dev Validates signatures and stores handles for later operator permission grants
     *      Permission grants are type-agnostic (only care about uint256 handle)
     *      Original utypes are preserved in event emission for operator decryption
     * @param ueiId The UEI identifier to map handles to
     * @param decoder Encrypted decoder address with signature
     * @param target Encrypted target address with signature
     * @param selector Encrypted selector with signature
     * @param args Array of dynamically-typed encrypted arguments with signatures
     */
    function _grantFHEPermissions(
        bytes32 ueiId,
        InEaddress calldata decoder,
        InEaddress calldata target,
        InEuint32 calldata selector,
        DynamicInE[] calldata args
    ) internal {
        // Convert In* types to internal FHE types (validates signatures)
        eaddress decoderHandle = FHE.asEaddress(decoder);
        eaddress targetHandle = FHE.asEaddress(target);
        euint32 selectorHandle = FHE.asEuint32(selector);

        // Convert all arguments using DynamicFHE library (type-aware loading)
        // Note: FHE permission system only cares about unwrapped uint256 handles
        // Original utypes preserved in event for operator decryption
        euint256[] memory argsHandles = new euint256[](args.length);
        for (uint256 i = 0; i < args.length; i++) {
            // Load dynamic encrypted input and get unwrapped handle
            uint256 handle = DynamicFHE.loadDynamic(args[i]);

            // Wrap as euint256 for uniform storage (safe - permissions are handle-based)
            argsHandles[i] = euint256.wrap(handle);

            // Grant permission to this contract (unwraps to same uint256 handle internally)
            FHE.allowThis(argsHandles[i]);
        }

        // Grant to this contract
        FHE.allowThis(decoderHandle);
        FHE.allowThis(targetHandle);
        FHE.allowThis(selectorHandle);

        // Store handles for operator permission grants during finalization
        ueiHandles[ueiId] = FHEHandles({
            decoder: decoderHandle,
            target: targetHandle,
            selector: selectorHandle,
            args: argsHandles
        });
    }

    /**
     * @notice Finalize the current open UEI batch and grant decrypt permissions to operators
     * @dev Can be called by keeper bot every few minutes, or by admin manually
     *      Automatically creates a new batch after finalization for rolling batches
     */
    function finalizeUEIBatch() external {
        // Fetch current open batch using counter
        bytes32 batchId = batchCounterToBatchId[currentBatchCounter];
        require(batchId != bytes32(0), "No active batch");

        TradeBatch storage batch = tradeBatches[batchId];
        require(!batch.finalized, "Batch already finalized");
        require(batch.intentIds.length > 0, "Batch is empty");

        // Require either timeout passed or admin override
        require(
            block.timestamp >= batch.createdAt + MAX_BATCH_IDLE || msg.sender == admin,
            "Batch not ready for finalization"
        );

        // Mark as finalized
        batch.finalized = true;
        batch.finalizedAt = block.timestamp;

        // Select operators using deterministic selection (use batch counter as seed)
        address[] memory selectedOps = _selectOperatorsForEpoch(currentBatchCounter);
        batch.selectedOperators = selectedOps;

        // Grant decrypt permissions to selected operators for all UEIs in this batch
        for (uint256 i = 0; i < batch.intentIds.length; i++) {
            bytes32 intentId = batch.intentIds[i];
            FHEHandles storage handles = ueiHandles[intentId];

            // Grant permissions to each selected operator (similar to swap batch)
            for (uint256 j = 0; j < selectedOps.length; j++) {
                FHE.allow(handles.decoder, selectedOps[j]);
                FHE.allow(handles.target, selectedOps[j]);
                FHE.allow(handles.selector, selectedOps[j]);

                // Grant for all arguments
                for (uint256 k = 0; k < handles.args.length; k++) {
                    FHE.allow(handles.args[k], selectedOps[j]);
                }
            }
        }

        // Emit finalization event
        emit UEIBatchFinalized(batchId, selectedOps, block.timestamp);

        // Update telemetry
        lastTradeBatchExecutionTime = block.timestamp;

        // Create new batch immediately for rolling batch system
        currentBatchCounter++; // Increment to next batch
        bytes32 newBatchId = keccak256(abi.encode("UEI_BATCH", currentBatchCounter, block.number, block.timestamp));
        batchCounterToBatchId[currentBatchCounter] = newBatchId;
        tradeBatches[newBatchId] = TradeBatch({
            intentIds: new bytes32[](0),
            createdAt: block.timestamp,
            finalizedAt: 0,
            finalized: false,
            executed: false,
            selectedOperators: new address[](0)
        });
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

        // Get the batch and selected operators
        TradeBatch storage batch = tradeBatches[task.batchId];
        require(batch.finalized, "Batch not finalized");
        address[] memory selectedOps = batch.selectedOperators;

        // Verify operator is selected for this batch
        bool isSelected = false;
        for (uint256 i = 0; i < selectedOps.length; i++) {
            if (selectedOps[i] == msg.sender) {
                isSelected = true;
                break;
            }
        }
        require(isSelected, "Operator not selected for this batch");

        // Verify consensus signatures
        uint256 validSignatures = 0;
        bytes32 dataHash = keccak256(abi.encode(intentId, decoder, target, reconstructedData));

        for (uint256 i = 0; i < operatorSignatures.length && i < selectedOps.length; i++) {
            address signer = dataHash.toEthSignedMessageHash().recover(operatorSignatures[i]);

            // Check if signer is a selected operator
            for (uint256 j = 0; j < selectedOps.length; j++) {
                if (selectedOps[j] == signer) {
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
    function setBoringVault(address payable _vault) external onlyAdmin {
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

    /**
     * @notice Get trade batch details
     * @param batchId The ID of the batch
     * @return The TradeBatch struct
     */
    function getTradeBatch(bytes32 batchId) external view returns (TradeBatch memory) {
        return tradeBatches[batchId];
    }
}