# Universal Privacy Hook - Implementation Plan 🔐

**Project**: Universal Privacy Hook for Uniswap V4
**Goal**: Enable private swaps on any Uniswap V4 pool using FHE encrypted tokens
**Architecture**: Multi-pool hook with encrypted token factory pattern

---

## 📋 Executive Summary

This plan implements a **Universal Privacy Hook** that can be attached to any Uniswap V4 pool to enable private swaps. Users deposit standard ERC20 tokens (USDC, USDT, WETH, etc.) and receive transferable encrypted tokens (eUSDC, eUSDT, eWETH). They can then submit encrypted swap intents that are processed privately through the hook, maintaining amount and direction privacy until execution.

### Key Innovation: Hybrid of Three Approaches
Our architecture combines the best elements from our analysis:

1. **From Market Order Hook**: Direct hook processing, queue-based execution, standard ERC20 compatibility
2. **From Iceberg**: Encrypted balance persistence, both direction and amount privacy  
3. **Our Innovation**: Universal multi-pool support, encrypted token factory, vault-as-peg-maintainer

---

## 🏗️ Core Architecture

### High-Level Flow
```
1. Pool enables UniversalPrivacyHook during initialization
2. User deposits USDC → Hook mints eUSDC (transferable encrypted token)
3. User submits encrypted intent: eUSDC → eUSDT (amount + direction private)
4. Hook processes intent: swaps hook's USDC reserves → USDT, mints eUSDT to user
5. User can transfer/use eUSDT or withdraw to plain USDT
```

### Component Architecture
```
UniversalPrivacyHook (single hook, multiple pools)
├── Per-Pool State Management
│   ├── poolEncryptedTokens[poolId][currency] → FHERC20 contract
│   ├── poolReserves[poolId][currency] → uint256 backing
│   └── poolIntentQueues[poolId] → Queue of pending intents
├── Hook Functions  
│   ├── deposit(poolKey, currency, amount) → mint encrypted tokens
│   ├── submitIntent(poolKey, tokenIn, tokenOut, encAmount) → queue encrypted intent
│   ├── beforeSwap() → process ready intents, block external swaps
│   └── withdraw(poolKey, currency, amount) → burn encrypted, return plain
└── Encrypted Token Factory
    └── Creates FHERC20 tokens on-demand per pool/currency pair
```

---

## 🎯 Technical Design

### 1. Universal Hook Support
**Capability**: One hook deployment serves infinite pools

```solidity
// Any pool can enable privacy by setting this hook
PoolKey memory anyPool = PoolKey({
    currency0: Currency.wrap(tokenA),
    currency1: Currency.wrap(tokenB),
    fee: 3000,
    tickSpacing: 60,
    hooks: IHooks(universalPrivacyHook)  // Same hook for all pools
});
```

**Benefits**:
- ✅ Network effects: More pools = more utility
- ✅ Liquidity aggregation across all pools  
- ✅ Cross-pool arbitrage with encrypted balances
- ✅ Single codebase maintains all pools

### 2. Encrypted Token Factory Pattern
**Innovation**: Automatic encrypted token creation per pool/currency

```solidity
// First deposit to USDC/USDT pool automatically creates:
FHERC20 eUSDC = new FHERC20("Encrypted USDC", "eUSDC");
FHERC20 eUSDT = new FHERC20("Encrypted USDT", "eUSDT");

// First deposit to WETH/WBTC pool automatically creates:  
FHERC20 eWETH = new FHERC20("Encrypted WETH", "eWETH");
FHERC20 eWBTC = new FHERC20("Encrypted WBTC", "eWBTC");
```

**Benefits**:
- ✅ True token composability (transferable, DeFi-compatible)
- ✅ User not locked to single platform
- ✅ Clear 1:1 backing model
- ✅ Standard ERC20 interfaces for encrypted tokens

### 3. Privacy Model
**What's Private**:
- ✅ Intent amounts (encrypted until execution)
- ✅ Intent direction (encrypted until execution) 
- ✅ User balance details (persistent encryption)
- ✅ Individual execution sizes (batched processing)

**What's Public**:
- ❌ Pool reserves and prices
- ❌ Hook's aggregate swap amounts  
- ❌ Deposit/withdraw amounts (entry/exit points)
- ❌ That intents were processed (timing visible)

**Privacy Protection Mechanisms**:
1. **Encrypted Intents**: Amount + direction hidden until decryption
2. **Batched Processing**: Multiple intents execute together
3. **Vault Trading**: Hook trades on behalf of users (no direct user-pool interaction)
4. **Queue Processing**: Intents processed when other swaps trigger beforeSwap

