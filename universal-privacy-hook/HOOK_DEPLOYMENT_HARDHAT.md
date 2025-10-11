# Uniswap V4 Hook Deployment in Hardhat - Challenge & Solutions

## The Challenge

Uniswap V4 hooks require specific address patterns where permissions are encoded in the address itself:
- The hook address must have specific bits set to indicate which functions it implements
- This requires mining a CREATE2 salt that produces the correct address pattern
- Foundry has `HookMiner` utility, but Hardhat deployment is different

## Hook Permission Requirements

```solidity
// Our hook needs BEFORE_SWAP_FLAG
uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG); // = 0x0080

// The deployed address must have this flag encoded
// e.g., 0x0000000000000000000000000000000000000080
```

## Solutions for Hardhat

### Solution 1: Use HookMiner in Hardhat (Recommended)

```typescript
// deploy/deployHook.ts
import { HookMiner } from "./utils/HookMiner";

async function deployHook() {
    const CREATE2_DEPLOYER = "0x4e59b44847b379578588920cA78FbF26c0B4956C";
    const flags = 0x0080; // BEFORE_SWAP_FLAG
    
    // Mine the salt
    const { salt, expectedAddress } = await HookMiner.find(
        CREATE2_DEPLOYER,
        flags,
        UniversalPrivacyHook.bytecode,
        ethers.utils.defaultAbiCoder.encode(["address"], [poolManager.address])
    );
    
    // Deploy with CREATE2
    const factory = await ethers.getContractFactory("UniversalPrivacyHook");
    const hook = await factory.deploy(poolManager.address, {
        salt: salt,
        customData: {
            salt: salt,
            deployerAddress: CREATE2_DEPLOYER
        }
    });
    
    console.log("Hook deployed to:", hook.address);
    console.log("Expected address:", expectedAddress);
    assert(hook.address === expectedAddress, "Address mismatch!");
}
```

### Solution 2: Pre-mine Salt Offline

```bash
# Use Foundry to mine the salt
forge script script/MineHookAddress.s.sol

# Output: salt = 0x00000000000000000000000000000000000000000000d4f5b8a9c3e2f1d7a6

# Use this salt in Hardhat deployment
```

### Solution 3: Mock for Testing (Development Only)

```solidity
// For testing, create a mock pool manager that doesn't validate addresses
contract MockPoolManager {
    function validateHookAddress(address hook) external pure returns (bool) {
        // Skip validation in tests
        return true;
    }
}
```

### Solution 4: Port HookMiner to TypeScript

```typescript
// utils/HookMiner.ts
export class HookMiner {
    static async find(
        deployer: string,
        flags: number,
        creationCode: string,
        constructorArgs: string
    ): Promise<{ salt: string, address: string }> {
        const initCodeHash = ethers.utils.keccak256(
            ethers.utils.concat([creationCode, constructorArgs])
        );
        
        let salt = 0;
        while (true) {
            const saltBytes32 = ethers.utils.hexZeroPad(
                ethers.utils.hexlify(salt), 
                32
            );
            
            const expectedAddress = ethers.utils.getCreate2Address(
                deployer,
                saltBytes32,
                initCodeHash
            );
            
            // Check if address has correct flags
            const addressBN = ethers.BigNumber.from(expectedAddress);
            if (addressBN.and(flags).eq(flags)) {
                return {
                    salt: saltBytes32,
                    address: expectedAddress
                };
            }
            salt++;
        }
    }
}
```

## Recommended Approach for Zama Migration

### Phase 1: Development (Skip Mining)
```typescript
// For initial development, deploy without mining
// This won't work on real Uniswap but fine for FHE testing

contract UniversalPrivacyHookDev {
    // Remove hook validation temporarily
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        // Return permissions without address validation
    }
}
```

### Phase 2: Integration Testing
```typescript
// Use CREATE2 factory with pre-mined salt
const PREMINED_SALT = "0x..."; // From Foundry script
const CREATE2_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C";

// Deploy using ethers with CREATE2
```

### Phase 3: Production
- Use proper HookMiner implementation
- Ensure address validation passes
- Test with actual Uniswap V4 contracts

## Alternative: Hybrid Approach

Keep two versions:
1. **Foundry version** - For Uniswap V4 integration testing
2. **Hardhat version** - For Zama FHE testing

```javascript
// package.json scripts
{
  "test:hooks": "forge test",           // Test hook logic with Foundry
  "test:fhe": "hardhat test",          // Test FHE with Hardhat
  "deploy:hook": "forge script ...",   // Deploy hook with Foundry
  "deploy:fhe": "hardhat deploy"       // Deploy FHE parts with Hardhat
}
```

## Simplified Testing Strategy

For Zama migration, focus on FHE functionality first:

```solidity
// SimplifiedPrivacyContract.sol (No Hook)
contract SimplifiedPrivacyContract {
    // All the FHE logic without Uniswap hooks
    // Test this first in Hardhat
}

// Later: UniversalPrivacyHook.sol
contract UniversalPrivacyHook is SimplifiedPrivacyContract, BaseHook {
    // Add hook integration
    // Deploy with Foundry
}
```

## Deployment Script for Hardhat

```typescript
// scripts/deploy.ts
import { ethers } from "hardhat";
import { HookMiner } from "../utils/HookMiner";

async function main() {
    // For testing: Deploy without mining
    console.log("Deploying Privacy Contract (without hook validation)...");
    
    const PrivacyContract = await ethers.getContractFactory("SimplifiedPrivacyContract");
    const privacy = await PrivacyContract.deploy();
    
    console.log("Privacy Contract deployed to:", privacy.address);
    console.log("Note: This is NOT a valid hook address for Uniswap V4");
    console.log("Use Foundry for proper hook deployment");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
```

## Recommendation

**Best approach for your case:**

1. **Start with non-hook version** in Hardhat
   - Test all FHE functionality
   - Get UI working
   - Verify Zama integration

2. **Keep Foundry for hook deployment**
   - Mine proper addresses
   - Test Uniswap integration
   - Deploy to testnet

3. **Bridge them together**
   - FHE logic tested in Hardhat
   - Hook deployment via Foundry
   - Same contract, different deployment methods

This way you don't fight with Hardhat for hook mining, which is complex and already solved in Foundry.