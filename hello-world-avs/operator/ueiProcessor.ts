/**
 * UEI Processor - Listens for batch finalization and processes encrypted UEI trades
 *
 * Complete Flow:
 * 1. Listen for UEIBatchFinalized event → get batchId & selectedOperators
 * 2. Check if this operator is selected
 * 3. Query past TradeSubmitted events filtered by batchId
 * 4. For each trade in batch:
 *    - Extract ctBlob from TradeSubmitted event (NOT from contract storage!)
 *    - Decode ctBlob to get encrypted handles
 *    - Batch decrypt all components using FHEVM
 *    - Reconstruct calldata (for POC: simple transfer)
 *    - Get consensus signatures from other operators
 *    - Call processUEI(intentId, decoder, target, calldata, signatures)
 * 5. Log execution results
 */

import { ethers } from 'ethers';
import * as dotenv from 'dotenv';
import * as fs from 'fs';
import { initializeCofhe, batchDecrypt, FheTypes, CoFheItem } from './cofheUtils';
import { loadDeploymentConfig, getNetworkName } from './config/deploymentConfig';

dotenv.config();

const PROVIDER_URL = process.env.RPC_URL || 'https://sepolia.infura.io/v3/YOUR_KEY';
const PRIVATE_KEY = process.env.PRIVATE_KEY || '';

// Dynamic addresses loaded from deployment files
let SWAP_MANAGER: string;
let BORING_VAULT: string;

/**
 * Decode event data to extract internal FHE handles with type information
 * Events emit HandleWithType structs: abi.encode(HandleWithType decoder, HandleWithType target, HandleWithType selector, HandleWithType[] args)
 * HandleWithType = {uint256 handle, uint8 utype}
 */
function decodeEventData(encodedData: string): {
    encDecoder: CoFheItem;
    encTarget: CoFheItem;
    encSelector: CoFheItem;
    encArgs: CoFheItem[];
} {
    try {
        // Decode HandleWithType structs (internal handles + utypes)
        const decoded = ethers.AbiCoder.defaultAbiCoder().decode(
            [
                'tuple(uint256 handle, uint8 utype)', // HandleWithType decoder
                'tuple(uint256 handle, uint8 utype)', // HandleWithType target
                'tuple(uint256 handle, uint8 utype)', // HandleWithType selector
                'tuple(uint256 handle, uint8 utype)[]' // HandleWithType[] args
            ],
            encodedData
        );

        const [decoderStruct, targetStruct, selectorStruct, argsStructs] = decoded;

        console.log("📦 Decoded event data with internal handles and type information:");
        console.log(`  Decoder: handle=${decoderStruct.handle}, utype=${decoderStruct.utype}`);
        console.log(`  Target: handle=${targetStruct.handle}, utype=${targetStruct.utype}`);
        console.log(`  Selector: handle=${selectorStruct.handle}, utype=${selectorStruct.utype}`);
        console.log(`  Args: ${argsStructs.length} arguments`);
        argsStructs.forEach((arg: any, i: number) => {
            console.log(`    [${i}]: handle=${arg.handle}, utype=${arg.utype}`);
        });

        return {
            encDecoder: {
                ctHash: BigInt(decoderStruct.handle),  // Internal handle, not original ctHash
                securityZone: 0,                        // Not needed for decryption
                utype: decoderStruct.utype,             // Preserved from original input
                signature: '0x'                         // Not needed for decryption
            },
            encTarget: {
                ctHash: BigInt(targetStruct.handle),
                securityZone: 0,
                utype: targetStruct.utype,
                signature: '0x'
            },
            encSelector: {
                ctHash: BigInt(selectorStruct.handle),
                securityZone: 0,
                utype: selectorStruct.utype,
                signature: '0x'
            },
            encArgs: argsStructs.map((arg: any) => ({
                ctHash: BigInt(arg.handle),
                securityZone: 0,
                utype: arg.utype,
                signature: '0x'
            }))
        };
    } catch (error) {
        console.error("❌ Failed to decode event data:", error);
        throw error;
    }
}

/**
 * Dynamically reconstruct calldata based on argument types (utype)
 * Converts decrypted values to appropriate Solidity types based on utype
 */
