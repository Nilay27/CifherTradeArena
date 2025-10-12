import { ethers } from "ethers";
import * as dotenv from "dotenv";
import { initializeCofheJs, batchDecryptAmounts, encryptAmount } from "./cofheUtils";
import { initializeUEIProcessor, processUEI, monitorUEIEvents, decodeUEIBlob, reconstructCalldata } from './ueiProcessor';
const fs = require('fs');
const path = require('path');
dotenv.config();

// Check if the process.env object is empty
if (!Object.keys(process.env).length) {
    throw new Error("process.env object is empty");
}

// Setup env variables
const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY!, provider);
/// TODO: Hack
let chainId = 31337;

const avsDeploymentData = JSON.parse(fs.readFileSync(path.resolve(__dirname, `../contracts/deployments/swap-manager/${chainId}.json`), 'utf8'));
// Load core deployment data
const coreDeploymentData = JSON.parse(fs.readFileSync(path.resolve(__dirname, `../contracts/deployments/core/${chainId}.json`), 'utf8'));


const delegationManagerAddress = coreDeploymentData.addresses.delegationManager; // todo: reminder to fix the naming of this contract in the deployment file, change to delegationManager
const avsDirectoryAddress = coreDeploymentData.addresses.avsDirectory;
const SwapManagerAddress = avsDeploymentData.addresses.SwapManager;
const ecdsaStakeRegistryAddress = avsDeploymentData.addresses.stakeRegistry;



// Load ABIs
const delegationManagerABI = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../abis/IDelegationManager.json'), 'utf8'));
const ecdsaRegistryABI = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../abis/ECDSAStakeRegistry.json'), 'utf8'));
const SwapManagerABI = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../abis/SwapManager.json'), 'utf8'));
const avsDirectoryABI = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../abis/IAVSDirectory.json'), 'utf8'));

// Initialize contract objects from ABIs
const delegationManager = new ethers.Contract(delegationManagerAddress, delegationManagerABI, wallet);
const SwapManager = new ethers.Contract(SwapManagerAddress, SwapManagerABI, wallet);
const ecdsaRegistryContract = new ethers.Contract(ecdsaStakeRegistryAddress, ecdsaRegistryABI, wallet);
const avsDirectory = new ethers.Contract(avsDirectoryAddress, avsDirectoryABI, wallet);



const registerOperator = async () => {

    // Registers as an Operator in EigenLayer.
    try {
        const nonce = await wallet.getNonce();
        const tx1 = await delegationManager.registerAsOperator(
            "0x0000000000000000000000000000000000000000", // initDelegationApprover
            0, // allocationDelay
            "", // metadataURI
            { nonce }
        );
        await tx1.wait();
        console.log("Operator registered to Core EigenLayer contracts");
    } catch (error: any) {
        if (error.data === "0x77e56a06") {
            console.log("Operator already registered to Core EigenLayer contracts");
        } else {
            console.error("Error in registering as operator:", error);
        }
    }

    try {
        const salt = ethers.hexlify(ethers.randomBytes(32));
        const expiry = Math.floor(Date.now() / 1000) + 3600; // Example expiry, 1 hour from now

        // Define the output structure
        let operatorSignatureWithSaltAndExpiry = {
            signature: "",
            salt: salt,
            expiry: expiry
        };

        // Calculate the digest hash, which is a unique value representing the operator, avs, unique value (salt) and expiration date.
        const operatorDigestHash = await avsDirectory.calculateOperatorAVSRegistrationDigestHash(
            wallet.address,
            await SwapManager.getAddress(),
            salt,
            expiry
        );
        console.log(operatorDigestHash);

        // Sign the digest hash with the operator's private key
        console.log("Signing digest hash with operator's private key");
        const operatorSigningKey = new ethers.SigningKey(process.env.PRIVATE_KEY!);
        const operatorSignedDigestHash = operatorSigningKey.sign(operatorDigestHash);

        // Encode the signature in the required format
        operatorSignatureWithSaltAndExpiry.signature = ethers.Signature.from(operatorSignedDigestHash).serialized;

        console.log("Registering Operator to AVS Registry contract");

        // Register Operator to AVS
        // Per release here: https://github.com/Layr-Labs/eigenlayer-middleware/blob/v0.2.1-mainnet-rewards/src/unaudited/ECDSAStakeRegistry.sol#L49
        const nonce2 = await wallet.getNonce();
        const tx2 = await ecdsaRegistryContract.registerOperatorWithSignature(
            operatorSignatureWithSaltAndExpiry,
            wallet.address,
            { nonce: nonce2 }
        );
        await tx2.wait();
        console.log("Operator registered on AVS successfully");
    } catch (error: any) {
        if (error.data === "0x42ee68b5" || error.code === "BAD_DATA") {
            console.log("Operator may already be registered on AVS or AVS not properly initialized");
        } else {
            console.error("Error registering operator on AVS:", error);
        }
    }
    
    // Register with SwapManager for batch processing
    try {
        // Check if already registered first
        const isAlreadyRegistered = await SwapManager.isOperatorRegistered(wallet.address);
        if (isAlreadyRegistered) {
            console.log("Operator already registered for batch processing");
        } else {
            console.log("Registering operator for batch processing...");
            const nonce3 = await wallet.getNonce();
            const tx3 = await SwapManager.registerOperatorForBatches({ nonce: nonce3 });
            await tx3.wait();
            console.log("Operator successfully registered for batch processing");
        }
        
        // Verify registration
        const isRegistered = await SwapManager.isOperatorRegistered(wallet.address);
        console.log(`Operator registration verified: ${isRegistered}`);
    } catch (error: any) {
        console.error("Error registering for batches:");
        console.error("Message:", error.message);
        if (error.reason) console.error("Reason:", error.reason);
        if (error.data) console.error("Data:", error.data);
        
        // Check if it's because not registered with stake registry
        try {
            const isRegisteredWithStake = await ecdsaRegistryContract.operatorRegistered(wallet.address);
            console.error(`Registered with ECDSAStakeRegistry: ${isRegisteredWithStake}`);
        } catch (e) {
            console.error("Could not check stake registry status");
        }
    }
};

