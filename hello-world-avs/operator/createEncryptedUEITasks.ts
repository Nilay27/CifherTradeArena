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

dotenv.config();

const PROVIDER_URL = process.env.RPC_URL || 'https://sepolia.infura.io/v3/YOUR_KEY';
const PRIVATE_KEY = process.env.PRIVATE_KEY || '';

// Sepolia testnet addresses
const SWAP_MANAGER = '0xE1e00b5d08a08Cb141a11a922e48D4c06d66D3bf';
const BORING_VAULT = '0x4D2a5229C238EEaF5DB0912eb4BE7c39575369f0';
const USDC_SEPOLIA = '0x59dd1A3Bd1256503cdc023bfC9f10e107d64C3C1'; // Sepolia USDC

// Mock decoder for ERC20 transfers (for testing - in production would be verified via merkle tree)
// Using a valid address format - decoder validation will be added with merkle tree in BoringVault
const MOCK_ERC20_DECODER = '0x0000000000000000000000000000000000000001';

/**
 * Batch encrypt all UEI components using CoFHE.js with type-aware encryption
 * Each component is encrypted with the correct FHE type:
 * - decoder: FheType.Address (InEaddress)
 * - target: FheType.Address (InEaddress)
 * - selector: FheType.Uint32 (InEuint32)
 * - args: FheType.Uint256 (InEuint256[])
 * Returns CoFheItem structs with correct utype for each component
 */
async function batchEncryptUEIComponents(
    decoder: string,
    target: string,
    selector: string,
    args: (string | bigint)[],
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
        console.log(`  Decoder: ${decoder} (type: Address)`);
        console.log(`  Target: ${target} (type: Address)`);
        console.log(`  Selector: ${selector} (type: Uint32)`);
        console.log(`  Args (${args.length}): (type: Uint256 each)`);
        args.forEach((arg, i) => console.log(`    [${i}]: ${arg.toString()}`));

        // Prepare typed inputs for batch encryption
        const inputs: EncryptionInput[] = [
            { value: decoder, type: FheTypes.Uint160 },     // decoder as Address (Uint160)
            { value: target, type: FheTypes.Uint160 },      // target as Address (Uint160)
            { value: selector, type: FheTypes.Uint32 },     // selector as Uint32
            ...args.map(arg => ({
                value: typeof arg === 'string' ? BigInt(arg) : arg,
                type: FheTypes.Uint256                       // each arg as Uint256
            }))
        ];

        // Batch encrypt all values with correct types
        const encryptedItems = await batchEncrypt(inputs, signerAddress, contractAddress);

        console.log("✅ Encrypted components with correct types:");
        console.log(`  Decoder: utype=${encryptedItems[0].utype} (expected ${FheTypes.Uint160})`);
        console.log(`  Target: utype=${encryptedItems[1].utype} (expected ${FheTypes.Uint160})`);
        console.log(`  Selector: utype=${encryptedItems[2].utype} (expected ${FheTypes.Uint32})`);
        encryptedItems.slice(3).forEach((item, i) => {
            console.log(`  Arg[${i}]: utype=${item.utype} (expected ${FheTypes.Uint256})`);
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

        console.log("👤 Submitter wallet:", wallet.address);
        console.log("💰 Boring Vault:", BORING_VAULT);
        console.log("🏦 SwapManager:", SWAP_MANAGER);
        console.log("💵 USDC:", USDC_SEPOLIA);

        // Load SwapManager ABI
        const swapManagerAbi = JSON.parse(
            fs.readFileSync('./abis/SwapManager.json', 'utf8')
        );
        const swapManager = new ethers.Contract(SWAP_MANAGER, swapManagerAbi, wallet);

        // Simple USDC transfer parameters
        // transfer(address to, uint256 amount)
        const transferSelector = '0xa9059cbb'; // transfer function selector
        const recipient = wallet.address; // Transfer to deployer for testing
        const amount = ethers.parseUnits('100', 6); // 100 USDC (6 decimals)

        console.log("\n📋 Transfer Details:");
        console.log(`  From: ${BORING_VAULT} (BoringVault)`);
        console.log(`  To: ${recipient}`);
        console.log(`  Amount: ${ethers.formatUnits(amount, 6)} USDC`);
        console.log(`  Selector: ${transferSelector}`);

        // Initialize CoFHE.js
        await initializeCofhe(wallet);

        // Batch encrypt: decoder, target, selector, args
        console.log("\n🔐 Encrypting UEI components...");
        const encrypted = await batchEncryptUEIComponents(
            MOCK_ERC20_DECODER,  // decoder
            USDC_SEPOLIA,        // target (USDC contract)
            transferSelector,    // selector (transfer)
            [
                BigInt(recipient),  // arg[0]: recipient address as uint256
                amount             // arg[1]: amount as uint256
            ],
            SWAP_MANAGER,        // contract address for encryption context
            wallet.address       // signer address
        );

        // Prepare CoFheItem structs for submission
        // Each component is a full struct with {ctHash, securityZone, utype, signature}
        // Contract expects: submitEncryptedUEI(InEaddress decoder, InEaddress target, InEuint32 selector, InEuint256[] args, deadline)
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

        const argsStructs = encrypted.encryptedArgs.map(item => ({
            ctHash: ethers.toBeHex(item.ctHash, 32),
            securityZone: item.securityZone,
            utype: item.utype,
            signature: item.signature
        }));

        console.log("\n📦 Prepared CoFheItem structs:");
        console.log(`  Decoder: utype=${decoderStruct.utype} (Address)`);
        console.log(`  Target: utype=${targetStruct.utype} (Address)`);
        console.log(`  Selector: utype=${selectorStruct.utype} (Uint32)`);
        console.log(`  Args: ${argsStructs.length} items, each utype=${argsStructs[0]?.utype || 'N/A'} (Uint256)`);

        // Submit to SwapManager
        const deadline = Math.floor(Date.now() / 1000) + 3600; // 1 hour

        console.log("\n📤 Submitting UEI to SwapManager...");
        console.log(`  Deadline: ${new Date(deadline * 1000).toLocaleString()}`);

        // Submit to SwapManager with individual CoFheItem structs
        // Each encrypted component is passed separately with its correct type
        const tx = await swapManager.submitEncryptedUEI(
            decoderStruct,   // InEaddress
            targetStruct,    // InEaddress
            selectorStruct,  // InEuint32
            argsStructs,     // InEuint256[]
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
