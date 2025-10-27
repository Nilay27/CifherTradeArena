/**
 * Simple script to register operator and start epoch
 * No mock deployments needed - just pure TradeManager interaction
 *
 * Usage: ts-node operator/setupAndStartEpoch.ts
 */

import { ethers } from "ethers";
import * as dotenv from "dotenv";
import { initializeCofhe, batchEncrypt, FheTypes } from "./cofheUtils";
import { getTradeManagerForChain } from "./utils/chainAddressMapping";
const fs = require('fs');
const path = require('path');
dotenv.config();

async function startEpochOnChain(rpcUrl: string | undefined, label: string) {
    if (!rpcUrl) {
        console.log(`\n⚠️ Skipping ${label}: RPC URL not configured`);
        return;
    }

    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const wallet = new ethers.Wallet(process.env.PRIVATE_KEY!, provider);

    console.log(`\n🚀 Setup and Start Epoch (${label})`);
    console.log(`Wallet: ${wallet.address}`);

    const chainId = Number((await provider.getNetwork()).chainId);
    console.log(`Chain ID: ${chainId}`);

    const tradeManagerAddress = getTradeManagerForChain(chainId);
    console.log(`TradeManager: ${tradeManagerAddress}\n`);

    const tradeManagerABI = JSON.parse(
        fs.readFileSync(path.resolve(__dirname, '../abis/TradeManager.json'), 'utf8')
    );

    const tradeManager = new ethers.Contract(tradeManagerAddress, tradeManagerABI, wallet);

    console.log("Step 1: Checking operator registration...");
    const isRegistered = await tradeManager.operatorRegistered(wallet.address);

    if (!isRegistered) {
        console.log("  Operator not registered. Registering...");
        try {
            const nonce1 = await provider.getTransactionCount(wallet.address);
            const tx1 = await tradeManager.registerOperator({ nonce: nonce1 });
            console.log(`  TX: ${tx1.hash}`);
            await tx1.wait();
            console.log("  ✅ Operator registered");
        } catch (error: any) {
            console.log(`  ℹ️ Registration might have failed: ${error.message}`);
        }
    } else {
        console.log("  ✅ Operator already registered");
    }

    console.log("\nStep 2: Encrypting simulation window...");
    await initializeCofhe(wallet);

    const now = Math.floor(Date.now() / 1000);
    const simStartTime = now - (7 * 24 * 60 * 60);
    const simEndTime = now - (1 * 24 * 60 * 60);

    console.log(`  Start: ${new Date(simStartTime * 1000).toISOString()}`);
    console.log(`  End: ${new Date(simEndTime * 1000).toISOString()}`);

    const encryptedTimes = await batchEncrypt(
        [
            { value: BigInt(simStartTime), type: FheTypes.Uint64 },
            { value: BigInt(simEndTime), type: FheTypes.Uint64 }
        ],
        wallet.address,
        tradeManagerAddress
    );

    const encSimStartTime = encryptedTimes[0];
    const encSimEndTime = encryptedTimes[1];
    console.log("  ✅ Encrypted");

    console.log("\nStep 3: Starting epoch...");

    const epochDuration = 5 * 60;
    const weights = [50,50];
    const notionalPerTrader = ethers.parseUnits("100000", 6);
    const allocatedCapital = ethers.parseUnits("100000", 6);

    console.log(`  Duration: ${epochDuration / 60} minutes`);
    console.log(`  Weights: [${weights.join(', ')}]`);
    console.log(`  Notional: ${ethers.formatUnits(notionalPerTrader, 6)} USDC`);
    console.log(`  Capital: ${ethers.formatUnits(allocatedCapital, 6)} USDC`);

    try {
        const nonce2 = await provider.getTransactionCount(wallet.address);
        const tx = await tradeManager.startEpoch(
            {
                ctHash: encSimStartTime.ctHash,
                securityZone: encSimStartTime.securityZone,
                utype: encSimStartTime.utype,
                signature: encSimStartTime.signature
            },
            {
                ctHash: encSimEndTime.ctHash,
                securityZone: encSimEndTime.securityZone,
                utype: encSimEndTime.utype,
                signature: encSimEndTime.signature
            },
            epochDuration,
            weights,
            notionalPerTrader,
            allocatedCapital,
            {
                nonce: nonce2,
                gasLimit: 5_000_000
            }
        );

        console.log(`  TX: ${tx.hash}`);
        console.log("  Waiting for confirmation...");

        const receipt = await tx.wait();
        console.log(`  ✅ Confirmed in block ${receipt.blockNumber}`);

        const epochNumber = await tradeManager.currentEpochNumber();
        console.log(`\n✅ Epoch ${epochNumber} started on ${label}!`);
        console.log(`Ends at: ${new Date((now + epochDuration) * 1000).toISOString()}`);
    } catch (error: any) {
        console.error(`\n❌ Failed to start epoch on ${label}:`);
        console.error(error.message);
        if (error.data) {
            console.error("Error data:", error.data);
        }
        // Do not exit; continue to next chain
    }
}

async function main() {
    await startEpochOnChain(process.env.RPC_URL, "Base");
    await startEpochOnChain(process.env.ARB_SEPOLIA_RPC_URL, "Arbitrum");
    console.log("\n✅ Setup script completed for all configured chains.");
}

main().catch((error) => {
    console.error("Error:", error);
    process.exit(1);
});