// Structure to hold intent details
interface Intent {
    intentId: string;
    user: string;
    tokenIn: string;
    tokenOut: string;
    encryptedAmount: string;
    decryptedAmount?: bigint;
}

// Structure for matched trades
interface InternalizedTransfer {
    intentIdA: string;
    intentIdB: string;
    userA: string;
    userB: string;
    tokenA: string;
    tokenB: string;
    amountA: bigint;
    amountB: bigint;
    encryptedAmountA: string;  // Keep encrypted amounts for privacy
    encryptedAmountB: string;  // Keep encrypted amounts for privacy
}

// Structure for net swap
interface NetSwap {
    tokenIn: string;
    tokenOut: string;
    netAmount: bigint;
    remainingIntents: string[];
}

// FIFO matching algorithm based on Python implementation
const matchIntents = (intents: Intent[]): { internalized: InternalizedTransfer[], netSwaps: Map<string, NetSwap> } => {
    console.log(`\n=== Starting FIFO Order Matching ===`);
    console.log(`Processing ${intents.length} intents`);
    
    const internalized: InternalizedTransfer[] = [];
    const unmatchedByPair = new Map<string, Intent[]>();
    
    // Group intents by trading pair
    for (const intent of intents) {
        const pair = `${intent.tokenIn}->${intent.tokenOut}`;
        const reversePair = `${intent.tokenOut}->${intent.tokenIn}`;
        
        // Check if there's a matching intent in the opposite direction
        const reverseQueue = unmatchedByPair.get(reversePair) || [];
        
        if (reverseQueue.length > 0) {
            // Match with first intent in reverse queue (FIFO)
            const matchedIntent = reverseQueue[0];
            const matchAmount = intent.decryptedAmount! < matchedIntent.decryptedAmount! 
                ? intent.decryptedAmount! 
                : matchedIntent.decryptedAmount!;
            
            // Create internalized transfer (encrypted amounts will be added later)
            internalized.push({
                intentIdA: matchedIntent.intentId,
                intentIdB: intent.intentId,
                userA: matchedIntent.user,
                userB: intent.user,
                tokenA: matchedIntent.tokenIn,
                tokenB: intent.tokenIn,
                amountA: matchAmount,
                amountB: matchAmount,
                encryptedAmountA: "",  // Will be encrypted during settlement preparation
                encryptedAmountB: ""   // Will be encrypted during settlement preparation
            });
            
            console.log(`Matched: ${matchedIntent.user} <-> ${intent.user} for ${matchAmount}`);
            
            // Update or remove matched intent
            matchedIntent.decryptedAmount! -= matchAmount;
            if (matchedIntent.decryptedAmount! === 0n) {
                reverseQueue.shift();
            }
            
            // Update current intent
            intent.decryptedAmount! -= matchAmount;
            
            // If intent still has remaining amount, add to unmatched
            if (intent.decryptedAmount! > 0n) {
                if (!unmatchedByPair.has(pair)) {
                    unmatchedByPair.set(pair, []);
                }
                unmatchedByPair.get(pair)!.push(intent);
            }
        } else {
            // No match found, add to unmatched queue
            if (!unmatchedByPair.has(pair)) {
                unmatchedByPair.set(pair, []);
            }
            unmatchedByPair.get(pair)!.push(intent);
        }
    }
    
    // Calculate net swaps for remaining unmatched intents
    const netSwaps = new Map<string, NetSwap>();
    for (const [pair, unmatched] of unmatchedByPair.entries()) {
        if (unmatched.length > 0) {
            const [tokenIn, tokenOut] = pair.split('->');
            const totalAmount = unmatched.reduce((sum, intent) => sum + intent.decryptedAmount!, 0n);
            
            netSwaps.set(pair, {
                tokenIn,
                tokenOut,
                netAmount: totalAmount,
                remainingIntents: unmatched.map(i => i.intentId)
            });
            
            console.log(`Net swap needed: ${pair} - Amount: ${totalAmount}`);
        }
    }
    
    console.log(`Matching complete: ${internalized.length} internalized, ${netSwaps.size} net swaps`);
    return { internalized, netSwaps };
};

