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
import {FHE, InEuint128, InEuint32, InEuint256, InEuint64, InEuint16, InEaddress, euint128, euint256, euint64, euint32, euint16, eaddress, ebool} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

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
        OPEN,       // Accepting submissions, operators posting APYs in real-time
        CLOSED,     // Submission period ended, decryption requested
        FINALIZED,  // APYs decrypted, winners selected
        EXECUTED    // Capital deployed via BoringVault
    }

    // Strategy node: single encrypted DeFi action
    struct StrategyNode {
        eaddress encoder;    // Sanitizer/decoder address (encrypted)
        eaddress target;     // Protocol address: Aave, Compound, etc. (encrypted)
        euint32 selector;    // Function selector as uint (encrypted)
        HandleWithType[] args;  // Function arguments with type info (handle + utype)
    }

    // Strategy performance tracking
    struct StrategyPerf {
        StrategyNode[] nodes;      // Array of encrypted strategy nodes
        euint16 encryptedAPY;      // Encrypted APY in basis points (e.g., 1234 = 12.34%)
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

    // SimpleBoringVault for executing aggregated strategies
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

    event APYReported(
        uint256 indexed epochNumber,
        address indexed submitter,
        address indexed operator,
        uint256 timestamp
    );

    event EpochClosed(
        uint256 indexed epochNumber,
        uint256 totalStrategies,
        uint256 timestamp
    );

    event EpochFinalized(
        uint256 indexed epochNumber,
        address[] winners,
        uint256[] decryptedAPYs,
        uint256[] allocations
    );

    event EpochExecuted(
        uint256 indexed epochNumber,
        uint256 totalDeployed
    );

    event StrategyExecutionFailed(
        uint256 indexed epochNumber,
        address indexed target,
        bytes calldata_data
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
        require(registeredOperators.length > 0, "No operators registered");

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

        // Select operators for this epoch
        address[] memory selectedOps = _selectOperatorsForEpoch(epochNumber);

        // Grant selected operators permission to decrypt simulation times
        for (uint256 i = 0; i < selectedOps.length; i++) {
            FHE.allow(simStart, selectedOps[i]);
            FHE.allow(simEnd, selectedOps[i]);
        }

        epochs[epochNumber] = EpochData({
            encSimStartTime: simStart,
            encSimEndTime: simEnd,
            epochStartTime: startTime,
            epochEndTime: endTime,
            weights: weights,
            notionalPerTrader: notionalPerTrader,
            allocatedCapital: allocatedCapital,
            state: EpochState.OPEN,
            selectedOperators: selectedOps,
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

    /**
     * @notice Submit encrypted strategy for current epoch
     * @dev Strategy nodes contain encrypted DeFi operations (encoder, target, selector, args)
     * @param encoders Array of encrypted encoder/sanitizer addresses
     * @param targets Array of encrypted target protocol addresses
     * @param selectors Array of encrypted function selectors
     * @param nodeArgs Array of arrays containing dynamically-typed encrypted arguments for each node
     */
    function submitEncryptedStrategy(
        InEaddress[] calldata encoders,
        InEaddress[] calldata targets,
        InEuint32[] calldata selectors,
        DynamicInE[][] calldata nodeArgs
    ) external {
        require(currentEpochNumber > 0, "No active epoch");
        EpochData storage epoch = epochs[currentEpochNumber];

        require(epoch.state == EpochState.OPEN, "Epoch not open for submissions");
        require(block.timestamp <= epoch.epochEndTime, "Epoch submission period ended");
        // require(!hasSubmittedStrategy[currentEpochNumber][msg.sender], "Strategy already submitted");

        // Validate all arrays have same length
        require(encoders.length == targets.length, "Array length mismatch");
        require(encoders.length == selectors.length, "Array length mismatch");
        require(encoders.length == nodeArgs.length, "Array length mismatch");
        require(encoders.length > 0, "Strategy must have at least one node");

        // Create strategy performance record
        StrategyPerf storage strategy = strategies[currentEpochNumber][msg.sender];
        strategy.submitter = msg.sender;
        strategy.submittedAt = block.timestamp;
        strategy.finalized = false;

        // Process each strategy node
        for (uint256 i = 0; i < encoders.length; i++) {
            // Convert input encrypted types to internal types
            eaddress encoder = FHE.asEaddress(encoders[i]);
            eaddress target = FHE.asEaddress(targets[i]);
            euint32 selector = FHE.asEuint32(selectors[i]);

            // Grant contract permission to use encrypted values
            FHE.allowThis(encoder);
            FHE.allowThis(target);
            FHE.allowThis(selector);

            // Grant selected operators permission to decrypt for simulation
            for (uint256 k = 0; k < epoch.selectedOperators.length; k++) {
                FHE.allow(encoder, epoch.selectedOperators[k]);
                FHE.allow(target, epoch.selectedOperators[k]);
                FHE.allow(selector, epoch.selectedOperators[k]);
            }

            // Process dynamic encrypted arguments
            HandleWithType[] memory args = new HandleWithType[](nodeArgs[i].length);
            for (uint256 j = 0; j < nodeArgs[i].length; j++) {
                // Load dynamic encrypted input and get unwrapped handle
                uint256 handle = DynamicFHE.loadDynamic(nodeArgs[i][j]);

                // Wrap as euint256 for permissions
                euint256 argHandle = euint256.wrap(handle);
                FHE.allowThis(argHandle);

                // Store as HandleWithType
                args[j] = HandleWithType({
                    handle: handle,
                    utype: nodeArgs[i][j].utype
                });

                // Grant selected operators permission to decrypt arguments
                for (uint256 k = 0; k < epoch.selectedOperators.length; k++) {
                    FHE.allow(argHandle, epoch.selectedOperators[k]);
                }
            }

            // Create and store strategy node
            StrategyNode memory node = StrategyNode({
                encoder: encoder,
                target: target,
                selector: selector,
                args: args
            });

            strategy.nodes.push(node);
        }

        // Mark submitter as having submitted
        hasSubmittedStrategy[currentEpochNumber][msg.sender] = true;
        epochSubmitters[currentEpochNumber].push(msg.sender);

        emit StrategySubmitted(currentEpochNumber, msg.sender, encoders.length, block.timestamp);
    }

    /**
     * @notice Operator reports encrypted APY for a trader's strategy
     * @dev Can be called anytime during OPEN state as operators simulate in real-time
     * @param epochNumber The epoch number
     * @param trader The trader whose strategy was simulated
     * @param encryptedAPY The encrypted APY in basis points (e.g., 1234 = 12.34%)
     */
    function reportEncryptedAPY(
        uint256 epochNumber,
        address trader,
        InEuint16 calldata encryptedAPY
    ) external onlyOperator {
        require(epochNumber <= currentEpochNumber, "Invalid epoch");
        EpochData storage epoch = epochs[epochNumber];
        require(epoch.state == EpochState.OPEN, "Epoch not open");
        require(hasSubmittedStrategy[epochNumber][trader], "No strategy submitted");

        // Verify operator is selected for this epoch
        bool isSelected = false;
        for (uint256 i = 0; i < epoch.selectedOperators.length; i++) {
            if (epoch.selectedOperators[i] == msg.sender) {
                isSelected = true;
                break;
            }
        }
        require(isSelected, "Operator not selected for this epoch");

        // Load and store encrypted APY
        StrategyPerf storage strategy = strategies[epochNumber][trader];
        euint16 apy = FHE.asEuint16(encryptedAPY);
        FHE.allowThis(apy);

        // Grant trader permission to decrypt their own APY (for viewMyAPY)
        FHE.allow(apy, trader);

        strategy.encryptedAPY = apy;

        emit APYReported(epochNumber, trader, msg.sender, block.timestamp);
    }

    /**
     * @notice Close epoch and request decryption for all APYs and simulation times
     * @dev Can be called by anyone after epoch duration has passed
     * @param epochNumber The epoch number to close
     */
    function closeEpoch(uint256 epochNumber) external {
        require(epochNumber <= currentEpochNumber, "Invalid epoch");
        EpochData storage epoch = epochs[epochNumber];

        require(epoch.state == EpochState.OPEN, "Epoch not open");
        // require(block.timestamp > epoch.epochEndTime, "Epoch duration not passed");

        // Decrypt simulation times (reveal the backtesting window)
        FHE.decrypt(epoch.encSimStartTime);
        FHE.decrypt(epoch.encSimEndTime);

        // Request decryption for all submitted strategies' APYs
        address[] memory submitters = epochSubmitters[epochNumber];
        for (uint256 i = 0; i < submitters.length; i++) {
            address trader = submitters[i];
            euint16 encryptedAPY = strategies[epochNumber][trader].encryptedAPY;

            // Decrypt APY (triggers decryption request to CoFHE network)
            // Note: Only decrypt if APY has been reported (non-zero handle)
            if (euint16.unwrap(encryptedAPY) != 0) {
                FHE.decrypt(encryptedAPY);
            }
        }

        epoch.state = EpochState.CLOSED;
        emit EpochClosed(epochNumber, submitters.length, block.timestamp);
    }

    /**
     * @notice Finalize epoch with decrypted APYs and select winners
     * @dev Called by operator after decryption completes off-chain
     * @param epochNumber The epoch number to finalize
     * @param winners Array of winning trader addresses (sorted by APY, highest first)
     * @param decryptedAPYs Array of decrypted APY values (in basis points)
     */
    function finalizeEpoch(
        uint256 epochNumber,
        address[] calldata winners,
        uint256[] calldata decryptedAPYs
    ) external onlyOperator {
        require(epochNumber <= currentEpochNumber, "Invalid epoch");
        EpochData storage epoch = epochs[epochNumber];

        require(epoch.state == EpochState.CLOSED, "Epoch not closed");
        require(winners.length == epoch.weights.length, "Winners length must match weights length");
        require(winners.length == decryptedAPYs.length, "Arrays length mismatch");

        // Verify operator is selected for this epoch
        bool isSelected = false;
        for (uint256 i = 0; i < epoch.selectedOperators.length; i++) {
            if (epoch.selectedOperators[i] == msg.sender) {
                isSelected = true;
                break;
            }
        }
        require(isSelected, "Operator not selected for this epoch");

        // Calculate allocations and store winners
        uint256[] memory allocations = new uint256[](winners.length);
        for (uint256 i = 0; i < winners.length; i++) {
            // Verify winner actually submitted a strategy
            require(hasSubmittedStrategy[epochNumber][winners[i]], "Winner did not submit strategy");

            // Calculate allocation based on weight
            allocations[i] = (epoch.allocatedCapital * epoch.weights[i]) / 100;

            // Store winner
            epochWinners[epochNumber].push(Winner({
                trader: winners[i],
                decryptedAPY: decryptedAPYs[i],
                allocation: allocations[i]
            }));

            // Mark strategy as finalized
            strategies[epochNumber][winners[i]].finalized = true;
        }

        epoch.state = EpochState.FINALIZED;
        emit EpochFinalized(epochNumber, winners, decryptedAPYs, allocations);
    }

    /**
     * @notice Execute aggregated strategies for finalized epoch
     * @dev Called by operator with batched/deduplicated strategy calls
     * @param epochNumber The epoch number to execute
     * @param encoders Array of encoder/sanitizer addresses
     * @param targets Array of target protocol addresses
     * @param calldatas Array of calldata (functionSelector + args)
     * @param operatorSignatures Array of operator signatures for consensus
     */
    function executeEpochTopStrategiesAggregated(
        uint256 epochNumber,
        address[] calldata encoders,
        address[] calldata targets,
        bytes[] calldata calldatas,
        bytes[] calldata operatorSignatures
    ) external onlyOperator {
        require(epochNumber <= currentEpochNumber, "Invalid epoch");
        EpochData storage epoch = epochs[epochNumber];

        require(epoch.state == EpochState.FINALIZED, "Epoch not finalized");
        require(encoders.length == targets.length, "Arrays length mismatch");
        require(targets.length == calldatas.length, "Arrays length mismatch");
        require(targets.length > 0, "No strategies to execute");
        require(boringVault != address(0), "BoringVault not set");

        // Verify operator is selected for this epoch
        bool isSelected = false;
        for (uint256 i = 0; i < epoch.selectedOperators.length; i++) {
            if (epoch.selectedOperators[i] == msg.sender) {
                isSelected = true;
                break;
            }
        }
        require(isSelected, "Operator not selected for this epoch");

        // Verify consensus signatures
        uint256 validSignatures = 0;
        bytes32 dataHash = keccak256(abi.encode(epochNumber, encoders, targets, calldatas));

        for (uint256 i = 0; i < operatorSignatures.length && i < epoch.selectedOperators.length; i++) {
            address signer = dataHash.toEthSignedMessageHash().recover(operatorSignatures[i]);

            // Check if signer is a selected operator
            for (uint256 j = 0; j < epoch.selectedOperators.length; j++) {
                if (epoch.selectedOperators[j] == signer) {
                    validSignatures++;
                    break;
                }
            }
        }

        require(validSignatures >= MIN_ATTESTATIONS, "Insufficient consensus");

        // Execute aggregated strategies via BoringVault
        uint256 successfulExecutions = 0;
        for (uint256 i = 0; i < targets.length; i++) {
            try SimpleBoringVault(boringVault).execute(targets[i], calldatas[i], 0) {
                successfulExecutions++;
            } catch {
                // Log failed execution but continue with others
                emit StrategyExecutionFailed(epochNumber, targets[i], calldatas[i]);
            }
        }

        require(successfulExecutions > 0, "All strategy executions failed");

        // Transition epoch to EXECUTED
        epoch.state = EpochState.EXECUTED;
        emit EpochExecuted(epochNumber, epoch.allocatedCapital);
    }

    /**
     * @notice Set the BoringVault address for strategy execution
     * @param _vault The BoringVault contract address
     */
    function setBoringVault(address payable _vault) external onlyAdmin {
        boringVault = _vault;
        emit BoringVaultSet(_vault);
    }

    // ============================= VIEW FUNCTIONS =============================

    /**
     * @notice Get the encrypted APY for a trader's strategy in an epoch
     * @param epochNumber The epoch number
     * @param trader The trader address
     * @return The encrypted APY (euint16)
     */
    function getEncryptedAPY(uint256 epochNumber, address trader) external view returns (euint16) {
        return strategies[epochNumber][trader].encryptedAPY;
    }

    /**
     * @notice Get the current state of an epoch
     * @param epochNumber The epoch number
     * @return The epoch state
     */
    function getEpochState(uint256 epochNumber) external view returns (EpochState) {
        return epochs[epochNumber].state;
    }

    /**
     * @notice Get decrypted APYs for all strategies in an epoch
     * @dev Returns 0 for APYs that haven't been decrypted yet
     * @param epochNumber The epoch number
     * @return traders Array of trader addresses
     * @return decryptedAPYs Array of decrypted APY values (0 if not yet decrypted)
     * @return decrypted Array of booleans indicating if each APY has been decrypted
     */
    function getDecryptedAPYs(uint256 epochNumber)
        external
        view
        returns (
            address[] memory traders,
            uint256[] memory decryptedAPYs,
            bool[] memory decrypted
        )
    {
        address[] memory submitters = epochSubmitters[epochNumber];
        traders = submitters;
        decryptedAPYs = new uint256[](submitters.length);
        decrypted = new bool[](submitters.length);

        for (uint256 i = 0; i < submitters.length; i++) {
            address trader = submitters[i];
            euint16 encryptedAPY = strategies[epochNumber][trader].encryptedAPY;

            if (euint16.unwrap(encryptedAPY) != 0) {
                (uint256 result, bool isDecrypted) = FHE.getDecryptResultSafe(encryptedAPY);
                decryptedAPYs[i] = result;
                decrypted[i] = isDecrypted;
            }
        }
    }

    /**
     * @notice Get decrypted simulation times for an epoch
     * @dev Returns 0 for times that haven't been decrypted yet
     * @param epochNumber The epoch number
     * @return simStartTime Decrypted simulation start time (0 if not yet decrypted)
     * @return simEndTime Decrypted simulation end time (0 if not yet decrypted)
     * @return startDecrypted Whether start time has been decrypted
     * @return endDecrypted Whether end time has been decrypted
     */
    function getDecryptedSimTimes(uint256 epochNumber)
        external
        view
        returns (
            uint256 simStartTime,
            uint256 simEndTime,
            bool startDecrypted,
            bool endDecrypted
        )
    {
        EpochData storage epoch = epochs[epochNumber];

        (simStartTime, startDecrypted) = FHE.getDecryptResultSafe(epoch.encSimStartTime);
        (simEndTime, endDecrypted) = FHE.getDecryptResultSafe(epoch.encSimEndTime);
    }

    /**
     * @notice Get strategy node count for a trader
     */
    function getStrategyNodeCount(uint256 epochNumber, address trader) external view returns (uint256) {
        return strategies[epochNumber][trader].nodes.length;
    }

    /**
     * @notice Get a specific strategy node with FHE handles
     */
    function getStrategyNode(uint256 epochNumber, address trader, uint256 nodeIndex)
        external
        view
        returns (
            uint256 encoderHandle,
            uint256 targetHandle,
            uint256 selectorHandle,
            HandleWithType[] memory argHandles
        )
    {
        StrategyNode storage node = strategies[epochNumber][trader].nodes[nodeIndex];
        encoderHandle = eaddress.unwrap(node.encoder);
        targetHandle = eaddress.unwrap(node.target);
        selectorHandle = euint32.unwrap(node.selector);
        argHandles = node.args;
    }
}
