# 🎯 CipherTradeArena - Encrypted Strategy Tournament Architecture

**Version:** 1.0 PoC
**Last Updated:** 2025-10-24

---

## 📋 Overview

**CipherTradeArena** is a private trading tournament system where traders submit **encrypted DeFi strategies**, an **AVS operator** privately simulates them on fixed notional, and winners are selected based on **encrypted APY rankings**. The system executes **one aggregated public trade** that combines winner strategies while preserving individual strategy privacy.

### Core Innovation
- **Complete Strategy Privacy**: Strategy nodes (protocols, functions, amounts) remain fully encrypted
- **Fair Competition**: All strategies simulated on same fixed notional (e.g., 100k USDC)
- **Time-Agnostic Design**: Simulation window is encrypted to prevent overfitting
- **Aggregated Execution**: Final deployment combines winners without revealing individual strategies

---

## 🏗️ System Architecture

### Key Components

```
┌─────────────┐
│   Traders   │  Submit encrypted strategy arrays
│  (Client)   │  (StrategyNode[] = DeFi action sequences)
└──────┬──────┘
       │ 1. Encrypt via CoFHE.js
       │    [transfer → deposit → borrow → swap → ...]
       ▼
┌─────────────────┐
│  TradeManager   │  2. Store encrypted strategies
│   (On-chain)    │  3. Epoch state management
│                 │  4. Grant AVS permissions
└──────┬──────────┘
       │ 5. EpochClosed event
       ▼
┌─────────────────┐
│  AVS Operators  │  6. Decrypt strategies + sim window
│  (Off-chain)    │  7. Simulate on fixed notional
│                 │  8. Compute APYs
└──────┬──────────┘  9. Encrypt APYs + sign consensus
       │ 10. Post encrypted APYs
       ▼
┌─────────────────┐
│  TradeManager   │ 11. Store encrypted APYs
│   (On-chain)    │ 12. Traders view own APY
└──────┬──────────┘ 13. After deadline: decrypt all
       │ 14. Rank + select winners
       ▼
┌─────────────────┐
│  AVS Operators  │ 15. Aggregate winner strategies
│  (Off-chain)    │ 16. Scale to allocations
│                 │ 17. Batch similar DeFi calls
└──────┬──────────┘ 18. Sign aggregated plan
       │ 19. Execute via BoringVault
       ▼
┌─────────────────┐
│  TradeManager   │ 20. Verify consensus
│   + Vault       │ 21. Deploy capital
└─────────────────┘ 22. Record results
```

---

## 📊 Data Structures

### StrategyNode
**A single encrypted DeFi action in a strategy**

```solidity
struct StrategyNode {
    eaddress encoder;    // Sanitizer/decoder address (encrypted)
    eaddress target;     // Protocol address: Aave, Compound, etc. (encrypted)
    euint32 selector;    // Function selector as uint (encrypted)
    euint256[] args;     // ALL function arguments as euint256 (encrypted)
}
```

**Example (Encrypted):**
```
Node 0: Transfer USDC to vault
  encoder: 0xDecoder...  (encrypted)
  target: 0xVault...     (encrypted)
  selector: 0xa9059cbb   (encrypted - transfer)
  args: [recipient, amount]  (all encrypted as euint256)

Node 1: Approve Aave for USDC
  encoder: 0xDecoder...
  target: 0xUSDC...
  selector: 0x095ea7b3   (encrypted - approve)
  args: [spender, amount]

Node 2: Aave supply
  encoder: 0xDecoder...
  target: 0xAavePool...
  selector: 0x617ba037   (encrypted - supply)
  args: [asset, amount, onBehalfOf, referralCode]
```

### StrategyPerf
**A trader's complete strategy submission + results**

```solidity
struct StrategyPerf {
    StrategyNode[] nodes;    // Array of encrypted actions
    euint256 encryptedAPY;   // Encrypted APY (set by AVS)
    address submitter;       // Strategy owner
    uint256 submittedAt;     // Submission timestamp
    bool finalized;          // Settlement status
}
```

### EpochData
**Per-epoch configuration and metadata**