const processBatch = async (batchId: string, batchData: any) => {
    try {
        console.log(`\n=== Processing Batch ${batchId} ===`);
        
        // Decode batch data to get intent IDs
        const [intentIds] = ethers.AbiCoder.defaultAbiCoder().decode(
            ["bytes32[]", "address"],
            batchData
        );
        
        console.log(`Batch contains ${intentIds.length} intents`);
        
        // For this mock, we need to fetch intent details from MockPrivacyHook
        // In production, this would come from the batch data or be queried
        const intents: Intent[] = [];
        
        // Fetch intent details from UniversalPrivacyHook contract
        // First try to load UniversalPrivacyHook address, fallback to MockPrivacyHook
        let hookAddress: string;
        let isUniversalHook = false;

        try {
            // Try to load UniversalPrivacyHook deployment
            const universalHookDeployment = JSON.parse(
                fs.readFileSync(path.resolve(__dirname, `../../universal-privacy-hook/deployments/latest.json`), 'utf8')
            );
            if (universalHookDeployment.universalPrivacyHook) {
                hookAddress = universalHookDeployment.universalPrivacyHook;
                isUniversalHook = true;
                console.log(`Using UniversalPrivacyHook at: ${hookAddress}`);
            } else {
                throw new Error("UniversalPrivacyHook not found");
            }
        } catch (e) {
            // Fallback to MockPrivacyHook
            const mockHookDeployment = JSON.parse(
                fs.readFileSync(path.resolve(__dirname, `../contracts/deployments/mock-hook/${chainId}.json`), 'utf8')
            );
            hookAddress = mockHookDeployment.addresses.mockPrivacyHook;
            console.log(`Using MockPrivacyHook at: ${hookAddress}`);
        }

        if (!hookAddress) {
            console.error("No hook address found in deployment");
            return;
        }

        // Load the appropriate ABI based on which hook we're using
        let hookABI;
        if (isUniversalHook) {
            // For UniversalPrivacyHook, we need the getIntent function
            // Since we don't have the full ABI, we'll define just what we need
            hookABI = [
                'function getIntent(bytes32) external view returns (address user, address tokenIn, address tokenOut, bytes encryptedAmount)'
            ];
        } else {
            hookABI = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../abis/MockPrivacyHook.json'), 'utf8'));
        }

        const mockHook = new ethers.Contract(hookAddress, hookABI, wallet);
        
        // Fetch and decrypt each intent
        console.log("Fetching and decrypting intents...");
        for (const intentId of intentIds) {
            try {
                const intent = await mockHook.getIntent(intentId);
                intents.push({
                    intentId: intentId,
                    user: intent.user,
                    tokenIn: intent.tokenIn,
                    tokenOut: intent.tokenOut,
                    encryptedAmount: intent.encryptedAmount
                });
            } catch (error) {
                console.error(`Failed to fetch intent ${intentId}:`, error);
            }
        }
        
        // Batch decrypt all amounts using actual FHE decryption
        console.log("\nDecrypting FHE encrypted amounts...");
        const encryptedAmounts = intents.map(i => i.encryptedAmount);
        const decryptedAmounts = await batchDecryptAmounts(encryptedAmounts);
        
        // Assign decrypted amounts to intents
        intents.forEach((intent, index) => {
            intent.decryptedAmount = decryptedAmounts[index];
            console.log(`Intent ${index}: ${intent.user.slice(0,6)}... ${intent.tokenIn}->${intent.tokenOut}: ${intent.decryptedAmount}`);
        });
        
        // Run FIFO matching algorithm
        const { internalized, netSwaps } = matchIntents(intents);
        
        // Prepare settlement data - use arrays instead of objects for ABI encoding
        // For internalized transfers, we need to encrypt the amounts for privacy
        const internalizedTransfers = await Promise.all(internalized.map(async t => {
            // Encrypt amounts for internalized transfers (for transferFromEncrypted)
            const encryptedAmountA = await encryptAmount(t.amountA);
            const encryptedAmountB = await encryptAmount(t.amountB);
            
            return [
                t.intentIdA,
                t.intentIdB,
                t.userA,
                t.userB,
                t.tokenA,
                t.tokenB,
                encryptedAmountA,  // bytes - FHE encrypted for privacy
                encryptedAmountB   // bytes - FHE encrypted for privacy
            ];
        }));
        
        // For simplicity, take the first net swap if exists
        let netSwap: {
            tokenIn: string;
            tokenOut: string;
            netAmount: bigint;
            remainingIntents: string[];
        } = {
            tokenIn: ethers.ZeroAddress,
            tokenOut: ethers.ZeroAddress,
            netAmount: 0n,
            remainingIntents: []
        };
        let hasNetSwap = false;

        if (netSwaps.size > 0) {
            const firstNetSwap = netSwaps.values().next().value;
            if (firstNetSwap) {
                netSwap = firstNetSwap;
                hasNetSwap = true;
            }
        }
        
        // Calculate totals
        const totalInternalized = internalized.reduce((sum, t) => sum + t.amountA + t.amountB, 0n);
        const totalNet = netSwap.netAmount;
        
        // Create settlement object for the contract
        const settlement = {
            batchId: batchId,
            internalizedTransfers: internalizedTransfers,
            netSwap: [netSwap.tokenIn, netSwap.tokenOut, netSwap.netAmount, netSwap.remainingIntents],
            hasNetSwap: hasNetSwap,
            totalInternalized: totalInternalized,
            totalNet: totalNet
        };
        
        // Create message hash and sign - encode as a single tuple
        // TokenTransfer now uses bytes for encrypted amounts instead of uint256
        const messageHash = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
            ["tuple(bytes32,tuple(bytes32,bytes32,address,address,address,address,bytes,bytes)[],tuple(address,address,uint256,bytes32[]),bool,uint256,uint256)"],
            [[
                batchId,
                internalizedTransfers,
                [netSwap.tokenIn, netSwap.tokenOut, netSwap.netAmount, netSwap.remainingIntents],
                hasNetSwap,
                totalInternalized,
                totalNet
            ]]
        ));
        
        const messageBytes = ethers.getBytes(ethers.toBeHex(messageHash, 32));
        const signature = await wallet.signMessage(messageBytes);
        
        console.log(`\nSubmitting settlement with ${internalized.length} internalized transfers...`);
        
        // Get current nonce to avoid conflicts
        const nonce = await wallet.getNonce();
        
        // Submit settlement to SwapManager
        // For testing, send the same signature 3 times to meet MIN_ATTESTATIONS requirement
        const tx = await SwapManager.submitBatchSettlement(
            settlement,
            [signature, signature, signature], // In production, would collect signatures from multiple operators
            { nonce }
        );
        
        await tx.wait();
        console.log(`Successfully submitted settlement for batch ${batchId}`);
        console.log(`Transaction hash: ${tx.hash}`);
        
    } catch (error) {
        console.error(`Error processing batch ${batchId}:`, error);
    }
};

