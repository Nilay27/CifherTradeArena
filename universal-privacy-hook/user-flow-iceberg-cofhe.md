# Iceberg Co-FHE Protocol: User Flow & Technical Deep Dive

## Executive Summary

The Iceberg protocol is a **private limit order system** built on Uniswap v4 hooks using **Fully Homomorphic Encryption (FHE)**. It allows users to place limit orders with **completely encrypted trade direction, amounts, and execution logic** until the moment of execution. The protocol uses hybrid FHE/ERC20 tokens and a sophisticated decryption queue system to maintain privacy while enabling efficient order execution.

## Key Innovation: What Makes This Different

This is **NOT** a typical limit order book. Instead, it's a privacy-preserving system where:

1. **Trade Intent Privacy**: Users can place orders without revealing whether they're buying or selling until execution
2. **Amount Privacy**: Order sizes remain encrypted until filled  
3. **Selective Disclosure**: Orders are only decrypted when price conditions are met
4. **Hybrid Token Model**: Tokens exist in both public (standard ERC20) and encrypted forms
5. **Persistent Balance Privacy**: User balances remain encrypted even after trade execution

**CRITICAL DISTINCTION**: This provides **end-to-end encrypted balances**, unlike market order hooks where balances become public after execution.

---

## Real-World Example: USDC/USDT Pool

Let's walk through a complete user journey using a USDC/USDT pool to understand how this works in practice.

### Setup Phase: Pool Creation

```
Pool: USDC/USDT (3000 fee tier)
Initial Price: 1 USDC = 1 USDT (tick = 0)
Tokens: HybridFHERC20 versions of USDC and USDT
```

Both USDC and USDT are deployed as `HybridFHERC20` tokens, meaning each token has:
- **Public balances**: Standard ERC20 functionality (`balanceOf[user]`)
- **Encrypted balances**: FHE-encrypted amounts (`encBalances[user]`)
- **Conversion methods**: `wrap()` (public → encrypted) and `unwrap()` (encrypted → public)

### Phase 1: User Prepares for Private Trading

**Alice wants to place a limit order but keep her trading strategy private.**

1. **Alice wraps her tokens** from public to encrypted form:
   ```solidity
   // Alice has 10,000 USDC in public form
   fheUSDC.wrap(alice, 10000e6);  // Convert to encrypted USDC
   ```
   
   **State After Wrap:**
   ```
   Alice's Public USDC Balance: 0
   Alice's Encrypted USDC Balance: 10,000 USDC (encrypted)
   ```

2. **Alice's trading intent**: She wants to sell 5,000 USDC for USDT when price hits 1.002 USDT per USDC
3. **Privacy goal**: Nobody should know Alice is selling or how much until her order executes

### Phase 2: Placing the Encrypted Limit Order

Alice calls `placeIcebergOrder()` with **fully encrypted parameters**:

```solidity
// All parameters are encrypted inputs
InEbool memory zeroForOne = encrypt(true);      // USDC → USDT (but encrypted!)
InEuint128 memory amount = encrypt(5000e6);     // 5,000 USDC (but encrypted!)
int24 tickLower = 20;                           // Price level ≈ 1.002 USDT per USDC

hook.placeIcebergOrder(poolKey, tickLower, zeroForOne, amount);
```

**What happens inside `placeIcebergOrder()` at src/Iceberg.sol:261:**

1. **Epoch Management**: The hook groups orders by price level (tickLower) in "epochs"
   ```solidity
   Epoch epoch = getEncEpoch(key, tickLower);  // Get/create epoch for this price level
   ```

2. **Encrypted Storage**: Alice's order details are stored **completely encrypted**:
   ```solidity
   // These additions happen under encryption - nobody can see the amounts!
   epochInfo.liquidityMapToken0[alice] = encryptedAdd(existing, amount);  // Using FHE.select
   epochInfo.zeroForOneLiquidity = encryptedAdd(total, amount);           // Total orders at this level
   ```

3. **Encrypted Token Transfer**: Alice sends tokens to the hook, but **both tokens are sent**:
   ```solidity
   euint128 token0Amount = FHE.select(zeroForOne, amount, ZERO);    // 5000 USDC or 0
   euint128 token1Amount = FHE.select(zeroForOne, ZERO, amount);    // 0 or 5000 USDT
   
   // Both transfers happen - outside observers can't tell which has real value!
   IFHERC20(USDC).transferFromEncrypted(alice, hook, token0Amount);  // Encrypted transfer
   IFHERC20(USDT).transferFromEncrypted(alice, hook, token1Amount);  // Encrypted transfer
   ```

