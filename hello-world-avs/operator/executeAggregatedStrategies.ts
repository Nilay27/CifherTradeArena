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
import { getEpochData, getStrategy, StrategyNode, StrategyData } from "./epochDatabase";
import { FheTypes } from "./cofheUtils";
import { mapAddressForChain, getTradeManagerForChain, CHAIN_IDS } from "./utils/chainAddressMapping";
import { initializeNexus, getNexusSdk, deinitializeNexus } from "./nexus";
import { ExecuteParams } from "@avail-project/nexus-core";
const fs = require('fs');
const path = require('path');
dotenv.config();

const tradeManagerABI = JSON.parse(
    fs.readFileSync(path.resolve(__dirname, '../abis/TradeManager.json'), 'utf8')
);

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
            const addrString = typeof arg === 'string'
                ? normalizeAddress(arg)
                : ethers.getAddress(ethers.toBeHex(BigInt(arg), 20));
            encodedArgs.push(addrString);
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

function isAddressType(argType: number): boolean {
    return argType === FheTypes.Uint160 || argType === FheTypes.Address || argType === 7;
}

function normalizeAddress(value: string): string {
    if (!value) {
        return ethers.ZeroAddress;
    }

    let candidate = value.trim();
    candidate = candidate.replace(/^0x0x/i, '0x');
    if (!/^0x/i.test(candidate)) {
        candidate = `0x${candidate}`;
    }

    try {
        return ethers.getAddress(candidate);
    } catch (error) {
        throw new Error(`Invalid address encountered during normalization: ${value}`);
    }
}

function tryMapAddress(value: any, targetChainId: number): any {
    if (typeof value === 'string') {
        try {
            const normalized = normalizeAddress(value);
            const mapped = mapAddressForChain(normalized, targetChainId);
            return normalizeAddress(mapped);
        } catch {
            return value;
        }
    }
    return value;
}

