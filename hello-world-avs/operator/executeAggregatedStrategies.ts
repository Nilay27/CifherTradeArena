/**
 * Execute Aggregated Strategies - Reconstruct calldata and execute winning strategies
 *
 * This script:
 * 1. Reads finalized epoch winners from chain
 * 2. Fetches their decrypted strategies from local database
 * 3. Aggregates similar DeFi calls (privacy-preserving)
 * 4. Reconstructs calldata using saved args + argTypes
 * 5. Gets operator consensus signatures
 * 6. Calls executeEpochTopStrategiesAggregated
 *
 * Usage: ts-node operator/executeAggregatedStrategies.ts <epochNumber>
 */

import { ethers } from "ethers";
import * as dotenv from "dotenv";
import { getEpochData, getStrategy, StrategyNode } from "./epochDatabase";
import { FheTypes } from "./cofheUtils";
const fs = require('fs');
const path = require('path');
dotenv.config();

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY!, provider);

/**
 * Dynamically reconstruct calldata based on argument types (utype)
 * Same logic as ueiProcessor.ts
 */
function reconstructCalldata(
    selector: string,
    args: any[],
    argTypes: number[]
): string {
    console.log(`  Reconstructing calldata for selector ${selector}...`);

    // Convert decrypted values based on utypes
    const solidityTypes: string[] = [];
    const encodedArgs: any[] = [];

    for (let i = 0; i < args.length; i++) {
        const arg = args[i];
        const utype = Number(argTypes[i]);

        if (utype === FheTypes.Bool) {
            solidityTypes.push('bool');
            encodedArgs.push(Boolean(arg));
        } else if (utype === FheTypes.Uint8) {
            solidityTypes.push('uint8');
            encodedArgs.push(arg);
        } else if (utype === FheTypes.Uint16) {
            solidityTypes.push('uint16');
            encodedArgs.push(arg);
        } else if (utype === FheTypes.Uint32) {
            solidityTypes.push('uint32');
            encodedArgs.push(arg);
        } else if (utype === FheTypes.Uint64) {
            solidityTypes.push('uint64');
            encodedArgs.push(arg);
        } else if (utype === FheTypes.Uint128) {
            solidityTypes.push('uint128');
            encodedArgs.push(arg);
        } else if (utype === FheTypes.Uint160 || utype === FheTypes.Address) {
            solidityTypes.push('address');
            const addr = typeof arg === 'string' ? arg : ethers.getAddress(ethers.toBeHex(BigInt(arg), 20));
            encodedArgs.push(addr);
        } else if (utype === FheTypes.Uint256) {
            solidityTypes.push('uint256');
            encodedArgs.push(arg);
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
 * Aggregate strategies to combine similar calls
 * For privacy: don't expose individual strategies, only aggregated calls
 */
function aggregateStrategies(winnerNodes: StrategyNode[][]): {
    encoders: string[];
    targets: string[];
    calldatas: string[];
} {
    console.log("\n📊 Aggregating strategies...");

    const aggregated: {
        encoder: string;
        target: string;
        calldata: string;
    }[] = [];

    // For now, simple aggregation: just collect all unique calls
    // TODO: In production, combine similar calls (e.g., multiple Aave supply → one big supply)
    for (const nodes of winnerNodes) {
        for (const node of nodes) {
            const calldata = reconstructCalldata(node.selector, node.args, node.argTypes);

            aggregated.push({
                encoder: node.encoder,
                target: node.target,
                calldata
            });
        }
    }

    console.log(`  Total aggregated calls: ${aggregated.length}`);

    return {
        encoders: aggregated.map(a => a.encoder),
        targets: aggregated.map(a => a.target),
        calldatas: aggregated.map(a => a.calldata)
    };
}

/**
 * Create operator signature for consensus
 */
async function createOperatorSignature(
    epochNumber: bigint,
    encoders: string[],
    targets: string[],
    calldatas: string[]
): Promise<string> {
    // Create hash of the data (same as contract verification)
    const dataHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
            ['uint256', 'address[]', 'address[]', 'bytes[]'],
            [epochNumber, encoders, targets, calldatas]
        )
    );

    // Sign with EIP-191 prefix (eth_sign format)
    const signature = await wallet.signMessage(ethers.getBytes(dataHash));

    console.log(`  Signature created: ${signature.slice(0, 20)}...`);
    return signature;
}

async function main() {
    const epochNumber = process.argv[2] ? BigInt(process.argv[2]) : null;

    if (!epochNumber) {
        console.error("Usage: ts-node operator/executeAggregatedStrategies.ts <epochNumber>");
        process.exit(1);
    }

    console.log(`\n🚀 Execute Aggregated Strategies\n`);
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
    // STEP 1: Check epoch state
    // ============================================================
    console.log("Step 1: Checking epoch state...");
    const epochData = await tradeManager.epochs(epochNumber);
    const epochState = Number(epochData.state);

    console.log(`  Epoch State: ${epochState} (0=OPEN, 1=CLOSED, 2=FINALIZED, 3=EXECUTED)`);

    if (epochState !== 2) {
        console.error(`\n❌ Epoch is not FINALIZED (state=${epochState})`);
        console.error(`   Run closeAndFinalizeEpoch.ts first`);
        process.exit(1);
    }

    console.log("  ✅ Epoch is FINALIZED");

    // ============================================================
    // STEP 2: Get winners from chain
    // ============================================================
    console.log("\nStep 2: Fetching winners from chain...");

    let winners: string[] = [];
    let idx = 0;
    try {
        while (true) {
            const winner = await tradeManager.epochWinners(epochNumber, idx);
            winners.push(winner.trader);
            console.log(`    Winner ${idx + 1}: ${winner.trader} (APY: ${winner.decryptedAPY} bps)`);
            idx++;
        }
    } catch {
        // Index out of bounds
    }

    if (winners.length === 0) {
        console.error("\n❌ No winners found");
        process.exit(1);
    }

    console.log(`  Found ${winners.length} winners`);

    // ============================================================
    // STEP 3: Fetch strategies from local database
    // ============================================================
    console.log("\nStep 3: Fetching strategies from local database...");

    const localEpochData = getEpochData(Number(epochNumber));

    if (!localEpochData) {
        console.error("\n❌ Epoch not found in local database");
        console.error("   Make sure operator has processed strategies");
        process.exit(1);
    }

    const winnerNodes: StrategyNode[][] = [];

    for (const winner of winners) {
        const strategy = getStrategy(Number(epochNumber), winner);

        if (!strategy) {
            console.error(`\n❌ Strategy not found for ${winner}`);
            process.exit(1);
        }

        console.log(`    - ${winner}: ${strategy.nodes.length} nodes`);
        winnerNodes.push(strategy.nodes);
    }

    // ============================================================
    // STEP 4: Aggregate strategies and reconstruct calldatas
    // ============================================================
    const { encoders, targets, calldatas } = aggregateStrategies(winnerNodes);

    // ============================================================
    // STEP 5: Create operator signature for consensus
    // ============================================================
    console.log("\nStep 5: Creating operator signature...");
    const signature = await createOperatorSignature(epochNumber, encoders, targets, calldatas);

    // ============================================================
    // STEP 6: Execute aggregated strategies
    // ============================================================
    console.log("\nStep 6: Executing aggregated strategies...");

    try {
        const nonce = await provider.getTransactionCount(wallet.address);
        const tx = await tradeManager.executeEpochTopStrategiesAggregated(
            epochNumber,
            encoders,
            targets,
            calldatas,
            [signature],
            {
                nonce,
                gasLimit: 5000000
            }
        );

        console.log(`  TX: ${tx.hash}`);
        console.log("  Waiting for confirmation...");

        const receipt = await tx.wait();
        console.log(`  ✅ Confirmed in block ${receipt.blockNumber}`);
        console.log(`  Gas used: ${receipt.gasUsed.toString()}`);

        // Parse EpochExecuted event
        const executedEvent = receipt.logs
            .map((log: any) => {
                try {
                    return tradeManager.interface.parseLog(log);
                } catch {
                    return null;
                }
            })
            .find((e: any) => e && e.name === 'EpochExecuted');

        if (executedEvent) {
            console.log(`\n📋 EpochExecuted Event:`);
            console.log(`  Epoch: ${executedEvent.args.epochNumber}`);
            const totalDeployedRaw = executedEvent.args.totalDeployed ?? 0n;
            const totalDeployed =
                typeof totalDeployedRaw === 'bigint'
                    ? totalDeployedRaw
                    : BigInt(totalDeployedRaw.toString());
            console.log(`  Capital Deployed: ${ethers.formatUnits(totalDeployed, 6)} USDC`);
        }

        console.log(`\n✅ Epoch ${epochNumber} executed successfully!`);
        console.log(`\n🎉 Strategies deployed to BoringVault!`);

    } catch (error: any) {
        console.error(`\n❌ Failed to execute strategies: ${error.message}`);
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
