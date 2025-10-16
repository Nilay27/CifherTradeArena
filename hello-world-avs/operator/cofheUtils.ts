/**
 * CoFHE.js Utilities
 * General-purpose type-safe FHE encryption/decryption operations
 * Designed for reusability across all operator files
 */

import { ethers } from 'ethers';
import { getNetworkConfig } from './utils/cofheConfig';

// CoFHE.js for FHE operations - Import FheTypes enum directly from SDK (single source of truth)
const { cofhejs, Encryptable, FheTypes } = require('cofhejs/node');

// Re-export FheTypes for convenience
export { FheTypes };

/**
 * Input for batch encryption with type specification
 * Uses FheTypes from CoFHE.js SDK to ensure correct utype values:
 * - Bool = 0, Uint8 = 2, Uint32 = 4, Uint128 = 6, Uint160/Address = 7, Uint256 = 8
 */
export interface EncryptionInput {
    value: bigint | string | boolean;  // Value to encrypt
    type: number;                      // FheTypes value (e.g., FheTypes.Uint256 = 8)
}

/**
 * CoFHE encrypted item structure
 * Matches InEtype structs in Solidity contracts (InEuint128, InEaddress, etc.)
 */
export interface CoFheItem {
    ctHash: bigint;         // The encrypted ciphertext hash
    securityZone: number;   // Security zone identifier
    utype: number;          // FHE type (matches FheTypes enum)
    signature: string;      // Signature for verification
}

// Module state
let operatorSigner: ethers.Wallet;
let isInitialized = false;

/**
 * Initialize CoFHE.js with the provided signer
 * Creates permit once for all subsequent operations
 */
export const initializeCofhe = async (signer: ethers.Wallet) => {
    try {
        operatorSigner = signer;

        // Get network configuration
        const network = await signer.provider!.getNetwork();
        const networkConfig = getNetworkConfig(Number(network.chainId));

        console.log(`Initializing CoFHE.js for ${networkConfig.name} (chainId: ${networkConfig.chainId})`);

        // Determine environment based on network
        const environment = networkConfig.environment === 'LOCAL' ? 'MOCK' : networkConfig.environment;

        // Initialize CoFHE.js with ethers provider and signer
        await cofhejs.initializeWithEthers({
            ethersProvider: signer.provider,
            ethersSigner: signer,
            environment: environment
        });

        // Create permit ONCE - stored internally by CoFHE.js for all subsequent operations
        try {
            await cofhejs.createPermit({
                type: 'self',
                issuer: signer.address,
            });
            console.log("✓ CoFHE.js permit created successfully");
        } catch (permitError) {
            console.log("⚠ Permit creation skipped (may not be critical for mock environment)");
        }

        isInitialized = true;
        console.log("✓ CoFHE.js initialized successfully");
        console.log("✓ FHE encryption/decryption enabled");
    } catch (initError) {
        console.error("✗ CoFHE.js initialization error:", initError);
        throw new Error("Failed to initialize CoFHE.js");
    }
};

/**
 * Helper: Convert value to appropriate Encryptable type
 * @param value - The value to convert
 * @param type - The target FHE type (from FheTypes enum)
 * @returns Encryptable object ready for encryption
 */
function toEncryptable(value: bigint | string | boolean, type: number): any {
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
        case FheTypes.Uint256:
            return Encryptable.uint256(BigInt(value));
        case FheTypes.Uint160:  // Address type
            // Address should be passed as string (0x...) or bigint
            const addrValue = typeof value === 'string' && value.startsWith('0x')
                ? value
                : ethers.getAddress(ethers.toBeHex(BigInt(value), 20));
            return Encryptable.address(addrValue);
        default:
            throw new Error(`Unsupported FHE type: ${type}`);
    }
}

