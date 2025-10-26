import { ethers } from "ethers";
import * as dotenv from "dotenv";
import { initializeCofhe, batchDecrypt, batchEncrypt, FheTypes, CoFheItem, EncryptionInput } from "./cofheUtils";
import { simulate, DecryptedNode } from "./utils/strategySimulator";
import { getProtocolFunction, getFunctionFromSelector, initializeProtocolAddresses } from "./utils/protocolMapping";
import { saveStrategy, StrategyNode } from "./epochDatabase";
const fs = require('fs');
const path = require('path');
dotenv.config();

/**
 * Parse decrypted value based on FHE type
 */
function parseDecryptedValue(value: bigint, utype: number): any {
    if (utype === FheTypes.Bool) {
        return Boolean(value);
    } else if (utype === FheTypes.Uint8 || utype === FheTypes.Uint16 ||
               utype === FheTypes.Uint32 || utype === FheTypes.Uint64) {
        return Number(value);
    } else if (utype === FheTypes.Uint128 || utype === FheTypes.Uint256) {
        return value; // Keep as bigint for large numbers
    } else if (utype === FheTypes.Uint160 || utype === FheTypes.Address) {
        return '0x' + value.toString(16).padStart(40, '0');
    } else {
        return value;
    }
}

// Check if the process.env object is empty
if (!Object.keys(process.env).length) {
    throw new Error("process.env object is empty");
}

// Setup env variables
const provider = new ethers.JsonRpcProvider(process.env.RPC_URL, undefined, { staticNetwork: true });
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY!, provider);

console.log(`Using RPC: ${process.env.RPC_URL}`);
console.log(`Operator Address: ${wallet.address}`);

// Global variables that will be initialized in main()
let chainId: number;
let delegationManagerAddress: string;
let avsDirectoryAddress: string;
let tradeManagerAddress: string;
let ecdsaStakeRegistryAddress: string;
let delegationManager: ethers.Contract;
let tradeManager: ethers.Contract;
let ecdsaRegistryContract: ethers.Contract;
let avsDirectory: ethers.Contract;

// Get chain ID from provider
async function getChainId(): Promise<number> {
    const network = await provider.getNetwork();
    return Number(network.chainId);
}

// Initialize all contracts and addresses
async function initializeContracts() {
    chainId = await getChainId();
    console.log(`Chain ID: ${chainId}`);

    // Initialize protocol addresses from mock deployment
    initializeProtocolAddresses(chainId);

    const avsDeploymentData = JSON.parse(fs.readFileSync(path.resolve(__dirname, `../contracts/deployments/trade-manager/${chainId}.json`), 'utf8'));
    // Load core deployment data
    const coreDeploymentData = JSON.parse(fs.readFileSync(path.resolve(__dirname, `../contracts/deployments/core/${chainId}.json`), 'utf8'));

    delegationManagerAddress = coreDeploymentData.addresses.delegationManager;
    avsDirectoryAddress = coreDeploymentData.addresses.avsDirectory;
    tradeManagerAddress = avsDeploymentData.addresses.tradeManager || avsDeploymentData.addresses.TradeManager;
    ecdsaStakeRegistryAddress = avsDeploymentData.addresses.stakeRegistry;

    // Load ABIs
    const delegationManagerABI = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../abis/IDelegationManager.json'), 'utf8'));
    const ecdsaRegistryABI = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../abis/ECDSAStakeRegistry.json'), 'utf8'));
    const tradeManagerABI = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../abis/TradeManager.json'), 'utf8'));
    const avsDirectoryABI = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../abis/IAVSDirectory.json'), 'utf8'));

    // Initialize contract objects from ABIs
    delegationManager = new ethers.Contract(delegationManagerAddress, delegationManagerABI, wallet);
    tradeManager = new ethers.Contract(tradeManagerAddress, tradeManagerABI, wallet);
    ecdsaRegistryContract = new ethers.Contract(ecdsaStakeRegistryAddress, ecdsaRegistryABI, wallet);
    avsDirectory = new ethers.Contract(avsDirectoryAddress, avsDirectoryABI, wallet);
}

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

        // Calculate the digest hash
        const operatorDigestHash = await avsDirectory.calculateOperatorAVSRegistrationDigestHash(
            wallet.address,
            await tradeManager.getAddress(),
            salt,
            expiry
        );

        // Sign the digest hash with the operator's private key
        const privateKey = process.env.PRIVATE_KEY!.startsWith('0x')
            ? process.env.PRIVATE_KEY!
            : '0x' + process.env.PRIVATE_KEY!;
        const operatorSigningKey = new ethers.SigningKey(privateKey);
        const operatorSignedDigestHash = operatorSigningKey.sign(operatorDigestHash);

        // Encode the signature in the required format
        operatorSignatureWithSaltAndExpiry.signature = ethers.Signature.from(operatorSignedDigestHash).serialized;

        console.log("Registering Operator to AVS Registry contract");

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

    // Register with TradeManager
    try {
        const isAlreadyRegistered = await tradeManager.isOperatorRegistered(wallet.address);
        if (isAlreadyRegistered) {
            console.log("Operator already registered with TradeManager");
        } else {
            console.log("Registering operator with TradeManager...");
            const nonce3 = await wallet.getNonce();
            const tx3 = await tradeManager.registerOperator({ nonce: nonce3 });
            await tx3.wait();
            console.log("Operator successfully registered with TradeManager");
        }

        // Verify registration
        const isRegistered = await tradeManager.isOperatorRegistered(wallet.address);
        console.log(`Operator registration verified: ${isRegistered}`);
    } catch (error: any) {
        console.error("Error registering with TradeManager:", error.message);
    }
};

