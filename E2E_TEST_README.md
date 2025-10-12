# End-to-End Testing Guide

This guide explains how to run the complete end-to-end testing for the encrypted swap flow connecting Universal Privacy Hook with the AVS system.

## Prerequisites

1. **Anvil**: Make sure Anvil is installed (comes with Foundry)
2. **Node.js**: Version 16+
3. **Dependencies installed** in both projects:
   ```bash
   cd universal-privacy-hook && npm install
   cd ../hello-world-avs && npm install
   ```

## Quick Start

Run the complete e2e test with the UniversalPrivacyHook and AVS integration:

```bash
./run-e2e-swap.sh
```

This script handles the correct deployment order:
1. **Sets up CoFHE mock contracts first** (required by UniversalPrivacyHook)
2. **Deploys UniversalPrivacyHook** with proper address mining
3. **Deploys AVS contracts** and connects them
4. **Runs the integration test**

## What Gets Deployed

The e2e test deploys in this order:

### Step 1: AVS Infrastructure (npm run deploy:all)
- **SwapManager**: Core AVS contract for managing encrypted swaps
- **ServiceManager**: AVS service management and operator coordination
- **StakeRegistry**: Operator staking and registration
- **MockPrivacyHook**: Deployed but not used (we use UniversalPrivacyHook instead)
- **MockCoFHE**: FHE mock contracts at `0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9` (required by UniversalPrivacyHook)

### Step 2: Universal Privacy Hook
- **PoolManager**: Core Uniswap v4 pool manager
- **UniversalPrivacyHook**: Hook with BEFORE_SWAP permission (address mined with HookMiner)
- **TokenA & TokenB**: Mock tokens (mUSDC and mUSDT)
- **Routers**: LiquidityRouter, SwapRouter for pool interactions
- **Initial Pool**: Created with the hook attached

### Step 3: Connection
- UniversalPrivacyHook is authorized in SwapManager
- Operator is registered and started
- Ready for encrypted swap flow

## Architecture

```
User → UniversalPrivacyHook → Encrypted Intent → AVS Operator → Decryption → Execution
```

1. **User deposits** tokens into UniversalPrivacyHook
2. **User submits** encrypted swap intent
3. **AVS monitors** for new intents
4. **Operator decrypts** and batches swaps
5. **Settlement** happens on-chain

## Manual Testing Steps

If you want to run steps manually:

### 1. Start Anvil
```bash
anvil --chain-id 31337
```

### 2. Deploy Universal Privacy Hook
```bash
cd universal-privacy-hook
forge script script/DeployUniversalPrivacyHook.s.sol:DeployUniversalPrivacyHook \
    --rpc-url http://localhost:8545 \
    --broadcast \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

### 3. Deploy AVS
```bash
cd ../hello-world-avs
npm run deploy:all
```

### 4. Register Operator
```bash
npm run register:operator
```

### 5. Start Operator
```bash
npm run start:operator
```

### 6. Submit Test Swap
```bash
npm run start:swap  # In hello-world-avs
```

## Deployed Addresses

After deployment, addresses are saved to:
- `universal-privacy-hook/deployments/latest.json` - Hook addresses
- `hello-world-avs/contracts/deployments/swap-manager/31337.json` - AVS addresses
- `hello-world-avs/contracts/deployments/mock-hook/31337.json` - MockHook addresses

## Hook Address Mining

The UniversalPrivacyHook requires specific permissions encoded in its address:
- **BEFORE_SWAP_FLAG**: Allows the hook to process swaps before execution

The deployment script uses HookMiner to find a salt that produces an address with these flags:

```solidity
uint160 permissions = uint160(Hooks.BEFORE_SWAP_FLAG);
(address hookAddress, bytes32 salt) = HookMiner.find(
    CREATE2_DEPLOYER,
    permissions,
    type(UniversalPrivacyHook).creationCode,
    abi.encode(address(manager))
);
```

## Troubleshooting

### Anvil not running
```
Error: Anvil is not running
Solution: Run 'anvil' in a separate terminal
```

### Compilation errors
```
Error: Contract compilation failed
Solution: Run 'forge build --via-ir' in the respective directory
```

### Operator not registered
```
Error: No operators registered
Solution: Run 'npm run register:operator' in hello-world-avs
```

### Hook address mismatch
```
Error: Hook address mismatch
Solution: The hook mining failed. Check CREATE2_DEPLOYER is correct (0x4e59b44847b379578588920cA78FbF26c0B4956C)
```

## Next Steps - Trader Flow

To add the trader flow integration:

1. **Implement trader strategy submission** in UniversalPrivacyHook
2. **Add merkle tree creation** in AVS operator for decrypted trades
3. **Integrate with Veda POC** for trade execution
4. **Update e2e tests** to include trader flow

The existing infrastructure (deployment, operator, monitoring) is ready for these additions.