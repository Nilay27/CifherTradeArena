# FHE Type System - Complete Context & Implementation Guide

## Critical Learnings from Current Session

### 1. Type System Architecture

#### Solidity FHE Types
```solidity
// Internal types (just uint256 wrappers - NO type info)
type euint256 is uint256;
type euint128 is uint256;
type euint32 is uint256;
type eaddress is uint256;

// External types (structs with type info - FOR off-chain communication)
struct InEuint256 {
    bytes32 ctHash;      // The encrypted handle
    uint8 securityZone;
    uint8 utype;         // ← TYPE INFORMATION (crucial!)
    bytes signature;
}

struct InEaddress {
    bytes32 ctHash;
    uint8 securityZone;
    uint8 utype;         // ← For address: utype = 7 (FheTypes.Uint160)
    bytes signature;
}
```

#### CoFHE.js FheTypes Enum (THE SOURCE OF TRUTH)
```typescript
// From: node_modules/cofhejs/src/types/base.ts
export enum FheTypes {
  Bool = 0,
  Uint4 = 1,
  Uint8 = 2,
  Uint16 = 3,
  Uint32 = 4,
  Uint64 = 5,
  Uint128 = 6,
  Uint160 = 7,   // ← This is Address type!
  Uint256 = 8,   // ← NOT 6!
  Uint512 = 9,
  Uint1024 = 10,
  Uint2048 = 11,
  // ... more types
}
```

**CRITICAL**: Our custom `FheType` enum in `cofheUtils.ts` has WRONG values!
```typescript
// WRONG - Current implementation
export enum FheType {
    Address = 7,   // ✓ Correct
    Uint256 = 6,   // ✗ WRONG! Should be 8
    Uint128 = 5,   // ✗ WRONG! Should be 6
    Uint32 = 3,    // ✗ WRONG! Should be 4
}
```

**SOLUTION**: Import `FheTypes` directly from `cofhejs/node` instead of defining our own!

---

### 2. Type Information Flow

#### Frontend → Contract → Operator Flow
```
1. USER ENCRYPTS (Frontend):
   cofhejs.encrypt([
       Encryptable.address(decoder),    // Returns { ctHash, utype: 7, ... }
       Encryptable.uint32(selector),    // Returns { ctHash, utype: 4, ... }
       Encryptable.uint256(amount)      // Returns { ctHash, utype: 8, ... }
   ])

2. USER SUBMITS (Transaction):
   contract.submitEncryptedUEI(
       decoderStruct,   // InEaddress with utype=7
       selectorStruct,  // InEuint32 with utype=4
       argsStructs      // InEuint256[] with utype=8
   )

3. CONTRACT VALIDATES & STORES:
   eaddress decoderHandle = FHE.asEaddress(decoder);  // Validates utype=7
   euint32 selectorHandle = FHE.asEuint32(selector);  // Validates utype=4

   // CRITICAL: Store internal handles (lose type info)
   ueiHandles[ueiId] = FHEHandles({
       decoder: decoderHandle,    // Just uint256 now
       selector: selectorHandle   // Just uint256 now
   });

4. CONTRACT EMITS EVENT:
   // MUST emit original InE* structs to preserve type!
   emit TradeSubmitted(
       ueiId,
       batchId,
       abi.encode(decoder, target, selector, args),  // ← Original structs!
       deadline
   );

5. OPERATOR READS EVENT:
   const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
       [
           'tuple(bytes32 ctHash, uint8 securityZone, uint8 utype, bytes signature)',
           'tuple(bytes32 ctHash, uint8 securityZone, uint8 utype, bytes signature)',
           'tuple(bytes32 ctHash, uint8 securityZone, uint8 utype, bytes signature)',
           'tuple(bytes32 ctHash, uint8 securityZone, uint8 utype, bytes signature)[]'
       ],
       ctBlob
   );

   // Extract utype from structs
   const decoderUtype = decoded[0].utype;  // 7
   const selectorUtype = decoded[2].utype; // 4
   const argUtypes = decoded[3].map(arg => arg.utype);  // [8, 8, ...]

6. OPERATOR UNSEALS WITH TYPE:
   import { FheTypes } from 'cofhejs/node';

   const decoder = await cofhejs.unseal(
       decoded[0].ctHash,
       decoded[0].utype  // ← REQUIRED! Uses utype from struct
   );
   // Returns: "0x..." (address string because utype=7)

   const selector = await cofhejs.unseal(
       decoded[2].ctHash,
       decoded[2].utype  // ← utype=4
   );
   // Returns: bigint
```