// Structure for strategy submission event
interface StrategySubmission {
    epochNumber: bigint;
    submitter: string;
    nodeCount: bigint;
    submittedAt: bigint;
    targetChainIdHandle: bigint;
}

/**
 * Process a submitted strategy: decrypt, simulate, and report APY
 */
const processStrategy = async (submission: StrategySubmission) => {
    try {
        console.log(`\n=== Processing Strategy ===`);
        console.log(`Epoch: ${submission.epochNumber}`);
        console.log(`Submitter: ${submission.submitter}`);
        console.log(`Nodes: ${submission.nodeCount}`);

        // Step 1: Fetch strategy nodes from contract
        const nodeCount = Number(submission.nodeCount);
        const encryptedHandles: CoFheItem[] = [];
        const nodeStructures: any[] = [];

        for (let i = 0; i < nodeCount; i++) {
            const node = await tradeManager.getStrategyNode(
                submission.epochNumber,
                submission.submitter,
                i
            );

            nodeStructures.push(node);

            // Collect all handles for batch decryption
            // encoder (address), target (address), selector (uint32), args (dynamic)
            encryptedHandles.push({
                ctHash: BigInt(node.encoderHandle),
                securityZone: 0,
                utype: FheTypes.Uint160,
                signature: '0x'
            });
            encryptedHandles.push({
                ctHash: BigInt(node.targetHandle),
                securityZone: 0,
                utype: FheTypes.Uint160,
                signature: '0x'
            });
            encryptedHandles.push({
                ctHash: BigInt(node.selectorHandle),
                securityZone: 0,
                utype: FheTypes.Uint32,
                signature: '0x'
            });

            // Add arg handles
            for (const arg of node.argHandles) {
                encryptedHandles.push({
                    ctHash: BigInt(arg.handle),
                    securityZone: 0,
                    utype: arg.utype,
                    signature: '0x'
                });
            }
        }

        if (submission.targetChainIdHandle && submission.targetChainIdHandle !== 0n) {
            encryptedHandles.push({
                ctHash: BigInt(submission.targetChainIdHandle),
                securityZone: 0,
                utype: FheTypes.Uint32,
                signature: '0x'
            });
        }

        console.log(`\nBatch decrypting ${encryptedHandles.length} FHE values...`);

        // Step 2: Batch decrypt all handles
        const decryptedValues = await batchDecrypt(encryptedHandles);

        // Step 3: Parse decrypted values into DecryptedNode format
        const decryptedNodes: DecryptedNode[] = [];
        const dbNodes: StrategyNode[] = []; // For database storage
        let valueIdx = 0;

        for (let i = 0; i < nodeCount; i++) {
            const node = nodeStructures[i];

            // Parse encoder, target, selector using type-aware parsing
            const encoder = parseDecryptedValue(decryptedValues[valueIdx++], FheTypes.Uint160) as string;
            const target = parseDecryptedValue(decryptedValues[valueIdx++], FheTypes.Uint160) as string;
            const selectorValue = decryptedValues[valueIdx++];
            const selector = '0x' + selectorValue.toString(16).padStart(8, '0');

            // Map protocol and function name from target address and selector
            const funcInfo = getProtocolFunction(target, selector);
            const { protocol, functionName } = funcInfo;

            // Parse args based on their utypes and map to semantic names
            const args: any = {};
            const dbArgs: any[] = []; // Raw args for database
            const argTypes: number[] = []; // Arg types for database

            for (let j = 0; j < node.argHandles.length; j++) {
                const argValue = decryptedValues[valueIdx++];
                const argType = node.argHandles[j].utype;
                const parsedValue = parseDecryptedValue(argValue, argType);

                // Store with both positional and semantic name
                args[`arg${j}`] = parsedValue;

                // Save for database (needed for calldata reconstruction)
                dbArgs.push(parsedValue);
                argTypes.push(argType);

                // Get semantic name from protocolMapping if available
                const funcDetails = getFunctionFromSelector(selector);
                if (funcDetails && funcDetails.argNames && funcDetails.argNames[j]) {
                    const argName = funcDetails.argNames[j];
                    args[argName] = parsedValue;
                    console.log(`    Arg[${j}] (${argName}): utype=${argType}, value=${parsedValue}`);
                } else {
                    console.log(`    Arg[${j}]: utype=${argType}, value=${parsedValue}`);
                }
            }

            console.log(`\nDecrypted Node ${i}:`);
            console.log(`  Encoder: ${encoder}`);
            console.log(`  Target: ${target}`);
            console.log(`  Selector: ${selector}`);
            console.log(`  Protocol: ${protocol}`);
            console.log(`  Function: ${functionName}`);
            console.log(`  Args:`, args);

            // Add to simulation format
            decryptedNodes.push({
                protocol,
                functionName,
                target,
                args
            });

            // Add to database format (for calldata reconstruction)
            dbNodes.push({
                encoder,
                target,
                selector,
                args: dbArgs,
                argTypes
            });
        }

        // Extract target chain id (appended at end of encryptedHandles)
        const targetChainIdValue = Number(
            parseDecryptedValue(
                decryptedValues[valueIdx++],
                FheTypes.Uint32
            )
        );
        console.log(`\nTarget Chain ID (decrypted): ${targetChainIdValue}`);

        // Step 4: Get epoch config for initial capital
        const epoch = await tradeManager.epochs(submission.epochNumber);
        const initialCapital = epoch.notionalPerTrader;
        console.log(`\nInitial Capital (from epoch): ${initialCapital}`);

        // Step 5: Simulate strategy and calculate APY
        const simulatedAPY = simulate(chainId, decryptedNodes, initialCapital);
        console.log(`Calculated APY: ${simulatedAPY / 100}% (${simulatedAPY} bps)`);

        // Clamp negative APYs to 0 (FHE doesn't support negative numbers)
        const clampedAPY = Math.max(0, simulatedAPY);
        if (simulatedAPY < 0) {
            console.log(`⚠️ Negative APY detected (${simulatedAPY} bps), clamping to 0 for encryption and storage`);
        }

        // Save to local database for later use (use clamped APY)
        console.log("Saving strategy to local database...");
        saveStrategy(
            Number(submission.epochNumber),
            submission.submitter,
            dbNodes,
            clampedAPY, // Save clamped APY, not negative one
            Number(submission.submittedAt),
            targetChainIdValue
        );

        // Encrypt the APY using CoFHE.js
        console.log("Encrypting APY...");
        const apyInput: EncryptionInput[] = [{
            value: BigInt(clampedAPY),
            type: FheTypes.Uint16
        }];

        const encryptedAPYs = await batchEncrypt(
            apyInput,
            submission.submitter, // userAddress (trader who owns the APY)
            tradeManagerAddress  // contractAddress
        );

        const encryptedAPY = encryptedAPYs[0];

        // Report encrypted APY to TradeManager
        console.log("Reporting encrypted APY to TradeManager...");
        const nonce = await wallet.getNonce();
        const tx = await tradeManager.reportEncryptedAPY(
            submission.epochNumber,
            submission.submitter,
            {
                ctHash: encryptedAPY.ctHash,
                securityZone: encryptedAPY.securityZone,
                utype: encryptedAPY.utype,
                signature: encryptedAPY.signature
            },
            { nonce }
        );

        console.log(`APY report transaction: ${tx.hash}`);
        const receipt = await tx.wait();
        console.log(`APY report confirmed in block ${receipt.blockNumber}`);

    } catch (error) {
        console.error(`Error processing strategy for ${submission.submitter}:`, error);
    }
};