/**
 * Batch encrypt multiple values with type specification
 * @param inputs - Array of values with their target FHE types
 * @param userAddress - Optional: user address for encryption context
 * @param contractAddress - Optional: contract address for encryption context
 * @returns Array of CoFheItem structs
 */
export const batchEncrypt = async (
    inputs: EncryptionInput[],
    userAddress?: string,
    contractAddress?: string
): Promise<CoFheItem[]> => {
    if (!isInitialized) {
        throw new Error("CoFHE.js not initialized. Call initializeCofhe() first.");
    }

    try {
        console.log(`Batch encrypting ${inputs.length} values with types...`);

        // Convert all inputs to Encryptable objects with appropriate types
        const encryptables = inputs.map((input, index) => {
            const encryptable = toEncryptable(input.value, input.type);
            console.log(`  [${index}] Preparing: ${input.value} as FheType ${input.type}`);
            return encryptable;
        });

        // Encrypt all values at once
        const encResult = await cofhejs.encrypt(encryptables);

        if (!encResult.success) {
            throw new Error(`Batch encryption failed: ${encResult.error?.message || 'Unknown error'}`);
        }

        // Return full encrypted items (CoFheItem structs)
        const encryptedItems: CoFheItem[] = encResult.data.map((item: any, index: number) => {
            console.log(`  [${index}] Encrypted: ${inputs[index].value} as FheType ${inputs[index].type} -> ctHash: ${item.ctHash}, utype: ${item.utype}`);

            // Verify utype matches expected type
            if (item.utype !== inputs[index].type) {
                console.warn(`  ⚠ Warning: Expected utype ${inputs[index].type} but got ${item.utype}`);
            }

            return {
                ctHash: BigInt(item.ctHash),
                securityZone: item.securityZone,
                utype: item.utype,
                signature: item.signature
            };
        });

        console.log(`✓ Successfully batch encrypted ${encryptedItems.length} values`);
        return encryptedItems;
    } catch (error) {
        console.error("Error batch encrypting values:", error);
        throw error;
    }
};

/**
 * Batch decrypt values with type-aware unsealing
 * Uses utype from each CoFheItem to correctly decrypt and convert values
 * @param items - Array of encrypted items with utype information
 * @returns Array of decrypted values (correctly typed based on utype)
 */
export const batchDecrypt = async (items: CoFheItem[]): Promise<any[]> => {
    if (!isInitialized) {
        throw new Error("CoFHE.js not initialized. Call initializeCofhe() first.");
    }

    try {
        console.log(`Batch decrypting ${items.length} values with type information...`);

        // Decrypt each value with its specific utype
        const decryptPromises = items.map(async (item, index) => {
            console.log(`  [${index}] Decrypting: ctHash=${item.ctHash}, utype=${item.utype}`);

            const result = await cofhejs.unseal(item.ctHash, item.utype);

            if (!result.success) {
                throw new Error(`Decryption failed for item ${index}: ${result.error?.message || 'Unknown error'}`);
            }

            let decryptedValue = result.data;

            // Convert based on utype
            if (item.utype === FheTypes.Uint160) {
                // Address type - convert to address string
                decryptedValue = typeof decryptedValue === 'string'
                    ? decryptedValue
                    : ethers.getAddress(ethers.toBeHex(BigInt(decryptedValue), 20));
            } else if (item.utype === FheTypes.Bool) {
                // Boolean type
                decryptedValue = Boolean(decryptedValue);
            } else {
                // Numeric types - ensure bigint
                decryptedValue = BigInt(decryptedValue);
            }

            console.log(`  [${index}] Decrypted (utype ${item.utype}): ${decryptedValue}`);
            return decryptedValue;
        });

        const results = await Promise.all(decryptPromises);
        console.log(`✓ Successfully batch decrypted ${results.length} values`);

        return results;
    } catch (error) {
        console.error("Error batch decrypting values:", error);
        throw error;
    }
};

// Export initialization status check
export const isCoFheInitialized = (): boolean => isInitialized;
