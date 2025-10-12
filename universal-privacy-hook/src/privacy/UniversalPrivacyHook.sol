// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title UniversalPrivacyHook
 * @dev A Uniswap V4 hook that enables private swaps on any pool using FHE encrypted tokens
 * 
 * This hook can be attached to any Uniswap V4 pool to provide:
 * - Private swap intents with encrypted amounts and directions
 * - Automatic creation of hybrid FHE/ERC20 tokens per pool currency
 * - Batched execution for enhanced privacy
 * - 1:1 backing of encrypted tokens with hook reserves
 * 
 * Architecture:
 * - Users deposit ERC20 tokens → receive hybrid FHE/ERC20 tokens
 * - Users submit encrypted swap intents (amount + direction private)
 * - Hook processes intents by swapping its reserves and updating encrypted balances
 * - Users can withdraw or transfer their hybrid tokens freely
 */

// Uniswap V4 Imports
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

// Privacy Components
import {HybridFHERC20} from "./HybridFHERC20.sol";
import {IFHERC20} from "./interfaces/IFHERC20.sol";
import {ISwapManager} from "./interfaces/ISwapManager.sol";

// Token & Security
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

// FHE
import {FHE, InEuint128, euint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

contract UniversalPrivacyHook is BaseHook, IUnlockCallback, ReentrancyGuardTransient {

    // =============================================================
    //                           EVENTS
    // =============================================================
    
    event EncryptedTokenCreated(PoolId indexed poolId, Currency indexed currency, address token);
    event Deposited(PoolId indexed poolId, Currency indexed currency, address indexed user, uint256 amount);
    event IntentSubmitted(PoolId indexed poolId, Currency tokenIn, Currency tokenOut, address indexed user, bytes32 intentId);
    event IntentExecuted(PoolId indexed poolId, bytes32 indexed intentId, uint128 amountIn, uint128 amountOut);
    event Withdrawn(PoolId indexed poolId, Currency indexed currency, address indexed user, address recipient, uint256 amount);
    event BatchCreated(bytes32 indexed batchId, PoolId indexed poolId, uint256 intentCount);
    event BatchSettled(bytes32 indexed batchId, uint256 matchedCount, uint256 netCount);

    // =============================================================
    //                          LIBRARIES
    // =============================================================
    
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    // FHE library usage for encrypted operations
    using FHE for uint256;

    // =============================================================
    //                          STRUCTS
    // =============================================================
    
    /**
     * @dev Represents an encrypted swap intent
     */
    struct Intent {
        euint128 encAmount;      // Encrypted amount to swap
        Currency tokenIn;        // Input currency (currency0 or currency1)
        Currency tokenOut;       // Output currency (currency1 or currency0)
        address owner;           // User who submitted the intent
        uint64 deadline;         // Expiration timestamp
        bool processed;          // Whether intent has been executed
        address[] selectedOperators; // Operators allowed to decrypt this intent
        bytes32 batchId;         // Batch this intent belongs to
    }
    
    /**
     * @dev Batch tracking for atomic settlement
     */
    struct Batch {
        bytes32[] intentIds;
        uint256 createdAt;
        uint256 settledAt;
        BatchStatus status;
        PoolId poolId;
        PoolKey poolKey; // Store the pool key for swap execution
    }
    
    enum BatchStatus {
        Collecting,
        Processing,
        Settled,
        Cancelled
    }

    // =============================================================
    //                         CONSTANTS
    // =============================================================
    
    bytes internal constant ZERO_BYTES = bytes("");
    
    // FHE encrypted constants for reuse
    euint128 private ENCRYPTED_ZERO;
    euint128 private ENCRYPTED_ONE;

    // =============================================================
    //                      STATE VARIABLES
    // =============================================================
    
    /// @dev AVS SwapManager for decentralized FHE decryption
    ISwapManager public swapManager;
    
    /// @dev Per-pool encrypted token contracts: poolId => currency => IFHERC20
    mapping(PoolId => mapping(Currency => IFHERC20)) public poolEncryptedTokens;
    
    /// @dev Per-pool reserves backing encrypted tokens: poolId => currency => amount
    mapping(PoolId => mapping(Currency => uint256)) public poolReserves;
    
    /// @dev Global intent storage: intentId => Intent
    mapping(bytes32 => Intent) public intents;
    
    /// @dev Batch management
    mapping(bytes32 => Batch) public batches;
    mapping(PoolId => bytes32) public currentBatchId; // Current collecting batch per pool
    mapping(PoolId => uint256) public lastBatchBlock; // Block when current batch started collecting
    mapping(bytes32 => bool) public processedBatches;
    
    /// @dev Configuration
    uint256 public batchBlockInterval = 5; // Process batch every N blocks

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================
    
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        // Initialize FHE constants and grant contract access
        ENCRYPTED_ZERO = FHE.asEuint128(0);
        ENCRYPTED_ONE = FHE.asEuint128(1);
        
        // CRITICAL: Contract must have access to use these constants
        FHE.allowThis(ENCRYPTED_ZERO);
        FHE.allowThis(ENCRYPTED_ONE);
    }

    // =============================================================
    //                      HOOK CONFIGURATION
    // =============================================================
    
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,                    // Process encrypted intents
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // =============================================================
    //                      ADMIN FUNCTIONS
    // =============================================================
    
    
    // =============================================================
    //                      CORE FUNCTIONS
    // =============================================================
    
    /**
     * @dev Deposit tokens to receive encrypted tokens for a specific pool
     * @param key The pool key identifying the pool
     * @param currency The currency to deposit (must be currency0 or currency1)
     * @param amount The amount to deposit
     */
    function deposit(
        PoolKey calldata key,
        Currency currency,
        uint256 amount
    ) external nonReentrant {
        PoolId poolId = key.toId();
        
        // Validate hook is enabled for this pool
        require(_isHookEnabledForPool(key), "Hook not enabled");
        
        // Validate currency belongs to this pool
        require(_isValidCurrency(key, currency), "Invalid currency");
        
        // Get or create encrypted token for this pool/currency
        IFHERC20 encryptedToken = _getOrCreateEncryptedToken(poolId, currency);
        
        // Transfer tokens from user to hook
        IERC20(Currency.unwrap(currency)).transferFrom(msg.sender, address(this), amount);
        
        // Mint encrypted tokens to user using trivial encryption
        euint128 encryptedAmount = FHE.asEuint128(amount);
        FHE.allowThis(encryptedAmount);
        FHE.allow(encryptedAmount, address(encryptedToken));
        encryptedToken.mintEncrypted(msg.sender, encryptedAmount);
        
        // Update hook reserves
        poolReserves[poolId][currency] += amount;
        
        emit Deposited(poolId, currency, msg.sender, amount);
    }
    
    /**
     * @dev Submit an encrypted swap intent
     * @param key The pool key
     * @param tokenIn Input currency
     * @param tokenOut Output currency
     * @param encAmount Encrypted amount to swap
     * @param deadline Intent expiration
     */
    function submitIntent(
        PoolKey calldata key,
        Currency tokenIn,
        Currency tokenOut,
        InEuint128 calldata encAmount,
        uint64 deadline
    ) external nonReentrant {
        PoolId poolId = key.toId();
        
        // Validate currencies form valid pair for this pool
        require(_isValidCurrencyPair(key, tokenIn, tokenOut), "Invalid pair");
        
        // Convert to euint128 and set up proper FHE access control
        euint128 amount = FHE.asEuint128(encAmount);
        FHE.allowThis(amount);
        
        // User transfers encrypted tokens to hook as collateral
        IFHERC20 inputToken = poolEncryptedTokens[poolId][tokenIn];
        require(address(inputToken) != address(0), "Token not exists");
        
        // Grant token contract access to the encrypted amount
        FHE.allow(amount, address(inputToken));
        
        // Transfer encrypted tokens from user to hook as collateral
        inputToken.transferFromEncrypted(msg.sender, address(this), amount);
        
        // For now, no operator selection per intent
        // Operators will be selected when batch is finalized
        address[] memory selectedOperators = new address[](0);
        
        // Get or create current batch for this pool (pass key for storage)
        bytes32 batchId = _getOrCreateBatch(poolId, key);
        
        // Create and store intent
        bytes32 intentId = keccak256(abi.encode(msg.sender, block.timestamp, poolId));
        intents[intentId] = Intent({
            encAmount: amount,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            owner: msg.sender,
            deadline: deadline,
            processed: false,
            selectedOperators: selectedOperators,
            batchId: batchId
        });
        
        // Add intent to current batch
        batches[batchId].intentIds.push(intentId);
        
        emit IntentSubmitted(poolId, tokenIn, tokenOut, msg.sender, intentId);
    }
    
    /**
     * @dev Withdraw encrypted tokens back to underlying ERC20
     * @param key The pool key
     * @param currency The currency to withdraw
     * @param amount The amount to withdraw
     * @param recipient The recipient address
     */
    function withdraw(
        PoolKey calldata key,
        Currency currency,
        uint256 amount,
        address recipient
    ) external nonReentrant {
        PoolId poolId = key.toId();
        
        // Burn encrypted tokens from user
        IFHERC20 encryptedToken = poolEncryptedTokens[poolId][currency];
        require(address(encryptedToken) != address(0), "Token not exists");
        
        encryptedToken.burn(msg.sender, amount);
        
        // Update reserves
        poolReserves[poolId][currency] -= amount;
        
        // Transfer underlying tokens to recipient
        IERC20(Currency.unwrap(currency)).transfer(recipient, amount);
        
        emit Withdrawn(poolId, currency, msg.sender, recipient, amount);
    }

    // =============================================================
    //                     HOOK IMPLEMENTATIONS
    // =============================================================
    
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata, // params
        bytes calldata // data
    ) internal override onlyPoolManager() returns (bytes4, BeforeSwapDelta, uint24) {
        
        // Allow hook-initiated swaps to pass through
        if (sender == address(this)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        
        // Regular swaps just pass through
        // All batch processing happens in settleBatch
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // =============================================================
    //                    BATCH SETTLEMENT
    // =============================================================
    
    /**
     * @dev Set the batch block interval (owner only)
     */
    function setBatchBlockInterval(uint256 _interval) external {
        require(msg.sender == address(this), "Only owner"); // TODO: Add proper access control
        require(_interval > 0 && _interval <= 100, "Invalid interval");
        batchBlockInterval = _interval;
    }
    
    /**
     * @dev Set the SwapManager address (owner only)
     */
    function setSwapManager(address _swapManager) external {
        require(msg.sender == address(this), "Only owner"); // TODO: Add proper access control
        swapManager = ISwapManager(_swapManager);
    }
    
    /**
     * @dev Check if a batch is ready for processing
     */
    function isBatchReady(PoolId poolId) external view returns (bool) {
        bytes32 batchId = currentBatchId[poolId];
        if (batchId == bytes32(0)) return false;
        
        Batch memory batch = batches[batchId];
        return batch.status == BatchStatus.Collecting && 
               block.number >= lastBatchBlock[poolId] + batchBlockInterval;
    }
    
    /**
     * @dev Settlement function called by SwapManager after AVS consensus
     * The Hook already holds all tokens from users who submitted intents
     * @param batchId The batch to settle
     * @param internalizedTransfers Direct token transfers from internalized matching
     * @param netSwap The single net swap with distribution info
     * @param hasNetSwap Whether there's a net swap needed
     */
    function settleBatch(
        bytes32 batchId,
        ISwapManager.TokenTransfer[] calldata internalizedTransfers,
        ISwapManager.NetSwap calldata netSwap,
        bool hasNetSwap
    ) external nonReentrant {
        require(msg.sender == address(swapManager), "Only SwapManager");
        require(batches[batchId].status == BatchStatus.Processing, "Invalid batch status");
        require(!processedBatches[batchId], "Already processed");
        
        Batch storage batch = batches[batchId];
        PoolId poolId = batch.poolId;
        
        // Step 1: Execute internalized transfers
        // Hook already has custody of all tokens, just distribute them
        for (uint256 i = 0; i < internalizedTransfers.length; i++) {
            ISwapManager.TokenTransfer memory transfer = internalizedTransfers[i];
            
            // Get the encrypted token contract
            IFHERC20 token = poolEncryptedTokens[poolId][Currency.wrap(transfer.token)];
            
            // Transfer from Hook to user (Hook already has the tokens)
            token.transferFromEncrypted(address(this), transfer.user, transfer.amount);
        }
        
        // Step 2: Process net swap through Uniswap pool if needed
        // This is the residual amount that couldn't be internalized
        if (hasNetSwap) {
            _processNetSwap(batch.poolId, netSwap);
        }
        
        // Mark batch as settled
        batch.status = BatchStatus.Settled;
        batch.settledAt = block.timestamp;
        processedBatches[batchId] = true;
        
        // Mark all intents as processed
        for (uint256 i = 0; i < batch.intentIds.length; i++) {
            intents[batch.intentIds[i]].processed = true;
        }
        
        emit BatchSettled(batchId, internalizedTransfers.length, hasNetSwap ? 1 : 0);
    }
    
    /**
     * @dev Get or create a batch for the pool
     */
    function _getOrCreateBatch(PoolId poolId, PoolKey memory key) internal returns (bytes32) {
        bytes32 batchId = currentBatchId[poolId];
        
        // Check if we need a new batch (block interval passed or first batch)
        if (batchId == bytes32(0) || 
            block.number >= lastBatchBlock[poolId] + batchBlockInterval) {
            
            // Finalize previous batch if exists
            if (batchId != bytes32(0) && batches[batchId].status == BatchStatus.Collecting) {
                batches[batchId].status = BatchStatus.Processing;
                
                // Notify SwapManager to process this batch (even if empty)
                if (address(swapManager) != address(0)) {
                    // Encode batch data for operators
                    bytes memory batchData = abi.encode(
                        batches[batchId].intentIds,
                        batches[batchId].poolKey
                    );
                    swapManager.finalizeBatch(batchId, batchData);
                }
            }
            
            // Create new batch
            batchId = keccak256(abi.encode(poolId, block.number, block.timestamp));
            batches[batchId] = Batch({
                intentIds: new bytes32[](0),
                createdAt: block.timestamp,
                settledAt: 0,
                status: BatchStatus.Collecting,
                poolId: poolId,
                poolKey: key
            });
            
            currentBatchId[poolId] = batchId;
            lastBatchBlock[poolId] = block.number;
            
            emit BatchCreated(batchId, poolId, 0);
        }
        
        return batchId;
    }
    
    /**
     * @dev Process the net swap through the Uniswap pool and distribute output
     */
    function _processNetSwap(PoolId poolId, ISwapManager.NetSwap memory netSwap) internal {
        // Get the pool key from the current batch
        bytes32 batchId = currentBatchId[poolId];
        require(batchId != bytes32(0), "No active batch");
        PoolKey memory key = batches[batchId].poolKey;
        
        // Prepare data for unlockCallback
        bytes memory unlockData = abi.encode(
            key,
            netSwap,
            poolId
        );
        
        // Execute via PoolManager unlock to handle swap
        poolManager.unlock(unlockData);
    }
    
    
    // =============================================================
    //                      HELPER FUNCTIONS
    // =============================================================
    
    function _isHookEnabledForPool(PoolKey calldata key) internal view returns (bool) {
        return address(key.hooks) == address(this);
    }
    
    function _isValidCurrency(PoolKey calldata key, Currency currency) internal pure returns (bool) {
        return currency == key.currency0 || currency == key.currency1;
    }
    
    function _isValidCurrencyPair(PoolKey calldata key, Currency tokenIn, Currency tokenOut) internal pure returns (bool) {
        return (tokenIn == key.currency0 && tokenOut == key.currency1) ||
               (tokenIn == key.currency1 && tokenOut == key.currency0);
    }
    
    function _getOrCreateEncryptedToken(PoolId poolId, Currency currency) internal returns (IFHERC20) {
        IFHERC20 existing = poolEncryptedTokens[poolId][currency];
        
        if (address(existing) == address(0)) {
            // Create new hybrid FHE/ERC20 token
            string memory symbol = _getCurrencySymbol(currency);
            string memory name = string(abi.encodePacked("Encrypted ", symbol));
            
            existing = new HybridFHERC20(name, string(abi.encodePacked("e", symbol)));
            poolEncryptedTokens[poolId][currency] = existing;
            
            emit EncryptedTokenCreated(poolId, currency, address(existing));
        }
        
        return existing;
    }
    
    function _getCurrencySymbol(Currency currency) internal view returns (string memory) {
        // Try to get the symbol from the ERC20 token
        try IERC20Metadata(Currency.unwrap(currency)).symbol() returns (string memory symbol) {
            // Check if symbol is empty and return fallback
            if (bytes(symbol).length == 0) {
                return "TOKEN";
            }
            return symbol;
        } catch {
            // Fallback if token doesn't implement symbol()
            return "TOKEN";
        }
    }
    
    // =============================================================
    //                      UNLOCK CALLBACK
    // =============================================================
    
    function unlockCallback(bytes calldata data) external override onlyPoolManager returns (bytes memory) {
        // Decode the net swap data
        (PoolKey memory key, ISwapManager.NetSwap memory netSwap, PoolId poolId) = 
            abi.decode(data, (PoolKey, ISwapManager.NetSwap, PoolId));
        
        // The netAmount is already decrypted by AVS
        uint256 amountIn = netSwap.netAmount;
        
        // Execute swap with EXACT INPUT (negative amount in V4)
        SwapParams memory swapParams = SwapParams({
            zeroForOne: netSwap.isZeroForOne,
            amountSpecified: -int256(amountIn),  // Negative for exact input
            sqrtPriceLimitX96: netSwap.isZeroForOne ? 
                TickMath.MIN_SQRT_PRICE + 1 : 
                TickMath.MAX_SQRT_PRICE - 1
        });
        
        BalanceDelta delta = poolManager.swap(key, swapParams, ZERO_BYTES);
        
        // Read signed deltas
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();
        
        // Settle what we owe (negative), take what we're owed (positive)
        if (d0 < 0) {
            key.currency0.settle(poolManager, address(this), uint128(-d0), false);
        }
        if (d1 < 0) {
            key.currency1.settle(poolManager, address(this), uint128(-d1), false);
        }
        if (d0 > 0) {
            key.currency0.take(poolManager, address(this), uint128(d0), false);
        }
        if (d1 > 0) {
            key.currency1.take(poolManager, address(this), uint128(d1), false);
        }
        
        // Calculate output amount from the positive delta
        uint256 outputAmount;
        Currency outputCurrency = Currency.wrap(netSwap.tokenOut);
        if (outputCurrency == key.currency0) {
            require(d0 > 0, "No token0 output");
            outputAmount = uint128(d0);
        } else {
            require(d1 > 0, "No token1 output");
            outputAmount = uint128(d1);
        }
        
        // Update hook reserves
        poolReserves[poolId][Currency.wrap(netSwap.tokenIn)] -= amountIn;
        poolReserves[poolId][outputCurrency] += outputAmount;
        
        // Mint encrypted output tokens and distribute to recipients
        IFHERC20 outputToken = poolEncryptedTokens[poolId][outputCurrency];
        require(address(outputToken) != address(0), "Output token not exists");
        
        // Mint the total output as encrypted tokens to the hook first
        euint128 encryptedOutput = FHE.asEuint128(outputAmount);
        FHE.allowThis(encryptedOutput);
        FHE.allow(encryptedOutput, address(outputToken));
        outputToken.mintEncrypted(address(this), encryptedOutput);
        
        // Distribute to recipients according to their amounts
        for (uint256 i = 0; i < netSwap.recipients.length; i++) {
            outputToken.transferFromEncrypted(
                address(this), 
                netSwap.recipients[i], 
                netSwap.recipientAmounts[i]
            );
        }
        
        return ZERO_BYTES;
    }
}