/**
 * Monitor for strategy submissions and process them
 */
const monitorStrategies = async () => {
    console.log("\n✅ Monitoring for strategy submissions...");

    let lastProcessedBlock = await provider.getBlockNumber();
    const processedSubmissions = new Set<string>();

    // Get current epoch number
    const currentEpochNumber = await tradeManager.currentEpochNumber();
    console.log(`Current epoch: ${currentEpochNumber}`);

    // Query past StrategySubmitted events for CURRENT EPOCH ONLY
    try {
        const filter = tradeManager.filters.StrategySubmitted();
        const fromBlock = Math.max(0, lastProcessedBlock - 1000);
        const events = await tradeManager.queryFilter(filter, fromBlock, lastProcessedBlock);

        if (events.length > 0) {
            console.log(`Found ${events.length} past StrategySubmitted events`);
            for (const event of events) {
                const parsedLog = tradeManager.interface.parseLog({
                    topics: event.topics as string[],
                    data: event.data
                });
                if (parsedLog) {
                    const submission: StrategySubmission = {
                        epochNumber: parsedLog.args[0],
                        submitter: parsedLog.args[1],
                        nodeCount: parsedLog.args[2],
                        submittedAt: parsedLog.args[3],
                        targetChainIdHandle: parsedLog.args[4]
                    };

                    // Only process strategies from the current epoch
                    if (submission.epochNumber === currentEpochNumber) {
                        const key = `${submission.epochNumber}-${submission.submitter}`;
                        console.log(`  Past strategy (current epoch): Epoch ${submission.epochNumber}, Submitter: ${submission.submitter}`);

                        processedSubmissions.add(key);
                        // Process the past strategy!
                        await processStrategy(submission);
                    } else {
                        console.log(`  Skipping past epoch ${submission.epochNumber} (current: ${currentEpochNumber})`);
                    }
                }
            }
        } else {
            console.log("No past StrategySubmitted events found");
        }
    } catch (error) {
        console.error("Error querying past events:", error);
    }

    // Use polling for new events
    console.log("Starting event polling...");
    setInterval(async () => {
        try {
            const currentBlock = await provider.getBlockNumber();

            if (currentBlock > lastProcessedBlock) {
                const filter = tradeManager.filters.StrategySubmitted();
                const events = await tradeManager.queryFilter(filter, lastProcessedBlock + 1, currentBlock);

                for (const event of events) {
                    const parsedLog = tradeManager.interface.parseLog({
                        topics: event.topics as string[],
                        data: event.data
                    });

                    if (parsedLog) {
                        const submission: StrategySubmission = {
                            epochNumber: parsedLog.args[0],
                            submitter: parsedLog.args[1],
                            nodeCount: parsedLog.args[2],
                            submittedAt: parsedLog.args[3],
                            targetChainIdHandle: parsedLog.args[4]
                        };

                        const key = `${submission.epochNumber}-${submission.submitter}`;

                        if (!processedSubmissions.has(key)) {
                            console.log(`\n🚀 New strategy detected!`);
                            console.log(`  Epoch: ${submission.epochNumber}`);
                            console.log(`  Submitter: ${submission.submitter}`);
                            console.log(`  Block: ${event.blockNumber}`);

                            processedSubmissions.add(key);
                            await processStrategy(submission);
                        }
                    }
                }

                lastProcessedBlock = currentBlock;
            }
        } catch (error) {
            console.error("Error in polling:", error);
        }
    }, 5000); // Poll every 5 seconds
};

const main = async () => {
    console.log("\n🎯 CipherTradeArena Operator Starting...\n");

    // Initialize contracts and load deployment configuration
    await initializeContracts();

    // Initialize CoFHE.js for FHE operations
    await initializeCofhe(wallet);

    // Register as operator
    await registerOperator();

    // Monitor for strategy submissions
    await monitorStrategies();
};

main().catch((error) => {
    console.error("Error in main function:", error);
});