---

### 3. Two Types of Unsealing

#### Method 1: `permit.unseal(sealed)` - Local Only
```typescript
// Direct unsealing with permit (NO network call)
const sealed = SealingKey.seal(value, permit.sealingPair.publicKey);
const unsealed = permit.unseal(sealed);  // ← No utype needed!
// Returns raw bigint
```
**Use case**: Already have sealed data locally, just decrypt with private key.

#### Method 2: `cofhejs.unseal(ctHash, utype)` - Network Call
```typescript
// Network unsealing (calls threshold network /sealoutput)
const result = await cofhejs.unseal(ctHash, FheTypes.Uint256);  // ← utype REQUIRED!
// Returns bigint | string | boolean (converted based on utype)
```
**Use case**: Decrypt on-chain encrypted data via threshold network.

**How it works internally**:
```typescript
// SDK calls threshold network
const response = await fetch(`${thresholdNetworkUrl}/sealoutput`, {
    body: JSON.stringify({
        ct_tempkey: ctHash,
        permit: permit.getPermission()
    })
});

const sealed = response.sealed;
const unsealed = permit.unseal(sealed);  // Local decryption

// Convert based on utype
return convertViaUtype(utype, unsealed);
// - utype=0 (Bool): returns boolean
// - utype=7 (Uint160/Address): returns "0x..." string
// - utype=2-8 (Uints): returns bigint
```

---

### 4. Why `decrypt()` Also Returns Type Info

```typescript
// SDK decrypt function (line 636 in index.ts)
const decryptOutput = await fetch(`${thresholdNetworkUrl}/decrypt`, { ... });
const data = await decryptOutput.json();

// Threshold network returns the type!
if (decryptOutput.encryption_type !== utype) {
    throw new Error(`Type mismatch: got ${decryptOutput.encryption_type}, expected ${utype}`);
}
```

**The threshold network KNOWS the type** when it decrypts! It validates against the provided `utype`.

---

## Required Changes

### Contract Changes (SwapManager.sol)

#### Current Problem
```solidity
// WRONG: Assumes all args are euint256
function submitEncryptedUEI(
    InEaddress calldata decoder,
    InEaddress calldata target,
    InEuint32 calldata selector,
    InEuint256[] calldata args,  // ← WRONG! Not all args are uint256
    uint256 deadline
)
```

#### Solution: Add argTypes Parameter
```solidity
function submitEncryptedUEI(
    InEaddress calldata decoder,
    InEaddress calldata target,
    InEuint32 calldata selector,
    bytes calldata encryptedArgs,    // ← Generic bytes for any type mix
    uint8[] calldata argTypes,       // ← Type for each arg [8, 7, 2] = [uint256, address, uint8]
    uint256 deadline
) external returns (bytes32 ueiId) {
    // Decode args based on argTypes
    // For each argType:
    //   - 0 = Bool
    //   - 2 = Uint8
    //   - 4 = Uint32
    //   - 7 = Address (Uint160)
    //   - 8 = Uint256

    // Store handles dynamically based on types
    FHEHandles memory handles;
    uint256 offset = 0;

    for (uint256 i = 0; i < argTypes.length; i++) {
        if (argTypes[i] == 7) {
            // Decode InEaddress
            InEaddress memory argStruct = abi.decode(
                encryptedArgs[offset:offset+128],
                (InEaddress)
            );
            handles.args[i] = eaddress.unwrap(FHE.asEaddress(argStruct));
            offset += 128;
        } else if (argTypes[i] == 8) {
            // Decode InEuint256
            InEuint256 memory argStruct = abi.decode(
                encryptedArgs[offset:offset+128],
                (InEuint256)
            );
            handles.args[i] = euint256.unwrap(FHE.asEuint256(argStruct));
            offset += 128;
        }
        // ... handle other types
    }

    // Emit with argTypes for operator
    emit TradeSubmitted(
        ueiId,
        batchId,
        abi.encode(decoder, target, selector, encryptedArgs, argTypes),
        deadline
    );
}
```

**Alternative Approach**: Keep flexible encoding
```solidity
// Use dynamic encoding that preserves types
struct UEIComponent {
    bytes32 ctHash;
    uint8 securityZone;
    uint8 utype;
    bytes signature;
}

function submitEncryptedUEI(
    UEIComponent calldata decoder,
    UEIComponent calldata target,
    UEIComponent calldata selector,
    UEIComponent[] calldata args,  // ← Flexible, each has its own utype!
    uint256 deadline
)
```

