/**
 * Create Encrypted UEI Tasks - Simplified for Testing
 *
 * This script submits a simple USDC transfer UEI to the SwapManager
 * Flow:
 * 1. Encrypt: decoder (address), target (USDC), selector (transfer), args [recipient, amount]
 *    - Each component encrypted with correct type (Address, Address, Uint32, Uint256[])
 * 2. Submit to SwapManager.submitEncryptedUEI(decoder, target, selector, args, deadline)
 *    - Each parameter is a CoFheItem struct with correct utype
 * 3. Wait for batch finalization (handled by keeper or manual call)
 * 4. Operator will decrypt and process (handled by ueiProcessor.ts)
 */

import { ethers } from 'ethers';
import * as dotenv from 'dotenv';
import * as fs from 'fs';
import { initializeCofhe, batchEncrypt, EncryptionInput, FheTypes, CoFheItem } from './cofheUtils';
import { loadDeploymentConfig, getNetworkName } from './config/deploymentConfig';

dotenv.config();

const PROVIDER_URL = process.env.RPC_URL || 'https://sepolia.infura.io/v3/YOUR_KEY';
const PRIVATE_KEY = process.env.PRIVATE_KEY || '';

// Dynamic addresses loaded from deployment files
let SWAP_MANAGER: string;
let BORING_VAULT: string;
let USDC_ADDRESS: string;

// Mock decoder for ERC20 transfers (for testing - in production would be verified via merkle tree)
// Using a valid address format - decoder validation will be added with merkle tree in BoringVault
const MOCK_ERC20_DECODER = '0x0000000000000000000000000000000000000001';

/**
 * Argument specification with value and FHE type
 */
interface ArgWithType {
    value: string | bigint;
    type: number;  // FheTypes value
}

/**
 * Batch encrypt all UEI components using CoFHE.js with type-aware encryption
 * Each component is encrypted with the correct FHE type:
 * - decoder: FheType.Uint160 (Address)
 * - target: FheType.Uint160 (Address)
 * - selector: FheType.Uint32
 * - args: Dynamic types (Address, Uint128, etc.) - NO Uint256!
 * Returns CoFheItem structs (DynamicInE) with correct utype for each component
 */
async function batchEncryptUEIComponents(
    decoder: string,
    target: string,
    selector: string,
    args: ArgWithType[],
    contractAddress: string,
    signerAddress: string
): Promise<{
    encryptedDecoder: CoFheItem;
    encryptedTarget: CoFheItem;
    encryptedSelector: CoFheItem;
    encryptedArgs: CoFheItem[];
}> {
    try {
        console.log("🔐 Batch encrypting UEI components using type-aware CoFHE.js...");
        console.log(`  Decoder: ${decoder} (type: Address = ${FheTypes.Uint160})`);
        console.log(`  Target: ${target} (type: Address = ${FheTypes.Uint160})`);
        console.log(`  Selector: ${selector} (type: Uint32 = ${FheTypes.Uint32})`);
        console.log(`  Args (${args.length}): Dynamic types`);
        args.forEach((arg, i) => {
            const typeName = arg.type === FheTypes.Uint160 ? 'Address' :
                           arg.type === FheTypes.Uint128 ? 'Uint128' :
                           arg.type === FheTypes.Uint64 ? 'Uint64' :
                           arg.type === FheTypes.Uint32 ? 'Uint32' : `Type${arg.type}`;
            console.log(`    [${i}]: ${arg.value.toString()} (type: ${typeName} = ${arg.type})`);
        });

        // Prepare typed inputs for batch encryption
        const inputs: EncryptionInput[] = [
            { value: decoder, type: FheTypes.Uint160 },     // decoder as Address (Uint160)
            { value: target, type: FheTypes.Uint160 },      // target as Address (Uint160)
            { value: selector, type: FheTypes.Uint32 },     // selector as Uint32
            ...args.map(arg => ({
                value: typeof arg.value === 'string' ? BigInt(arg.value) : arg.value,
                type: arg.type  // Use provided type (Uint160, Uint128, etc.)
            }))
        ];

        // Batch encrypt all values with correct types
        const encryptedItems = await batchEncrypt(inputs, signerAddress, contractAddress);

        console.log("✅ Encrypted components with correct types:");
        console.log(`  Decoder: utype=${encryptedItems[0].utype} (expected ${FheTypes.Uint160})`);
        console.log(`  Target: utype=${encryptedItems[1].utype} (expected ${FheTypes.Uint160})`);
        console.log(`  Selector: utype=${encryptedItems[2].utype} (expected ${FheTypes.Uint32})`);
        encryptedItems.slice(3).forEach((item, i) => {
            console.log(`  Arg[${i}]: utype=${item.utype} (expected ${args[i].type})`);
        });

        return {
            encryptedDecoder: encryptedItems[0],
            encryptedTarget: encryptedItems[1],
            encryptedSelector: encryptedItems[2],
            encryptedArgs: encryptedItems.slice(3)
        };
    } catch (error) {
        console.error("❌ Encryption failed:", error);
        throw error;
    }
}

