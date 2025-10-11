# Migration Guide: UniversalPrivacyHook to Zama FHEVM

## Project Overview
A privacy-preserving Uniswap V4 hook enabling confidential swaps using FHE. Users deposit tokens to receive encrypted representations, submit encrypted swap intents, and execute swaps without revealing amounts.

## Core Architecture

### Key Components
1. **UniversalPrivacyHook.sol** - Main hook managing multi-pool privacy
2. **Queue.sol** - FIFO queue for encrypted intent processing  
3. **HybridFHERC20.sol** - Encrypted/public token hybrid implementation
4. **IFHERC20.sol** - Interface for FHE token operations

### Core Flow
```
1. User deposits USDC → receives eUSDC (encrypted tokens)
2. User submits encrypted swap intent (e.g., 200 eUSDC → eUSDT)
3. FHE decryption requested
4. Hook executes swap when decrypted
5. User receives encrypted output tokens
```

## Migration Requirements: Fhenix → Zama

### 1. Import Changes
```solidity
// FROM (Fhenix)
import {FHE, euint128, InEuint128} from "@fhenixprotocol/cofhe-contracts/FHE.sol";

// TO (Zama)
import {FHE, euint128, externalEuint128} from "@fhevm/solidity/lib/FHE.sol";
import {SepoliaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

// Add inheritance
contract UniversalPrivacyHook is SepoliaConfig, BaseHook {
```

### 2. Input Validation Changes
```solidity
// FROM (Fhenix)
function submitIntent(
    PoolKey calldata key,
    Currency tokenIn,
    Currency tokenOut,
    InEuint128 calldata liquidity,
    uint64 deadline
)

// TO (Zama)
function submitIntent(
    PoolKey calldata key,
    Currency tokenIn,
    Currency tokenOut,
    externalEuint128 liquidity,
    bytes calldata inputProof,
    uint64 deadline
) {
    euint128 _liquidity = FHE.fromExternal(liquidity, inputProof);
}
```

### 3. Decryption Pattern Changes
```solidity
// FROM (Fhenix) - Synchronous checking
FHE.decrypt(_liquidity);
// Later in beforeSwap:
(uint128 amount, bool ready) = FHE.getDecryptResultSafe(handle);
if (ready) {
    _executeIntent(key, intentId, amount);
}

// TO (Zama) - Asynchronous callback
// Add new mappings
mapping(uint256 => bytes32) private requestToIntentId;
mapping(uint256 => PoolKey) private requestToPoolKey;

// Request decryption
function _requestIntentDecryption(euint128 amount, bytes32 intentId, PoolKey memory key) internal {
    bytes32[] memory cts = new bytes32[](1);
    cts[0] = euint128.unwrap(amount);
    uint256 requestId = FHE.requestDecryption(
        cts,
        this.processDecryptedIntent.selector
    );
    requestToIntentId[requestId] = intentId;
    requestToPoolKey[requestId] = key;
}

// Callback from FHE Gateway
function processDecryptedIntent(
    uint256 requestId,
    uint128 decryptedAmount,
    bytes[] memory signatures
) public {
    FHE.checkSignatures(requestId, signatures);
    bytes32 intentId = requestToIntentId[requestId];
    PoolKey memory key = requestToPoolKey[requestId];
    
    // Execute the intent
    _executeIntent(key, intentId, decryptedAmount);
    
    // Clean up
    delete requestToIntentId[requestId];
    delete requestToPoolKey[requestId];
}
```

### 4. Queue Processing Changes
The queue no longer needs to check readiness in `beforeSwap`. Instead:
- Queue stores encrypted amounts
- Decryption requested when intent submitted
- Callback triggers execution
- Remove intent from queue after processing

### 5. Access Control
```solidity
// Similar pattern but ensure compatibility
FHE.allowThis(value);
FHE.allow(value, targetAddress);
```

### 6. Trivial Encryption (Mostly Same)
```solidity
// Both support this
euint128 encrypted = FHE.asEuint128(plainAmount);
```

## Key Implementation Notes

### Queue Management
- Keep Queue.sol mostly unchanged
- Queue still stores euint128 handles
- Processing triggered by callbacks instead of beforeSwap checks

