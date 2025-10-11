import { ethers } from "ethers";
import * as dotenv from "dotenv";
import { initializeCofheJs, decryptSwapTask } from "./cofheUtils";
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
        const tx1 = await delegationManager.registerAsOperator(
            "0x0000000000000000000000000000000000000000", // initDelegationApprover
            0, // allocationDelay
            "", // metadataURI
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
        const tx2 = await ecdsaRegistryContract.registerOperatorWithSignature(
            operatorSignatureWithSaltAndExpiry,
            wallet.address
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
    
    // Register with SwapManager for task selection
    try {
        // Check if already registered first
        const isAlreadyRegistered = await SwapManager.isOperatorRegistered(wallet.address);
        if (isAlreadyRegistered) {
            console.log("Operator already registered for task selection");
        } else {
            console.log("Registering operator for task selection...");
            const tx3 = await SwapManager.registerOperatorForTasks();
            await tx3.wait();
            console.log("Operator successfully registered for task selection");
        }
        
        // Verify registration
        const isRegistered = await SwapManager.isOperatorRegistered(wallet.address);
        console.log(`Operator registration verified: ${isRegistered}`);
    } catch (error: any) {
        console.error("Error registering for tasks:");
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

const decryptAndRespondToSwapTask = async (taskIndex: number, task: any, taskCreatedBlock: number) => {
    try {
        console.log(`\n=== Processing Swap Task ${taskIndex} ===`);
        
        // Decrypt the swap task to get the actual amount
        const decryptedTask = await decryptSwapTask(task);
        
        console.log(`Decrypted swap details:`);
        console.log(`- User: ${decryptedTask.user}`);
        console.log(`- Token In: ${decryptedTask.tokenIn}`);
        console.log(`- Token Out: ${decryptedTask.tokenOut}`);
        console.log(`- Amount: ${decryptedTask.decryptedAmount}`);
        
        // Calculate swap output (simplified - in real scenario this would involve price calculation)
        // For demo purposes, using a simple 1:1 ratio
        const outputAmount = decryptedTask.decryptedAmount;
        
        console.log(`Calculated output amount: ${outputAmount}`);
        
        // Create the message hash that includes task hash and decrypted amount
        // Create a copy of selectedOperators to avoid read-only array issues
        const selectedOpsCopy = [...task.selectedOperators];
        const taskHash = ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(
            ["address", "address", "address", "address", "bytes", "uint64", "uint32", "address[]"],
            [task.hook, task.user, task.tokenIn, task.tokenOut, task.encryptedAmount, task.deadline, taskCreatedBlock, selectedOpsCopy]
        ));
        
        const messageHash = ethers.keccak256(ethers.solidityPacked(
            ["bytes32", "uint256"],
            [taskHash, decryptedTask.decryptedAmount]
        ));
        
        const messageBytes = ethers.getBytes(messageHash);
        const signature = await wallet.signMessage(messageBytes);
        
        console.log(`Submitting response for task ${taskIndex}...`);
        
        // Prepare the aggregated signature format expected by the contract
        const operators = [wallet.address];
        const signatures = [signature];
        const signedTaskResponse = ethers.AbiCoder.defaultAbiCoder().encode(
            ["address[]", "bytes[]", "uint32"],
            [operators, signatures, taskCreatedBlock]
        );
        
        // Submit the response to the SwapManager
        // Create a new array to avoid read-only array issues
        const selectedOps = [...task.selectedOperators];
        
        const tx = await SwapManager.respondToSwapTask(
            {
                hook: task.hook,
                user: task.user,
                tokenIn: task.tokenIn,
                tokenOut: task.tokenOut,
                encryptedAmount: task.encryptedAmount,
                deadline: task.deadline,
                taskCreatedBlock: taskCreatedBlock,
                selectedOperators: selectedOps
            },
            taskIndex,
            decryptedTask.decryptedAmount,
            signedTaskResponse
        );
        
        await tx.wait();
        console.log(`Successfully responded to task ${taskIndex}`);
        console.log(`Transaction hash: ${tx.hash}`);
        
    } catch (error) {
        console.error(`Error processing swap task ${taskIndex}:`, error);
    }
};

const monitorNewTasks = async () => {
    SwapManager.on("NewSwapTaskCreated", async (taskIndex: number, task: any) => {
        console.log(`New swap task detected: Task ${taskIndex}`);
        console.log(`- User: ${task.user}`);
        console.log(`- TokenIn: ${task.tokenIn}`);
        console.log(`- TokenOut: ${task.tokenOut}`);
        console.log(`- Selected Operators: ${task.selectedOperators}`);
        console.log(`- Task Created Block: ${task.taskCreatedBlock}`);
        
        // Check if this operator is selected for this task
        const isSelected = task.selectedOperators.includes(wallet.address);
        if (isSelected) {
            console.log("This operator is selected for the task!");
            // Decrypt and respond to the swap task
            await decryptAndRespondToSwapTask(taskIndex, task, task.taskCreatedBlock);
        } else {
            console.log("This operator was not selected for this task");
        }
    });

    console.log("Monitoring for new swap tasks...");
};

const main = async () => {
    // Initialize CoFHE.js for FHE operations
    await initializeCofheJs(wallet);
    
    await registerOperator();
    monitorNewTasks().catch((error) => {
        console.error("Error monitoring tasks:", error);
    });
};

main().catch((error) => {
    console.error("Error in main function:", error);
});