**Key Privacy Feature**: External observers see Alice interacting with both USDC and USDT contracts, but due to encryption, they cannot determine:
- Which token she's actually trading
- How much she's trading
- Whether she's buying or selling

**State After Order Placement:**
```
Alice's Encrypted USDC: 5,000 USDC (reduced by encrypted amount)
Alice's Encrypted USDT: 0 USDT (unchanged, but transfer was encrypted)
Hook's Encrypted USDC: +5,000 USDC (encrypted)
Hook's Encrypted USDT: +0 USDT (encrypted, but actually zero)
Order Storage: Epoch for tick 20 contains Alice's encrypted order details
```

### Phase 3: Market Movement & Order Activation

**Bob makes a large trade that moves the price up:**

```solidity
// Bob swaps 100,000 USDT → USDC, pushing price from 1.000 to 1.003
swapRouter.exactInputSingle({
    tokenIn: USDT,
    tokenOut: USDC,
    fee: 3000,
    recipient: bob,
    amountIn: 100000e6,
    amountOutMinimum: 0,
    sqrtPriceLimitX96: 0
});
```

**Price Movement:**
```
Before: 1 USDC = 1.000 USDT (tick ≈ 0)
After:  1 USDC = 1.003 USDT (tick ≈ 30)
```

Since the price crossed tick 20 (≈1.002), Alice's limit order is now "in the money" and should be executed.

### Phase 4: Order Discovery & Decryption Queue

**In `afterSwap` hook (src/Iceberg.sol:313):**

1. **Tick Range Calculation**: The hook identifies which price levels were crossed:
   ```solidity
   (int24 tickLower, int24 lower, int24 upper) = _getCrossedTicks(poolId, tickSpacing);
   // Result: lower=0, upper=20 (ticks that were crossed)
   ```

2. **Order Discovery**: For each crossed tick, check if orders exist:
   ```solidity
   for (int24 tick = lower; tick <= upper; tick += tickSpacing) {
       _decryptEpoch(key, tick, zeroForOne);  // zeroForOne = !params.zeroForOne
   }
   ```

3. **Decryption Request** (`_decryptEpoch` at src/Iceberg.sol:335):
   ```solidity
   Epoch epoch = getEncEpoch(key, tick);
   EncEpochInfo storage encEpoch = encEpochInfos[epoch];
   
   // Get encrypted liquidity total for this direction
   euint128 liquidityTotal = FHE.select(zeroForOne, 
                                       encEpoch.zeroForOneLiquidity, 
                                       encEpoch.oneForZeroLiquidity);
   
   // Request decryption from FHE coprocessor
   euint128 liquidityHandle = IFHERC20(token).requestUnwrap(hook, liquidityTotal);
   
   // Add to decryption queue for processing in next swap
   Queue queue = getPoolQueue(key);
   queue.push(liquidityHandle);
   
   // Store metadata for when decryption completes
   orderInfo[liquidityHandle] = DecryptedOrder(zeroForOne, tick, token);
   ```

**Critical Insight**: Orders are only decrypted **when price conditions are met**. Until this moment, Alice's order details remained completely private.

**State After Decryption Request:**
```
Alice's order is queued for decryption
FHE coprocessor begins decrypting: liquidityTotal for (USDC/USDT, tick=20, zeroForOne=true)
Queue contains: liquidityHandle pointing to Alice's order batch
```

### Phase 5: Order Execution 

**Charlie attempts another swap, triggering order execution:**

```solidity
// Charlie's swap triggers beforeSwap hook
swapRouter.exactInputSingle({
    tokenIn: USDT,
    tokenOut: USDC,
    fee: 3000,
    recipient: charlie,
    amountIn: 1000e6,
    // ... other params
});
```

**In `beforeSwap` hook (src/Iceberg.sol:180):**

1. **Decryption Queue Processing**:
   ```solidity
   Queue queue = getPoolQueue(key);
   
   while (!queue.isEmpty()) {
       euint128 liquidityHandle = queue.peek();
       DecryptedOrder memory order = orderInfo[liquidityHandle];
       
       // Check if FHE coprocessor finished decryption
       (uint128 decryptedLiquidity, bool decrypted) = 
           IFHERC20(order.token).getUnwrapResultSafe(hook, liquidityHandle);
           
       if (!decrypted) {
           return;  // Not ready yet, continue with Charlie's swap
       }
       
       // Decryption complete! Execute Alice's order
       queue.pop();  // Remove from queue
   }
   ```

