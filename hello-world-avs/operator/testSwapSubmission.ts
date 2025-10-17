import { ethers } from "ethers";
import * as dotenv from "dotenv";
import { initializeCofhe, batchEncrypt, FheTypes, CoFheItem, EncryptionInput } from './cofheUtils';
import { loadDeploymentConfig, getNetworkName } from './config/deploymentConfig';
const fs = require('fs');
const path = require('path');
dotenv.config();

// Setup env variables
const provider = new ethers.JsonRpcProvider(process.env.RPC_URL || "https://sepolia.gateway.tenderly.co");
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY!, provider);

// Get chain ID from provider
async function getChainId(): Promise<number> {
    const network = await provider.getNetwork();
    return Number(network.chainId);
}

// Load deployment config (will be initialized in main)
let config: ReturnType<typeof loadDeploymentConfig>;
let UNIVERSAL_PRIVACY_HOOK: string;
let USDC_ADDRESS: string;
let USDT_ADDRESS: string;

// Load UniversalPrivacyHook ABI from abis folder
let UniversalHookABI: any;
try {
    UniversalHookABI = JSON.parse(
        fs.readFileSync(path.resolve(__dirname, '../abis/UniversalPrivacyHook.json'), 'utf8')
    );
} catch (e) {
    console.error("UniversalPrivacyHook ABI not found at abis/UniversalPrivacyHook.json");
    console.error(e);
    process.exit(1);
}

interface SwapIntent {
    tokenIn: string;
    tokenOut: string;
    amount: bigint;
    description: string;
}

// Helper function to encrypt amount for intent submission
async function encryptAmountForIntent(
    amount: bigint,
    contractAddress: string,
    signerAddress: string
): Promise<CoFheItem> {
    try {
        console.log(`Encrypting amount using CoFHE.js: ${amount}`);

        // Encrypt using general batchEncrypt with Uint128 type for swap amounts
        const inputs: EncryptionInput[] = [{
            value: amount,
            type: FheTypes.Uint128  // Swap amounts are always Uint128
        }];

        const encryptedItems = await batchEncrypt(inputs, signerAddress, contractAddress);
        const encryptedItem = encryptedItems[0];

        console.log("Encrypted to CoFheItem struct with ctHash:", encryptedItem.ctHash);
        console.log(`  utype: ${encryptedItem.utype} (expected ${FheTypes.Uint128})`);

        return encryptedItem;
    } catch (error) {
        console.error("Error encrypting amount:", error);
        throw error;
    }
}

async function submitEncryptedIntent(
    universalHook: ethers.Contract,
    poolKey: any,
    intent: SwapIntent
): Promise<string | null> {
    console.log(`\n=== Submitting Test Swap Intent ===`);
    console.log(`Description: ${intent.description}`);
    console.log(`Token In: ${intent.tokenIn === USDC_ADDRESS ? 'USDC' : 'USDT'}`);
    console.log(`Token Out: ${intent.tokenOut === USDC_ADDRESS ? 'USDC' : 'USDT'}`);
    console.log(`Amount: ${intent.amount.toString()}`);

    try {
        // Encrypt the amount using CoFHE.js
        const encryptedItem = await encryptAmountForIntent(
            intent.amount,
            UNIVERSAL_PRIVACY_HOOK,
            wallet.address
        );

        const deadline = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now

        // Get current nonce and gas price to avoid estimation issues
        const nonce = await wallet.getNonce();
        console.log(`Using nonce: ${nonce}`);

        const feeData = await provider.getFeeData();
        const gasPrice = (feeData.gasPrice! * 120n) / 100n;
        console.log(`Gas price: ${gasPrice.toString()}`);

        console.log("Submitting transaction to UniversalPrivacyHook...");

        // Submit the encrypted intent to UniversalPrivacyHook with CoFheItem struct
        const tx = await universalHook.submitIntent(
            poolKey,
            intent.tokenIn,
            intent.tokenOut,
            encryptedItem, // Pass full CoFheItem struct as InEuint128
            deadline,
            {
                nonce: nonce,
                gasLimit: 5000000,
                gasPrice: gasPrice
            }
        );

        console.log(`Transaction submitted: ${tx.hash}`);
        console.log("Waiting for confirmation...");

        // Add timeout for transaction confirmation
        const timeoutPromise = new Promise((_, reject) =>
            setTimeout(() => reject(new Error("Transaction timeout after 2 minutes")), 120000)
        );

        const receipt = await Promise.race([
            tx.wait(1), // Wait for 1 confirmation
            timeoutPromise
        ]) as any;

        // Parse events from the receipt
        const intentSubmittedEvent = receipt.logs.find((log: any) => {
            try {
                const parsed = universalHook.interface.parseLog(log);
                return parsed?.name === "IntentSubmitted";
            } catch {
                return false;
            }
        });

        if (intentSubmittedEvent) {
            const intentParsed = universalHook.interface.parseLog(intentSubmittedEvent);
            const intentId = intentParsed?.args.intentId;

            console.log(`Intent submitted successfully!`);
            console.log(`   Intent ID: ${intentId}`);
            console.log(`   Transaction: ${tx.hash}`);

            return intentId;
        }

        return null;
    } catch (error) {
        console.error(`Error submitting intent:`, error);
        return null;
    }
}

