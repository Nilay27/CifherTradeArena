import { ethers } from "ethers";
import * as dotenv from "dotenv";
const fs = require('fs');
const path = require('path');
dotenv.config();

// Setup env variables
const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY!, provider);

// For local testing
const chainId = 31337;

// Load deployment data
const avsDeploymentData = JSON.parse(
    fs.readFileSync(path.resolve(__dirname, `../contracts/deployments/swap-manager/${chainId}.json`), 'utf8')
);

// Load MockHook address from deployment
let mockHookAddress: string | null = null;
try {
    const mockHookDeployment = JSON.parse(
        fs.readFileSync(path.resolve(__dirname, `../contracts/deployments/mock-hook/${chainId}.json`), 'utf8')
    );
    mockHookAddress = mockHookDeployment.addresses.mockPrivacyHook;
    console.log("Found MockPrivacyHook deployment at:", mockHookAddress);
} catch (e) {
    // Fallback to hardcoded address if file doesn't exist
    mockHookAddress = "0xe8D2A1E88c91DCd5433208d4152Cc4F399a7e91d";
    console.log("Using fallback MockPrivacyHook at:", mockHookAddress);
}

// Load ABIs
const SwapManagerABI = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../abis/SwapManager.json'), 'utf8'));
const MockHookABI = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../abis/MockPrivacyHook.json'), 'utf8'));

// Mock token addresses for testing
const MOCK_USDC = "0x0000000000000000000000000000000000000001";
const MOCK_USDT = "0x0000000000000000000000000000000000000002";
const MOCK_WETH = "0x0000000000000000000000000000000000000003";

interface SwapIntent {
    tokenIn: string;
    tokenOut: string;
    amount: bigint;
    description: string;
}

// Test swap intents
const testIntents: SwapIntent[] = [
    {
        tokenIn: MOCK_USDC,
        tokenOut: MOCK_USDT,
        amount: BigInt(1000 * 1e6), // 1000 USDC (6 decimals)
        description: "Swap 1000 USDC to USDT"
    },
    {
        tokenIn: MOCK_USDC,
        tokenOut: MOCK_WETH,
        amount: BigInt(500 * 1e6), // 500 USDC
        description: "Swap 500 USDC to WETH"
    },
    {
        tokenIn: MOCK_WETH,
        tokenOut: MOCK_USDC,
        amount: BigInt(1 * 1e18), // 1 WETH (18 decimals)
        description: "Swap 1 WETH to USDC"
    }
];

async function createEncryptedSwapTask(
    mockHook: ethers.Contract,
    intent: SwapIntent
): Promise<void> {
    console.log(`\n=== Creating Encrypted Swap Task ===`);
    console.log(`Description: ${intent.description}`);
    console.log(`Token In: ${intent.tokenIn}`);
    console.log(`Token Out: ${intent.tokenOut}`);
    console.log(`Amount: ${intent.amount.toString()}`);
    
    try {
        // For local Anvil testing: use submitTestIntent which simulates encryption
        // Real FHE encryption requires either:
        // 1. Fhenix testnet connection (TESTNET mode)
        // 2. Mock contracts deployed at specific addresses (MOCK mode with hardhat plugin)
        
        console.log("Using simulated encryption for local Anvil testing");
        
        // The MockHook's submitTestIntent will encode the amount as if it were encrypted
        const tx = await mockHook.submitTestIntent(
            intent.tokenIn,
            intent.tokenOut,
            intent.amount
        );
        
        console.log(`Transaction submitted: ${tx.hash}`);
        const receipt = await tx.wait();
        
        // Parse events from the receipt
        const intentSubmittedEvent = receipt.logs.find((log: any) => {
            try {
                const parsed = mockHook.interface.parseLog(log);
                return parsed?.name === "IntentSubmitted";
            } catch {
                return false;
            }
        });
        
        const taskCreatedEvent = receipt.logs.find((log: any) => {
            try {
                const parsed = mockHook.interface.parseLog(log);
                return parsed?.name === "TaskCreated";
            } catch {
                return false;
            }
        });
        
        if (intentSubmittedEvent && taskCreatedEvent) {
            const intentParsed = mockHook.interface.parseLog(intentSubmittedEvent);
            const taskParsed = mockHook.interface.parseLog(taskCreatedEvent);
            
            console.log(`✅ Intent submitted successfully!`);
            console.log(`   Intent ID: ${intentParsed?.args.intentId}`);
            console.log(`   Task Index: ${taskParsed?.args.taskIndex}`);
            console.log(`   Selected Operators: ${taskParsed?.args.selectedOperators.join(', ')}`);
        }
        
    } catch (error) {
        console.error(`❌ Error creating task:`, error);
    }
}

async function main() {
    console.log("Starting Encrypted Swap Task Generator");
    console.log("=====================================\n");
    
    // Check if MockHook is deployed
    if (!mockHookAddress) {
        console.error("MockPrivacyHook not deployed. Please run:");
        console.error("cd contracts && forge script script/DeployWithMockHook.s.sol --rpc-url http://localhost:8545 --broadcast");
        process.exit(1);
    }
    
    // Initialize contracts
    const mockHook = new ethers.Contract(mockHookAddress, MockHookABI, wallet);
    const swapManager = new ethers.Contract(avsDeploymentData.addresses.SwapManager, SwapManagerABI, wallet);
    
    // Check if there are registered operators
    const operatorCount = await swapManager.getOperatorCount();
    console.log(`Registered operators: ${operatorCount}`);
    
    if (operatorCount === 0) {
        console.warn("⚠️  No operators registered yet. Tasks will be created but won't be processed.");
        console.warn("   Please start the operator first: npm run start:operator");
    }
    
    // Submit tasks with delays
    console.log("\nSubmitting encrypted swap tasks...");
    
    for (let i = 0; i < testIntents.length; i++) {
        await createEncryptedSwapTask(mockHook, testIntents[i]);
        
        // Wait between tasks
        if (i < testIntents.length - 1) {
            console.log("\nWaiting 10 seconds before next task...");
            await new Promise(resolve => setTimeout(resolve, 10000));
        }
    }
    
    console.log("\n=== All tasks submitted ===");
    
    // Monitor for responses
    console.log("\nMonitoring for operator responses...");
    
    swapManager.on("SwapTaskResponded", (taskIndex: number, task: any, operator: string, decryptedAmount: bigint) => {
        console.log(`\n📨 Task ${taskIndex} responded by operator ${operator}`);
        console.log(`   Decrypted amount: ${decryptedAmount.toString()}`);
    });
    
    // Keep the script running to monitor events
    console.log("\nPress Ctrl+C to exit...");
}

// Execute main function
main().catch((error) => {
    console.error("Error in main:", error);
    process.exit(1);
});