function reconstructCalldata(
    selector: string,
    args: any[],
    argTypes: number[]
): string {
    console.log("\n🔧 Dynamically reconstructing calldata...");
    console.log(`  Selector: ${selector}`);
    console.log(`  Args: ${args.length}`);

    // Convert decrypted values based on utypes
    const solidityTypes: string[] = [];
    const encodedArgs: any[] = [];

    for (let i = 0; i < args.length; i++) {
        const arg = args[i];
        const utype = argTypes[i];

        if (utype === FheTypes.Bool) {
            solidityTypes.push('bool');
            encodedArgs.push(Boolean(arg));
            console.log(`  Arg[${i}]: bool = ${Boolean(arg)}`);
        } else if (utype === FheTypes.Uint8) {
            solidityTypes.push('uint8');
            encodedArgs.push(arg);
            console.log(`  Arg[${i}]: uint8 = ${arg}`);
        } else if (utype === FheTypes.Uint16) {
            solidityTypes.push('uint16');
            encodedArgs.push(arg);
            console.log(`  Arg[${i}]: uint16 = ${arg}`);
        } else if (utype === FheTypes.Uint32) {
            solidityTypes.push('uint32');
            encodedArgs.push(arg);
            console.log(`  Arg[${i}]: uint32 = ${arg}`);
        } else if (utype === FheTypes.Uint64) {
            solidityTypes.push('uint64');
            encodedArgs.push(arg);
            console.log(`  Arg[${i}]: uint64 = ${arg}`);
        } else if (utype === FheTypes.Uint128) {
            solidityTypes.push('uint128');
            encodedArgs.push(arg);
            console.log(`  Arg[${i}]: uint128 = ${arg}`);
        } else if (utype === FheTypes.Uint160) {
            solidityTypes.push('address');
            const addr = typeof arg === 'string' ? arg : ethers.getAddress(ethers.toBeHex(BigInt(arg), 20));
            encodedArgs.push(addr);
            console.log(`  Arg[${i}]: address = ${addr}`);
        } else if (utype === FheTypes.Uint256) {
            solidityTypes.push('uint256');
            encodedArgs.push(arg);
            console.log(`  Arg[${i}]: uint256 = ${arg.toString()}`);
        } else {
            throw new Error(`Unsupported utype: ${utype}`);
        }
    }

    // Encode with correct types
    const encodedParams = ethers.AbiCoder.defaultAbiCoder().encode(
        solidityTypes,
        encodedArgs
    );

    const calldata = selector + encodedParams.slice(2);
    console.log(`  Calldata: ${calldata.slice(0, 66)}... (${calldata.length} chars)`);

    return calldata;
}

/**
 * Create operator signature for consensus
 */
async function createOperatorSignature(
    operatorWallet: ethers.Wallet,
    intentId: string,
    decoder: string,
    target: string,
    reconstructedData: string
): Promise<string> {
    // Create hash of the data
    const dataHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
            ['bytes32', 'address', 'address', 'bytes'],
            [intentId, decoder, target, reconstructedData]
        )
    );

    // Sign with EIP-191 prefix (eth_sign format)
    const signature = await operatorWallet.signMessage(ethers.getBytes(dataHash));

    console.log(`  Signature created: ${signature.slice(0, 20)}...`);
    return signature;
}

/**
 * Process a single UEI trade
 */