// Generate random amount between 2-5 tokens (with 6 decimals)
function getRandomAmount(): bigint {
    const min = 2 * 1e6; // 2 tokens
    const max = 5 * 1e6; // 5 tokens
    const randomAmount = Math.floor(Math.random() * (max - min + 1)) + min;
    return BigInt(randomAmount);
}

// Generate random swap direction
function getRandomSwapDirection(): { tokenIn: string; tokenOut: string } {
    const useUsdcToUsdt = Math.random() < 0.5;
    if (useUsdcToUsdt) {
        return { tokenIn: USDC_ADDRESS, tokenOut: USDT_ADDRESS };
    } else {
        return { tokenIn: USDT_ADDRESS, tokenOut: USDC_ADDRESS };
    }
}

async function main() {
    console.log("Test Swap Intent Submission Script");
    console.log("===================================\n");

    // Load deployment configuration based on chain ID
    const chainId = await getChainId();
    console.log(`Detected chain ID: ${chainId} (${getNetworkName(chainId)})`);

    config = loadDeploymentConfig(chainId);
    UNIVERSAL_PRIVACY_HOOK = config.universalPrivacyHook;
    USDC_ADDRESS = config.mockUSDC;
    USDT_ADDRESS = config.mockUSDT;

    console.log("\nLoaded deployment addresses:");
    console.log("  UniversalPrivacyHook:", UNIVERSAL_PRIVACY_HOOK);
    console.log("  Mock USDC:", USDC_ADDRESS);
    console.log("  Mock USDT:", USDT_ADDRESS);
    console.log("  Pool ID:", config.poolId);

    // Initialize CoFHE.js for FHE encryption
    console.log("\nInitializing CoFHE.js...");
    await initializeCofhe(wallet);
    console.log("CoFHE.js initialized successfully");
    console.log("FHE encryption enabled\n");

    // Initialize UniversalPrivacyHook contract
    const universalHook = new ethers.Contract(UNIVERSAL_PRIVACY_HOOK, UniversalHookABI, wallet);

    // Create PoolKey for the USDC/USDT pool
    // Order tokens correctly (lower address first)
    const [currency0, currency1] = USDC_ADDRESS.toLowerCase() < USDT_ADDRESS.toLowerCase()
        ? [USDC_ADDRESS, USDT_ADDRESS]
        : [USDT_ADDRESS, USDC_ADDRESS];

    const poolKey = {
        currency0: currency0,
        currency1: currency1,
        fee: 3000, // 0.3% fee
        tickSpacing: 60,
        hooks: UNIVERSAL_PRIVACY_HOOK
    };

    console.log("Pool Key:", poolKey);
    console.log("Wallet:", wallet.address);
    console.log("\nSubmitting 5 random swap intents with 2s delay between each...\n");

    const totalIntents = 5;
    const successfulIntents: string[] = [];

    for (let i = 0; i < totalIntents; i++) {
        console.log(`\n[${i + 1}/${totalIntents}] Generating random swap intent...`);

        const amount = getRandomAmount();
        const { tokenIn, tokenOut } = getRandomSwapDirection();

        const intent: SwapIntent = {
            tokenIn,
            tokenOut,
            amount,
            description: `Test swap ${i + 1}`
        };

        const intentId = await submitEncryptedIntent(universalHook, poolKey, intent);

        if (intentId) {
            successfulIntents.push(intentId);
        }

        // Wait 2 seconds before next submission (except for the last one)
        if (i < totalIntents - 1) {
            console.log("\nWaiting 2 seconds before next submission...");
            await new Promise(resolve => setTimeout(resolve, 2000));
        }
    }

    console.log("\n\n=== Test Submission Complete ===");
    console.log(`Total intents submitted: ${totalIntents}`);
    console.log(`Successful submissions: ${successfulIntents.length}`);
    console.log(`Failed submissions: ${totalIntents - successfulIntents.length}`);

    if (successfulIntents.length > 0) {
        console.log("\nSuccessful Intent IDs:");
        successfulIntents.forEach((id, idx) => {
            console.log(`  ${idx + 1}. ${id}`);
        });
    }

    console.log("\nNow monitor your AVS operator to see if it processes these intents!");
    process.exit(0);
}

// Execute main function
main().catch((error) => {
    console.error("Error in main:", error);
    process.exit(1);
});