### Multi-Pool Support
- Architecture remains the same
- Each pool gets its own encrypted tokens
- Independent reserves per pool

### Testing Approach
1. Start with SimplifiedPrivacyHook (single pool, basic operations)
2. Test deposit/withdraw with FHE
3. Add swap functionality
4. Expand to multi-pool
5. Port full UniversalPrivacyHook

## Files to Copy

### Core Contracts
```
src/privacy/UniversalPrivacyHook.sol (351 lines)
src/Queue.sol (31 lines)
src/privacy/HybridFHERC20.sol (205 lines)
src/privacy/interfaces/IFHERC20.sol (29 lines)
```

### Test Reference
```
test/UniversalPrivacyHook.t.sol (480 lines)
- Shows all test scenarios
- Demonstrates expected behavior
```

## Hardhat Test Structure
```typescript
import { fhevm } from "hardhat";

// Encrypt values for testing
const encryptedAmount = await fhevm
    .createEncryptedInput(contractAddress, signer.address)
    .add128(amount)
    .encrypt();

// Call contract
await contract.submitIntent(
    poolKey,
    tokenIn,
    tokenOut,
    encryptedAmount.handles[0],
    encryptedAmount.inputProof,
    deadline
);

// Decrypt for verification
const result = await fhevm.userDecryptEuint(
    FhevmType.euint128,
    encryptedValue,
    contractAddress,
    signer
);
```

## Critical Success Factors

1. **Callback Security**: Ensure only FHE Gateway can call decryption callbacks
2. **State Management**: Handle async callbacks that might arrive during other transactions
3. **Gas Optimization**: Callbacks add gas overhead - optimize where possible
4. **Error Handling**: Gracefully handle failed decryptions
5. **Queue Integrity**: Ensure queue remains consistent with async processing

## Development Steps (REVISED - Hook Complexity Considered)

1. **Setup**: Create simplified contract WITHOUT Uniswap hooks first
2. **FHE Migration**: Port privacy logic to Zama FHE
3. **Test in Hardhat**: Verify FHE functionality works
4. **UI Integration**: Build interface with Zama SDK
5. **Hook Integration**: Add Uniswap hooks back using Foundry
6. **Deployment**: Use Hardhat for FHE, Foundry for hooks

## Simplified Architecture for Hardhat

```solidity
// PrivacyVault.sol - Core FHE logic (Hardhat/Zama)
contract PrivacyVault is SepoliaConfig {
    // All FHE logic
    // No Uniswap dependencies
    // Test this in Hardhat
}

// UniversalPrivacyHook.sol - Full implementation (Foundry)
contract UniversalPrivacyHook is PrivacyVault, BaseHook {
    // Inherits FHE logic
    // Adds hook functions
    // Deploy with Foundry
}
```

## UI Integration Notes

The Zama template includes:
- `fhevm/` - SDK for client-side encryption
- `hooks/` - React hooks for FHE operations
- `abi/` - Contract ABIs and addresses

Leverage these for:
- Encrypting amounts client-side
- Generating proofs
- Calling contracts
- Handling decryption

## Known Challenges

1. **Async Complexity**: Callbacks make flow less predictable
2. **Testing**: Hardhat tests differ from Foundry
3. **Gas Costs**: Callbacks add overhead
4. **Reentrancy**: More complex with callbacks

## Success Metrics

- [ ] All 5 test scenarios pass in Hardhat
- [ ] Deposit/withdraw works with FHE
- [ ] Swap intents process correctly
- [ ] Multi-pool support maintained
- [ ] UI can interact with contracts

---

## Quick Reference Commands

```bash
# In Zama template
cd /Users/nilay/hookathon/fhevm-react-template/packages/fhevm-hardhat-template

# Test
npm test

# Deploy local
npm run deploy:local

# Run UI
cd ../site
npm run dev
```

## Contact & Resources

- Original repo: [Current Foundry implementation]
- Zama docs: https://docs.zama.ai/fhevm
- Uniswap V4: https://docs.uniswap.org/contracts/v4/overview