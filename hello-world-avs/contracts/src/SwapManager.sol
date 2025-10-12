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
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title Primary entrypoint for decentralized swap execution with FHE decryption.
 * @author Modified for AlphaEngine Hook
 */
contract SwapManager is ECDSAServiceManagerBase, ISwapManager {
    using ECDSAUpgradeable for bytes32;

    uint32 public latestTaskNum;
    
    // Committee configuration
    uint256 public constant COMMITTEE_SIZE = 7; // Number of operators per task
    uint256 public constant MIN_ATTESTATIONS = 5; // Minimum attestations needed
    
    // Track registered operators for selection
    address[] public registeredOperators;
    mapping(address => bool) public isOperatorRegistered;
    mapping(address => uint256) public operatorIndex;

    // mapping of task indices to all tasks hashes
    // when a task is created, task hash is stored here,
    // and responses need to pass the actual task,
    // which is hashed onchain and checked against this mapping
    mapping(uint32 => bytes32) public allTaskHashes;

    // mapping of task indices to hash of abi.encode(taskResponse, taskResponseMetadata)
    mapping(address => mapping(uint32 => bytes)) public allTaskResponses;

    // mapping of task indices to task status (true if task has been responded to, false otherwise)
    // TODO: use bitmap?
    mapping(uint32 => bool) public taskWasResponded;

    // max interval in blocks for responding to a task
    // operators can be penalized if they don't respond in time
    uint32 public immutable MAX_RESPONSE_INTERVAL_BLOCKS;

    modifier onlyOperator() {
        require(
            ECDSAStakeRegistry(stakeRegistry).operatorRegistered(msg.sender),
            "Operator must be the caller"
        );
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

    // These are just to comply with IServiceManager interface
    function addPendingAdmin(
        address admin
    ) external onlyOwner {}

    function removePendingAdmin(
        address pendingAdmin
    ) external onlyOwner {}

    function removeAdmin(
        address admin
    ) external onlyOwner {}

    function setAppointee(address appointee, address target, bytes4 selector) external onlyOwner {}

    function removeAppointee(
        address appointee,
        address target,
        bytes4 selector
    ) external onlyOwner {}

    function deregisterOperatorFromOperatorSets(
        address operator,
        uint32[] memory operatorSetIds
    ) external {
        // unused
    }

    /* FUNCTIONS */
    // NOTE: this function creates new swap task, assigns it a taskId
    function createNewSwapTask(
        address user,
        address tokenIn,
        address tokenOut,
        bytes calldata encryptedAmount,
        uint64 deadline
    ) external returns (SwapTask memory) {
        // Deterministically select operators for this task
        address[] memory selectedOps = _selectOperatorsForTask(latestTaskNum);
        
        // create a new swap task struct
        SwapTask memory newTask;
        newTask.hook = msg.sender; // Privacy hook is the caller
        newTask.user = user;
        newTask.tokenIn = tokenIn;
        newTask.tokenOut = tokenOut;
        newTask.encryptedAmount = encryptedAmount;
        newTask.deadline = deadline;
        newTask.taskCreatedBlock = uint32(block.number);
        newTask.selectedOperators = selectedOps;

        // store hash of task onchain, emit event, and increase taskNum
        allTaskHashes[latestTaskNum] = keccak256(abi.encode(newTask));
        emit NewSwapTaskCreated(latestTaskNum, newTask);
        latestTaskNum = latestTaskNum + 1;

        return newTask;
    }
    
    /**
     * @notice Register an operator for task selection
     * @dev Operator must already be registered with ECDSAStakeRegistry
     */
    function registerOperatorForTasks() external {
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
     * @notice Deregister an operator from task selection
     */
    function deregisterOperatorFromTasks() external {
        require(isOperatorRegistered[msg.sender], "Operator not registered");
        
        // Remove operator by swapping with last and popping
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
     * @notice Deterministically select operators for a task using native randomness
     * @param taskId The task ID to select operators for
     * @return selectedOps Array of selected operator addresses
     */
    function _selectOperatorsForTask(uint32 taskId) internal view returns (address[] memory) {
        uint256 operatorCount = registeredOperators.length;
        
        // If not enough operators, return all available operators
        if (operatorCount < COMMITTEE_SIZE) {
            return registeredOperators;
        }
        
        // Use block.prevrandao + block.number + taskId for deterministic randomness
        uint256 seed = uint256(keccak256(abi.encode(block.prevrandao, block.number, taskId)));
        
        address[] memory selectedOps = new address[](COMMITTEE_SIZE);
        bool[] memory selected = new bool[](operatorCount);
        
        for (uint256 i = 0; i < COMMITTEE_SIZE; i++) {
            // Generate new random index
            uint256 randomIndex = uint256(keccak256(abi.encode(seed, i))) % operatorCount;
            
            // Find next available operator (linear probing to avoid duplicates)
            while (selected[randomIndex]) {
                randomIndex = (randomIndex + 1) % operatorCount;
            }
            
            selected[randomIndex] = true;
            selectedOps[i] = registeredOperators[randomIndex];
        }
        
        return selectedOps;
    }

    function respondToSwapTask(
        SwapTask calldata task,
        uint32 referenceTaskIndex,
        uint256 decryptedAmount,
        bytes memory signature
    ) external {
        // check that the task is valid, hasn't been responded yet, and is being responded in time
        require(
            keccak256(abi.encode(task)) == allTaskHashes[referenceTaskIndex],
            "supplied task does not match the one recorded in the contract"
        );
        require(
            block.number <= task.taskCreatedBlock + MAX_RESPONSE_INTERVAL_BLOCKS,
            "Task response time has already expired"
        );

        // The message that was signed - includes task hash and decrypted amount
        bytes32 messageHash = keccak256(abi.encodePacked(keccak256(abi.encode(task)), decryptedAmount));
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        bytes4 magicValue = IERC1271Upgradeable.isValidSignature.selector;

        // Decode the signature data to get operators and their signatures
        (address[] memory operators, bytes[] memory signatures, uint32 referenceBlock) =
            abi.decode(signature, (address[], bytes[], uint32));

        // Check that referenceBlock matches task creation block
        require(
            referenceBlock == task.taskCreatedBlock,
            "Reference block must match task creation block"
        );

        // Store each operator's signature
        for (uint256 i = 0; i < operators.length; i++) {
            // Check that this operator hasn't already responded
            require(
                allTaskResponses[operators[i]][referenceTaskIndex].length == 0,
                "Operator has already responded to the task"
            );

            // Store the operator's signature
            allTaskResponses[operators[i]][referenceTaskIndex] = signatures[i];

            // Emit event for this operator with decrypted amount
            emit SwapTaskResponded(referenceTaskIndex, task, operators[i], decryptedAmount);
        }

        taskWasResponded[referenceTaskIndex] = true;

        // Verify all signatures at once
        bytes4 isValidSignatureResult =
            ECDSAStakeRegistry(stakeRegistry).isValidSignature(ethSignedMessageHash, signature);

        require(magicValue == isValidSignatureResult, "Invalid signature");
    }

    function slashOperator(
        SwapTask calldata task,
        uint32 referenceTaskIndex,
        address operator
    ) external {
        // check that the task is valid, hasn't been responsed yet
        require(
            keccak256(abi.encode(task)) == allTaskHashes[referenceTaskIndex],
            "supplied task does not match the one recorded in the contract"
        );
        require(!taskWasResponded[referenceTaskIndex], "Task has already been responded to");
        require(
            allTaskResponses[operator][referenceTaskIndex].length == 0,
            "Operator has already responded to the task"
        );
        require(
            block.number > task.taskCreatedBlock + MAX_RESPONSE_INTERVAL_BLOCKS,
            "Task response time has not expired yet"
        );
        // check operator was registered when task was created
        uint256 operatorWeight = ECDSAStakeRegistry(stakeRegistry).getOperatorWeightAtBlock(
            operator, task.taskCreatedBlock
        );
        require(operatorWeight > 0, "Operator was not registered when task was created");

        // we update the storage with a sentinel value
        allTaskResponses[operator][referenceTaskIndex] = "slashed";

        // TODO: slash operator
    }
    
    function getTask(uint32 taskIndex) external view returns (SwapTask memory) {
        // For testing, return a dummy task
        // In production, you'd store and retrieve the full task
        SwapTask memory task;
        return task;
    }
    
    function getOperatorCount() external view returns (uint256) {
        return registeredOperators.length;
    }
}
