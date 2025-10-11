# FHE Market Order Hook - User Flow Analysis

## Protocol Overview

This is **NOT a hybrid ERC20 token** - it's a **Uniswap V4 Hook** that enables privacy-preserving market orders using Fully Homomorphic Encryption (FHE). The underlying pool trades regular ERC20 tokens (like USDC/USDT), but users can place market orders where the **order amount is encrypted** to prevent front-running.

## Core Architecture

### What is NOT encrypted:
- ❌ The tokens themselves (USDC and USDT remain regular ERC20s)
- ❌ Pool liquidity or prices
- ❌ User balances after execution (public ERC20 balance changes visible)

### What IS encrypted:
- ✅ **Order amounts only** - how much USDC/USDT the user wants to swap
- ✅ **Trade direction** - whether buying or selling (zeroForOne parameter is public but this is market order so direction is immediate)
- ✅ Order privacy until execution (~10 second decryption window)

## Real-World Example: USDC/USDT Pool

Let's trace through a complete user journey with Alice wanting to swap USDC for USDT.

### Step 1: Pool Setup
**State:**
- Pool: USDC/USDT pair with regular liquidity providers
- Tokens: Normal ERC20 USDC and USDT tokens  
- Hook: MarketOrder contract attached to pool
- Queues: Two empty FIFO queues (USDC→USDT and USDT→USDC)

### Step 2: Alice Places Market Order
**Alice's Intent:** Swap 1000 USDC for USDT (but keep amount private)

**What happens:**
1. Alice calls `placeMarketOrder(poolKey, true, encryptedAmount)`
   - `poolKey`: Identifies USDC/USDT pool
   - `true` = zeroForOne = USDC→USDT direction (PUBLIC - this is the limitation of market orders)
   - `encryptedAmount`: FHE encrypted value of 1000 USDC (PRIVATE)

2. **Hook flushes existing orders first** - processes any previously decrypted orders

3. **Order gets queued:**
   - Encrypted amount (1000 USDC) stored in USDC→USDT queue
   - Order handle mapped to Alice's address
   - FHE decryption process begins (takes ~10 seconds)

**Key State Variables:**
- Alice's USDC balance: Still 1000 USDC (no tokens transferred yet)
- Queue: Contains Alice's encrypted order handle
- Mapping: `userOrders[poolId][handle] = Alice`

### Step 3: Decryption Period
**What happens:**
- FHE decryption runs in background (~10 seconds)
- Alice's order sits in queue, amount still encrypted
- No tokens have moved yet
- Other users can place orders in same/opposite direction

**State:**
- Alice's tokens: Unchanged (1000 USDC, 0 USDT)
- Order status: Encrypted, queued, waiting for decryption

### Step 4: Trigger Event (Another User's Swap)
**Scenario:** Bob makes a regular USDT→USDC swap

**What happens:**
1. Bob calls regular swap function on the pool
2. **beforeSwap hook triggers** - this is the key execution moment
3. Hook calls `_settleDecryptedOrders()` for both directions
4. Hook finds Alice's order is now decrypted (reveals 1000 USDC)

### Step 5: Alice's Order Execution
**Execution Flow:**

1. **Token Collection Phase:**
   - Hook tries to transfer 1000 USDC from Alice to itself
   - If Alice has sufficient balance and approval → success
   - If not → order marked as failed and removed from queue

2. **Swap Execution Phase** (assuming success):
   - Hook swaps 1000 USDC for USDT via pool manager
   - Let's say receives 999 USDT (after fees/slippage)

3. **Settlement Phase:**
   - Hook settles with pool manager (sends USDC, receives USDT)
   - Hook transfers 999 USDT directly to Alice
   - Order removed from queue
   - `OrderSettled` event emitted

