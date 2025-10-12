const { ethers } = require("ethers");
const dotenv = require("dotenv");
const { cofhejs, Encryptable } = require('cofhejs/node');
const fs = require('fs');
const path = require('path');
dotenv.config();

// Setup env variables
const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

// For local testing
const chainId = 31337;

// Load deployment data
const avsDeploymentData = JSON.parse(
    fs.readFileSync(path.resolve(__dirname, `../contracts/deployments/swap-manager/${chainId}.json`), 'utf8')
);

// Load UniversalPrivacyHook address from deployment
let universalHookAddress = null;
try {
    const hookDeployment = JSON.parse(
        fs.readFileSync(path.resolve(__dirname, `../../universal-privacy-hook/deployments/latest.json`), 'utf8')
    );
    universalHookAddress = hookDeployment.universalPrivacyHook;
    console.log("Found UniversalPrivacyHook deployment at:", universalHookAddress);
} catch (e) {
    console.error("UniversalPrivacyHook deployment file not found!");
    console.error("Please run the deployment script in universal-privacy-hook");
    process.exit(1);
}

// Load ABIs
const SwapManagerABI = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../abis/SwapManager.json'), 'utf8'));
// Load UniversalPrivacyHook ABI from the compiled output
const UniversalHookArtifact = JSON.parse(
    fs.readFileSync(path.resolve(__dirname, '../../universal-privacy-hook/out/UniversalPrivacyHook.sol/UniversalPrivacyHook.json'), 'utf8')
);
const UniversalHookABI = UniversalHookArtifact.abi;

// We'll use the actual deployed tokens instead of mock addresses

// SwapIntent structure
// { tokenIn, tokenOut, amount, description }

// Test swap intents will be defined after we have the actual token addresses
let testIntents = [];

async function encryptAmount(amount) {
    try {
        console.log(`Encrypting amount using CoFHE.js: ${amount}`);

        // Use real CoFHE.js encryption
        const encResult = await cofhejs.encrypt([Encryptable.uint128(amount)]);

        if (!encResult.success) {
            throw new Error(`Encryption failed: ${encResult.error?.message || 'Unknown error'}`);
        }

        const encryptedHandle = encResult.data[0];
        console.log(`Encrypted to FHE handle:`, encryptedHandle);

        // Return the full encrypted handle for UniversalPrivacyHook
        return encryptedHandle;
    } catch (error) {
        console.error("Error encrypting amount:", error);
        throw error;
    }
}