```solidity
struct EpochData {
    euint64 encSimStartTime;     // Encrypted sim window start
    euint64 encSimEndTime;       // Encrypted sim window end
    uint64 epochStartTime;       // Public submission open time
    uint64 epochEndTime;         // Public submission close time
    uint8[] weights;             // Capital allocation [50, 30, 20]
    uint256 notionalPerTrader;   // Fixed simulation amount (100k)
    uint256 allocatedCapital;    // Real capital to deploy (1M)
    EpochState state;            // Current epoch state
}

enum EpochState {
    OPEN,              // Accepting submissions
    CLOSED,            // Simulating off-chain
    RESULTS_POSTED,    // Encrypted APYs available
    FINALIZED,         // Winners selected
    EXECUTED           // Capital deployed
}
```

---

## 🔄 Complete Flow: UEI-Style Sequence

### **PHASE 1: Epoch Initialization (Admin)**

```
┌─────────┐
│  Admin  │
└────┬────┘
     │
     │ startEpoch(EpochData)
     ▼
┌──────────────────┐
│  TradeManager    │
│                  │
│ 1. Encrypt sim   │─────► CoFHE: Encrypt time window
│    window times  │       (prevents overfitting)
│                  │
│ 2. Validate      │─────► require(sum(weights) == 100)
│    weights[]     │
│                  │
│ 3. Store epoch   │─────► epochs[epochNumber] = EpochData
│    config        │       state = OPEN
│                  │
│ 4. Emit event    │─────► EpochStarted(epochNum, endTime, weights)
└──────────────────┘
```

**Key Point:** Simulation window is **encrypted** so traders cannot overfit to specific dates.

---

### **PHASE 2: Strategy Submission (Traders)**

```
┌────────────┐
│  Trader    │
│ (Client)   │
└─────┬──────┘
      │
      │ Design strategy:
      │ [transfer → deposit → borrow → swap → ...]
      │
      │ For each node:
      ▼
┌─────────────────┐
│  CoFHE.js       │
│  (Client-side)  │
│                 │
│ Encrypt:        │
│ • encoder addr  │────► euint256
│ • target addr   │────► euint256
│ • selector      │────► euint256
│ • args[]        │────► euint256[]
│                 │
│ Output:         │
│ • handles[]     │
│ • inputProof    │
└────────┬────────┘
         │
         │ submitEncryptedStrategy(
         │   epochNumber,
         │   encryptedNodes[],
         │   inputProof
         │ )
         ▼
┌──────────────────────┐
│   TradeManager       │
│                      │
│ 1. Validate epoch    │──► require(state == OPEN)
│    is open           │   require(!hasSubmitted[user])
│                      │
│ 2. Convert handles   │──► FHE.fromExternal()
│    to internal       │   for all node components
│                      │
│ 3. Store strategy    │──► strategies[epoch][submitter] =
│                      │     StrategyPerf{nodes, ...}
│                      │
│ 4. Grant AVS         │──► FHE.allow(operator) for all nodes
│    permissions       │   (for future decryption)
│                      │
│ 5. Emit event        │──► StrategySubmitted(epoch, trader, id)
└──────────────────────┘
```

**Key Point:** All strategy details (protocol, function, amounts) remain **fully encrypted**.

---

### **PHASE 3: Epoch Closure & AVS Processing**