---

### Operator Changes (TypeScript)

#### 1. Update cofheUtils.ts

```typescript
// REMOVE custom FheType enum, use CoFHE.js directly
import { FheTypes } from 'cofhejs/node';

// Update EncryptionInput to use FheTypes
export interface EncryptionInput {
    value: bigint | string | boolean;
    type: FheTypes;  // ← Use SDK enum
}

// Update all functions to use FheTypes
export const encryptValue = async (
    value: bigint | string | boolean,
    type: FheTypes,  // ← Not our custom enum
    userAddress?: string,
    contractAddress?: string
): Promise<CoFheItem> => {
    const encryptable = toEncryptable(value, type);
    const encResult = await cofhejs.encrypt([encryptable]);

    // Validate utype matches
    if (encResult.data[0].utype !== type) {
        console.warn(`Type mismatch: expected ${type}, got ${encResult.data[0].utype}`);
    }

    return {
        ctHash: BigInt(encResult.data[0].ctHash),
        securityZone: encResult.data[0].securityZone,
        utype: encResult.data[0].utype,
        signature: encResult.data[0].signature
    };
};

// Update toEncryptable helper
function toEncryptable(value: bigint | string | boolean, type: FheTypes): any {
    switch (type) {
        case FheTypes.Bool:
            return Encryptable.bool(Boolean(value));
        case FheTypes.Uint8:
            return Encryptable.uint8(BigInt(value));
        case FheTypes.Uint16:
            return Encryptable.uint16(BigInt(value));
        case FheTypes.Uint32:
            return Encryptable.uint32(BigInt(value));
        case FheTypes.Uint64:
            return Encryptable.uint64(BigInt(value));
        case FheTypes.Uint128:
            return Encryptable.uint128(BigInt(value));
        case FheTypes.Uint160:  // ← Address
            const addr = typeof value === 'string' && value.startsWith('0x')
                ? value
                : ethers.getAddress(ethers.toBeHex(BigInt(value), 20));
            return Encryptable.address(addr);
        case FheTypes.Uint256:
            return Encryptable.uint256(BigInt(value));
        default:
            throw new Error(`Unsupported FHE type: ${type}`);
    }
}
```

#### 2. Update createEncryptedUEITasks.ts

```typescript
import { FheTypes } from 'cofhejs/node';

async function batchEncryptUEIComponents(
    decoder: string,
    target: string,
    selector: string,
    args: Array<{ value: bigint | string, type: FheTypes }>,  // ← Pass types!
    contractAddress: string,
    signerAddress: string
): Promise<{
    encryptedDecoder: CoFheItem;
    encryptedTarget: CoFheItem;
    encryptedSelector: CoFheItem;
    encryptedArgs: CoFheItem[];
    argTypes: number[];  // ← Return types for contract
}> {
    const inputs: EncryptionInput[] = [
        { value: decoder, type: FheTypes.Uint160 },  // Address
        { value: target, type: FheTypes.Uint160 },   // Address
        { value: selector, type: FheTypes.Uint32 },  // Selector
        ...args  // Each arg has its own type!
    ];

    const encrypted = await batchEncrypt(inputs, signerAddress, contractAddress);

    return {
        encryptedDecoder: encrypted[0],
        encryptedTarget: encrypted[1],
        encryptedSelector: encrypted[2],
        encryptedArgs: encrypted.slice(3),
        argTypes: args.map(arg => arg.type)  // ← For contract
    };
}

// Example usage with mixed types
const encrypted = await batchEncryptUEIComponents(
    MOCK_ERC20_DECODER,
    USDC_SEPOLIA,
    transferSelector,
    [
        { value: BigInt(recipient), type: FheTypes.Uint160 },  // address
        { value: amount, type: FheTypes.Uint256 }               // uint256
    ],
    SWAP_MANAGER,
    wallet.address
);

// Submit with argTypes
await swapManager.submitEncryptedUEI(
    encrypted.encryptedDecoder,
    encrypted.encryptedTarget,
    encrypted.encryptedSelector,
    encrypted.encryptedArgs,
    encrypted.argTypes,  // ← Pass to contract
    deadline
);
```

#### 3. Update ueiProcessor.ts - Dynamic Type Handling