async function submitEncryptedIntent(
    universalHook,
    poolKey,
    intent
) {
    console.log(`\n=== Submitting Encrypted Intent ===`);
    console.log(`Description: ${intent.description}`);
    console.log(`Token In: ${intent.tokenIn}`);
    console.log(`Token Out: ${intent.tokenOut}`);
    console.log(`Amount: ${intent.amount.toString()}`);

    try {
        // Encrypt the amount using real FHE
        const encryptedHandle = await encryptAmount(intent.amount);

        // For UniversalPrivacyHook, we need to pass the full encrypted struct
        const encryptedAmount = {
            ctHash: encryptedHandle.ctHash,
            securityZone: encryptedHandle.securityZone || 0,
            utype: encryptedHandle.utype || 6,
            signature: encryptedHandle.signature || ('0x' + '00'.repeat(65))
        };

        const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600); // 1 hour from now

        // Get current nonce and gas price to avoid estimation issues
        const nonce = await wallet.getNonce();
        const feeData = await provider.getFeeData();

        // Submit the encrypted intent to UniversalPrivacyHook
        console.log("Calling submitIntent with:");
        console.log("  poolKey:", poolKey);
        console.log("  tokenIn:", intent.tokenIn);
        console.log("  tokenOut:", intent.tokenOut);
        console.log("  encryptedAmount:", encryptedAmount);
        console.log("  deadline:", deadline);

        const tx = await universalHook.submitIntent(
            poolKey,
            intent.tokenIn,
            intent.tokenOut,
            encryptedAmount,
            deadline,
            {
                nonce: nonce,
                gasLimit: 5000000,
                gasPrice: feeData.gasPrice
            }
        );
        
        console.log(`Transaction submitted: ${tx.hash}`);
        const receipt = await tx.wait();
        
        // Parse events from the receipt
        const intentSubmittedEvent = receipt.logs.find((log) => {
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
    
    // Check if UniversalHook is deployed
    if (!universalHookAddress) {
        console.error("UniversalPrivacyHook not deployed.");
        process.exit(1);
    }

    // Load token addresses from deployment
    const hookDeployment = JSON.parse(
        fs.readFileSync(path.resolve(__dirname, `../../universal-privacy-hook/deployments/latest.json`), 'utf8')
    );
    const tokenA = hookDeployment.tokenA;
    const tokenB = hookDeployment.tokenB;

    console.log("TokenA:", tokenA);
    console.log("TokenB:", tokenB);

    // First, mint tokens and deposit them to the hook for liquidity
    console.log("\n💰 Setting up liquidity in the hook...");

    const mockERC20ABI = [
        'function mint(address to, uint256 amount) external',
        'function approve(address spender, uint256 amount) external returns (bool)',
        'function balanceOf(address account) external view returns (uint256)'
    ];

    const tokenAContract = new ethers.Contract(tokenA, mockERC20ABI, wallet);
    const tokenBContract = new ethers.Contract(tokenB, mockERC20ABI, wallet);

    // Mint tokens
    const mintAmount = ethers.parseUnits('10000', 18);
    console.log("Minting tokens...");
    try {
        await (await tokenAContract.mint(wallet.address, mintAmount)).wait();
        await (await tokenBContract.mint(wallet.address, mintAmount)).wait();
        console.log("✅ Tokens minted");
    } catch (e) {
        console.log("Token minting skipped (may already have balance)");
    }

    // Create PoolKey for UniversalPrivacyHook
    const [currency0, currency1] = tokenA.toLowerCase() < tokenB.toLowerCase()
        ? [tokenA, tokenB]
        : [tokenB, tokenA];

    const poolKey = {
        currency0: currency0,
        currency1: currency1,
        fee: 3000, // 0.3% fee
        tickSpacing: 60,
        hooks: universalHookAddress
    };

    console.log("PoolKey:", poolKey);

    // Approve and deposit to hook
    const depositAmount = ethers.parseUnits('1000', 18);
    console.log("Depositing tokens to hook...");

    await (await tokenAContract.approve(universalHookAddress, depositAmount)).wait();
    await (await universalHook.deposit(poolKey, tokenA, depositAmount)).wait();
    console.log("✅ Deposited tokenA to hook");

    await (await tokenBContract.approve(universalHookAddress, depositAmount)).wait();
    await (await universalHook.deposit(poolKey, tokenB, depositAmount)).wait();
    console.log("✅ Deposited tokenB to hook");

    // Define test intents using actual tokens
    testIntents = [
        // A->B swaps
        {
            tokenIn: tokenA,
            tokenOut: tokenB,
            amount: BigInt(100 * 1e18), // 100 tokenA
            description: "User A: Swap 100 tokenA to tokenB"
        },
        // B->A swap (opposite direction)
        {
            tokenIn: tokenB,
            tokenOut: tokenA,
            amount: BigInt(50 * 1e18), // 50 tokenB
            description: "User B: Swap 50 tokenB to tokenA (opposite direction)"
        },
        // Another A->B swap
        {
            tokenIn: tokenA,
            tokenOut: tokenB,
            amount: BigInt(75 * 1e18), // 75 tokenA
            description: "User C: Swap 75 tokenA to tokenB"
        },
    ];

    // Initialize contracts
    console.log("Initializing contracts...");
    console.log("UniversalHookABI functions:", UniversalHookABI.filter((x) => x.type === 'function').map((x) => x.name));

    const universalHook = new ethers.Contract(universalHookAddress, UniversalHookABI, wallet);
    console.log("UniversalHook contract initialized");
    console.log("Has submitIntent?", typeof universalHook.submitIntent);

    const swapManager = new ethers.Contract(avsDeploymentData.addresses.SwapManager, SwapManagerABI, wallet);

    // Check if UniversalHook is authorized
    const isAuthorized = await swapManager.authorizedHooks(universalHookAddress);
    console.log(`UniversalHook authorized in SwapManager: ${isAuthorized}`);
    
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
    const submittedIntentIds = [];
    
    for (let i = 0; i < testIntents.length; i++) {
        const intentId = await submitEncryptedIntent(universalHook, poolKey, testIntents[i]);
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

    // Wait for block interval to pass, then submit one more intent to trigger finalization
    console.log("\n⏳ Waiting for 6 blocks to pass before submitting trigger intent...");

    for (let i = 0; i < 6; i++) {
        await provider.send('evm_mine', []);
        const currentBlock = await provider.getBlockNumber();
        console.log(`Mined block ${currentBlock}`);
    }

    console.log("\n📝 Submitting trigger intent to finalize batch...");

    // Submit one more intent to trigger batch finalization
    const triggerIntent = {
        tokenIn: tokenB,
        tokenOut: tokenA,
        amount: BigInt(25 * 1e18), // 25 tokenB
        description: "User D: Trigger intent - Swap 25 tokenB to tokenA"
    };

    const triggerId = await submitEncryptedIntent(universalHook, poolKey, triggerIntent);
    if (triggerId) {
        submittedIntentIds.push(triggerId);
        console.log("✅ Trigger intent submitted - batch should finalize now!");
    }

    console.log("\n🎯 Batch should be finalized and picked up by operator.");
    console.log("Operators are monitoring for BatchFinalized events from SwapManager.");
    
    // Monitor for batch settlement events
    console.log("\nMonitoring for batch settlements...");
    
    swapManager.on("BatchSettlementSubmitted", (batchId, internalizedCount, netSwapCount) => {
        console.log(`\n📨 Batch ${batchId} settlement submitted!`);
        console.log(`   Internalized transfers: ${internalizedCount}`);
        console.log(`   Net swaps: ${netSwapCount}`);
    });
    
    swapManager.on("BatchSettled", (batchId, success) => {
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