2. **Order Execution**:
   ```solidity
   // Execute Alice's limit order: sell 5,000 USDC for USDT
   BalanceDelta delta = _swapPoolManager(key, order.zeroForOne, -5000e6);
   ```
   
   This performs the actual swap:
   ```
   Hook sends: 5,000 USDC to pool
   Hook receives: ~4,985 USDT from pool (after fees/slippage)
   ```

3. **Balance Settlement**:
   ```solidity
   (uint128 amount0, uint128 amount1) = _settlePoolManagerBalances(key, delta, zeroForOne);
   // amount0 = 5,000 USDC (sent to pool)
   // amount1 = 4,985 USDT (received from pool)
   
   // Wrap newly received tokens back to encrypted form
   IFHERC20(USDT).wrap(hook, amount1);  // Convert 4,985 USDT to encrypted
   ```

4. **Update Epoch Storage**:
   ```solidity
   epochInfo.zeroForOnefilled = true;
   epochInfo.zeroForOneToken0 = encryptedAdd(epochInfo.zeroForOneToken0, 5000e6);
   epochInfo.zeroForOneToken1 = encryptedAdd(epochInfo.zeroForOneToken1, 4985e6);
   ```

**State After Execution:**
```
Hook's Public USDC: -5,000 (sent to pool)
Hook's Public USDT: +4,985 (received from pool) 
Hook's Encrypted USDT: +4,985 (wrapped immediately)
Epoch Storage: Records that 5,000 USDC was traded for 4,985 USDT (encrypted)
Order Status: zeroForOnefilled = true
```

### Phase 6: User Withdraws Proceeds

**Alice withdraws her trade proceeds:**

```solidity
(euint128 amount0, euint128 amount1) = hook.withdraw(poolKey, tickLower);
```

**In `withdraw()` (src/Iceberg.sol:362):**

1. **Calculate Alice's Share**:
   ```solidity
   euint128 liquidityZero = epochInfo.liquidityMapToken0[alice];  // Alice's USDC contribution
   euint128 liquidityOne = epochInfo.liquidityMapToken1[alice];   // Alice's USDT contribution
   
   // Determine trade direction (encrypted comparison)
   ebool zeroForOne = liquidityZero.gte(liquidityOne);
   
   // Calculate Alice's proportional share of proceeds
   euint128 amount1 = FHE.select(zeroForOne, 
       _safeMulDiv(epochInfo.zeroForOneToken1, liquidityZero, liquidityTotal0), 
       ZERO);
   ```

2. **Encrypted Transfer**:
   ```solidity
   // Transfer Alice's USDT proceeds (encrypted)
   IFHERC20(USDT).transferFromEncrypted(hook, alice, amount1);
   ```

**Final State:**
```
Alice's Encrypted USDC: 5,000 USDC (original - traded amount) - STILL ENCRYPTED!
Alice's Encrypted USDT: 4,985 USDT (proceeds from trade) - STILL ENCRYPTED!
Trade Completed: Alice sold 5,000 USDC for 4,985 USDT at price ~1.003

KEY INSIGHT: Alice's final balances remain encrypted. External observers cannot determine:
- Her final token amounts
- Whether she profited or lost
- Her remaining trading capacity
```

**Privacy Persistence:** Unlike market order systems where execution reveals all details, Alice's balances stay private permanently until she chooses to unwrap to public tokens.

---

## Technical Architecture Deep Dive

### 1. Hybrid Token Model (`HybridFHERC20.sol`)

Each token is **dual-mode**:

- **Public Mode**: Standard ERC20 (`balanceOf`, `transfer`, `approve`)
- **Encrypted Mode**: FHE operations (`encBalances`, `transferFromEncrypted`, `mintEncrypted`)

**Key Methods:**
```solidity
// Conversion between modes
function wrap(address user, uint128 amount) external;          // Public → Encrypted
function requestUnwrap(address user, euint128 amount) external; // Encrypted → Public (async)
function getUnwrapResult(address user, euint128 burnAmount) external; // Get unwrap result

// Encrypted operations  
function transferFromEncrypted(address from, address to, euint128 amount) external returns (euint128);
function mintEncrypted(address user, InEuint128 memory amount) external;
```