### 4. Economic Model
**Hook as Peg Maintainer**:
```
Hook Reserves = Total Encrypted Token Supply (1:1 backing)

For USDC/USDT pool:
hook.balance(USDC) + hook.balance(USDT) = eUSDC.totalSupply + eUSDT.totalSupply
```

**User Journey Economics**:
```
1. Deposit: 1000 USDC → Hook reserves +1000 USDC, User gets 1000 eUSDC
2. Intent: User burns 200 eUSDC → Hook swaps 200 USDC→USDT → User gets ~200 eUSDT  
3. Withdraw: User burns 200 eUSDT → Hook reserves -200 USDT, User gets 200 USDT
```

---

## 🛠️ Implementation Components

### Phase 1: Core FHE Infrastructure (Week 1)
**Deliverables**:
- [ ] `IFHERC20.sol` - Interface for encrypted tokens
- [ ] `FHERC20.sol` - FHE-powered encrypted token implementation  
- [ ] FHE access control patterns and constants
- [ ] Basic encrypted arithmetic operations

**Key Files**:
```
src/privacy/
├── interfaces/
│   └── IFHERC20.sol
├── FHERC20.sol
└── lib/
    └── FHEHelpers.sol
```

**Critical FHE Patterns**:
```solidity
// Always grant access when storing
function storeEncryptedValue(euint128 value) internal {
    storage[key] = value;
    FHE.allowThis(value);    // Contract needs access
    FHE.allowSender(value);  // User needs access
}

// Use select for all conditionals
function conditionalTransfer(euint128 balance, euint128 amount) internal returns (euint128) {
    ebool canTransfer = FHE.gte(balance, amount);
    return FHE.select(canTransfer, amount, FHE.asEuint128(0));
}
```

### Phase 2: Hook Core Logic (Week 2)
**Deliverables**:
- [ ] `UniversalPrivacyHook.sol` - Main hook contract
- [ ] Multi-pool state management
- [ ] Deposit/withdraw functionality with encrypted token minting
- [ ] Currency validation against pool pairs

**Key Functions**:
```solidity
contract UniversalPrivacyHook is BaseHook {
    function deposit(PoolKey calldata key, Currency currency, uint256 amount) external;
    function submitIntent(PoolKey calldata key, Currency tokenIn, Currency tokenOut, InEuint128 calldata encAmount, uint64 deadline) external;
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata data) external override returns (bytes4);
    function withdraw(PoolKey calldata key, Currency currency, uint256 amount, address recipient) external;
}
```

### Phase 3: Intent Processing System (Week 2)
**Deliverables**:
- [ ] Intent data structures and storage
- [ ] Per-pool intent queues (reuse existing Queue.sol)
- [ ] Encrypted intent submission with FHE decryption requests
- [ ] Intent validation and deadline management

**Intent Flow**:
```solidity
struct Intent {
    euint128 encAmount;      // Encrypted amount to swap
    Currency tokenIn;        // Pool's currency0 or currency1  
    Currency tokenOut;       // Pool's currency1 or currency0
    address owner;           // User who submitted intent
    uint64 deadline;         // Expiration timestamp
}
```

### Phase 4: Swap Execution Logic (Week 3)
**Deliverables**:
- [ ] beforeSwap hook processing of decrypted intents
- [ ] Hook-initiated swaps via PoolManager
- [ ] Encrypted balance updates after execution
- [ ] Reserve management and 1:1 backing validation

**Execution Pattern**:
```solidity
function _processReadyIntents(PoolKey memory key) internal {
    // Check intent queue for this specific pool
    // Process all decrypted intents
    // Execute hook swaps via poolManager.swap()
    // Update encrypted balances and reserves
    // Mint encrypted output tokens to users
}
```

### Phase 5: Testing & Integration (Week 4)
**Deliverables**:
- [ ] Comprehensive test suite based on MarketOrder.t.sol patterns
- [ ] Multi-pool testing (USDC/USDT, WETH/WBTC, cross-pool scenarios)
- [ ] FHE operation testing with proper vm.warp timing
- [ ] Integration tests with real Uniswap v4 pools

**Test Scenarios**:
```solidity
// Basic flow test
function testDepositSubmitIntentExecuteWithdraw() public;

// Multi-pool test  
function testCrossPoolPrivateSwaps() public;

// Privacy test
function testIntentAmountsRemainPrivate() public;

// Batching test
function testMultipleIntentsBatchedExecution() public;
```

---

## 🔒 Security Considerations