async function processUEITrade(
    swapManager: ethers.Contract,
    intentId: string,
    encodedData: string,
    operatorWallet: ethers.Wallet
): Promise<void> {
    try {
        console.log("\n" + "=".repeat(80));
        console.log(`🎯 Processing UEI: ${intentId}`);
        console.log("=".repeat(80));

        // Step 1: Decode event data to get encrypted structs with type info
        const decoded = decodeEventData(encodedData);

        // Step 2: Batch decrypt all components with type-aware unsealing
        console.log("\n🔓 Decrypting UEI components...");
        const allEncrypted = [
            decoded.encDecoder,
            decoded.encTarget,
            decoded.encSelector,
            ...decoded.encArgs
        ];

        const decryptedValues = await batchDecrypt(allEncrypted);

        const decoder = decryptedValues[0] as string;
        const target = decryptedValues[1] as string;
        const selectorNum = Number(decryptedValues[2]);
        const selector = `0x${selectorNum.toString(16).padStart(8, '0')}`;
        const args = decryptedValues.slice(3);
        // Convert utypes from BigInt to Number for comparison with FheTypes enum
        const argTypes = decoded.encArgs.map(arg => typeof arg.utype === 'bigint' ? Number(arg.utype) : arg.utype);

        console.log("\n✅ Decrypted UEI:");
        console.log(`  Decoder: ${decoder}`);
        console.log(`  Target: ${target}`);
        console.log(`  Selector: ${selector}`);
        console.log(`  Args: ${args.length}`);

        // Step 3: Dynamically reconstruct calldata based on arg types
        const calldata = reconstructCalldata(selector, args, argTypes);

        // Step 4: Create operator signature
        console.log("\n✍️  Creating operator signature...");
        const signature = await createOperatorSignature(
            operatorWallet,
            intentId,
            decoder,
            target,
            calldata
        );

        // Step 5: Submit to processUEI
        console.log("\n📤 Submitting processUEI transaction...");
        console.log(`  Intent ID: ${intentId}`);
        console.log(`  Decoder: ${decoder}`);
        console.log(`  Target: ${target}`);
        console.log(`  Calldata length: ${calldata.length} chars`);

        const tx = await swapManager.processUEI(
            intentId,
            decoder,
            target,
            calldata,
            [signature],
            { nonce: await operatorWallet.getNonce() }
        );

        console.log(`  Transaction hash: ${tx.hash}`);
        console.log("  Waiting for confirmation...");

        const receipt = await tx.wait();
        console.log("✅ UEI processed successfully!");
        console.log(`  Gas used: ${receipt.gasUsed.toString()}`);

        // Check execution result
        const execution = await swapManager.getUEIExecution(intentId);
        console.log("\n📊 Execution Result:");
        console.log(`  Success: ${execution.success}`);
        console.log(`  Executor: ${execution.executor}`);
        console.log(`  Executed at: ${new Date(Number(execution.executedAt) * 1000).toLocaleString()}`);

        if (execution.result && execution.result !== '0x') {
            console.log(`  Result: ${execution.result}`);
        }

        console.log("\n" + "=".repeat(80));

    } catch (error: any) {
        console.error(`\n❌ Failed to process UEI ${intentId}:`, error.message);
        throw error;
    }
}

/**
 * Handle UEIBatchFinalized event
 */
async function handleBatchFinalized(
    provider: ethers.Provider,
    swapManager: ethers.Contract,
    batchId: string,
    selectedOperators: string[],
    operatorWallet: ethers.Wallet
): Promise<void> {
    try {
        console.log("\n🚀 UEI Batch Finalized!");
        console.log("=" .repeat(80));
        console.log(`  Batch ID: ${batchId}`);
        console.log(`  Selected Operators (${selectedOperators.length}):`);
        selectedOperators.forEach((op, i) => console.log(`    ${i + 1}. ${op}`));

        // Check if this operator is selected
        const isSelected = selectedOperators.some(
            op => op.toLowerCase() === operatorWallet.address.toLowerCase()
        );

        if (!isSelected) {
            console.log(`\n❌ This operator (${operatorWallet.address}) is NOT selected`);
            console.log("=" .repeat(80));
            return;
        }

        console.log(`\n✅ This operator IS selected for this batch!`);

        // Get batch details
        const batch = await swapManager.getTradeBatch(batchId);
        console.log(`\n📋 Batch contains ${batch.intentIds.length} trades:`);
        batch.intentIds.forEach((id: string, i: number) => {
            console.log(`  ${i + 1}. ${id}`);
        });

        // Query past TradeSubmitted events for this batchId
        // CRITICAL: ctBlob is in events, NOT contract storage!
        console.log(`\n🔍 Fetching TradeSubmitted events for batch ${batchId}...`);

        const filter = swapManager.filters.TradeSubmitted(null, null, batchId);
        const currentBlock = await provider.getBlockNumber();
        const events = await swapManager.queryFilter(filter, currentBlock - 10000, currentBlock);

        console.log(`  Found ${events.length} TradeSubmitted events`);

        if (events.length === 0) {
            console.log("⚠️  No TradeSubmitted events found for this batch!");
            return;
        }

        // Process each trade
        for (let i = 0; i < events.length; i++) {
            const event = events[i];

            // Extract args from EventLog
            if (!('args' in event) || !event.args) continue;

            const intentId = event.args[0];
            const encodedData = event.args[3]; // Encoded InE* structs (4th parameter in TradeSubmitted)

            console.log(`\n📥 Processing trade ${i + 1}/${events.length}...`);

            await processUEITrade(swapManager, intentId, encodedData, operatorWallet);

            // Small delay between processing trades
            if (i < events.length - 1) {
                await new Promise(resolve => setTimeout(resolve, 2000));
            }
        }

        console.log("\n✅ All trades in batch processed!");
        console.log("=" .repeat(80));

    } catch (error: any) {
        console.error("\n❌ Error handling batch finalization:", error.message);
        throw error;
    }
}

