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

// Test swap intents - designed to create matches
const testIntents: SwapIntent[] = [
    // These two should match (USDC <-> USDT)
    {
        tokenIn: MOCK_USDC,
        tokenOut: MOCK_USDT,
        amount: BigInt(1000 * 1e6), // 1000 USDC
        description: "User A: Swap 1000 USDC to USDT"
    },
    {
        tokenIn: MOCK_USDT,
        tokenOut: MOCK_USDC,
        amount: BigInt(800 * 1e6), // 800 USDT
        description: "User B: Swap 800 USDT to USDC (should match with User A)"
    },
    // These two should partially match (WETH <-> USDC)
    {
        tokenIn: MOCK_WETH,
        tokenOut: MOCK_USDC,
        amount: BigInt(2 * 1e18), // 2 WETH
        description: "User C: Swap 2 WETH to USDC"
    },
    {
        tokenIn: MOCK_USDC,
        tokenOut: MOCK_WETH,
        amount: BigInt(3000 * 1e6), // 3000 USDC
        description: "User D: Swap 3000 USDC to WETH (partial match with User C)"
    },
    // This one won't match
    {
        tokenIn: MOCK_USDT,
        tokenOut: MOCK_WETH,
        amount: BigInt(500 * 1e6), // 500 USDT
        description: "User E: Swap 500 USDT to WETH (no match, will be net swap)"
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

async function submitEncryptedIntent(
    mockHook: ethers.Contract,
    intent: SwapIntent
): Promise<string | null> {
    console.log(`\n=== Submitting Encrypted Intent ===`);
    console.log(`Description: ${intent.description}`);
    console.log(`Token In: ${intent.tokenIn}`);
    console.log(`Token Out: ${intent.tokenOut}`);
    console.log(`Amount: ${intent.amount.toString()}`);
    
    try {
        // Encrypt the amount using real FHE
        const encryptedAmount = await encryptAmount(intent.amount);
         // Get current nonce and gas price to avoid estimation issues
         const nonce = await wallet.getNonce();
         const feeData = await provider.getFeeData();
        // Submit the encrypted intent to the batch
        const tx = await mockHook.submitIntent(
            intent.tokenIn,
            intent.tokenOut,
            encryptedAmount,
            {
                nonce: nonce,
                gasLimit: 5000000,
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
        
        if (intentSubmittedEvent) {
            const intentParsed = mockHook.interface.parseLog(intentSubmittedEvent);
            const intentId = intentParsed?.args.intentId;
            
            console.log(`✅ Intent submitted successfully!`);
            console.log(`   Intent ID: ${intentId}`);
            
            return intentId;
        }
        
        return null;
    } catch (error) {
        console.error(`❌ Error submitting intent:`, error);
        return null;
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
    
    // Check if MockHook is authorized
    const isAuthorized = await swapManager.authorizedHooks(mockHookAddress);
    console.log(`MockHook authorized in SwapManager: ${isAuthorized}`);
    
    if (!isAuthorized) {
        console.error("MockHook is not authorized! Run the deployment script again.");
        process.exit(1);
    }
    
    // Check if there are registered operators
    const operatorCount = await swapManager.getOperatorCount();
    console.log(`Registered operators: ${operatorCount}`);
    
    if (operatorCount === 0) {
        console.warn("⚠️  No operators registered yet. Tasks will be created but won't be processed.");
        console.warn("   Please start the operator first: npm run start:operator");
    }
    
    // Submit intents to create a batch
    console.log("\nSubmitting encrypted intents to batch...");
    const submittedIntentIds: string[] = [];
    
    for (let i = 0; i < testIntents.length; i++) {
        const intentId = await submitEncryptedIntent(mockHook, testIntents[i]);
        if (intentId) {
            submittedIntentIds.push(intentId);
        }
        
        // Small delay between intents
        if (i < testIntents.length - 1) {
            console.log("\nWaiting 2 seconds before next intent...");
            await new Promise(resolve => setTimeout(resolve, 2000));
        }
    }
    
    console.log(`\n=== All ${submittedIntentIds.length} intents submitted ===`);
    
    // In production, batches auto-finalize after the block interval (5 blocks)
    // when a new intent arrives. The operator monitors for BatchFinalized events.
    console.log("\nBatches will auto-finalize after 5 blocks when new intents arrive.");
    console.log("Operators are monitoring for BatchFinalized events from SwapManager.");
    
    // Monitor for batch settlement events
    console.log("\nMonitoring for batch settlements...");
    
    swapManager.on("BatchSettlementSubmitted", (batchId: string, internalizedCount: number, netSwapCount: number) => {
        console.log(`\n📨 Batch ${batchId} settlement submitted!`);
        console.log(`   Internalized transfers: ${internalizedCount}`);
        console.log(`   Net swaps: ${netSwapCount}`);
    });
    
    swapManager.on("BatchSettled", (batchId: string, success: boolean) => {
        console.log(`\n✅ Batch ${batchId} settled: ${success ? 'SUCCESS' : 'FAILED'}`);
    });
    
    // Keep the script running to monitor events
    console.log("\nPress Ctrl+C to exit...");
}

// Execute main function
main().catch((error) => {
    console.error("Error in main:", error);
    process.exit(1);
});