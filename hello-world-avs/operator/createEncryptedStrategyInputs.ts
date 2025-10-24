/**
 * Helper script to create encrypted strategy inputs for testing
 * Usage: ts-node createEncryptedStrategyInputs.ts
 */

import { ethers } from "ethers";
import * as dotenv from "dotenv";
import { initializeCofhe, batchEncrypt, FheTypes, EncryptionInput } from "./cofheUtils";
const fs = require('fs');
const path = require('path');
dotenv.config();

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY!, provider);

async function main() {
    console.log("\n🔐 Creating Encrypted Strategy Inputs\n");

    // Initialize CoFHE.js
    await initializeCofhe(wallet);

    // Example strategy node: Aave deposit 1000 USDC
    const encoder = "0x1234567890123456789012345678901234567890"; // Example encoder address
    const target = "0xAbcD123456789012345678901234567890AbCdEf";   // Example Aave pool address
    const selector = 0xe8eda9df; // deposit(address,uint256,address,uint16) selector

    // Example args: asset, amount, onBehalfOf, referralCode
    const args = [
        "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174", // USDC on Polygon
        BigInt(1000e6), // 1000 USDC (6 decimals)
        wallet.address, // onBehalfOf
        BigInt(0) // referralCode
    ];

    console.log("Example Strategy Node:");
    console.log("  Encoder:", encoder);
    console.log("  Target:", target);
    console.log("  Selector:", `0x${selector.toString(16)}`);
    console.log("  Args:", args);
    console.log();

    // Get TradeManager address from deployment
    const chainId = Number((await provider.getNetwork()).chainId);
    const avsDeploymentData = JSON.parse(
        fs.readFileSync(path.resolve(__dirname, `../contracts/deployments/trade-manager/${chainId}.json`), 'utf8')
    );
    const tradeManagerAddress = avsDeploymentData.addresses.tradeManager;

    console.log(`TradeManager: ${tradeManagerAddress}`);
    console.log(`User: ${wallet.address}`);
    console.log();

    // Prepare encryption inputs
    const inputs: EncryptionInput[] = [
        { value: encoder, type: FheTypes.Address },
        { value: target, type: FheTypes.Address },
        { value: BigInt(selector), type: FheTypes.Uint32 },
        // Args
        { value: args[0], type: FheTypes.Address },      // asset address
        { value: args[1], type: FheTypes.Uint128 },      // amount
        { value: wallet.address, type: FheTypes.Address }, // onBehalfOf
        { value: BigInt(args[3]), type: FheTypes.Uint16 } // referralCode
    ];

    console.log("Encrypting strategy inputs...");
    const encrypted = await batchEncrypt(
        inputs,
        wallet.address,       // userAddress
        tradeManagerAddress   // contractAddress
    );

    console.log("\n✅ Encryption complete!\n");

    // Format for submitEncryptedStrategy call
    const encoders = [{
        ctHash: encrypted[0].ctHash,
        securityZone: encrypted[0].securityZone,
        utype: encrypted[0].utype,
        signature: encrypted[0].signature
    }];

    const targets = [{
        ctHash: encrypted[1].ctHash,
        securityZone: encrypted[1].securityZone,
        utype: encrypted[1].utype,
        signature: encrypted[1].signature
    }];

    const selectors = [{
        ctHash: encrypted[2].ctHash,
        securityZone: encrypted[2].securityZone,
        utype: encrypted[2].utype,
        signature: encrypted[2].signature
    }];

    const nodeArgs = [[
        {
            ctHash: encrypted[3].ctHash,
            securityZone: encrypted[3].securityZone,
            utype: encrypted[3].utype,
            signature: encrypted[3].signature
        },
        {
            ctHash: encrypted[4].ctHash,
            securityZone: encrypted[4].securityZone,
            utype: encrypted[4].utype,
            signature: encrypted[4].signature
        },
        {
            ctHash: encrypted[5].ctHash,
            securityZone: encrypted[5].securityZone,
            utype: encrypted[5].utype,
            signature: encrypted[5].signature
        },
        {
            ctHash: encrypted[6].ctHash,
            securityZone: encrypted[6].securityZone,
            utype: encrypted[6].utype,
            signature: encrypted[6].signature
        }
    ]];

    // Save to JSON for easy use
    const output = {
        encoders,
        targets,
        selectors,
        nodeArgs,
        metadata: {
            description: "Aave deposit 1000 USDC",
            createdAt: new Date().toISOString(),
            user: wallet.address,
            tradeManager: tradeManagerAddress
        }
    };

    const outputPath = path.resolve(__dirname, 'encrypted-strategy-example.json');
    fs.writeFileSync(outputPath, JSON.stringify(output, (key, value) =>
        typeof value === 'bigint' ? '0x' + value.toString(16) : value
    , 2));

    console.log("📁 Output saved to:", outputPath);
    console.log("\nYou can use this in your contract calls:");
    console.log("  tradeManager.submitEncryptedStrategy(encoders, targets, selectors, nodeArgs)");
}

main().catch((error) => {
    console.error("Error:", error);
    process.exit(1);
});