/**
 * Main UEI Processor - Monitors and processes batches
 */
async function startUEIProcessor() {
    try {
        console.log("\n🤖 Starting UEI Processor...\n");
        console.log("=" .repeat(80));

        // Setup
        const provider = new ethers.JsonRpcProvider(PROVIDER_URL);
        const operatorWallet = new ethers.Wallet(PRIVATE_KEY, provider);

        // Load deployment config based on chain ID
        const network = await provider.getNetwork();
        const chainId = Number(network.chainId);
        const config = loadDeploymentConfig(chainId);

        SWAP_MANAGER = config.swapManager;
        BORING_VAULT = config.boringVault || '0x0000000000000000000000000000000000000000';

        console.log(`Network: ${config.network} (Chain ID: ${chainId})`);
        console.log("👤 Operator wallet:", operatorWallet.address);
        console.log("🏦 SwapManager:", SWAP_MANAGER);
        console.log("💰 BoringVault:", BORING_VAULT);

        // Load SwapManager ABI
        const swapManagerAbi = JSON.parse(
            fs.readFileSync('./abis/SwapManager.json', 'utf8')
        );
        const swapManager = new ethers.Contract(SWAP_MANAGER, swapManagerAbi, operatorWallet);

        // Initialize CoFHE.js
        await initializeCofhe(operatorWallet);

        console.log("\n👂 Starting event polling for UEIBatchFinalized...");
        console.log("(Ankr RPC doesn't support eth_newFilter)");
        console.log("=" .repeat(80));

        // Track processed batches and blocks
        let lastProcessedBlock = await provider.getBlockNumber();
        const processedBatches = new Set<string>();

        // Query past UEIBatchFinalized events first (last 1000 blocks)
        try {
            const filter = swapManager.filters.UEIBatchFinalized();
            const fromBlock = Math.max(0, lastProcessedBlock - 1000);
            const events = await swapManager.queryFilter(filter, fromBlock, lastProcessedBlock);

            if (events.length > 0) {
                console.log(`\n📜 Found ${events.length} past UEIBatchFinalized events`);
                for (const event of events) {
                    if (!('args' in event) || !event.args) continue;

                    const batchId = event.args[0];
                    const selectedOperators = event.args[1];

                    if (!processedBatches.has(batchId)) {
                        processedBatches.add(batchId);
                        await handleBatchFinalized(
                            provider,
                            swapManager,
                            batchId,
                            selectedOperators,
                            operatorWallet
                        ).catch(error => {
                            console.error("Error processing past batch:", error);
                        });
                    }
                }
            } else {
                console.log("\n📜 No past UEIBatchFinalized events found");
            }
        } catch (error) {
            console.error("Error querying past events:", error);
        }

        // Check if operator is admin (can bypass time constraints)
        const adminAddress = await swapManager.admin();
        const isAdmin = adminAddress.toLowerCase() === operatorWallet.address.toLowerCase();

        console.log("\n✅ UEI Processor is running...");
        console.log("Polling every 5 seconds for new batches...");
        console.log(`Auto-finalizing batches every 20 seconds (when non-empty${isAdmin ? ', as admin - no time constraint' : ', respecting MAX_BATCH_IDLE'})...`);
        console.log("Press Ctrl+C to stop\n");

        // Poll for new events every 5 seconds
        setInterval(async () => {
            try {
                const currentBlock = await provider.getBlockNumber();

                if (currentBlock > lastProcessedBlock) {
                    const filter = swapManager.filters.UEIBatchFinalized();
                    const events = await swapManager.queryFilter(
                        filter,
                        lastProcessedBlock + 1,
                        currentBlock
                    );

                    for (const event of events) {
                        if (!('args' in event) || !event.args) continue;

                        const batchId = event.args[0];
                        const selectedOperators = event.args[1];

                        if (!processedBatches.has(batchId)) {
                            processedBatches.add(batchId);
                            console.log(`\n🔔 New UEIBatchFinalized event detected at block ${event.blockNumber}`);

                            await handleBatchFinalized(
                                provider,
                                swapManager,
                                batchId,
                                selectedOperators,
                                operatorWallet
                            ).catch(error => {
                                console.error("Error processing batch:", error);
                            });
                        }
                    }

                    lastProcessedBlock = currentBlock;
                }
            } catch (error: any) {
                console.error("Error in polling:", error.message);
            }
        }, 5000); // Poll every 5 seconds

        // Auto-finalize batches every 20 seconds (independent of processUEI)
        setInterval(async () => {
            try {
                console.log("\n⏰ Checking if batch should be finalized...");

                // Get current batch counter and ID
                const currentCounter = await swapManager.currentBatchCounter();
                const batchId = await swapManager.batchCounterToBatchId(currentCounter);

                // Check if batch exists (should not be zero)
                if (batchId === ethers.ZeroHash) {
                    console.log("  ⏭️  No active batch (batchId is zero), skipping finalization");
                    return;
                }

                // Get batch details
                const batch = await swapManager.getTradeBatch(batchId);

                // Check if batch is empty
                if (batch.intentIds.length === 0) {
                    console.log("  📭 Batch is empty, skipping finalization");
                    return;
                }

                // Check if batch is already finalized
                if (batch.finalized) {
                    console.log("  ✅ Batch already finalized, skipping");
                    return;
                }

                // Check if enough time has passed (unless operator is admin)
                if (!isAdmin) {
                    const MAX_BATCH_IDLE = 60; // 1 minute in seconds
                    const currentTimestamp = Math.floor(Date.now() / 1000);
                    const batchAge = currentTimestamp - Number(batch.createdAt);

                    if (batchAge < MAX_BATCH_IDLE) {
                        console.log(`  ⏳ Batch is only ${batchAge}s old, need ${MAX_BATCH_IDLE}s. Waiting...`);
                        return;
                    }
                }

                console.log(`  🎯 Batch ${batchId} has ${batch.intentIds.length} intent(s), triggering finalization...`);

                // Call finalizeUEIBatch
                const tx = await swapManager.finalizeUEIBatch({
                    nonce: await operatorWallet.getNonce()
                });

                console.log(`  📤 Finalization transaction sent: ${tx.hash}`);
                console.log("  ⏳ Waiting for confirmation...");

                const receipt = await tx.wait();
                console.log(`  ✅ Batch finalized successfully! Gas used: ${receipt.gasUsed.toString()}`);

            } catch (error: any) {
                // Handle specific errors gracefully
                if (error.message.includes("Batch is empty")) {
                    console.log("  📭 Batch is empty (caught in transaction), skipping");
                } else if (error.message.includes("Batch already finalized")) {
                    console.log("  ✅ Batch already finalized (caught in transaction), skipping");
                } else if (error.message.includes("No active batch")) {
                    console.log("  ⏭️  No active batch (caught in transaction), skipping");
                } else if (error.message.includes("Batch not ready for finalization")) {
                    console.log("  ⏳ Batch not ready yet (time constraint), will retry in 20s");
                } else {
                    console.error("  ❌ Error in auto-finalization:", error.message);
                }
            }
        }, 20000); // Check and finalize every 20 seconds

        // Keep process alive
        await new Promise(() => {});

    } catch (error: any) {
        console.error("\n❌ UEI Processor failed to start:", error.message);
        process.exit(1);
    }
}

// Run if executed directly
if (require.main === module) {
    startUEIProcessor().catch(console.error);
}

export { startUEIProcessor, processUEITrade };