```typescript
import { FheTypes } from 'cofhejs/node';

interface EncryptedComponent {
    ctHash: bigint;
    utype: number;  // FheTypes value
}

function decodeCTBlob(ctBlob: string): {
    encDecoder: EncryptedComponent;
    encTarget: EncryptedComponent;
    encSelector: EncryptedComponent;
    encArgs: EncryptedComponent[];
} {
    // Decode full InE* structs to get utype
    const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
        [
            'tuple(bytes32 ctHash, uint8 securityZone, uint8 utype, bytes signature)',
            'tuple(bytes32 ctHash, uint8 securityZone, uint8 utype, bytes signature)',
            'tuple(bytes32 ctHash, uint8 securityZone, uint8 utype, bytes signature)',
            'tuple(bytes32 ctHash, uint8 securityZone, uint8 utype, bytes signature)[]'
        ],
        ctBlob
    );

    return {
        encDecoder: {
            ctHash: BigInt(decoded[0].ctHash),
            utype: decoded[0].utype  // ← Extract utype!
        },
        encTarget: {
            ctHash: BigInt(decoded[1].ctHash),
            utype: decoded[1].utype
        },
        encSelector: {
            ctHash: BigInt(decoded[2].ctHash),
            utype: decoded[2].utype
        },
        encArgs: decoded[3].map((arg: any) => ({
            ctHash: BigInt(arg.ctHash),
            utype: arg.utype  // ← Each arg has its own type!
        }))
    };
}

async function batchDecryptUEI(
    encDecoder: EncryptedComponent,
    encTarget: EncryptedComponent,
    encSelector: EncryptedComponent,
    encArgs: EncryptedComponent[]
): Promise<{
    decoder: string;
    target: string;
    selector: string;
    args: any[];  // Mixed types!
}> {
    console.log(`\n🔓 Batch decrypting UEI with types...`);
    console.log(`  Decoder: ctHash=${encDecoder.ctHash}, utype=${encDecoder.utype}`);
    console.log(`  Target: ctHash=${encTarget.ctHash}, utype=${encTarget.utype}`);
    console.log(`  Selector: ctHash=${encSelector.ctHash}, utype=${encSelector.utype}`);

    // Unseal with correct types
    const decoder = await cofhejs.unseal(encDecoder.ctHash, encDecoder.utype);
    const target = await cofhejs.unseal(encTarget.ctHash, encTarget.utype);
    const selector = await cofhejs.unseal(encSelector.ctHash, encSelector.utype);

    // Decrypt args with their individual types
    const args = [];
    for (let i = 0; i < encArgs.length; i++) {
        console.log(`  Arg[${i}]: ctHash=${encArgs[i].ctHash}, utype=${encArgs[i].utype}`);
        const decrypted = await cofhejs.unseal(encArgs[i].ctHash, encArgs[i].utype);
        args.push(decrypted);
    }

    console.log(`\n✅ Decrypted values:`);
    console.log(`  Decoder: ${decoder}`);
    console.log(`  Target: ${target}`);
    console.log(`  Selector: ${selector}`);
    console.log(`  Args:`, args);

    return { decoder, target, selector, args };
}

// Dynamic calldata reconstruction based on utypes
function reconstructCalldata(
    selector: string,
    args: any[],
    argUtypes: number[]
): string {
    console.log(`\n🔧 Reconstructing calldata...`);
    console.log(`  Selector: ${selector}`);

    // Convert decrypted values based on utypes
    const solidityTypes: string[] = [];
    const encodedArgs: any[] = [];

    for (let i = 0; i < args.length; i++) {
        const arg = args[i];
        const utype = argUtypes[i];

        if (utype === FheTypes.Bool) {
            solidityTypes.push('bool');
            encodedArgs.push(Boolean(arg));
        } else if (utype === FheTypes.Uint8) {
            solidityTypes.push('uint8');
            encodedArgs.push(arg);
        } else if (utype === FheTypes.Uint32) {
            solidityTypes.push('uint32');
            encodedArgs.push(arg);
        } else if (utype === FheTypes.Uint128) {
            solidityTypes.push('uint128');
            encodedArgs.push(arg);
        } else if (utype === FheTypes.Uint160) {
            solidityTypes.push('address');
            encodedArgs.push(typeof arg === 'string' ? arg : ethers.getAddress(ethers.toBeHex(arg, 20)));
        } else if (utype === FheTypes.Uint256) {
            solidityTypes.push('uint256');
            encodedArgs.push(arg);
        }

        console.log(`  Arg[${i}]: type=${solidityTypes[i]}, value=${encodedArgs[i]}`);
    }

    // Encode with correct types
    const encodedParams = ethers.AbiCoder.defaultAbiCoder().encode(
        solidityTypes,
        encodedArgs
    );

    const calldata = selector + encodedParams.slice(2);
    console.log(`  Calldata: ${calldata.slice(0, 66)}...`);

    return calldata;
}
```