/**
 * Create and submit a simple USDC transfer UEI
 */
async function createUSDCTransferUEI() {
    try {
        console.log("\n🚀 Creating USDC Transfer UEI\n");
        console.log("=" .repeat(60));

        // Setup provider and wallet
        const provider = new ethers.JsonRpcProvider(PROVIDER_URL);
        const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

        // Load deployment config based on chain ID
        const network = await provider.getNetwork();
        const chainId = Number(network.chainId);
        const config = loadDeploymentConfig(chainId);

        SWAP_MANAGER = config.swapManager;
        BORING_VAULT = config.boringVault || '0x0000000000000000000000000000000000000000';
        USDC_ADDRESS = config.mockUSDC;

        console.log(`Network: ${config.network} (Chain ID: ${chainId})`);
        console.log("👤 Submitter wallet:", wallet.address);
        console.log("💰 Boring Vault:", BORING_VAULT);
        console.log("🏦 SwapManager:", SWAP_MANAGER);
        console.log("💵 USDC:", USDC_ADDRESS);

        // Load SwapManager ABI
        const swapManagerAbi = JSON.parse(
            fs.readFileSync('./abis/SwapManager.json', 'utf8')
        );
        const swapManager = new ethers.Contract(SWAP_MANAGER, swapManagerAbi, wallet);

        // Simple USDC transfer parameters
        // transfer(address to, uint128 amount) - Using Uint128 to avoid deprecated Uint256
        const transferSelector = '0xa9059cbb'; // transfer function selector
        const recipient = wallet.address; // Transfer to deployer for testing
        const amount = ethers.parseUnits('100', 6); // 100 USDC (6 decimals)

        console.log("\n📋 Transfer Details:");
        console.log(`  From: ${BORING_VAULT} (BoringVault)`);
        console.log(`  To: ${recipient}`);
        console.log(`  Amount: ${ethers.formatUnits(amount, 6)} USDC`);
        console.log(`  Selector: ${transferSelector}`);
        console.log(`  Function: transfer(address, uint128) - Dynamic types!`);

        // Initialize CoFHE.js
        await initializeCofhe(wallet);

        // Batch encrypt: decoder, target, selector, args
        // Using dynamic types: Address (Uint160) for recipient, Uint128 for amount
        console.log("\n🔐 Encrypting UEI components with dynamic types...");
        const encrypted = await batchEncryptUEIComponents(
            MOCK_ERC20_DECODER,  // decoder
            USDC_ADDRESS,        // target (USDC contract)
            transferSelector,    // selector (transfer)
            [
                { value: recipient, type: FheTypes.Uint160 },  // arg[0]: recipient as Address (utype 7)
                { value: amount, type: FheTypes.Uint128 }      // arg[1]: amount as Uint128 (utype 6)
            ],
            SWAP_MANAGER,        // contract address for encryption context
            wallet.address       // signer address
        );

        // Prepare DynamicInE structs for submission
        // Each component is a full struct with {ctHash, securityZone, utype, signature}
        // Contract expects: submitEncryptedUEI(InEaddress decoder, InEaddress target, InEuint32 selector, DynamicInE[] args, deadline)
        const decoderStruct = {
            ctHash: ethers.toBeHex(encrypted.encryptedDecoder.ctHash, 32),
            securityZone: encrypted.encryptedDecoder.securityZone,
            utype: encrypted.encryptedDecoder.utype,
            signature: encrypted.encryptedDecoder.signature
        };

        const targetStruct = {
            ctHash: ethers.toBeHex(encrypted.encryptedTarget.ctHash, 32),
            securityZone: encrypted.encryptedTarget.securityZone,
            utype: encrypted.encryptedTarget.utype,
            signature: encrypted.encryptedTarget.signature
        };

        const selectorStruct = {
            ctHash: ethers.toBeHex(encrypted.encryptedSelector.ctHash, 32),
            securityZone: encrypted.encryptedSelector.securityZone,
            utype: encrypted.encryptedSelector.utype,
            signature: encrypted.encryptedSelector.signature
        };

        // Args are now DynamicInE[] with mixed types (Address, Uint128, etc.)
        const argsStructs = encrypted.encryptedArgs.map(item => ({
            ctHash: ethers.toBeHex(item.ctHash, 32),
            securityZone: item.securityZone,
            utype: item.utype,
            signature: item.signature
        }));

        console.log("\n📦 Prepared DynamicInE structs:");
        console.log(`  Decoder: utype=${decoderStruct.utype} (Address)`);
        console.log(`  Target: utype=${targetStruct.utype} (Address)`);
        console.log(`  Selector: utype=${selectorStruct.utype} (Uint32)`);
        console.log(`  Args (DynamicInE[]): ${argsStructs.length} items with mixed types:`);
        argsStructs.forEach((arg, i) => {
            const typeName = arg.utype === 7 ? 'Address' :
                           arg.utype === 6 ? 'Uint128' :
                           arg.utype === 4 ? 'Uint32' : `Type${arg.utype}`;
            console.log(`    [${i}]: utype=${arg.utype} (${typeName})`);
        });

        // Submit to SwapManager
        const deadline = Math.floor(Date.now() / 1000) + 3600; // 1 hour

        console.log("\n📤 Submitting UEI to SwapManager...");
        console.log(`  Deadline: ${new Date(deadline * 1000).toLocaleString()}`);

        // Submit to SwapManager with DynamicInE structs
        // Each encrypted component is passed with its original type preserved
        // Args can be mixed types (Address, Uint128, etc.) - NO Uint256!
        const tx = await swapManager.submitEncryptedUEI(
            decoderStruct,   // InEaddress
            targetStruct,    // InEaddress
            selectorStruct,  // InEuint32
            argsStructs,     // DynamicInE[] - Mixed types!
            deadline,
            { nonce: await wallet.getNonce() }  // Add nonce as per project instructions
        );

        console.log(`  Transaction hash: ${tx.hash}`);
        console.log("  Waiting for confirmation...");

        const receipt = await tx.wait();
        console.log("✅ UEI submitted successfully!");

        // Extract intent ID from TradeSubmitted event
        const tradeSubmittedEvent = receipt.logs.find((log: any) => {
            try {
                const parsed = swapManager.interface.parseLog(log);
                return parsed && parsed.name === 'TradeSubmitted';
            } catch {
                return false;
            }
        });

        if (tradeSubmittedEvent) {
            const parsed = swapManager.interface.parseLog(tradeSubmittedEvent);
            const tradeId = parsed?.args[0];
            const batchId = parsed?.args[2];

            console.log("\n🎯 Trade Details:");
            console.log(`  Trade ID: ${tradeId}`);
            console.log(`  Batch ID: ${batchId}`);
            console.log(`  Submitter: ${parsed?.args[1]}`);
            console.log(`  Deadline: ${new Date(Number(parsed?.args[4]) * 1000).toLocaleString()}`);

            // Check task details
            const task = await swapManager.getUEITask(tradeId);
            console.log("\n📊 Task Status:");
            console.log(`  Status: ${['Pending', 'Processing', 'Executed', 'Failed', 'Expired'][task.status]}`);
            console.log(`  Batch ID: ${task.batchId}`);

            console.log("\n⏳ Next Steps:");
            console.log("  1. Waiting 5 seconds before triggering batch finalization...");
            console.log("  2. Admin will forcefully finalize batch (admin override)");
            console.log("  3. Operator will decrypt and process via ueiProcessor.ts");

            // Wait 5 seconds
            await new Promise(resolve => setTimeout(resolve, 5000));

            console.log("\n🔨 Finalizing batch as admin...");
            const finalizeTx = await swapManager.finalizeUEIBatch();
            console.log(`  Transaction hash: ${finalizeTx.hash}`);
            console.log("  Waiting for confirmation...");

            const finalizeReceipt = await finalizeTx.wait();
            console.log("✅ Batch finalized!");

            // Extract UEIBatchFinalized event
            const batchFinalizedEvent = finalizeReceipt.logs.find((log: any) => {
                try {
                    const parsed = swapManager.interface.parseLog(log);
                    return parsed && parsed.name === 'UEIBatchFinalized';
                } catch {
                    return false;
                }
            });

            if (batchFinalizedEvent) {
                const parsed = swapManager.interface.parseLog(batchFinalizedEvent);
                const finalizedBatchId = parsed?.args[0];
                const selectedOperators = parsed?.args[1];
                const finalizedAt = parsed?.args[2];

                console.log("\n🎉 Batch Finalized Event:");
                console.log(`  Batch ID: ${finalizedBatchId}`);
                console.log(`  Selected Operators (${selectedOperators.length}):`);
                selectedOperators.forEach((op: string, i: number) => {
                    console.log(`    ${i + 1}. ${op}`);
                });
                console.log(`  Finalized at: ${new Date(Number(finalizedAt) * 1000).toLocaleString()}`);
                console.log("\n👂 Operator should now pick up and process this batch!");
            }
        }

        console.log("\n" + "=".repeat(60));

    } catch (error: any) {
        console.error("\n❌ Failed to create UEI:", error);
        if (error.message) console.error("Error message:", error.message);
        throw error;
    }
}

// Run if executed directly
if (require.main === module) {
    createUSDCTransferUEI().catch(console.error);
}

export { createUSDCTransferUEI };
