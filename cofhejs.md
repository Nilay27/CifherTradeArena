# CoFHE.js Documentation

## Table of Contents
- [Getting Started](#getting-started)
  - [Overview](#overview)
  - [Mental Model](#mental-model)
  - [Installation](#installation)
  - [Setup](#setup)
- [Core Concepts](#core-concepts)
  - [Encrypting Input Data](#encrypting-input-data)
  - [Creating Permits](#creating-permits)
  - [Unsealing Data](#unsealing-data)
- [Complete Examples](#complete-examples)
  - [End-to-End Example](#end-to-end-example)
- [API Reference](#api-reference)
  - [Encryption](#encryption)
  - [Sealing & Unsealing](#sealing--unsealing)
  - [Permits Management](#permits-management)
  - [Error Handling](#error-handling)

---

## Getting Started

### Overview

**CoFHE.js** is a TypeScript package designed to enable seamless interaction between clients and Fhenix's co-processor (CoFHE). It is an essential component for engineers working with FHE-enabled smart contracts, facilitating the encryption and decryption processes required for secure data handling in decentralized applications (dApps).

CoFHE.js ensures that data remains private throughout its journey from input to output in the blockchain ecosystem.

#### Key Features

FHE-enabled contracts require three primary modifications to the client/frontend:

1. **Encrypting Input Data**: Before passing data to the smart contract, input must be encrypted to ensure its confidentiality
2. **Creating Permits and Permissions**: The client must generate permits and permissions that determine who can interact with or view the data
3. **Unsealing Output Data**: After the contract processes the data, the client must decrypt the output for it to be used or displayed

CoFHE.js allows encryption to begin and end privately in a dApp, while FHE-enabled contracts do work on and with these encrypted values.

---

### Mental Model

To understand how CoFHE.js fits into the Fhenix framework, consider a simple mental model showing how data moves through Fhenix-powered dApps.

#### Example: Private Counter Contract

Consider a smart contract called "Counter" where each user has an individual counter, and users increment and read their own counters with complete privacy. In this example:
- **Public key** = A lock
- **Private key** = The corresponding key to unlock it

#### Adding to the User's Counter

When users want to add a value to their counter (e.g., "5"):

1. User places the value inside a "box"
2. Using CoFHE.js, this box is secured by locking it with Fhenix Co-Processor's public key (encryption)
3. The locked box is sent to the smart contract
4. Thanks to Fully Homomorphic Encryption (FHE), Fhenix can perform mathematical operations directly on these sealed boxes—without accessing the raw data inside
5. The user's encrypted value "5" can be added to the user's encrypted counter while remaining private

#### Retrieving the User's Counter

To retrieve the counter value, the user needs to read the data inside the box without breaking the encryption:

1. User sends a second "lock" (their own public key) along with the request to read its data
2. This second lock is applied to the box while Fhenix removes its own lock (the Co-Processor's public key)
3. The box remains locked and the data remains private, but now only the user can open it using their private key

---

### Installation

To get started with CoFHE.js, install it as a dependency in your JavaScript project using npm, Yarn, or pnpm:

<details>
<summary><b>Package Manager Commands</b></summary>

```bash
# Using Yarn
yarn add cofhejs

# Using npm
npm install cofhejs

# Using pnpm
pnpm add cofhejs
```

</details>

---

### Setup

To use CoFHE.js for interacting with FHE-enabled smart contracts, it must first be initialized. The CoFHE.js client handles key operations such as encrypting input data, creating permits, and decrypting output data from the blockchain.

#### Node.js Setup

```javascript
const { cofhejs } = require("cofhejs/node");
const { ethers } = require("ethers");

// Initialize your web3 provider
const provider = new ethers.JsonRpcProvider("http://127.0.0.1:42069");
const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

// Initialize cofhejs Client with ethers (it also supports viem)
await cofhejs.initializeWithEthers({
  ethersProvider: provider,
  ethersSigner: wallet,
  environment: "TESTNET"
});
```

#### Browser Setup

```javascript
import { cofhejs } from "cofhejs";
import { ethers } from "ethers";

// Initialize your web3 provider
const provider = new ethers.BrowserProvider(window.ethereum);
const signer = await provider.getSigner();

// Initialize cofhejs Client
await cofhejs.initializeWithEthers({
  ethersProvider: provider,
  ethersSigner: signer,
  environment: "TESTNET"
});
```

---

## Core Concepts

### Encrypting Input Data

This step secures the data before sending it to the smart contract.

> **Important**: All data sent to a smart contract on a blockchain is inherently public. However, Fhenix operates differently. To maintain user confidentiality and protect sensitive input data, Fhenix utilizes CoFHE.js to provide built-in encryption methods that must be applied before sending any data to an FHE-enabled contract.

#### Basic Encryption Example

```javascript
const logState = (state) => {
  console.log(`Log Encrypt State :: ${state}`);
};

// This will encrypt only the encrypted values (total 4 in this case)
const encryptedValues = await cofhejs.encrypt([
  { a: Encryptable.bool(false), b: Encryptable.uint64(10n), c: "hello" },
  ["hello", 20n, Encryptable.address(contractAddress)],
  Encryptable.uint8("10"),
] as const, logState);

const contract = new ethers.Contract(CONTRACT_ADDRESS, CONTRACT_ABI, wallet);
// Use the encrypted value of 10n
const tx = await contract.add(encryptedValues.data[1]);
```

By encrypting user data before sending it to a contract, Fhenix ensures that data remains private throughout its lifecycle in the blockchain environment.

---

### Creating Permits

After encryption, values can be passed into FHE-enabled smart contracts, and the contract can operate on this data securely. However, to ensure that only the respective user can view the processed (encrypted) data, permissions and sealing mechanisms are used.

#### Purpose of Permissions

Permissions serve two main purposes:

1. **Verify User Identity**: Ensure that the data access request comes from the correct user by verifying that the message is signed with the user's private key
2. **Sealing User Data**: Provide a public key to "seal" the encrypted data, meaning it is encrypted in such a way that only the user holding the corresponding private key can decrypt it later

> **Note**: Fhenix uses EIP712, a widely used Ethereum standard for signing structured data. This means:
> - First, a user must sign a permit in their wallet to authenticate themselves and authorize the creation of the permit
> - Second, permits are stored locally in local storage and can be reused for future interactions with the same contract
> - Currently, each contract that the user interacts with requires its own unique permit (subject to change)

#### Creating a Permit

```javascript
const permit = await cofhejs.createPermit({
  type: 'self',
  issuer: wallet.address,
});
```

---

### Unsealing Data

After encryption, the data can be securely processed by the contract and sealed with the user's public key (from their permit), and it is returned to the user when requested. To access and interpret this data, the user must unseal it using their private key, which is securely stored on their device.

#### Why Unsealing is Necessary

When the contract returns the encrypted data to the user, it remains sealed. This means the data is still encrypted with the user's public key and cannot be read until the corresponding private key is used to unlock it.

#### Unsealing Example

```javascript
const permit = await cofhejs.getPermit({
  type: 'self',
  issuer: wallet.address,
});

const result = await contract.getSomeEncryptedValue();
const unsealed = await cofhejs.unseal(
  result,
  FheTypes.Uint32,
  permit.data.issuer,
  permit.data.getHash()
);
```

---

## Complete Examples

### End-to-End Example

This example demonstrates a full interaction between a dApp and an FHE-enabled smart contract using CoFHE.js. It walks through:
- Setting up the client
- Encrypting data
- Sending it to the contract
- Creating a permit for accessing sealed data
- Unsealing the returned data for the user

```javascript
const { cofhejs, FheTypes } = require("cofhejs/node");
const { ethers } = require("ethers");

// Initialize your web3 provider
const provider = new ethers.JsonRpcProvider("http://127.0.0.1:42069");
const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

// Initialize cofhejs Client with ethers (see cofhejs docs for viem)
await cofhejs.initializeWithEthers({
  ethersProvider: provider,
  ethersSigner: wallet,
  environment: "TESTNET"
});

const contract = new ethers.Contract(CONTRACT_ADDRESS, CONTRACT_ABI, wallet);

const logState = (state) => {
  console.log(`Log Encrypt State :: ${state}`);
};

// Helper function to read counter (decrypted value)
const readCounterDecryptedValue = async () => {
  try {
    const result = await contract.get_counter_value();
    console.log("readCounterDecryptedValue result:", result);
  } catch (error) {
    console.error("Error reading from contract:", error);
  }
};

// Helper function to read counter (encrypted value)
const readCounterEncryptedValue = async () => {
  const result = await contract.get_encrypted_counter_value();
  console.log("Result:", result);

  // Let's create a permit to unseal the encrypted value
  const permit = await cofhejs.createPermit({
    type: "self",
    issuer: wallet.address
  });

  // When creating a permit cofhejs will use it automatically, but you can pass it manually as well
  const unsealed = await cofhejs.unseal(
    result,
    FheTypes.Uint64,
    permit.data.issuer,
    permit.data.getHash()
  );
  console.log(unsealed);
};

// Helper function to increment counter
const incrementCounter = async () => {
  const tx = await contract.increment_counter();
  console.log("incrementCounter tx hash:", tx.hash);
  await tx.wait();
};

// Helper function to reset counter with encrypted value
const resetCounter = async (value) => {
  const tx = await contract.reset_counter(value);
  console.log("resetCounter tx hash:", tx.hash);
  await tx.wait();
};

// Helper function to decrypt counter
const decryptCounter = async () => {
  const tx = await contract.decrypt_counter();
  console.log("decryptCounter tx hash:", tx.hash);
  await tx.wait();
};

// Execute the flow
(async () => {
  // Value not ready (when running this script for the first time)
  await readCounterDecryptedValue();

  await incrementCounter();

  // Return the value 1 (after unsealing)
  await readCounterEncryptedValue();

  await incrementCounter();

  // Sending transaction to decrypt the counter
  await decryptCounter();

  // Result should be 2
  await readCounterDecryptedValue();

  const encryptedValues = await cofhejs.encrypt([Encryptable.uint64(10n)], logState);
  await resetCounter(encryptedValues.data[0]);

  // Result should be 10
  await readCounterEncryptedValue();
})();
```

---

## API Reference

### Encryption

CoFHE.js provides an easy-to-use function to encrypt your inputs before sending them to the Fhenix Co-Processor.

> **Tip**: Encryption in Fhenix is done using the global chain key. This key is loaded when you create a CoFHE.js client automatically.

When we perform encryption, we specify the type of euint (Encrypted Integer) we want to create. This should match the expected type in the Solidity contract we are working with.

#### Initialization

First, initialize the library:

```javascript
// With Ethers
await cofhejs.initializeWithEthers({
  ethersProvider: provider,
  ethersSigner: wallet,
  environment: "LOCAL",
});

// With Viem
await cofhejs.initializeWithViem({
  viemClient: provider,
  viemWalletClient: wallet,
  environment: "LOCAL",
});
```

#### Encrypting Different Types

```javascript
import { cofhejs, Encryptable } from "cofhejs/node";

// Initialize cofhejs

const logState = (state) => {
  console.log(`Log Encrypt State :: ${state}`);
};

// Single value encryption
let result: [CofheInBool] = await cofhejs.encrypt([Encryptable.bool(true)], logState);
let result: [CoFheInUint8] = await cofhejs.encrypt([Encryptable.uint8(10)], logState);
let result: [CoFheInUint16] = await cofhejs.encrypt([Encryptable.uint16(10)], logState);
let result: [CoFheInUint32] = await cofhejs.encrypt([Encryptable.uint32(10)], logState);
let result: [CoFheInUint64] = await cofhejs.encrypt([Encryptable.uint64(10)], logState);
let result: [CoFheInUint128] = await cofhejs.encrypt([Encryptable.uint128(10)], logState);
let result: [CoFheInUint256] = await cofhejs.encrypt([Encryptable.uint256(10)], logState);
let result: [CoFheInAddress] = await cofhejs.encrypt([
  Encryptable.address("0x1234567890123456789012345678901234567890")
], logState);
```

#### Batch Encryption

Or, we can use the nested form to encrypt multiple values at once:

```javascript
let result = await cofhejs.encrypt([
  Encryptable.bool(true),
  Encryptable.uint8(10),
  Encryptable.uint16(10),
  Encryptable.uint32(10),
  Encryptable.uint64(10),
  Encryptable.uint128(10),
  Encryptable.uint256(10),
  Encryptable.address('0x1234567890123456789012345678901234567890'),
], logState);
```

#### Return Types

The returned types from the encrypt function will be an array of the type `CoFheInBool`, `CoFheInUint8`, `CoFheInUint16`, `CoFheInUint32` (or 64/128/256) or `CoFheInAddress` depending on the type you specified.

These encrypted types have the following structure:

```typescript
export type CoFheInItem = {
  ctHash: bigint;
  securityZone: number;
  utype: FheTypes;
  signature: string;
};

export type CoFheInUint8 extends CoFheInItem {
  utype: FheTypes.Uint8;
}
```

These types exist in order to enable type checking when interacting with Solidity contracts, and to make it easier to work with encrypted data.

#### Encryption State Callback

The `setState` function is used to monitor the state of the encryption process. Since the process is asynchronous, we can use this function to get the state of the encryption process for better UI experience.

```javascript
const logState = (state) => {
  console.log(`Log Encrypt State :: ${state}`);
};
```

##### Available States

1. **Extract** - Getting all the data ready for encryption (values to encrypt, chain information, etc.)
2. **Pack** - Preparing the data for the encryption process
3. **Prove** - Signing the data
4. **Verify** - Verifies the user's input, ensuring that it is safe to use
5. **Replace** - Preparing the result and replacing the old values with encrypted ones
6. **Done** - Process is finished

---

### Sealing & Unsealing

#### Overview

In Fhenix's FHE system, data returned from smart contracts is "sealed" (internally re-encrypted since it already exists in an encrypted state) to maintain confidentiality during transmission. The unsealing process converts this encrypted data back into readable values using your permit's sealing key pair.

> **Note**: To learn more about sealed box encryption, take a look at the [libsodium sealedbox docs](https://libsodium.gitbook.io/doc/public-key_cryptography/sealed_boxes).

#### Basic Usage

##### Simple Unsealing

The most straightforward way to unseal data is using `cofhejs.unseal()`:

> **Note**: Unsealing requires CoFHE.js to be initialized and for a permit to be created.

```javascript
// Get sealed data from a contract
const sealedBalance = await myContract.getBalance();

// Unseal with the correct type
const result = await cofhejs.unseal(sealedBalance, FheTypes.Uint64);

if (!result.success) {
  console.error('Failed to unseal:', result.error);
  return;
}

console.log('Balance:', result.data); // Unsealed value as BigInt
```

#### Supported Types

The unsealing process supports all FHE data types:

```javascript
// Integer types
const uint8 = await cofhejs.unseal(sealed, FheTypes.Uint8);
const uint16 = await cofhejs.unseal(sealed, FheTypes.Uint16);
const uint32 = await cofhejs.unseal(sealed, FheTypes.Uint32);
const uint64 = await cofhejs.unseal(sealed, FheTypes.Uint64);
const uint128 = await cofhejs.unseal(sealed, FheTypes.Uint128);
const uint256 = await cofhejs.unseal(sealed, FheTypes.Uint256);

// Boolean
const bool = await cofhejs.unseal(sealed, FheTypes.Bool);

// Address
const address = await cofhejs.unseal(sealed, FheTypes.Address);
```

#### Advanced Usage

##### Direct Permit Unsealing

For lower-level control, you can use the Permit class directly to unseal data:

```javascript
const permit = await Permit.create({
  type: 'self',
  issuer: userAddress,
});

// Seal some data (for demonstration)
const value = 937387n;
const sealed = SealingKey.seal(value, permit.sealingPair.publicKey);

// Unseal directly with permit
const unsealed = permit.unseal(sealed);
console.log(unsealed === value); // true
```

##### Type Conversions

Internally, data types require specific handling when unsealed:

```javascript
// Boolean values
const boolValue = true;
const sealedBool = SealingKey.seal(boolValue ? 1 : 0, permit.sealingPair.publicKey);
const unsealedBool = permit.unseal(sealedBool);
const resultBool = unsealedBool === 1n; // Convert BigInt to boolean

// Address values
const addressValue = '0x1234...';
const sealedAddress = SealingKey.seal(BigInt(addressValue), permit.sealingPair.publicKey);
const unsealedAddress = permit.unseal(sealedAddress);
const resultAddress = getAddress(`0x${unsealedAddress.toString(16).slice(-40)}`);
```

> **Note**: However this is handled for you with `cofhejs.unseal`. Unsealing an encrypted boolean will return a bool, an encrypted address will return a 0x prefixed string, and an encrypted number will return a js bigint.

---

### Permits Management

Permits are a crucial security mechanism in Fhenix that allow users to authenticate themselves when accessing encrypted data through off-chain operations like `sealoutput` and `decrypt`. These operations are exposed and handled by CoFHE.js.

#### Quick Start

##### Basic Integration (Development)

In a development environment, permit management can be handled automatically by CoFHE.js. When initialized with a valid provider and signer, the SDK will prompt users to sign a new permit, granting them access to their encrypted data:

```javascript
// Initialize your web3 provider
const provider = new ethers.JsonRpcProvider('http://127.0.0.1:42069');
const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

// Initialize cofhejs Client with ethers (it also supports viem)
await cofhejs.initializeWithEthers({
  ethersProvider: provider,
  ethersSigner: wallet,
  environment: 'TESTNET',
});
```

##### Production Setup

For production environments, you'll want more control over the permit generation process. Disable automatic permit generation by setting `generatePermit: false`:

```javascript
// Initialize your web3 provider
const provider = new ethers.JsonRpcProvider('http://127.0.0.1:42069');
const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

// Initialize cofhejs Client with ethers (it also supports viem)
await cofhejs.initializeWithEthers({
  provider: provider,
  signer: signer,
  environment: 'MAINNET',
  generatePermit: false,
});
```

After initialization, you'll need to manually call `cofhe.createPermit()` to generate user permits. It's recommended to inform users about the purpose of permits before requesting their signature.

##### User Interface Example

Here's an example modal that explains permits to users:

```javascript
const PermitModal = () => (
  <div className='permit-modal'>
    <h2>Sign a Permit</h2>
    <p>Permits grant secure access to your encrypted data on Fhenix by authenticating you with your signature. Each permit:</p>
    <ul>
      <li>Is valid for 24 hours</li>
      <li>Can only be used by you</li>
      <li>Ensures your data remains private</li>
    </ul>
    <button onClick={handleSignPermit}>Sign Permit</button>
  </div>
);
```

The sign permit action should call:

```javascript
const handleSignPermit = async () => {
  const result = await cofhejs.createPermit({
    type: 'self',
    issuer: userAddress,
  });

  if (!result.success) {
    console.error('Failed to create permit:', result.error);
    return;
  }
  // Permit created successfully
};
```

This will trigger the user's wallet to prompt for their signature. Once signed, the permit will be automatically stored and used for subsequent `cofhe.unseal` operations.

#### Sharing Permits

##### Overview

Sharing permits enables users to grant others access to their encrypted data in a secure way. The sharing process involves three steps:

1. Original data owner creates a sharing permit
2. Owner sends the permit to the recipient
3. Recipient activates the permit with their signature

##### Implementation

<details>
<summary><b>Step 1: Data owner creates a sharing permit</b></summary>

```javascript
const createSharingPermit = async (ownerAddress: string, recipientAddress: string) => {
  const result = await cofhejs.createPermit({
    type: 'sharing',
    issuer: ownerAddress,
    recipient: recipientAddress,
  });

  if (!result.success) {
    throw new Error(`Failed to create sharing permit: ${result.error}`);
  }

  return result.data;
};
```

The permit data can be safely transmitted to the recipient as plaintext since it contains no confidential information.

</details>

<details>
<summary><b>Step 2: Recipient activates the permit</b></summary>

```javascript
const activateReceivedPermit = async (sharingPermit: Permit) => {
  const result = await cofhejs.createPermit({
    ...sharingPermit,
    type: 'recipient',
  });

  if (!result.success) {
    throw new Error(`Failed to activate permit: ${result.error}`);
  }

  return result.data;
};
```

</details>

#### Advanced Features

##### Permit Validation

Permits include built-in validation mechanisms:

- **Expiration**: Permits automatically expire after 24 hours (configurable)
- **Signature Verification**: Ensures permits are only used by authorized parties
- **Chain Validation**: Permits are bound to specific networks

##### Custom Validators

You can implement custom validation logic by specifying a validator contract:

```javascript
const permitWithValidator = await cofhejs.createPermit({
  type: 'self',
  issuer: userAddress,
  validatorContract: '0x...', // Your validator contract address
  validatorId: 1, // Custom validation identifier
});
```

#### Error Handling

Always handle permit operations with proper error checking:

```javascript
const handlePermitCreation = async () => {
  try {
    const result = await cofhejs.createPermit({
      type: 'self',
      issuer: userAddress,
    });

    if (!result.success) {
      console.error('Permit creation failed:', result.error);
      return;
    }

    // Handle successful permit creation
  } catch (error) {
    console.error('Unexpected error:', error);
  }
};
```

#### API Reference

See `PermitOptions` interface for the complete list of options available when creating permits:

```typescript
interface PermitOptions {
  type: 'self' | 'sharing' | 'recipient';
  issuer: string;
  recipient?: string;
  expiration?: number;
  validatorId?: number;
  validatorContract?: string;
  name?: string;
}
```

---

### Error Handling

CoFHE.js uses a consistent error handling pattern based on the `Result` type to provide predictable and type-safe error handling throughout the library.

#### The Result Type

CoFHE.js uses a functional approach to error handling with the Result type. This pattern avoids exceptions and provides explicit error information.

```typescript
export type Result<T, E = string> =
  | { success: true; data: T; error: null }
  | { success: false; data: null; error: E };
```

The Result type is a discriminated union that represents either:
- A successful operation with data (`success: true`)
- A failed operation with an error message (`success: false`)

#### Helper Functions

CoFHE.js provides two helper functions to create Result objects:

```typescript
// Creates a Result representing a failure
export const ResultErr = <T, E>(error: E): Result<T, E> => ({
  success: false,
  data: null,
  error,
});

// Creates a Result representing a success
export const ResultOk = <T, E>(data: T): Result<T, E> => ({
  success: true,
  data,
  error: null,
});
```

#### Where Result is Used

Most asynchronous operations in CoFHE.js return a Result type, including:

- Initialization functions (`initializeWithEthers`, `initializeWithViem`, `initialize`)
- Permit operations (`createPermit`, `getPermit`, `getPermission`)
- Encryption and decryption operations

#### Handling Errors

When working with functions that return a Result, always check the `success` property before accessing the data.

##### Basic Error Handling Pattern

```javascript
const result = await cofhejs.initialize({
  provider: ethersProvider,
  signer: wallet,
  environment: 'TESTNET',
});

if (!result.success) {
  console.error('Initialization failed:', result.error);
  // Handle the error appropriately
  return;
}

// Safe to access result.data only after checking success
const permit = result.data;
// Continue with your application logic
```

##### Error Handling with Destructuring

You can use destructuring to make your code more concise:

```javascript
const {
  success,
  data: permit,
  error,
} = await cofhejs.createPermit({
  type: 'self',
  issuer: userAddress,
});

if (!success) {
  console.error('Failed to create permit:', error);
  return;
}

// Use permit safely
console.log('Permit created successfully:', permit);
```

#### Common Error Scenarios

<details>
<summary><b>Initialization Errors</b></summary>

- Missing provider or signer
- Network connectivity issues
- Unsupported environment

</details>

<details>
<summary><b>Permit Errors</b></summary>

- Invalid permit parameters
- Missing signer
- Unauthorized operations

</details>

<details>
<summary><b>Encryption Errors</b></summary>

- Missing FHE public key
- Invalid input types
- Network service unavailability

</details>

#### Complete Example

Here's a complete example of initializing CoFHE.js and handling potential errors:

```javascript
async function initializeCoFHE() {
  try {
    // Initialize your web3 provider
    const provider = new ethers.BrowserProvider(window.ethereum);
    const signer = (await provider.getSigner()) as ethers.JsonRpcSigner;

    // Initialize cofhejs Client with ethers (it also supports viem)
    const result = await cofhejs.initializeWithEthers({
      provider: window.ethereum,
      signer: wallet,
      environment: 'TESTNET',
    });

    if (!result.success) {
      // Handle specific error cases
      if (result.error.includes('missing provider')) {
        console.error('Provider not available. Please install a wallet extension.');
      } else if (result.error.includes('failed to initialize cofhejs')) {
        console.error('FHE initialization failed. The network may not be FHE-enabled.');
      } else {
        console.error('Initialization error:', result.error);
      }
      return null;
    }

    console.log('`cofhejs` initialized successfully');
    return result.data; // The permit, if generated
  } catch (unexpectedError) {
    // Catch any unexpected errors not handled by the Result pattern
    console.error('Unexpected error during initialization:', unexpectedError);
    return null;
  }
}

// Example of creating and using a permit with error handling
async function createAndUsePermit(userAddress) {
  const permitResult = await cofhejs.createPermit({
    type: 'self',
    issuer: userAddress,
  });

  if (!permitResult.success) {
    console.error('Permit creation failed:', permitResult.error);
    return;
  }

  const permit = permitResult.data;
  console.log('Permit created successfully:', permit);

  // Continue with operations that require the permit
  // ...
}
```

#### Testing Error Cases

When writing tests, CoFHE.js provides utility functions to validate error results:

```javascript
import { expectResultError } from 'cofhejs/test';

test('should return error for invalid parameters', async () => {
  const result = await cofhejs.initialize({
    // Missing required parameters
  });

  expectResultError(
    result,
    'initialize :: missing provider - Please provide an AbstractProvider interface'
  );
});
```

By consistently checking the `success` property and appropriately handling errors, you can build robust applications that gracefully handle failure cases when working with CoFHE.js.

---

## Summary

This documentation covers the essential aspects of working with CoFHE.js:

- **Getting Started**: Installation, setup, and mental models
- **Core Concepts**: Encryption, permits, and unsealing
- **Complete Examples**: End-to-end usage patterns
- **API Reference**: Detailed documentation for all major features

For additional support or questions, please refer to the [Fhenix documentation](https://docs.fhenix.zone) or reach out to the community.