function remapNodeForChain(node: StrategyNode, targetChainId: number): StrategyNode {
    const mappedArgs = node.args.map((arg, idx) => {
        const argType = Number(node.argTypes[idx]);
        return isAddressType(argType) ? tryMapAddress(arg, targetChainId) : arg;
    });

    return {
        ...node,
        encoder: tryMapAddress(node.encoder, targetChainId),
        target: tryMapAddress(node.target, targetChainId),
        args: mappedArgs,
    };
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
                encoder: normalizeAddress(node.encoder),
                target: normalizeAddress(node.target),
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

    await initializeNexus(wallet, { network: 'testnet', debug: false });
    console.log('Nexus SDK initialized successfully with operator wallet:', wallet.address);

    try {
        const nexusSdk = getNexusSdk();
        const unified = await nexusSdk.getUnifiedBalances();
        console.log('Unified balances data:', unified);
        const assets = Array.isArray(unified)
            ? unified
            : Array.isArray((unified as any)?.assets)
            ? (unified as any).assets
            : [];
        const assetSummaries = assets.map((asset: any) => {
            const balance = typeof asset.balance === 'string'
                ? asset.balance
                : asset.balance?.toString?.() ?? '0';
            const fiat = typeof asset.balanceInFiat === 'number'
                ? asset.balanceInFiat.toFixed(2)
                : asset.balanceInFiat ?? '0';
            return `${asset.symbol}: ${balance} (~${fiat} USD)`;
        });
        console.log('Unified balances summary:', assetSummaries.length ? assetSummaries.join(', ') : 'none');
    } catch (balanceError) {
        console.error('Failed to fetch unified balances summary:', balanceError);
    }


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

    const baseStrategyNodes: StrategyNode[][] = [];
    const crossChainStrategies = new Map<number, StrategyNode[][]>();

    for (const winner of winners) {
        const strategy = getStrategy(Number(epochNumber), winner);

        if (!strategy) {
            console.error(`\n❌ Strategy not found for ${winner}`);
            process.exit(1);
        }

        const targetChainId = strategy.targetChainId ?? chainId;
        console.log(`    - ${winner}: ${strategy.nodes.length} nodes (target chain ${targetChainId})`);

        const remappedNodes = targetChainId === chainId
            ? strategy.nodes
            : strategy.nodes.map((node) => remapNodeForChain(node, targetChainId));

        if (targetChainId === chainId) {
            baseStrategyNodes.push(remappedNodes);
        } else {
            if (!crossChainStrategies.has(targetChainId)) {
                crossChainStrategies.set(targetChainId, []);
            }
            crossChainStrategies.get(targetChainId)!.push(remappedNodes);
        }
    }

    const baseAggregated = baseStrategyNodes.length > 0 ? aggregateStrategies(baseStrategyNodes) : null;
    const crossAggregated = new Map<number, { encoders: string[]; targets: string[]; calldatas: string[] }>();

    for (const [targetChainId, nodes] of crossChainStrategies.entries()) {
        console.log(`\n[Cross-chain] Preparing ${nodes.length} strategy bundles for chain ${targetChainId}`);
        crossAggregated.set(targetChainId, aggregateStrategies(nodes));
    }

    async function executeCrossChainViaNexus(
        epoch: bigint,
        targetChainId: number,
        aggregated: { encoders: string[]; targets: string[]; calldatas: string[] },
        signature: string,
    ): Promise<void> {
        const tradeManagerAddress = getTradeManagerForChain(targetChainId);
        const sdk = getNexusSdk();

        try {
            console.log(`  → Dispatching executeEpochTopStrategiesAggregated to ${tradeManagerAddress} on chain ${targetChainId}`);
            const result = await sdk.execute({
                toChainId: targetChainId,
                contractAddress: tradeManagerAddress,
                contractAbi: tradeManagerABI,
                functionName: 'executeEpochTopStrategiesAggregated',
                buildFunctionParams: () => ({
                    functionParams: [
                        epoch,
                        aggregated.encoders,
                        aggregated.targets,
                        aggregated.calldatas,
                        [signature],
                    ],
                }),
                waitForReceipt: true,
                requiredConfirmations: 1,
            } as ExecuteParams);

            if (result.receipt) {
                console.log(`  ✅ Cross-chain execution included in tx ${result.receipt.transactionHash}`);
                console.log(`Nexus execution submitted for Chain ${targetChainId}`);
            } else {
                console.log('  ⚠️ Cross-chain execution dispatched; receipt unavailable (check Nexus dashboard).');
            }
        } catch (error: any) {
            console.error(`  ❌ Nexus execution failed for chain ${targetChainId}: ${error?.message ?? error}`);
            throw error;
        }
    }

    if (baseAggregated) {
        console.log("\nStep 5: Creating operator signature...");
        const baseSignature = await createOperatorSignature(
            epochNumber,
            baseAggregated.encoders,
            baseAggregated.targets,
            baseAggregated.calldatas
        );

        console.log("\nStep 6: Executing aggregated strategies on base chain...");

        try {
            const nonce = await provider.getTransactionCount(wallet.address);
            const tx = await tradeManager.executeEpochTopStrategiesAggregated(
                epochNumber,
                baseAggregated.encoders,
                baseAggregated.targets,
                baseAggregated.calldatas,
                [baseSignature],
                {
                    nonce,
                    gasLimit: 5_000_000
                }
            );

            console.log(`  TX: ${tx.hash}`);
            console.log("  Waiting for confirmation...");

            const receipt = await tx.wait();
            console.log(`  ✅ Confirmed in block ${receipt.blockNumber}`);
            console.log(`  Gas used: ${receipt.gasUsed.toString()}`);

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

            console.log(`\n✅ Epoch ${epochNumber} executed successfully on base chain!`);
        } catch (error: any) {
            console.error(`\n❌ Failed to execute strategies on base chain: ${error.message}`);
            if (error.reason) {
                console.error(`Reason: ${error.reason}`);
            }
        }
    } else {
        console.log("\nNo base-chain strategies to execute locally.");
    }

    for (const [targetChainId, aggregated] of crossAggregated.entries()) {
        console.log(`\n🌐 Executing aggregated strategies on chain ${targetChainId} via Nexus...`);
        const signature = await createOperatorSignature(
            epochNumber,
            aggregated.encoders,
            aggregated.targets,
            aggregated.calldatas
        );
        await executeCrossChainViaNexus(epochNumber, targetChainId, aggregated, signature);
    }
}

main().catch((error) => {
    console.error("Error:", error);
    process.exit(1);
});