```
After epochEndTime:

┌──────────────┐
│ Admin/Anyone │
└──────┬───────┘
       │
       │ closeEpoch(epochNumber)
       ▼
┌──────────────────────┐
│   TradeManager       │
│                      │
│ 1. Validate timing   │──► require(block.timestamp >= epochEndTime)
│                      │
│ 2. Update state      │──► state = CLOSED
│                      │
│ 3. Select operators  │──► Deterministic based on epochNumber
│                      │   (for PoC: single operator)
│                      │
│ 4. Grant FHE access  │──► FHE.allow(operators) for:
│    to operators      │   • All strategy nodes
│                      │   • Encrypted sim window
│                      │
│ 5. Emit event        │──► EpochClosed(epoch, strategyIds[], ops[])
└──────────────────────┘
       │
       │ Monitor event
       ▼
┌──────────────────────────┐
│   AVS Operators          │
│   (Off-chain)            │
│                          │
│ 1. Fetch strategies      │──► Read from TradeManager storage
│                          │
│ 2. Collect FHE handles   │──► For each strategy:
│                          │     - node[].encoder handles
│                          │     - node[].target handles
│                          │     - node[].selector handles
│                          │     - node[].args[] handles
│                          │   Plus: simStartTime, simEndTime handles
│                          │
│ 3. Batch decrypt         │──► CoFHE Gateway:
│    via CoFHE             │     decrypt(allHandles[])
│                          │
│ 4. Parse strategies      │──► Using decoder configs:
│                          │     "0xAave..." → Aave.supply()
│                          │     args[0] = asset address
│                          │     args[1] = amount
│                          │
│ 5. Simulate each         │──► For each strategy:
│    strategy              │     • Fork state at simStartTime
│                          │     • Start with 100k notional
│                          │     • Execute nodes sequentially
│                          │     • Track portfolio value
│                          │     • End at simEndTime
│                          │     • Compute APY:
│                          │       ((finalValue - 100k) / 100k)
│                          │       * (365 / days)
│                          │
│ 6. Encrypt APYs          │──► For each APY result:
│                          │     encryptedAPY = CoFHE.encrypt(apy)
│                          │     Grant submitter access:
│                          │       FHE.allow(submitter)
│                          │
│ 7. Sign consensus        │──► operators[].sign(
│                          │       epochNumber,
│                          │       encryptedAPYs[]
│                          │     )
└──────────────────────────┘
```

**Key Point:** Operators decrypt strategies privately, simulate on **fixed 100k notional**, and return **encrypted APYs**.

---

### **PHASE 4: Post Encrypted Results**

```
┌──────────────────┐
│  AVS Operator    │
└────────┬─────────┘
         │
         │ reportEncryptedAPYs(
         │   epochNumber,
         │   encryptedAPYs[],
         │   operatorSignatures[]
         │ )
         ▼
┌──────────────────────┐
│   TradeManager       │
│                      │
│ 1. Verify operator   │──► require(isOperator[msg.sender])
│                      │
│ 2. Verify consensus  │──► Check signatures from
│    signatures        │   selected operators
│                      │
│ 3. Validate state    │──► require(state == CLOSED)
│                      │
│ 4. Store APYs        │──► For each strategy:
│                      │     strategies[i].encryptedAPY =
│                      │       encryptedAPYs[i]
│                      │
│ 5. Grant access      │──► FHE.allow(submitter) for their APY
│                      │   (traders can view own results)
│                      │
│ 6. Update state      │──► state = RESULTS_POSTED
│                      │
│ 7. Emit event        │──► EncryptedAPYsPosted(epoch, count)
└──────────────────────┘
```

**During Epoch:**
```
┌─────────┐
│ Trader  │
└────┬────┘
     │
     │ viewMyAPY(epochNumber)
     ▼
┌──────────────────────┐
│   TradeManager       │
│                      │
│ Return encrypted APY │──► Trader decrypts client-side
│ (trader has access)  │   Others: no permission
└──────────────────────┘
```

**Key Point:** Traders see **their own encrypted APY** during the epoch, creating competitive tension without full transparency.

---

### **PHASE 5: Finalization & Winner Selection**

```
After settlement period (e.g., +1 day):

┌──────────────┐
│ Admin/Anyone │
└──────┬───────┘
       │
       │ finalizeEpoch(epochNumber)
       ▼
┌──────────────────────────────┐
│   TradeManager               │
│                              │
│ 1. Request decryption        │──► FHE.requestDecryption(
│    of ALL APYs               │       allAPYHandles[]
│                              │     )
│                              │
│ 2. Gateway callback          │──► finalizeEpochCallback(
│    (async)                   │       decryptedAPYs[]
│                              │     )
│                              │
│ 3. Rank strategies           │──► Sort by APY (descending)
│                              │     strategy[0] = highest APY
│                              │     strategy[1] = 2nd highest
│                              │     ...
│                              │
│ 4. Select winners            │──► Based on weights[]:
│    by weights[]              │     weights = [50, 30, 20]
│                              │
│                              │     Winner 1 (rank 0):
│                              │       50% of allocatedCapital
│                              │     Winner 2 (rank 1):
│                              │       30% of allocatedCapital
│                              │     Winner 3 (rank 2):
│                              │       20% of allocatedCapital
│                              │
│ 5. Store leaderboard         │──► leaderboard[epoch] = [
│                              │       winner1,
│                              │       winner2,
│                              │       winner3
│                              │     ]
│                              │
│                              │     publicAPYs[epoch] = [
│                              │       apy1, apy2, apy3
│                              │     ]
│                              │
│ 6. Update state              │──► state = FINALIZED
│                              │
│ 7. Emit event                │──► EpochFinalized(
│                              │       epoch,
│                              │       winners[],
│                              │       apys[],
│                              │       allocations[]
│                              │     )
└──────────────────────────────┘
```

