# Rules for Claude - CipherTradeArena AVS Development

> **Before making ANY change, follow these rules in order.**

---

## 0. Package Manager & Environment

**IMPORTANT**: This project spans multiple environments with different package managers.

### Contracts (Solidity/Foundry)
```
✅ DO: Use forge for contract development
- forge build
- forge test
- forge script <path> --broadcast
- forge install <dependency>

❌ DON'T: Use npm, yarn, or bun in the contracts folder
```

### Operator (TypeScript/Node)
```
✅ DO: Use npm for operator development
- npm install
- npm run dev
- npm run build

❌ DON'T: Use bun or yarn in the operator folder
```

### Nonce Management
```
✅ CRITICAL: Always add nonce wherever submitting transactions
- Prevents "nonce too low" errors
- Track and increment nonce manually in operator code
```

---

## 1. Check the Docs First

### Must Read Before Coding:
- **`CIPHER_TRADE_ARENA.md`** → Complete system architecture, data flow, and sequence diagrams
- **`core.md`** → FHE library operations (FHE.sol functions, types, access control)
- **`cofhejs.md`** → CoFHE.js SDK for operator-side encryption/decryption
- **`README_ZAMA.md`** → UEI reference architecture (similar pattern to CipherTradeArena)

**Rule**: If you don't know how FHE works, how to encrypt/decrypt, or how the flow works, READ these docs first. Don't guess.

---

## 2. Iterative Development - One Step at a Time

```
✅ DO: Add ONE feature/function at a time
✅ DO: Compile and test after EACH change
✅ DO: Modify existing files when context suits (don't create new files unnecessarily)
✅ DO: Make incremental changes
✅ DO: Verify FHE permissions are correctly granted

❌ DON'T: Make big sweeping changes
❌ DON'T: Create multiple test scripts (e.g., testStrategy.ts, testStrategyV2.ts, checkAPY.ts)
❌ DON'T: Add unnecessary files - keep the repo LEAN
❌ DON'T: Hallucinate new contracts when existing ones can be modified
❌ DON'T: Change FHE logic without verifying access control
❌ DON'T: Create new storage patterns - follow existing mappings
```

**Rule**: Small steps. One feature. Compile. Test. Repeat. If a file exists and fits the purpose, modify it instead of creating a new one.

**Example - Testing:**
```
❌ WRONG: Creating multiple scripts
operator/testStrategy.ts
operator/testStrategyLatest.ts
operator/checkAPY.ts
operator/verifySimulation.ts

✅ CORRECT: One reusable script
operator/test.ts (with different functions/flags as needed)
```

---

## 3. Follow the Architecture

### CipherTradeArena Flow (from CIPHER_TRADE_ARENA.md)
```
Trader (Client) → TradeManager (On-chain) → AVS (Off-chain) → TradeManager (On-chain) → BoringVault (Execution)

PHASE 1: Epoch Initialization (startEpoch)
PHASE 2: Strategy Submission (submitEncryptedStrategy)
PHASE 3: Epoch Closure & AVS Processing (closeEpoch, decrypt, simulate)
PHASE 4: Post Encrypted Results (reportEncryptedAPYs)
PHASE 5: Finalization (finalizeEpoch, rank, select winners)
PHASE 6: Aggregated Execution (executeAggregatedPlan)
```

**Rule**: Never deviate from this flow. All code must fit into one of these phases.

### Where Things Go
**Contracts:**
- Core logic → `contracts/src/TradeManager.sol`
- Interfaces → `contracts/src/ITradeManager.sol`
- Vault integration → `contracts/src/BoringVault.sol`
- Deploy scripts → `contracts/script/`
- Tests → `contracts/test/`

**Operator:**
- Event listeners → `operator/eventListener.ts`
- Simulation logic → `operator/simulator.ts`
- Strategy decryption → `operator/decryptStrategies.ts`
- APY encryption → `operator/encryptAPYs.ts`
- Main orchestrator → `operator/index.ts`
- Types → `operator/types.ts`
- Utils → `operator/utils/`

---

## 4. FHE-Specific Rules

### Critical FHE Patterns (from core.md)

#### Access Control - NEVER FORGET THIS
```solidity
// ❌ WRONG: Storing encrypted data without granting access
function storeStrategy(euint256 encryptedNode) external {
    strategies[msg.sender] = encryptedNode;
}

// ✅ CORRECT: Always grant access when storing
function storeStrategy(euint256 encryptedNode) external {
    strategies[msg.sender] = encryptedNode;
    FHE.allowThis(encryptedNode);     // Contract needs access
    FHE.allowSender(encryptedNode);   // User needs access
}
```

#### Returning Encrypted Values
```solidity
// ❌ WRONG: No access granted
function getAPY() external view returns (euint256) {
    return apys[msg.sender];  // User can't decrypt!
}

// ✅ CORRECT: Access already granted in storage function
function getAPY() external view returns (euint256) {
    return apys[msg.sender];  // User already has access from storage
}
```