### 2. Privacy Preservation Mechanisms

**a) Encrypted Trade Direction**
```solidity
// Users send both tokens, but only one has real value
euint128 token0Amount = FHE.select(zeroForOne, amount, ZERO);
euint128 token1Amount = FHE.select(zeroForOne, ZERO, amount);

// Both transfers execute - external observers can't tell which is real
IFHERC20(token0).transferFromEncrypted(user, hook, token0Amount);
IFHERC20(token1).transferFromEncrypted(user, hook, token1Amount);
```

**b) Encrypted Amount Handling**
```solidity
// All arithmetic happens under encryption
epochInfo.zeroForOneLiquidity = FHE.add(epochInfo.zeroForOneLiquidity, amount);
epochInfo.liquidityMapToken0[user] = FHE.select(zeroForOne, 
    FHE.add(epochInfo.liquidityMapToken0[user], amount), 
    epochInfo.liquidityMapToken0[user]);
```

**c) Selective Decryption**
- Orders remain encrypted until price conditions trigger decryption
- Only the specific order amounts needed for execution are decrypted
- Decryption is asynchronous via FHE coprocessor

### 3. Order Execution Flow

**Trigger Conditions:**
1. Price crosses order's tick level (`afterSwap` hook)
2. FHE decryption completes (`beforeSwap` hook)
3. Sufficient liquidity available in pool

**Execution Phases:**
1. **Detection**: `afterSwap` identifies crossed ticks
2. **Decryption**: `_decryptEpoch` queues orders for decryption  
3. **Execution**: `beforeSwap` processes decrypted orders
4. **Settlement**: Balances updated, tokens wrapped/unwrapped

### 4. Epoch System & Batching

**Epoch Structure:**
```solidity
struct EncEpochInfo {
    bool zeroForOnefilled;           // Has any zeroForOne order been filled?
    bool oneForZerofilled;           // Has any oneForZero order been filled?
    Currency currency0;              // Token 0 address
    Currency currency1;              // Token 1 address
    euint128 zeroForOneToken0;       // Total token0 traded (zeroForOne direction)
    euint128 zeroForOneToken1;       // Total token1 received (zeroForOne direction)  
    euint128 oneForZeroToken0;       // Total token0 received (oneForZero direction)
    euint128 oneForZeroToken1;       // Total token1 traded (oneForZero direction)
    euint128 zeroForOneLiquidity;    // Total pending zeroForOne orders
    euint128 oneForZeroLiquidity;    // Total pending oneForZero orders
    mapping(address => euint128) liquidityMapToken0;  // User's token0 contributions
    mapping(address => euint128) liquidityMapToken1;  // User's token1 contributions
}
```

**Benefits:**
- **Gas Efficiency**: Multiple orders at same price execute in single transaction
- **Privacy**: Individual order sizes mixed with others at same level
- **Fair Distribution**: Proportional sharing of execution proceeds

### 5. Decryption Queue System

**Components:**
- **Queue Contract**: FIFO queue for decryption handles
- **Order Mapping**: Links decryption handles to order metadata
- **Async Processing**: Decryption happens between transactions

**Flow:**
```
afterSwap → requestDecryption → queue.push(handle) → orderInfo[handle] = metadata
         ↓
beforeSwap → queue.peek() → getUnwrapResult() → execute if ready → queue.pop()
```

---

## Liquidity Addition & AMM Integration

### Regular Liquidity (Not Encrypted)

The protocol works on top of standard Uniswap v4 pools. Regular liquidity providers add liquidity normally:

```solidity
// Standard Uniswap v4 liquidity addition
positionManager.mint(poolKey, tickLower, tickUpper, liquidityAmount, ...);
```

This provides the **base liquidity** that limit orders trade against.

### Limit Orders Are Not Liquidity

**Key Distinction**: Iceberg orders are **NOT liquidity provision** - they are **limit orders** that:
1. Wait for specific price levels
2. Execute as market orders when triggered
3. Trade **against** the existing AMM liquidity

### Pool Composition

A typical pool contains:
```
Regular Liquidity: 80% (standard AMM LPs earning fees)
Pending Limit Orders: 20% (waiting for execution triggers)
```

When limit orders execute, they:
1. Remove liquidity from the AMM (like any swap)
2. Pay fees to regular LPs  
3. Receive market-rate execution
4. Do NOT earn trading fees (they are the traders, not LPs)

