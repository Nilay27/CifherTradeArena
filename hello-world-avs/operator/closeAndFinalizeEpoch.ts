/**
 * Automated admin script for epoch lifecycle management across Base + Arbitrum.
 *
 * Usage: ts-node operator/closeAndFinalizeEpoch.ts <epochNumber>
 */

import { ethers } from "ethers";
import * as dotenv from "dotenv";
import { getEpochStrategies } from "./epochDatabase";
const fs = require("fs");
const path = require("path");
dotenv.config();

interface RankedStrategy {
    trader: string;
    apy: bigint;
}

async function closeAndFinalizeOnChain(
    epochNumber: bigint,
    rpcUrl: string | undefined,
    label: string
): Promise<void> {
    if (!rpcUrl) {
        console.log(`\n⚠️ Skipping ${label}: RPC URL not configured`);
        return;
    }

    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const wallet = new ethers.Wallet(process.env.PRIVATE_KEY!, provider);

    console.log(`\n🔄 Automated Epoch Lifecycle Management (${label})`);
    console.log(`Operator: ${wallet.address}`);
    console.log(`Epoch Number: ${epochNumber}\n`);

    const chainId = Number((await provider.getNetwork()).chainId);
    console.log(`Chain ID: ${chainId}`);

    const deploymentPath = path.resolve(
        __dirname,
        `../contracts/deployments/trade-manager/${chainId}.json`
    );
    if (!fs.existsSync(deploymentPath)) {
        console.log(`  ⚠️ Deployment file not found for chain ${chainId}, skipping ${label}`);
        return;
    }
    const avsDeploymentData = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));
    const tradeManagerAddress =
        avsDeploymentData.addresses.tradeManager || avsDeploymentData.addresses.TradeManager;

    console.log(`TradeManager: ${tradeManagerAddress}\n`);

    const tradeManagerABI = JSON.parse(
        fs.readFileSync(path.resolve(__dirname, "../abis/TradeManager.json"), "utf8")
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
        console.log("  ⏳ Closing epoch...");
        try {
            const nonce1 = await provider.getTransactionCount(wallet.address);
            const tx1 = await tradeManager.closeEpoch(epochNumber, { nonce: nonce1 });
            console.log(`  TX: ${tx1.hash}`);
            await tx1.wait();
            console.log("  ✅ Epoch closed");
        } catch (error: any) {
            console.error(`  ❌ Failed to close epoch: ${error.message}`);
            return;
        }
    } else if (epochState === 1) {
        console.log("  ✅ Epoch already closed");
    } else if (epochState === 2) {
        console.log("  ℹ️ Epoch already finalized");
        return;
    } else if (epochState === 3) {
        console.log("  ℹ️ Epoch already executed");
        return;
    }

    // ============================================================
    // STEP 2: Fetch all submitted strategies for this epoch
    // ============================================================
    console.log("\nStep 2: Fetching all submitted strategies...");
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
        // Exhausted submissions
    }
    console.log(`  Found ${submitters.length} strategy submissions`);

    // ============================================================
    // STEP 3: Retrieve APYs from local database
    // ============================================================
    console.log("\nStep 3: Retrieving APYs from local database...");
    const strategies = getEpochStrategies(Number(epochNumber)) ?? {};
    const rankedStrategies: RankedStrategy[] = [];

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

    // ============================================================
    // STEP 4: Rank strategies by APY (highest first)
    // ============================================================
    console.log("\nStep 4: Ranking strategies...");
    rankedStrategies.sort((a, b) => (a.apy > b.apy ? -1 : a.apy < b.apy ? 1 : 0));
    console.log("  Rankings:");
    rankedStrategies.forEach((strategy, index) => {
        console.log(
            `    ${index + 1}. ${strategy.trader}: ${Number(strategy.apy)} bps (${Number(strategy.apy) / 100}%)`
        );
    });

    // ============================================================
    // STEP 5: Select winners based on weights array
    // ============================================================
    console.log("\nStep 5: Selecting winners...");
    const epochData = await tradeManager.epochs(epochNumber);
    let weightsArray: number[] = [];

    if (epochData.weights && Array.isArray(epochData.weights)) {
        weightsArray = epochData.weights.map((weight: any) => Number(weight));
    }

    if (weightsArray.length === 0) {
        const epochStartedFilter = tradeManager.filters.EpochStarted(epochNumber);
        const currentBlock = await provider.getBlockNumber();
        const searchWindow = 5_000;
        let fromBlock = currentBlock > searchWindow ? currentBlock - searchWindow : 0;
        let epochEvent: any = null;

        while (!epochEvent && fromBlock >= 0) {
            const toBlock = fromBlock + searchWindow;
            try {
                const events = await tradeManager.queryFilter(epochStartedFilter, fromBlock, toBlock);
                if (events.length > 0) {
                    epochEvent = events[0];
                    break;
                }
                if (fromBlock === 0) {
                    break;
                }
                fromBlock = fromBlock > searchWindow ? fromBlock - Math.floor(searchWindow / 2) : 0;
            } catch (err: any) {
                if (err?.code === -32062) {
                    fromBlock = Math.max(0, fromBlock - Math.floor(searchWindow / 2));
                    continue;
                }
                throw err;
            }
        }

        if (epochEvent) {
            const parsedEvent = tradeManager.interface.parseLog({
                topics: epochEvent.topics as string[],
                data: epochEvent.data
            });
            if (parsedEvent?.args?.weights) {
                console.log(`  Debug - Weights from event:`, parsedEvent.args.weights);
                weightsArray = Array.from(parsedEvent.args.weights).map((weight: any) => Number(weight));
            }
        }
    }

    if (weightsArray.length === 0) {
        console.error(`\n❌ Could not fetch weights for this epoch on ${label}`);
    }

    const numWinners = weightsArray.length;
    console.log(`  Weights: [${weightsArray.join(", ")}]`);
    console.log(`  Selecting top ${numWinners} strategies`);

    if (rankedStrategies.length === 0) {
        console.log("  No ranked strategies available. Proceeding with empty winners for finalization.");
    }

    const winners: string[] = [];
    const winnerAPYs: bigint[] = [];

    if (rankedStrategies.length > 0 && numWinners > 0) {
        if (rankedStrategies.length < numWinners) {
            console.log(
                `  ⚠️ Only ${rankedStrategies.length} strategies submitted, but ${numWinners} weights configured`
            );
            console.log("  Repeating best strategies to fill all positions");
        }

        for (let i = 0; i < numWinners; i++) {
            const strategyIdx = Math.min(i, rankedStrategies.length - 1);
            const strategy = rankedStrategies[strategyIdx];
            if (strategy) {
                winners.push(strategy.trader);
                winnerAPYs.push(strategy.apy);
                console.log(
                    `    Winner ${i + 1}: ${strategy.trader} (${Number(strategy.apy)} bps)${
                        strategyIdx < i ? " [repeated]" : ""
                    }`
                );
            } else {
                console.log(`    Winner ${i + 1}: <none available>`);
            }
        }
    } else if (numWinners > 0) {
        console.log("  ℹ️ Contract is configured with non-zero weights; finalizeEpoch may revert without winners.");
    }

    // ============================================================
    // STEP 6: Call finalizeEpoch
    // ============================================================
    console.log("\nStep 6: Finalizing epoch...");

    try {
        const nonce2 = await provider.getTransactionCount(wallet.address);
        const tx2 = await tradeManager.finalizeEpoch(epochNumber, winners, winnerAPYs, {
            nonce: nonce2,
            gasLimit: 5_000_000
        });

        console.log(`  TX: ${tx2.hash}`);
        console.log("  Waiting for confirmation...");

        const receipt = await tx2.wait();
        console.log(`  ✅ Confirmed in block ${receipt.blockNumber}`);

        const finalizedEvent = receipt.logs
            .map((log: any) => {
                try {
                    return tradeManager.interface.parseLog(log);
                } catch {
                    return null;
                }
            })
            .find((event: any) => event && event.name === "EpochFinalized");

        if (finalizedEvent) {
            console.log(`\n📋 EpochFinalized Event:`);
            console.log(`  Epoch: ${finalizedEvent.args.epochNumber}`);
            console.log(`  Winners:`, finalizedEvent.args.winners);
            console.log(
                `  APYs:`,
                finalizedEvent.args.decryptedAPYs.map((apy: bigint) => `${Number(apy)} bps`)
            );
            console.log(
                `  Allocations:`,
                finalizedEvent.args.allocations.map((alloc: bigint) => `${ethers.formatUnits(alloc, 6)} USDC`)
            );
        }

        console.log(`\n✅ Epoch ${epochNumber} finalized successfully on ${label}!`);
    } catch (error: any) {
        console.error(`\n❌ Failed to finalize epoch on ${label}: ${error.message}`);
        if (error.reason) {
            console.error(`Reason: ${error.reason}`);
        }
    }
}

async function main() {
    const epochNumber = process.argv[2] ? BigInt(process.argv[2]) : null;
    if (!epochNumber) {
        console.error("Usage: ts-node operator/closeAndFinalizeEpoch.ts <epochNumber>");
        process.exit(1);
    }

    await closeAndFinalizeOnChain(epochNumber, process.env.RPC_URL, "Base");
    await closeAndFinalizeOnChain(epochNumber, process.env.ARB_SEPOLIA_RPC_URL, "Arbitrum");

    console.log("\n✅ Close & finalize script completed for all configured chains.");
}

main().catch((error) => {
    console.error("Error:", error);
    process.exit(1);
});