**Key Point:** All APYs are decrypted simultaneously, ensuring fair ranking and transparency.

---

### **PHASE 6: Aggregated Execution (Capital Deployment)**

```
┌──────────────────┐
│  AVS Operator    │
│  (Off-chain)     │
│                  │
│ Now we have:     │
│ • Winner 1: 7    │──► Allocation: 500k (50%)
│   nodes          │
│ • Winner 2: 8    │──► Allocation: 300k (30%)
│   nodes          │
│ • Winner 3: 6    │──► Allocation: 200k (20%)
│   nodes          │
│                  │
│ GOAL: Execute    │──► One public aggregated trade
│ 1M capital       │   Hides individual strategies
│                  │
│ 1. Scale         │──► For each winner:
│    strategies    │     • Re-simulate with real allocation
│                  │     • Winner 1: 500k (not 100k)
│                  │     • Winner 2: 300k
│                  │     • Winner 3: 200k
│                  │
│ 2. Aggregate     │──► Group by protocol + function:
│    calls         │
│                  │     Example:
│                  │     W1: Aave.supply(USDC, 300k)
│                  │     W2: Aave.supply(USDC, 200k)
│                  │     W3: Aave.supply(USDC, 350k)
│                  │
│                  │     Aggregated:
│                  │     → Aave.supply(USDC, 850k)
│                  │
│                  │     Privacy preserved:
│                  │     Cannot reverse-engineer
│                  │     individual strategies
│                  │
│ 3. Construct     │──► aggregatedPlan = [
│    calldata      │       {
│                  │         target: Aave,
│                  │         selector: supply(),
│                  │         args: [USDC, 850k, ...]
│                  │       },
│                  │       {
│                  │         target: Aave,
│                  │         selector: borrow(),
│                  │         args: [USDC, 400k, ...]
│                  │       },
│                  │       {
│                  │         target: Uniswap,
│                  │         selector: swap(),
│                  │         args: [USDC, ETH, 600k, ...]
│                  │       },
│                  │       ...
│                  │     ]
│                  │
│ 4. Sign          │──► operators[].sign(
│    consensus     │       epochNumber,
│                  │       aggregatedPlan
│                  │     )
└──────┬───────────┘
       │
       │ executeAggregatedPlan(
       │   epochNumber,
       │   aggregatedCalls[],
       │   operatorSignatures[]
       │ )
       ▼
┌──────────────────────────────┐
│   TradeManager               │
│                              │
│ 1. Validate state            │──► require(state == FINALIZED)
│                              │
│ 2. Verify signatures         │──► Check operator consensus
│                              │
│ 3. Execute via Vault         │──► BoringVault.execute(
│                              │       aggregatedCalls[]
│                              │     )
│                              │
│    ┌─────────────────────┐  │
│    │   BoringVault       │  │
│    │                     │  │
│    │ Execute each call:  │  │
│    │ • Aave.supply()     │  │
│    │ • Aave.borrow()     │  │
│    │ • Uniswap.swap()    │  │
│    │ • ...               │  │
│    │                     │  │
│    │ Deploy 1M capital   │  │
│    │ across protocols    │  │
│    │                     │  │
│    │ Return positions    │  │
│    └─────────────────────┘  │
│                              │
│ 4. Update state              │──► state = EXECUTED
│                              │
│ 5. Emit event                │──► EpochExecuted(
│                              │       epoch,
│                              │       totalDeployed: 1M,
│                              │       finalValue
│                              │     )
└──────────────────────────────┘
```