### FHE Security Patterns
1. **Access Control**: Always use `FHE.allowThis()` when storing encrypted values
2. **Permission Management**: Grant minimal necessary permissions per operation
3. **Decryption Safety**: Use `getDecryptResultSafe()` to handle timing gracefully
4. **Conditional Logic**: Always use `FHE.select()` instead of `if` statements with encrypted booleans

### Hook Security
1. **Pool Validation**: Verify hook is enabled for pool before processing
2. **Currency Validation**: Ensure currencies belong to the specified pool
3. **Reserve Management**: Maintain exact 1:1 backing between reserves and encrypted token supply  
4. **Reentrancy Protection**: Use OpenZeppelin's ReentrancyGuard for state-changing functions

### Privacy Protection
1. **Intent Queuing**: Process intents only when external swaps trigger beforeSwap
2. **Batching**: Execute multiple intents together when possible
3. **Access Restriction**: Block direct pool swaps to force intent-based privacy
4. **Timing Isolation**: Separate intent submission from execution timing

---

## 🚀 Deployment Strategy

### Development Phases
1. **Local Testing**: Anvil + mocked CoFHE contracts
2. **Fhenix Testnet**: Real FHE operations, limited testing
3. **Mainnet Preparation**: Audit, optimization, documentation

### Scaling Plan
1. **Phase 1**: Launch with USDC/USDT pool only
2. **Phase 2**: Add major pairs (WETH/USDC, WETH/WBTC) 
3. **Phase 3**: Enable community pool adoption
4. **Phase 4**: Cross-pool routing and advanced features

---

## 📊 Success Metrics

### Privacy Goals
- ✅ Intent amounts remain encrypted until execution  
- ✅ Intent directions remain encrypted until execution
- ✅ Individual swap sizes not observable (batched execution)
- ✅ User balance details remain private (persistent encryption)

### Performance Goals  
- ✅ Intent processing latency < 2 blocks (FHE decryption time)
- ✅ Gas efficient encrypted operations (appropriate FHE bit lengths)
- ✅ Batch execution of multiple intents in single transaction
- ✅ 1:1 backing maintained (reserves = encrypted token supply)

### Adoption Goals
- ✅ Multi-pool support from day one
- ✅ Standard ERC20 compatibility for encrypted tokens
- ✅ DeFi composability (encrypted tokens work with other protocols)
- ✅ Clear user experience (deposit → encrypted tokens → private swaps → withdraw)

---

## 🔄 Future Enhancements (v2)

### Advanced Privacy Features
- **Decoy Intents**: Submit fake intents to mask real trading patterns
- **Privacy Pools**: Separate intent processing by privacy level
- **Cross-Pool Routing**: Private multi-hop swaps across different pools
- **Time-Delayed Processing**: Add random delays to break timing correlation

### Performance Optimizations  
- **Intent Batching Logic**: Sophisticated algorithms to maximize batch sizes
- **Gas Optimization**: Custom FHE operations for common patterns
- **Layer 2 Integration**: Deploy on multiple L2s for cheaper operations
- **Parallel Processing**: Multiple intent queues processed simultaneously

### Ecosystem Integration
- **DeFi Protocols**: Native support for encrypted tokens in lending, yield farming
- **Wallet Integration**: Custom UI for encrypted balance management
- **MEV Protection**: Advanced private inclusion and order flow auction
- **Governance**: Community control over hook parameters and pool adoption

---

## 📚 Reference Documentation

### Architecture Analysis Documents
- `user-flow-market-order.md` - Market order hook analysis and patterns
- `user-flow-iceberg-cofhe.md` - Encrypted token architecture analysis  
- `privateSwap/core.md` - FHE development patterns and best practices
- `privateSwap/Plan.md` - Original AlphaEngine architecture (with AVS complexity)
- `privateSwap/TDD.md` - Technical design document (full featured version)

### Key Architectural Insights
1. **EigenLayer AVS Removal**: Simplified from complex off-chain operator consensus to direct hook processing
2. **Multi-Pool Innovation**: Single hook serves infinite pools vs. single-pool limitation
3. **Token Factory Pattern**: Automatic encrypted token creation vs. pre-deployed token pairs
4. **Privacy Sweet Spot**: 90% privacy protection with 10% complexity vs. perfect privacy with massive complexity

### Development Philosophy
- **Start Simple**: Core privacy functionality first, advanced features later
- **Proven Patterns**: Reuse working FHE patterns from market order analysis
- **Progressive Enhancement**: Add complexity only when core functionality is proven
- **User Experience Focus**: Prioritize usability over theoretical privacy perfection

---

This implementation plan serves as the definitive guide for building the Universal Privacy Hook, preserving all architectural insights and providing clear development phases for successful execution.