---

## Security & Trust Model

### What Stays Private (Key Advantage)
- **Order amounts** until execution  
- **Trade direction** until execution
- **User balances** even after execution (encrypted balances persist)
- **Individual user positions** within an epoch batch
- **Multi-hop trading patterns** (if user does USDC→USDT→ETH, amounts stay hidden)
- **Portfolio composition** (others can't determine user's total holdings)

### What Becomes Public at Execution
- **Pool state changes** (price, total liquidity impact)
- **That orders were filled** at specific tick levels
- **Total epoch volume** (but not individual contributions)
- **Swap direction in pool** (the poolManager.swap call is public)

### What's Always Public  
- **Pool state** (price, liquidity)
- **Tick crossings** (which price levels were hit)
- **Contract interactions** (users calling functions, but parameters are encrypted)

### Trust Assumptions
- **FHE Coprocessor**: Must correctly decrypt values when requested
- **Uniswap v4**: Standard AMM security model
- **Hook Contract**: Must handle encrypted operations correctly

### Attack Vectors & Mitigations
- **MEV**: Limited by encryption - MEV bots can't see order details until execution
- **Front-running**: Impossible to front-run encrypted orders
- **Sandwich attacks**: Reduced effectiveness due to encrypted amounts
- **Gas Analysis**: All transactions have similar gas usage regardless of trade size/direction

---

## Comparison with Other Privacy Approaches

| Feature | Traditional Limit Orders | Market Order Hook | Iceberg Co-FHE |
|---------|--------------------------|-------------------|-----------------|
| **Order Privacy** | None (public book) | Amount hidden ~10s | Direction + amount hidden until execution |
| **Balance Privacy** | None | None (public ERC20) | **Persistent encrypted balances** |
| **MEV Exposure** | High (fully visible) | Medium (amount hidden) | Low (everything hidden) |
| **Front-running** | Easy | Reduced | **Impossible** |
| **Gas Costs** | Low | Medium | **High** (FHE operations) |
| **Execution** | Immediate | ~10s delay | **~20s delay** (decryption) |
| **Composability** | High | **High** (standard tokens) | Low (hybrid tokens) |
| **Implementation** | Simple | **Simple** | **Very Complex** |
| **User Experience** | Good | **Good** | Poor (wrap/unwrap) |

### Key Insight: Architecture Trade-offs

**Iceberg's Unique Value:** **Persistent encrypted balances** - the only system where user portfolio details remain private after trading.

**Market Order Hook Sweet Spot:** **90% of MEV protection with 10% of complexity** - ideal for most users.

**Traditional Orders:** **Maximum efficiency, zero privacy** - suitable for transparent market making.

---

## Conclusion

The Iceberg Co-FHE protocol represents a significant innovation in DeFi privacy, combining:

1. **Fully Homomorphic Encryption** for computation on encrypted data
2. **Uniswap v4 Hooks** for seamless AMM integration  
3. **Hybrid Token Design** supporting both public and private operations
4. **Asynchronous Decryption** for practical FHE implementation
5. **Epoch Batching** for gas efficiency and additional privacy

The result is a limit order system where users can trade without revealing their strategies until execution, providing protection against MEV, front-running, and other forms of value extraction while maintaining the efficiency and composability of automated market makers.

### Architecture Decision Framework:

**Choose Iceberg Co-FHE when:**
- ✅ Users need **persistent balance privacy** (institutions, whales)
- ✅ **Perfect MEV protection** is worth high gas costs
- ✅ **Multi-hop privacy** is required (complex trading strategies)
- ✅ Users can tolerate **complex UX** (wrap/unwrap tokens)

**Choose Market Order Hook when:**
- ✅ Users want **good MEV protection** with **simple UX**
- ✅ **Standard token compatibility** is important
- ✅ **Lower gas costs** matter more than perfect privacy
- ✅ **Broader adoption** is the goal

**Choose Traditional Orders when:**
- ✅ **Maximum efficiency** and **immediate execution** required
- ✅ **Transparency** is acceptable or desired
- ✅ **Lowest gas costs** are critical

**Trade-offs Summary**: Iceberg provides **maximum privacy** at the cost of **maximum complexity**. Market order hooks provide **practical privacy** with **practical usability**. The choice depends on whether persistent encrypted balances justify the architectural overhead.