**Final State:**
- Alice's tokens: 0 USDC, 999 USDT
- Hook's tokens: 0 (just facilitates, doesn't hold)
- Queue: Empty (Alice's order processed and removed)

## Key Mechanisms Deep Dive

### beforeSwap Hook Logic
```
For every swap on the pool:
1. Check both queues (USDC→USDT and USDT→USDC)  
2. Process all decrypted orders in FIFO order
3. For each decrypted order:
   - Try to collect input tokens from user
   - If successful: execute swap and send output tokens to user
   - If failed: mark as failed and remove from queue
4. Continue with original swap
```

### Queue Management
- **Two queues per pool:** One for each direction
- **FIFO processing:** First order placed = first order executed
- **Atomic operations:** Either order fully succeeds or fully fails
- **Auto-flush:** New orders trigger processing of existing decrypted orders

### Token Flow Summary
```
User's Perspective:
1. Place order: No token movement (just encrypt amount)
2. Wait for decryption: Still no movement
3. Execution: Input tokens transferred out, output tokens received

Hook's Perspective:
1. Receives encrypted order
2. When decrypted + triggered: Collects input, swaps, sends output
3. Never holds tokens permanently (just facilitates)

Pool's Perspective:
1. Regular liquidity pool
2. Hook performs swaps like any other trader
3. No special encrypted token handling needed
```

## Important Clarifications

### This is NOT:
- ❌ A new token standard or hybrid ERC20
- ❌ An encrypted token that users hold
- ❌ A pool that trades encrypted assets
- ❌ A system where liquidity provision is encrypted

### This IS:
- ✅ A privacy layer for market order amounts
- ✅ A front-running protection mechanism
- ✅ A FIFO queue system for delayed execution
- ✅ An addon to existing Uniswap V4 pools

### Liquidity Provision
Liquidity providers add regular USDC/USDT to the pool using standard Uniswap mechanisms. The FHE system only affects market orders, not liquidity provision.

### Privacy Analysis

**Privacy Protection Period:**
- **During placement → execution (~10s):** Order amount is hidden from MEV bots
- **At execution:** Both amount and direction become fully public via:
  - Token transfers: `IERC20(USDC).transferFrom(alice, hook, 1000)`
  - Pool swap: `poolManager.swap(key, {zeroForOne: true, amount: 1000})`
  - Balance changes: Alice's public USDC/USDT balances update

**MEV Protection:**
- ✅ **Sandwich attack protection:** Bots can't see order size to sandwich
- ✅ **Front-running protection:** ~10s window where order details are hidden
- ❌ **Direction is public at placement:** Bots know Alice wants USDC→USDT
- ❌ **Full transparency at execution:** All details become public

## Technical Security Features

1. **Reentrancy Protection:** Uses OpenZeppelin's ReentrancyGuardTransient
2. **Safe Token Transfers:** Uses SafeERC20 with try/catch for failed transfers
3. **FIFO Fairness:** Orders processed in placement order
4. **Atomic Execution:** Orders either fully succeed or cleanly fail
5. **No Token Custody:** Hook doesn't permanently hold user funds

## Architecture Comparison Summary

### Market Order Hook (This Implementation):
**Strengths:**
- ✅ **Simple implementation:** Works with standard ERC20 tokens
- ✅ **Good composability:** Integrates with existing DeFi ecosystem
- ✅ **Lower gas costs:** No encrypted token operations
- ✅ **Amount privacy:** Protects against sandwich attacks
- ✅ **Immediate execution:** Market orders execute when any swap occurs

**Limitations:**
- ❌ **Direction visible at placement:** MEV bots know buy/sell intent immediately
- ❌ **Full transparency at execution:** All details public after execution
- ❌ **No persistent privacy:** User balances remain public ERC20
- ❌ **Individual execution:** Orders execute separately (no batching privacy)

**Best For:** General MEV protection, retail traders, applications needing standard token compatibility

### Key Architectural Insight:
This architecture provides **temporal privacy** (amount hidden for ~10s) with **excellent practical usability**. The privacy window is sufficient to prevent most MEV attacks while maintaining full DeFi composability through standard ERC20 tokens.