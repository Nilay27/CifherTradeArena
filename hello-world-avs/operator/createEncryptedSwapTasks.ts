import { ethers } from "ethers";
import * as dotenv from "dotenv";
const { cofhejs, Encryptable, FheTypes } = require('cofhejs/node');
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
    console.error("MockPrivacyHook deployment file not found!");
    console.error("Please run: npm run deploy:mock-hook");
    process.exit(1);
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

async function encryptAmount(amount: bigint): Promise<string> {
    try {
        console.log(`Encrypting amount using CoFHE.js: ${amount}`);
        
        // Use real CoFHE.js encryption
        const encResult = await cofhejs.encrypt([Encryptable.uint128(amount)]);
        
        if (!encResult.success) {
            throw new Error(`Encryption failed: ${encResult.error?.message || 'Unknown error'}`);
        }
        
        const encryptedHandle = encResult.data[0];
        console.log(`Encrypted to FHE handle:`, encryptedHandle);
        
        // Extract just the ctHash from the encrypted handle object
        const ctHash = encryptedHandle.ctHash;
        console.log(`Using ctHash: ${ctHash}`);
        
        return ethers.AbiCoder.defaultAbiCoder().encode(
            ["uint256"],
            [ctHash]
        );
    } catch (error) {
        console.error("Error encrypting amount:", error);
        throw error;
    }
}

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
        // Encrypt the amount
        const encryptedAmount = await encryptAmount(intent.amount);
        
        // Get current nonce and gas price to avoid estimation issues
        const nonce = await wallet.getNonce();
        const feeData = await provider.getFeeData();
        
        // Submit the encrypted intent with explicit transaction parameters
        const tx = await mockHook.submitEncryptedIntent(
            intent.tokenIn,
            intent.tokenOut,
            encryptedAmount,
            {
                nonce: nonce,
                gasLimit: 500000,
                gasPrice: feeData.gasPrice
            }
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
    
    // Initialize CoFHE.js for real FHE encryption
    console.log("Initializing CoFHE.js...");
    
    await cofhejs.initializeWithEthers({
        ethersProvider: provider,
        ethersSigner: wallet,
        environment: 'MOCK'
    });
    
    // Try to create a permit for FHE operations (may fail but not critical for mock)
    try {
        await cofhejs.createPermit();
        console.log("Permit created successfully");
    } catch (permitError) {
        console.log("Permit creation skipped (not critical for mock environment)");
    }
    
    console.log("CoFHE.js initialized successfully");
    console.log("Real FHE encryption enabled\n");
    
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
    
    swapManager.on("SwapTaskResponded", (taskIndex: number, _task: any, operator: string, decryptedAmount: bigint) => {
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