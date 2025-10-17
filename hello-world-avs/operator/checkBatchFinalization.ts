import { ethers } from "ethers";
import * as dotenv from "dotenv";
import { loadDeploymentConfig, getNetworkName } from './config/deploymentConfig';
const fs = require('fs');
const path = require('path');
dotenv.config();

// Setup env variables
const provider = new ethers.JsonRpcProvider(process.env.RPC_URL!);

// Get chain ID from provider
async function getChainId(): Promise<number> {
    const network = await provider.getNetwork();
    return Number(network.chainId);
}

async function main() {
    console.log("Checking Intent Submissions and Batch Finalizations");
    console.log("===================================================\n");

    // Load deployment configuration
    const chainId = await getChainId();
    console.log(`Chain ID: ${chainId} (${getNetworkName(chainId)})`);

    const config = loadDeploymentConfig(chainId);
    const UNIVERSAL_PRIVACY_HOOK = config.universalPrivacyHook;

    console.log(`UniversalPrivacyHook: ${UNIVERSAL_PRIVACY_HOOK}`);

    // Load UniversalPrivacyHook ABI
    const UniversalHookABI = JSON.parse(
        fs.readFileSync(path.resolve(__dirname, '../abis/UniversalPrivacyHook.json'), 'utf8')
    );

    const hookContract = new ethers.Contract(UNIVERSAL_PRIVACY_HOOK, UniversalHookABI, provider);

    const targetWallet = "0x0cD73A4E3d34D5488BC4E547fECeDAc86305dB9d";
    console.log(`\nSearching for IntentSubmitted events from wallet: ${targetWallet}\n`);

    // Get current block
    const currentBlock = await provider.getBlockNumber();
    console.log(`Current block: ${currentBlock}`);

    // Search last 10000 blocks
    const fromBlock = Math.max(0, currentBlock - 10000);
    console.log(`Searching from block: ${fromBlock}\n`);

    // Query IntentSubmitted events
    const intentFilter = hookContract.filters.IntentSubmitted(null, null, null, targetWallet);
    const intentEvents = await hookContract.queryFilter(intentFilter, fromBlock, currentBlock);

    console.log(`Found ${intentEvents.length} IntentSubmitted events\n`);

    // Get last 5 events
    const last5Events = intentEvents.slice(-5);

    // Also get batch created blocks
    const batchCreatedFilter = hookContract.filters["BatchCreated(bytes32,bytes32,uint256)"]();
    const batchCreatedEvents = await hookContract.queryFilter(batchCreatedFilter, fromBlock, currentBlock);

    console.log(`Found ${batchCreatedEvents.length} BatchCreated events\n`);

    for (let i = 0; i < last5Events.length; i++) {
        const event = last5Events[i] as ethers.EventLog;
        console.log(`\n=== Intent ${i + 1}/${last5Events.length} ===`);
        console.log(`Transaction Hash: ${event.transactionHash}`);
        console.log(`Block Number: ${event.blockNumber}`);
        console.log(`Intent ID: ${event.args.intentId}`);

        // Get the full transaction receipt
        const receipt = await provider.getTransactionReceipt(event.transactionHash);

        if (receipt) {
            console.log(`\nLogs in this transaction:`);
            let foundBatchFinalized = false;

            for (const log of receipt.logs) {
                try {
                    const parsed = hookContract.interface.parseLog({
                        topics: log.topics as string[],
                        data: log.data
                    });

                    if (parsed) {
                        console.log(`  - ${parsed.name}`);

                        if (parsed.name === "BatchFinalized") {
                            foundBatchFinalized = true;
                            console.log(`    Batch ID: ${parsed.args.batchId}`);
                            console.log(`    Intent Count: ${parsed.args.intentCount}`);
                        } else if (parsed.name === "BatchCreated") {
                            console.log(`    Batch ID: ${parsed.args.batchId}`);
                            console.log(`    Intent Count: ${parsed.args.intentCount}`);
                        } else if (parsed.name === "IntentSubmitted") {
                            console.log(`    Intent ID: ${parsed.args.intentId}`);
                        }
                    }
                } catch (e) {
                    // Not a hook event, skip
                }
            }

            if (!foundBatchFinalized) {
                console.log(`  ❌ No BatchFinalized event in this transaction`);
            } else {
                console.log(`  ✅ BatchFinalized event found!`);
            }
        }
    }

    // Now check if there are ANY BatchFinalized events in the time range
    console.log(`\n\n=== Checking ALL BatchFinalized events ===`);
    const batchFinalizedFilter = hookContract.filters["BatchFinalized(bytes32,uint256)"]();
    const batchEvents = await hookContract.queryFilter(batchFinalizedFilter, fromBlock, currentBlock);

    console.log(`Found ${batchEvents.length} BatchFinalized events total\n`);

    if (batchEvents.length > 0) {
        console.log("Recent BatchFinalized events:");
        batchEvents.slice(-5).forEach((event, idx) => {
            const e = event as ethers.EventLog;
            console.log(`  ${idx + 1}. Block ${e.blockNumber}, Batch ID: ${e.args.batchId}, Intent Count: ${e.args.intentCount}`);
        });
    } else {
        console.log("❌ NO BatchFinalized events found in the entire range!");
        console.log("\nThis means batches are NOT being finalized automatically.");
        console.log("The BATCH_INTERVAL logic is not triggering batch finalization.");
    }

    // Check the current batch status
    console.log(`\n\n=== Checking Current Batch Status ===`);

    // Get pool ID from config
    const poolId = config.poolId;
    console.log(`Pool ID: ${poolId}`);

    try {
        const currentBatchId = await hookContract.currentBatchId(poolId);
        console.log(`Current Batch ID: ${currentBatchId}`);

        if (currentBatchId !== ethers.ZeroHash) {
            const batch = await hookContract.batches(currentBatchId);
            console.log(`\nBatch Details:`);
            console.log(`  Created Block: ${batch.createdBlock}`);
            console.log(`  Submitted Block: ${batch.submittedBlock}`);
            console.log(`  Finalized: ${batch.finalized}`);
            console.log(`  Settled: ${batch.settled}`);
            console.log(`  Intent Count: ${batch.intentIds.length}`);

            const blocksSinceCreation = currentBlock - Number(batch.createdBlock);
            console.log(`\n  Blocks since creation: ${blocksSinceCreation}`);
            console.log(`  BATCH_INTERVAL: 5 blocks`);
            console.log(`  Ready for finalization: ${blocksSinceCreation >= 5 ? '✅ YES' : '❌ NO'}`);
        } else {
            console.log("No active batch currently");
        }
    } catch (error: any) {
        console.error("Error checking batch status:", error.message);
    }
}

main().catch((error) => {
    console.error("Error:", error);
    process.exit(1);
});
