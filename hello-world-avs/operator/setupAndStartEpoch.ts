/**
 * Simple script to register operator and start epoch
 * No mock deployments needed - just pure TradeManager interaction
 *
 * Usage: ts-node operator/setupAndStartEpoch.ts
 */

import { ethers } from "ethers";
import * as dotenv from "dotenv";
import { initializeCofhe, batchEncrypt, FheTypes } from "./cofheUtils";
const fs = require('fs');
const path = require('path');
dotenv.config();

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY!, provider);

async function main() {
    console.log("\n🚀 Setup and Start Epoch\n");
    console.log(`Wallet: ${wallet.address}`);

    // Get chain ID
    const chainId = Number((await provider.getNetwork()).chainId);
    console.log(`Chain ID: ${chainId}`);

    // Hardcoded TradeManager address for Arbitrum Sepolia
    const tradeManagerAddress = chainId === 421614
        ? "0x0104cC21941834d934C574358956a395779Be1Ec"
        : "0x9189AA689Ac1C1ff764FA9b242f6dDcD52D861B2"; // Base Sepolia fallback

    console.log(`TradeManager: ${tradeManagerAddress}\n`);

    // Load full ABI
    const tradeManagerABI = JSON.parse(
        fs.readFileSync(path.resolve(__dirname, '../abis/TradeManager.json'), 'utf8')
    );

    const tradeManager = new ethers.Contract(tradeManagerAddress, tradeManagerABI, wallet);

    // Step 1: Check if operator is already registered
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

    // Step 2: Initialize CoFHE for encrypting simulation window
    console.log("\nStep 2: Encrypting simulation window...");
    await initializeCofhe(wallet);

    // Define simulation window (7 days ago to 1 day ago)
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

    // Step 3: Start epoch
    console.log("\nStep 3: Starting epoch...");

    const epochDuration = 10 * 60; // 5 minutes
    const weights = [50, 30, 20];
    const notionalPerTrader = ethers.parseUnits("100000", 6); // 100k USDC
    const allocatedCapital = ethers.parseUnits("1000000", 6); // 1M USDC

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
                gasLimit: 5000000
            }
        );

        console.log(`  TX: ${tx.hash}`);
        console.log("  Waiting for confirmation...");

        const receipt = await tx.wait();
        console.log(`  ✅ Confirmed in block ${receipt.blockNumber}`);

        const epochNumber = await tradeManager.currentEpochNumber();
        console.log(`\n✅ Epoch ${epochNumber} started!`);
        console.log(`Ends at: ${new Date((now + epochDuration) * 1000).toISOString()}`);
        console.log(`\nNext: ts-node operator/createEncryptedStrategyInputs.ts`);

    } catch (error: any) {
        console.error("\n❌ Failed to start epoch:");
        console.error(error.message);
        if (error.data) {
            console.error("Error data:", error.data);
        }
        process.exit(1);
    }
}

main().catch((error) => {
    console.error("Error:", error);
    process.exit(1);
});
