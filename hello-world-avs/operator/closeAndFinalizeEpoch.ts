/**
 * Automated admin script for epoch lifecycle management
 *
 * This script will:
 * 1. Close the specified epoch
 * 2. Wait for CoFHE decryption to complete
 * 3. Fetch all submitted strategies for the epoch
 * 4. Retrieve decrypted APYs
 * 5. Rank strategies by APY
 * 6. Call finalizeEpoch with top winners
 *
 * Usage: ts-node operator/closeAndFinalizeEpoch.ts <epochNumber>
 */

import { ethers } from "ethers";
import * as dotenv from "dotenv";
import { getEpochStrategies } from "./epochDatabase";
const fs = require('fs');
const path = require('path');
dotenv.config();

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY!, provider);

interface RankedStrategy {
    trader: string;
    apy: bigint;
}

async function main() {
    const epochNumber = process.argv[2] ? BigInt(process.argv[2]) : null;

    if (!epochNumber) {
        console.error("Usage: ts-node operator/closeAndFinalizeEpoch.ts <epochNumber>");
        process.exit(1);
    }

    console.log(`\n🔄 Automated Epoch Lifecycle Management\n`);
    console.log(`Operator: ${wallet.address}`);
    console.log(`Epoch Number: ${epochNumber}\n`);

    // Get chain ID
    const chainId = Number((await provider.getNetwork()).chainId);
    console.log(`Chain ID: ${chainId}`);

    // Load TradeManager deployment
    const avsDeploymentData = JSON.parse(
        fs.readFileSync(path.resolve(__dirname, `../contracts/deployments/trade-manager/${chainId}.json`), 'utf8')
    );
    const tradeManagerAddress = avsDeploymentData.addresses.tradeManager || avsDeploymentData.addresses.TradeManager;

    console.log(`TradeManager: ${tradeManagerAddress}\n`);

    // Load full ABI
    const tradeManagerABI = JSON.parse(
        fs.readFileSync(path.resolve(__dirname, '../abis/TradeManager.json'), 'utf8')
    );

    const tradeManager = new ethers.Contract(tradeManagerAddress, tradeManagerABI, wallet);

    // ============================================================
    // STEP 1: Check epoch state and close if needed
    // ============================================================
    console.log("Step 1: Checking epoch state...");
    const epoch = await tradeManager.epochs(epochNumber);
    const epochState = Number(epoch.state);
    const epochEndTime = Number(epoch.epochEndTime);

    console.log(`  Epoch State: ${epochState} (0=OPEN, 1=CLOSED, 2=FINALIZED, 3=EXECUTED)`);
    console.log(`  End Time: ${new Date(epochEndTime * 1000).toISOString()}`);

    if (epochState === 0) {
        // OPEN - need to close
        const now = Math.floor(Date.now() / 1000);
        if (now <= epochEndTime) {
            console.error(`\n❌ Epoch is still open and has not ended yet.`);
            console.error(`   Current time: ${new Date(now * 1000).toISOString()}`);
            console.error(`   Ends at: ${new Date(epochEndTime * 1000).toISOString()}`);
            console.error(`   Wait ${epochEndTime - now} seconds before closing.`);
            process.exit(1);
        }

        console.log("  ⏳ Closing epoch...");
        try {
            const nonce1 = await provider.getTransactionCount(wallet.address);
            const tx1 = await tradeManager.closeEpoch(epochNumber, { nonce: nonce1 });
            console.log(`  TX: ${tx1.hash}`);
            await tx1.wait();
            console.log("  ✅ Epoch closed");
        } catch (error: any) {
            console.error(`  ❌ Failed to close epoch: ${error.message}`);
            process.exit(1);
        }
    } else if (epochState === 1) {
        console.log("  ✅ Epoch already closed");
    } else if (epochState === 2) {
        console.log("  ℹ️ Epoch already finalized");
        process.exit(0);
    } else if (epochState === 3) {
        console.log("  ℹ️ Epoch already executed");
        process.exit(0);
    }

    // ============================================================
    // STEP 2: Fetch all submitted strategies for this epoch
    // ============================================================
    console.log("\nStep 2: Fetching all submitted strategies...");

    // Use epochSubmitters mapping to get all traders who submitted
    const submitters: string[] = [];
    let idx = 0;
    try {
        while (true) {
            const submitter = await tradeManager.epochSubmitters(epochNumber, idx);
            submitters.push(submitter);
            console.log(`    - ${submitter}`);
            idx++;
        }
    } catch {
        // Index out of bounds means we've fetched all submitters
    }

    console.log(`  Found ${submitters.length} strategy submissions`);

    if (submitters.length === 0) {
        console.error("  ❌ No strategies submitted for this epoch");
        process.exit(1);
    }

    // ============================================================
    // STEP 3: Retrieve APYs from local database
    // ============================================================
    console.log("\nStep 3: Retrieving APYs from local database...");

    const strategies = getEpochStrategies(Number(epochNumber));
    const rankedStrategies: RankedStrategy[] = [];

    if (Object.keys(strategies).length === 0) {
        console.error("\n❌ No strategies found in local database for this epoch");
        console.error("   Make sure the operator has processed StrategySubmitted events");
        process.exit(1);
    }

    for (const submitter of submitters) {
        const strategy = strategies[submitter];

        if (!strategy) {
            console.log(`    - ${submitter}: ⚠️ Not found in database`);
            continue;
        }

        rankedStrategies.push({
            trader: submitter,
            apy: BigInt(strategy.simulatedAPY)
        });
        console.log(`    - ${submitter}: ${strategy.simulatedAPY} bps (${strategy.simulatedAPY / 100}%)`);
    }

    if (rankedStrategies.length === 0) {
        console.error("\n❌ No APYs available");
        process.exit(1);
    }

    // ============================================================
    // STEP 4: Rank strategies by APY (highest first)
    // ============================================================
    console.log("\nStep 4: Ranking strategies...");

    rankedStrategies.sort((a, b) => {
        // Sort descending (highest APY first)
        if (a.apy > b.apy) return -1;
        if (a.apy < b.apy) return 1;
        return 0;
    });

    console.log("  Rankings:");
    rankedStrategies.forEach((strategy, idx) => {
        console.log(`    ${idx + 1}. ${strategy.trader}: ${Number(strategy.apy)} bps (${Number(strategy.apy) / 100}%)`);
    });

    // ============================================================
    // STEP 5: Select winners based on weights array
    // ============================================================
    console.log("\nStep 5: Selecting winners...");

    // Re-fetch epoch to ensure we have latest data with all fields
    const epochData = await tradeManager.epochs(epochNumber);

    // Debug: Try to access weights from the EpochStarted event instead
    // Since struct parsing is buggy, let's get it from the event
    const epochStartedFilter = tradeManager.filters.EpochStarted(epochNumber);
    const currentBlock = await provider.getBlockNumber();
    const fromBlock = Math.max(0, currentBlock - 10000);
    const epochEvents = await tradeManager.queryFilter(epochStartedFilter, fromBlock, currentBlock);

    let weightsArray: number[] = [];

    if (epochEvents.length > 0) {
        const event = epochEvents[0];
        const parsedEvent = tradeManager.interface.parseLog({
            topics: event.topics as string[],
            data: event.data
        });

        if (parsedEvent) {
            // EpochStarted event has weights as one of its parameters
            const eventWeights = parsedEvent.args.weights;
            console.log(`  Debug - Weights from event:`, eventWeights);

            for (let i = 0; i < eventWeights.length; i++) {
                weightsArray.push(Number(eventWeights[i]));
            }
        }
    }

    if (weightsArray.length === 0) {
        console.error(`\n❌ Could not fetch weights for this epoch`);
        process.exit(1);
    }

    const numWinners = weightsArray.length;
    console.log(`  Weights: [${weightsArray.join(', ')}]`);
    console.log(`  Selecting top ${numWinners} strategies`);

    const winners: string[] = [];
    const winnerAPYs: bigint[] = [];

    // Handle case where fewer strategies than weights
    if (rankedStrategies.length < numWinners) {
        console.log(`  ⚠️ Only ${rankedStrategies.length} strategies submitted, but ${numWinners} weights configured`);
        console.log(`  Repeating best strategies to fill all positions`);
    }

    for (let i = 0; i < numWinners; i++) {
        // If we run out of unique strategies, repeat the last/best ones
        const strategyIdx = Math.min(i, rankedStrategies.length - 1);
        const strategy = rankedStrategies[strategyIdx];

        winners.push(strategy.trader);
        winnerAPYs.push(strategy.apy);
        console.log(`    Winner ${i + 1}: ${strategy.trader} (${Number(strategy.apy)} bps)${strategyIdx < i ? ' [repeated]' : ''}`);
    }

    // ============================================================
    // STEP 6: Call finalizeEpoch
    // ============================================================
    console.log("\nStep 6: Finalizing epoch...");

    try {
        const nonce2 = await provider.getTransactionCount(wallet.address);
        const tx2 = await tradeManager.finalizeEpoch(
            epochNumber,
            winners,
            winnerAPYs,
            {
                nonce: nonce2,
                gasLimit: 5000000
            }
        );

        console.log(`  TX: ${tx2.hash}`);
        console.log("  Waiting for confirmation...");

        const receipt = await tx2.wait();
        console.log(`  ✅ Confirmed in block ${receipt.blockNumber}`);

        // Parse EpochFinalized event
        const finalizedEvent = receipt.logs
            .map((log: any) => {
                try {
                    return tradeManager.interface.parseLog(log);
                } catch {
                    return null;
                }
            })
            .find((e: any) => e && e.name === 'EpochFinalized');

        if (finalizedEvent) {
            console.log(`\n📋 EpochFinalized Event:`);
            console.log(`  Epoch: ${finalizedEvent.args.epochNumber}`);
            console.log(`  Winners:`, finalizedEvent.args.winners);
            console.log(`  APYs:`, finalizedEvent.args.decryptedAPYs.map((apy: bigint) => `${Number(apy)} bps`));
            console.log(`  Allocations:`, finalizedEvent.args.allocations.map((alloc: bigint) => ethers.formatUnits(alloc, 6) + ' USDC'));
        }

        console.log(`\n✅ Epoch ${epochNumber} finalized successfully!`);
        console.log(`\n🏆 Winners:`);
        winners.forEach((winner, idx) => {
            const apy = Number(winnerAPYs[idx]);
            const weight = weightsArray[idx];
            const allocatedCapital = epochData[6]; // allocatedCapital is at index 6
            // Calculate allocation as bigint to avoid precision issues
            const allocationBigInt = (BigInt(allocatedCapital) * BigInt(weight)) / 100n;
            console.log(`  ${idx + 1}. ${winner}`);
            console.log(`     APY: ${apy / 100}% (${apy} bps)`);
            console.log(`     Weight: ${weight}%`);
            console.log(`     Allocation: ${ethers.formatUnits(allocationBigInt, 6)} USDC`);
        });

        console.log(`\n🔍 Next steps:`);
        console.log(`  - Operators can now aggregate winning strategies`);
        console.log(`  - Call executeEpochTopStrategiesAggregated to deploy capital`);
        console.log(`  - Winners will receive their allocations based on weights`);

    } catch (error: any) {
        console.error(`\n❌ Failed to finalize epoch: ${error.message}`);
        if (error.reason) {
            console.error(`Reason: ${error.reason}`);
        }
        process.exit(1);
    }
}

main().catch((error) => {
    console.error("Error:", error);
    process.exit(1);
});