**Key Privacy Feature:**
- Public only sees **aggregated calls** (e.g., "supplied 850k to Aave")
- Individual winner strategies remain **completely private**
- Impossible to reverse-engineer which winner did what
- Only operators know decomposition (trusted/slashable)

---

## 🔑 Key Design Decisions

### 1. Why Encrypt Simulation Window?
- **Prevents overfitting** to specific dates/market conditions
- Forces **time-agnostic** strategy design
- Traders must build robust strategies that work across conditions
- Revealed after finalization for **transparency**

### 2. Why Fixed Notional (100k)?
- **Fair comparison** across all traders
- APY is **capital-agnostic** performance metric
- Actual deployment **scales** winner strategies proportionally
- Eliminates advantage of "bigger is better"

### 3. Why Encrypted APYs During Epoch?
- Traders get **private feedback** (gamification)
- Others can't **front-run or copy**
- Creates **competitive dynamics** without full transparency
- Builds suspense until finalization

### 4. Why Aggregated Execution?
- **Privacy**: Individual strategies never revealed publicly
- **Efficiency**: Batching similar calls saves ~50% gas
- **Security**: Operators can't front-run individual strategies
- **Capital Efficiency**: Combines allocations optimally

### 5. Why AVS Off-Chain Simulation?
- **Computation**: Strategy simulation too expensive on-chain
- **Flexibility**: Complex multi-step strategies with loops
- **Historical Data**: Needs past prices/state for accurate simulation
- **Verification**: Consensus via multiple operators

---

## 🎯 PoC Scope

### ✅ In Scope (What We're Building)
- `startEpoch()` - Initialize epoch with encrypted sim window + weights
- `submitEncryptedStrategy(StrategyNode[])` - Trader submission
- `closeEpoch()` - Lock submissions, grant AVS permissions
- `reportEncryptedAPYs()` - AVS posts encrypted results
- `viewMyAPY()` - Trader decrypts their own APY
- `finalizeEpoch()` - Decrypt all, rank, select winners
- `executeAggregatedPlan()` - Deploy capital via BoringVault

**Simplified Assumptions:**
- Single operator (no multi-operator consensus)
- Mock simulation (not real historical data)
- Events-only result distribution (no encrypted distribution)

### ❌ Out of Scope (Future Enhancements)
- Multi-operator consensus with slashing
- Allowlist/KYC for traders
- Risk constraints on strategies (max leverage, protocol limits)
- Real historical price data simulation
- Encrypted result distribution to users
- Advanced matching algorithms for similar strategies
- Cross-chain strategy execution

---

## 📈 State Machine

```
Epoch Lifecycle:

OPEN
  ↓ (traders submit strategies)
  ↓ epochEndTime reached
CLOSED
  ↓ (AVS simulating off-chain)
  ↓ AVS posts encrypted APYs
RESULTS_POSTED
  ↓ (traders view own APY)
  ↓ settlement period ends
FINALIZED
  ↓ (winners selected, APYs public)
  ↓ AVS aggregates + signs plan
EXECUTED
  ↓ (capital deployed)
  ↓ (epoch complete)
```

---

## 🔐 Security Considerations

1. **FHE Permissions**: Only selected operators can decrypt strategies
2. **Operator Consensus**: Multiple signatures required (future)
3. **Slashing**: Malicious operators slashed for incorrect results (future)
4. **Time Windows**: Encrypted to prevent overfitting
5. **Fair Ranking**: All APYs decrypted simultaneously
6. **Privacy Preservation**: Aggregation prevents strategy leakage

---

## 📚 Reference Documents

**For Development, Always Refer To:**
- **`CIPHER_TRADE_ARENA.md`** (this file) - Complete architecture
- **`core.md`** - FHE library operations and patterns
- **`cofhejs.md`** - CoFHE.js SDK for encryption/decryption
- **`CLAUDE.md`** - Development rules and best practices

---

## 🚀 Next Steps

1. Implement TradeManager contract with epoch management
2. Define StrategyNode and StrategyPerf structs
3. Add encryption/decryption flows for strategies
4. Build AVS operator simulation logic
5. Implement ranking and winner selection
6. Add BoringVault aggregated execution
7. Create frontend for strategy submission
8. Test end-to-end flow with mock data

---

**Last Updated:** 2025-10-24
**Version:** 1.0 PoC Specification