#### Granting AVS Operator Access
```solidity
// ✅ CORRECT: Grant operators access to decrypt
function closeEpoch(uint256 epochNumber) external {
    EpochData storage epoch = epochs[epochNumber];

    // Grant operator access to ALL strategy components
    for (uint i = 0; i < strategies.length; i++) {
        for (uint j = 0; j < strategies[i].nodes.length; j++) {
            FHE.allow(strategies[i].nodes[j].encoder, operator);
            FHE.allow(strategies[i].nodes[j].target, operator);
            FHE.allow(strategies[i].nodes[j].selector, operator);
            for (uint k = 0; k < strategies[i].nodes[j].args.length; k++) {
                FHE.allow(strategies[i].nodes[j].args[k], operator);
            }
        }
    }

    // Grant access to encrypted sim window
    FHE.allow(epoch.encSimStartTime, operator);
    FHE.allow(epoch.encSimEndTime, operator);
}
```

#### Conditional Logic with FHE
```solidity
// ❌ WRONG: Using ebool in if statement
ebool condition = FHE.gt(apy1, apy2);
if (condition) {  // ERROR: Won't compile!
    return apy1;
}

// ✅ CORRECT: Use FHE.select
ebool condition = FHE.gt(apy1, apy2);
euint256 winner = FHE.select(condition, apy1, apy2);
return winner;
```

#### Encrypted Constants
```solidity
// ✅ CORRECT: Create once in constructor
contract TradeManager {
    euint256 private ENCRYPTED_ZERO;

    constructor() {
        ENCRYPTED_ZERO = FHE.asEuint256(0);
        FHE.allowThis(ENCRYPTED_ZERO);  // Contract needs access
    }

    function useZero() external {
        // Reuse constant efficiently
        euint256 result = FHE.select(condition, value, ENCRYPTED_ZERO);
    }
}
```

### CoFHE.js Patterns for Operator (from cofhejs.md)

#### Initialization
```typescript
import { cofhejs } from "cofhejs/node";
import { ethers } from "ethers";

const provider = new ethers.JsonRpcProvider(RPC_URL);
const wallet = new ethers.Wallet(OPERATOR_PRIVATE_KEY, provider);

await cofhejs.initializeWithEthers({
  ethersProvider: provider,
  ethersSigner: wallet,
  environment: "TESTNET"
});
```

#### Encrypting Strategy Nodes (Client-side)
```typescript
// Trader encrypts strategy before submission
const encryptedNodes = await cofhejs.encrypt([
  Encryptable.address(encoderAddress),
  Encryptable.address(targetAddress),
  Encryptable.uint32(selector),
  Encryptable.uint256(arg1),
  Encryptable.uint256(arg2),
] as const);

// Submit to TradeManager
await tradeManager.submitEncryptedStrategy(
  epochNumber,
  encryptedNodes.data,
  { gasLimit: 5000000 }
);
```

#### Decrypting Strategies (Operator-side)
```typescript
// Operator decrypts after closeEpoch grants permissions
const permit = await cofhejs.createPermit({
  type: 'self',
  issuer: operatorAddress,
});

// Get sealed strategy data from contract
const sealedStrategy = await tradeManager.getStrategy(epochNumber, strategyId);

// Unseal each component
const encoder = await cofhejs.unseal(sealedStrategy.encoder, FheTypes.Address);
const target = await cofhejs.unseal(sealedStrategy.target, FheTypes.Address);
const selector = await cofhejs.unseal(sealedStrategy.selector, FheTypes.Uint32);
const args = await Promise.all(
  sealedStrategy.args.map(arg => cofhejs.unseal(arg, FheTypes.Uint256))
);
```

#### Encrypting APYs (Operator posts results)
```typescript
// Operator encrypts computed APYs before posting
const encryptedAPYs = await cofhejs.encrypt(
  apyResults.map(apy => Encryptable.uint256(apy))
);

// Sign and submit
const signature = await wallet.signMessage(
  ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
    ['uint256', 'uint256[]'],
    [epochNumber, encryptedAPYs.data]
  ))
);

await tradeManager.reportEncryptedAPYs(
  epochNumber,
  encryptedAPYs.data,
  [signature],
  { nonce: await provider.getTransactionCount(operatorAddress), gasLimit: 5000000 }
);
```

---

## 5. Error Handling is Not Optional

**Rule**: Every blockchain operation MUST handle errors properly.

### Contracts (Solidity)
```solidity
// ✅ CORRECT: Proper validation
function submitEncryptedStrategy(
    uint256 epochNumber,
    StrategyNode[] calldata nodes
) external {
    require(epochs[epochNumber].state == EpochState.OPEN, "Epoch not open");
    require(!hasSubmitted[epochNumber][msg.sender], "Already submitted");
    require(nodes.length > 0, "Empty strategy");
    require(nodes.length <= MAX_NODES, "Too many nodes");

    // Process strategy...
}
```