const monitorBatches = async () => {
    // Listen for BatchFinalized events
    SwapManager.on("BatchFinalized", async (batchId: string, batchData: any) => {
        console.log(`\n🚀 New batch detected: ${batchId}`);
        
        // Check if this operator is selected for this batch
        const isSelected = await SwapManager.isOperatorSelectedForBatch(batchId, wallet.address);
        
        if (isSelected) {
            console.log("✅ This operator is selected for the batch!");
            // Process the batch
            await processBatch(batchId, batchData);
        } else {
            console.log("❌ This operator was not selected for this batch");
        }
    });
    
    console.log("Monitoring for new batches...");
    
    // Query past BatchFinalized events
    try {
        const filter = SwapManager.filters.BatchFinalized();
        const currentBlock = await provider.getBlockNumber();
        const fromBlock = Math.max(0, currentBlock - 100);
        const events = await SwapManager.queryFilter(filter, fromBlock, currentBlock);
        
        if (events.length > 0) {
            console.log(`Found ${events.length} past BatchFinalized events in the last 100 blocks`);
            for (const event of events) {
                const parsed = SwapManager.interface.parseLog(event);
                if (parsed) {
                    console.log(`Past batch: ${parsed.args[0]}, Block: ${event.blockNumber}`);
                }
            }
        } else {
            console.log("No past BatchFinalized events found in the last 100 blocks");
        }
    } catch (error) {
        console.error("Error querying past events:", error);
    }
};

const main = async () => {
    // Initialize CoFHE.js for FHE operations
    await initializeCofheJs(wallet);

    // Initialize UEI processor with the same wallet
    await initializeUEIProcessor(wallet);

    await registerOperator();

    // Monitor for swap batches
    monitorBatches().catch((error) => {
        console.error("Error monitoring batches:", error);
    });

    // Monitor for UEI events
    console.log("\n🔍 Starting UEI monitoring...");
    monitorUEIEvents(SwapManager, wallet.address);
};

main().catch((error) => {
    console.error("Error in main function:", error);
});