---

## Key Architectural Decisions

### 1. Why Emit InE* Structs in Events?
**Because**: `euint*` types lose type information (just uint256 wrappers). Operators need `utype` to call `cofhejs.unseal(ctHash, utype)` correctly.

### 2. Why Not Store Types in Contract?
**Because**: Gas efficiency. Internal operations don't need type info. Only external communication (events, return values) needs types.

### 3. Why Use CoFHE.js FheTypes Instead of Custom Enum?
**Because**:
- Single source of truth
- SDK and threshold network use these values
- Prevents mismatches (our Uint256=6 vs SDK Uint256=8)

### 4. Contract ACL for Operator Access
```solidity
// In finalizeUEIBatch()
for (uint256 j = 0; j < selectedOps.length; j++) {
    FHE.allow(handles.decoder, selectedOps[j]);
    FHE.allow(handles.target, selectedOps[j]);
    FHE.allow(handles.selector, selectedOps[j]);
    for (uint256 k = 0; k < handles.args.length; k++) {
        FHE.allow(handles.args[k], selectedOps[j]);
    }
}
```

This grants operators permission to decrypt via threshold network.

---

## Testing Strategy

### 1. Test with Mixed Argument Types
```typescript
// Test case: transferFrom(address from, address to, uint256 amount)
const args = [
    { value: fromAddress, type: FheTypes.Uint160 },
    { value: toAddress, type: FheTypes.Uint160 },
    { value: amount, type: FheTypes.Uint256 }
];

// Operator should correctly:
// - Decrypt address as string
// - Decrypt uint256 as bigint
// - Reconstruct calldata with ['address', 'address', 'uint256']
```

### 2. Test Type Validation
```typescript
// Should FAIL: Wrong type
const badEncryption = await cofhejs.encrypt([
    Encryptable.uint128(amount)  // utype=6
]);

// Contract should reject
await expect(
    contract.submitEncryptedUEI(..., badEncryption)  // Expected utype=8
).to.be.revertedWith("Type mismatch");
```

---

## Implementation Priority

1. **HIGH**: Update `cofheUtils.ts` to use `FheTypes` from CoFHE.js SDK
2. **HIGH**: Update `ueiProcessor.ts` to extract and use `utype` from events
3. **MEDIUM**: Update contract to support dynamic arg types
4. **MEDIUM**: Update `createEncryptedUEITasks.ts` to pass arg types
5. **LOW**: Add comprehensive type validation tests

---

## References

- CoFHE.js SDK: `node_modules/cofhejs/src/types/base.ts`
- SDK unseal: `node_modules/cofhejs/src/core/sdk/index.ts:471`
- SDK decrypt: `node_modules/cofhejs/src/core/sdk/index.ts:562`
- Type conversion: `node_modules/cofhejs/src/core/utils/utype.ts:12`
- Contract FHE: `hello-world-avs/contracts/lib/cofhe-contracts/FHE.sol`

---

## Common Pitfalls to Avoid

1. ❌ **Don't emit `euint*` in events** - Use `InE*` structs to preserve type
2. ❌ **Don't use custom FheType enum** - Import from CoFHE.js SDK
3. ❌ **Don't assume all args are uint256** - Support mixed types
4. ❌ **Don't forget `utype` in unseal()** - Required for network calls
5. ❌ **Don't call `permit.unseal()` for on-chain data** - Use `cofhejs.unseal()`

---

## Next Session TODO

- [ ] Import `FheTypes` from `cofhejs/node` in all operator files
- [ ] Remove custom `FheType` enum from `cofheUtils.ts`
- [ ] Update `decodeCTBlob()` to extract full structs with `utype`
- [ ] Update `batchDecryptUEI()` to use `cofhejs.unseal(ctHash, utype)`
- [ ] Add dynamic calldata reconstruction based on `utype`
- [ ] Update contract to accept `argTypes[]` parameter
- [ ] Update event emission to include arg types
- [ ] Test with mixed type arguments (address + uint256 + uint8)