### Operator (TypeScript)
```typescript
// ✅ CORRECT: Proper error handling
async function simulateStrategy(strategy: DecryptedStrategy): Promise<APY> {
  try {
    const result = await runSimulation(strategy);

    if (!result.success) {
      console.error(`Simulation failed: ${result.error}`);
      return { apy: 0n, error: result.error };
    }

    return { apy: result.data.apy, error: null };
  } catch (error) {
    console.error('Unexpected simulation error:', error);
    return { apy: 0n, error: error.message };
  }
}
```

### CoFHE.js Result Pattern
```typescript
// ✅ CORRECT: Check Result type
const result = await cofhejs.unseal(sealedData, FheTypes.Uint256);

if (!result.success) {
  console.error('Unsealing failed:', result.error);
  return;
}

const value = result.data;  // Safe to use
```

---

## 6. Type Everything

**Rule**: No `any`, no untyped props, no untyped functions.

### Contracts (Solidity)
```solidity
// ✅ CORRECT: Explicit types
struct StrategyNode {
    eaddress encoder;
    eaddress target;
    euint32 selector;
    euint256[] args;
}

struct StrategyPerf {
    StrategyNode[] nodes;
    euint256 encryptedAPY;
    address submitter;
    uint256 submittedAt;
    bool finalized;
}
```

### Operator (TypeScript)
```typescript
// ✅ CORRECT: Typed interfaces
interface DecryptedStrategyNode {
  encoder: string;
  target: string;
  selector: number;
  args: bigint[];
}

interface SimulationResult {
  finalValue: bigint;
  apy: bigint;
  success: boolean;
  error?: string;
}

// ❌ WRONG: Using any
function processStrategy(data: any) {
  return data.map((item: any) => item.apy);
}

// ✅ CORRECT: Proper types
function processStrategies(strategies: DecryptedStrategy[]): bigint[] {
  return strategies.map(strategy => strategy.apy);
}
```

---

## 7. Security & Privacy Awareness

### FHE Privacy Rules
```
✅ DO: Keep strategies encrypted until operator decrypts
✅ DO: Grant FHE permissions only to authorized operators
✅ DO: Aggregate execution to hide individual strategies
✅ DO: Encrypt simulation window to prevent overfitting

❌ DON'T: Log decrypted strategy details
❌ DON'T: Store decrypted strategies on-chain
❌ DON'T: Reveal APYs before finalization
❌ DON'T: Front-run traders based on encrypted data
```

### Operator Security
```
✅ DO: Validate operator signatures before executing
✅ DO: Use environment variables for private keys
✅ DO: Rate-limit simulation requests
✅ DO: Verify epoch state before processing

❌ DON'T: Hardcode private keys
❌ DON'T: Skip signature verification
❌ DON'T: Process strategies from invalid epochs
```

---

## 8. Testing Mindset

### Before Committing Code

**Contracts:**
1. ✅ Does it compile? (`forge build`)
2. ✅ Do all tests pass? (`forge test`)
3. ✅ Are FHE permissions correctly granted?
4. ✅ Does it handle invalid epochs?
5. ✅ Does it prevent double submissions?

**Operator:**
1. ✅ Does it decrypt correctly?
2. ✅ Does it handle missing strategies?
3. ✅ Does it encrypt APYs properly?
4. ✅ Does it sign consensus messages?
5. ✅ Does it include nonce in transactions?

---

## 9. Git Commit Rules

**Commit Message Format:**
- Maximum 50 characters for the subject line
- Clear, descriptive, action-oriented language
- Never mention Claude or AI assistance
- Never include "Co-Authored-By: Claude"

**Example:**
```
Update TradeManager epoch lifecycle
Update operator simulation logic
Add encrypted APY reporting
Fix FHE permission grants
```

**What NOT to do:**
```
❌ Fixed some stuff and updated contracts

🤖 Generated with Claude Code
Co-Authored-By: Claude <noreply@anthropic.com>
```

---

## 10. Performance Consciousness

### Gas Optimization (Contracts)
```solidity
// ✅ CORRECT: Cache array length
uint256 length = strategies.length;
for (uint i = 0; i < length; i++) {
    // Process strategies
}

// ❌ WRONG: Repeated storage reads
for (uint i = 0; i < strategies.length; i++) {
    // strategies.length read on every iteration
}
```

