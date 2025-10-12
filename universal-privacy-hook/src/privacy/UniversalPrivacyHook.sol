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
import {Queue} from "../Queue.sol";
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
    
    /// @dev Per-pool intent queues: poolId => Queue
    mapping(PoolId => Queue) public poolIntentQueues;
    
    /// @dev Global intent storage: intentId => Intent
    mapping(bytes32 => Intent) public intents;
    
    /// @dev Maps encrypted amount handle to intent ID for queue processing
    /// Similar to MarketOrder's userOrders mapping
    mapping(PoolId => mapping(uint256 => bytes32)) public handleToIntentId;

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
    
    /**
     * @dev Set the SwapManager AVS contract address (only owner/deployer can call)
     * @param _swapManager The SwapManager contract address
     */
    function setSwapManager(address _swapManager) external {
        // In production, add proper access control
        swapManager = ISwapManager(_swapManager);
    }
    
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
        
        // Start FHE decryption process for swap amount
        FHE.decrypt(amount);
        
        // Create and store intent
        bytes32 intentId = keccak256(abi.encode(msg.sender, block.timestamp, poolId));
        intents[intentId] = Intent({
            encAmount: amount,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            owner: msg.sender,
            deadline: deadline,
            processed: false
        });
        
        // Store the handle-to-intent mapping (like MarketOrder's userOrders)
        uint256 handle = euint128.unwrap(amount);
        handleToIntentId[poolId][handle] = intentId;
        
        // Add encrypted amount to pool's intent queue (like MarketOrder pattern)
        Queue queue = _getOrCreateQueue(poolId);
        queue.push(amount);
        
        // Submit task to AVS for decentralized FHE decryption (if SwapManager is set)
        if (address(swapManager) != address(0)) {
            // Convert encrypted amount to bytes for AVS
            bytes memory encryptedAmountBytes = abi.encode(euint128.unwrap(amount));
            
            // Create swap task on AVS
            swapManager.createNewSwapTask(
                msg.sender,
                Currency.unwrap(tokenIn),
                Currency.unwrap(tokenOut),
                encryptedAmountBytes,
                deadline
            );
        }
        
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
        SwapParams calldata params,
        bytes calldata data
    ) internal override onlyPoolManager() returns (bytes4, BeforeSwapDelta, uint24) {
        
        // Allow hook-initiated swaps to pass through
        if (sender == address(this)) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        
        // Process any ready intents for this pool
        _processReadyIntents(key);
        
        // For privacy, we could block external swaps or allow them
        // For now, let's allow external swaps but process intents first
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // =============================================================
    //                      PRIVATE FUNCTIONS
    // =============================================================
    
    /**
     * @dev Process decrypted intents for a specific pool (temporarily disabled)
     */
    function _processReadyIntents(PoolKey calldata key) internal {
        PoolId poolId = key.toId();
        Queue queue = poolIntentQueues[poolId];
        
        // Process encrypted amounts from queue (following MarketOrder pattern)
        while (!queue.isEmpty()) {
            euint128 handle = queue.peek();
            
            // Check if decryption is ready (same as MarketOrder)
            (uint128 amount, bool ready) = FHE.getDecryptResultSafe(handle);
            
            if (!ready) {
                break; // Stop processing, decryption not ready
            }
            
            // Amount is ready - pop from queue and execute
            queue.pop();
            
            // Find the intent using the handle (like MarketOrder's userOrders lookup)
            uint256 handleUnwrapped = euint128.unwrap(handle);
            bytes32 intentId = handleToIntentId[poolId][handleUnwrapped];
            
            if (intentId != bytes32(0)) {
                // Execute the intent with the decrypted amount
                _executeIntent(key, intentId, amount);
            }
        }
    }
                
    /**
     * @dev Execute a single decrypted intent
     */
    function _executeIntent(
        PoolKey calldata key,
        bytes32 intentId,
        uint128 amount
    ) internal {
        Intent storage intent = intents[intentId];
        PoolId poolId = key.toId();
        
        // Determine swap direction
        bool zeroForOne = intent.tokenIn == key.currency0;
        
        // Execute swap using hook's reserves
        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(uint256(amount)),
            sqrtPriceLimitX96: zeroForOne ? 
                TickMath.MIN_SQRT_PRICE + 1 : 
                TickMath.MAX_SQRT_PRICE - 1
        });
        
        BalanceDelta delta = poolManager.swap(key, swapParams, ZERO_BYTES);
        
        // Calculate output amount and settle with pool manager
        uint128 outputAmount;
        if (zeroForOne) {
            // Swapping token0 for token1
            outputAmount = uint128(uint256(int256(delta.amount1())));
            // Hook owes token0 to pool, pool owes token1 to hook
            key.currency0.settle(poolManager, address(this), amount, false);
            key.currency1.take(poolManager, address(this), outputAmount, false);
        } else {
            // Swapping token1 for token0
            outputAmount = uint128(uint256(int256(-delta.amount0())));
            // Hook owes token1 to pool, pool owes token0 to hook
            key.currency1.settle(poolManager, address(this), amount, false);
            key.currency0.take(poolManager, address(this), outputAmount, false);
        }
        
        // Update hook reserves
        poolReserves[poolId][intent.tokenIn] -= amount;
        poolReserves[poolId][intent.tokenOut] += outputAmount;
        
        // Mint encrypted output tokens to user using trivial encryption
        IFHERC20 outputToken = poolEncryptedTokens[poolId][intent.tokenOut];
        // Create output token if it doesn't exist
        if (address(outputToken) == address(0)) {
            outputToken = _getOrCreateEncryptedToken(poolId, intent.tokenOut);
        }
        euint128 encryptedOutput = FHE.asEuint128(outputAmount);
        FHE.allowThis(encryptedOutput);
        FHE.allow(encryptedOutput, address(outputToken));
        outputToken.mintEncrypted(intent.owner, encryptedOutput);
        
        // Mark intent as processed
        intent.processed = true;
        
        emit IntentExecuted(poolId, intentId, amount, outputAmount);
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
    
    function _getOrCreateQueue(PoolId poolId) internal returns (Queue) {
        if (address(poolIntentQueues[poolId]) == address(0)) {
            poolIntentQueues[poolId] = new Queue();
        }
        return poolIntentQueues[poolId];
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
        // This can be used for batched operations if needed
        return ZERO_BYTES;
    }
}