### Operator Efficiency
```typescript
// ✅ CORRECT: Batch decrypt
const handles = strategies.flatMap(s =>
  s.nodes.flatMap(n => [n.encoder, n.target, n.selector, ...n.args])
);
const decrypted = await cofhejs.batchUnseal(handles);

// ❌ WRONG: Decrypt one by one
for (const strategy of strategies) {
  for (const node of strategy.nodes) {
    await cofhejs.unseal(node.encoder);  // Multiple round trips
    await cofhejs.unseal(node.target);
    // ...
  }
}
```

---

## 11. Documentation Standards

### Document Non-Obvious Decisions
```solidity
// ✅ GOOD: Explains the "why"
// Simulation window is encrypted to prevent traders from
// overfitting strategies to specific market conditions
euint64 public encSimStartTime;
euint64 public encSimEndTime;

// ❌ BAD: No context
euint64 public encSimStartTime;
```

```typescript
// ✅ GOOD: Explains the approach
// We aggregate similar DeFi calls to preserve strategy privacy.
// Public only sees "supplied 850k to Aave", not individual allocations.
const aggregatedCalls = aggregateBatchCalls(winnerStrategies);
```

---

## 12. Don't Over-Engineer

**Rule**: Solve the problem at hand. Don't build abstractions for hypothetical future needs.

```typescript
// ❌ WRONG: Over-engineered for PoC
class StrategySimulationFactory {
  createSimulator(type: string): IStrategySimulator {
    return this.simulators[type] ?? new DefaultSimulator();
  }
}

// ✅ CORRECT: Solves current need simply
async function simulateStrategy(strategy: DecryptedStrategy): Promise<SimulationResult> {
  // Run simulation on 100k notional
  // Return APY
}
```

---

## Quick Decision Tree

```
Before writing code, ask:

1. Do I know WHERE this goes?
   NO → Read CIPHER_TRADE_ARENA.md
   YES ↓

2. Does this involve FHE operations?
   YES → Read core.md
   NO ↓

3. Does this involve operator encryption/decryption?
   YES → Read cofhejs.md
   NO ↓

4. Am I following the 6-phase architecture?
   NO → Re-read CIPHER_TRADE_ARENA.md flow
   YES ↓

5. Are FHE permissions correctly granted?
   NO → Add FHE.allow*() calls
   YES ↓

6. Is everything typed?
   NO → Add types
   YES ↓

7. Have I handled errors properly?
   NO → Add error handling
   YES ↓

8. Am I including nonce in transactions?
   NO → Add nonce parameter
   YES ↓

9. Can I modify an existing file instead of creating a new one?
   YES → Modify existing file
   NO ↓

10. Am I making ONE small change at a time?
    NO → Break into smaller steps
    YES ↓

11. Am I certain about the approach?
    NO → Ask user
    YES → Proceed
```

---

## Summary: The Golden Rules

1. **Read docs first** (CIPHER_TRADE_ARENA.md, core.md, cofhejs.md)
2. **One step at a time** (iterative development, modify before creating)
3. **Follow the 6-phase architecture** (Epoch Init → Submit → Close → Report → Finalize → Execute)
4. **FHE access control is CRITICAL** (Always grant permissions)
5. **Handle all errors** (Solidity reverts, TypeScript Result types)
6. **Type everything** (Solidity structs, TypeScript interfaces)
7. **Always add nonce** (Operator transactions)
8. **Keep strategies private** (Aggregate execution, no logging)
9. **Test mentally before committing**
10. **Stay lean and simple**

---

## Reference Architecture Summary

### CipherTradeArena Flow
```
1. Admin → startEpoch(encrypted sim window, weights[])
2. Traders → submitEncryptedStrategy(StrategyNode[])
3. Admin → closeEpoch() [grants AVS permissions]
4. AVS → decrypt strategies, simulate on 100k, compute APYs
5. AVS → reportEncryptedAPYs() [encrypted results]
6. Traders → viewMyAPY() [decrypt own result]
7. Admin → finalizeEpoch() [decrypt all, rank, select winners]
8. AVS → executeAggregatedPlan() [deploy capital via BoringVault]
```

### Key Data Structures
```solidity
struct StrategyNode {
    eaddress encoder;    // Protocol decoder
    eaddress target;     // Aave, Compound, etc.
    euint32 selector;    // Function selector
    euint256[] args;     // All args as euint256
}

struct StrategyPerf {
    StrategyNode[] nodes;
    euint256 encryptedAPY;
    address submitter;
    uint256 submittedAt;
    bool finalized;
}

struct EpochData {
    euint64 encSimStartTime;     // Encrypted
    euint64 encSimEndTime;       // Encrypted
    uint64 epochStartTime;       // Public
    uint64 epochEndTime;         // Public
    uint8[] weights;             // [50, 30, 20]
    uint256 notionalPerTrader;   // 100k
    uint256 allocatedCapital;    // 1M
    EpochState state;
}
```

---

*These rules exist to maintain code quality, preserve privacy, and ensure correct FHE usage. Follow them strictly.*
