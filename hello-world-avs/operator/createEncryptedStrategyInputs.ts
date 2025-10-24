/**
 * Helper script to create encrypted strategy inputs for testing
 * Usage: ts-node createEncryptedStrategyInputs.ts
 */

import { ethers } from "ethers";
import * as dotenv from "dotenv";
import { initializeCofhe, batchEncrypt, FheTypes, EncryptionInput } from "./cofheUtils";
import { loadMockDeployment, PROTOCOL_FUNCTIONS } from "./utils/protocolMapping";
const fs = require('fs');
const path = require('path');
dotenv.config();

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY!, provider);

async function main() {
    console.log("\n🔐 Creating Encrypted Strategy Inputs\n");

    // Initialize CoFHE.js
    await initializeCofhe(wallet);

    // Load actual deployed addresses based on chain
    const chainId = Number((await provider.getNetwork()).chainId);
    const deployment = loadMockDeployment(chainId);

    // Get Aave functions from protocol mapping
    const aaveSupplyFunc = PROTOCOL_FUNCTIONS.find(
        f => f.protocol === "aave" && f.functionName === "supply"
    );
    const aaveBorrowFunc = PROTOCOL_FUNCTIONS.find(
        f => f.protocol === "aave" && f.functionName === "borrow"
    );

    if (!aaveSupplyFunc || !aaveBorrowFunc) {
        throw new Error("Aave functions not found in protocol mapping");
    }

    // Strategy: 2 nodes
    // Node 1: Aave supply 1000 USDC (as collateral)
    // Node 2: Aave borrow 500 USDT (against collateral)

    const nodes = [
        {
            func: aaveSupplyFunc,
            encoder: wallet.address, // TODO: Replace with deployed encoder contract
            target: deployment.protocols.aave,
            selector: parseInt(aaveSupplyFunc.selector, 16),
            // supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
            args: [
                deployment.tokens.USDC,
                BigInt(1000e6), // 1000 USDC (6 decimals)
                wallet.address,
                BigInt(0)
            ]
        },
        {
            func: aaveBorrowFunc,
            encoder: wallet.address, // TODO: Replace with deployed encoder contract
            target: deployment.protocols.aave,
            selector: parseInt(aaveBorrowFunc.selector, 16),
            // borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
            args: [
                deployment.tokens.USDT,
                BigInt(500e6), // 500 USDT (6 decimals)
                BigInt(2), // Variable rate mode
                BigInt(0), // referralCode
                wallet.address
            ]
        }
    ];

    console.log("Example Strategy (2 nodes):\n");
    nodes.forEach((node, idx) => {
        console.log(`Node ${idx + 1}: ${node.func.protocol}.${node.func.functionName}`);
        console.log("  Signature:", node.func.signature);
        console.log("  Encoder:", node.encoder);
        console.log("  Target:", node.target);
        console.log("  Selector:", node.func.selector);
        console.log("  Args:");
        node.func.argNames.forEach((name: string, i: number) => {
            console.log(`    ${name}:`, node.args[i]?.toString());
        });
        console.log();
    });

    // Get TradeManager address from deployment
    const avsDeploymentData = JSON.parse(
        fs.readFileSync(path.resolve(__dirname, `../contracts/deployments/trade-manager/${chainId}.json`), 'utf8')
    );
    const tradeManagerAddress = avsDeploymentData.addresses.tradeManager;

    console.log(`TradeManager: ${tradeManagerAddress}`);
    console.log(`User: ${wallet.address}`);
    console.log();

    // Prepare encryption inputs for all nodes
    const inputs: EncryptionInput[] = [];

    for (const node of nodes) {
        // Encoder, target, selector
        inputs.push(
            { value: node.encoder, type: FheTypes.Uint160 },  // Address = Uint160
            { value: node.target, type: FheTypes.Uint160 },   // Address = Uint160
            { value: BigInt(node.selector), type: FheTypes.Uint32 }
        );

        // Args - determine types based on function signature
        for (let i = 0; i < node.args.length; i++) {
            const arg = node.args[i];
            const argName = node.func.argNames[i];

            // Type inference based on arg name and function signature
            let fheType: number;
            if (typeof arg === 'string' && arg.startsWith('0x') && arg.length === 42) {
                fheType = FheTypes.Uint160;  // Address = Uint160
            } else if (argName === 'referralCode' || argName === 'interestRateMode') {
                // Small values like referralCode and interestRateMode can use Uint16
                fheType = FheTypes.Uint16;
            } else {
                // Default to Uint128 for amounts (max supported by CoFHE)
                fheType = FheTypes.Uint128;
            }

            inputs.push({ value: arg, type: fheType });
        }
    }

    console.log("Encrypting strategy inputs...");
    console.log(`Total inputs to encrypt: ${inputs.length}`);

    // Debug: Check for undefined types
    inputs.forEach((input, idx) => {
        if (input.type === undefined) {
            console.error(`❌ Input ${idx} has undefined type:`, input);
        }
    });

    const encrypted = await batchEncrypt(
        inputs,
        wallet.address,       // userAddress
        tradeManagerAddress   // contractAddress
    );

    console.log("\n✅ Encryption complete!\n");

    // Format for submitEncryptedStrategy call
    const encoders = [];
    const targets = [];
    const selectors = [];
    const nodeArgs = [];

    let encryptedIdx = 0;

    for (const node of nodes) {
        // Encoder
        encoders.push({
            ctHash: encrypted[encryptedIdx].ctHash,
            securityZone: encrypted[encryptedIdx].securityZone,
            utype: encrypted[encryptedIdx].utype,
            signature: encrypted[encryptedIdx].signature
        });
        encryptedIdx++;

        // Target
        targets.push({
            ctHash: encrypted[encryptedIdx].ctHash,
            securityZone: encrypted[encryptedIdx].securityZone,
            utype: encrypted[encryptedIdx].utype,
            signature: encrypted[encryptedIdx].signature
        });
        encryptedIdx++;

        // Selector
        selectors.push({
            ctHash: encrypted[encryptedIdx].ctHash,
            securityZone: encrypted[encryptedIdx].securityZone,
            utype: encrypted[encryptedIdx].utype,
            signature: encrypted[encryptedIdx].signature
        });
        encryptedIdx++;

        // Args for this node
        const encryptedArgs = [];
        for (let i = 0; i < node.args.length; i++) {
            encryptedArgs.push({
                ctHash: encrypted[encryptedIdx].ctHash,
                securityZone: encrypted[encryptedIdx].securityZone,
                utype: encrypted[encryptedIdx].utype,
                signature: encrypted[encryptedIdx].signature
            });
            encryptedIdx++;
        }
        nodeArgs.push(encryptedArgs);
    }

    // Initialize TradeManager contract
    const TRADE_MANAGER_ABI = [
        "function submitEncryptedStrategy(tuple(uint256 ctHash, uint32 securityZone, uint8 utype, bytes signature)[] encoders, tuple(uint256 ctHash, uint32 securityZone, uint8 utype, bytes signature)[] targets, tuple(uint256 ctHash, uint32 securityZone, uint8 utype, bytes signature)[] selectors, tuple(uint256 ctHash, uint32 securityZone, uint8 utype, bytes signature)[][] nodeArgs) external",
        "function currentEpochNumber() external view returns (uint256)",
        "function epochs(uint256) external view returns (uint64 encSimStartTime, uint64 encSimEndTime, uint64 epochStartTime, uint64 epochEndTime, uint256 notionalPerTrader, uint256 allocatedCapital, uint8 state)",
        "event StrategySubmitted(uint256 indexed epochNumber, address indexed trader, uint256 timestamp)"
    ];

    const tradeManager = new ethers.Contract(tradeManagerAddress, TRADE_MANAGER_ABI, wallet);

    // Get current epoch
    const currentEpoch = await tradeManager.currentEpochNumber();
    console.log(`Current Epoch: ${currentEpoch}`);

    if (currentEpoch === 0n) {
        console.error("\n❌ No active epoch! Admin must call startEpoch() first.");
        console.log("To start an epoch, run: forge script contracts/script/StartEpoch.s.sol --broadcast");
        process.exit(1);
    }

    // Check epoch state (0=PENDING, 1=OPEN, 2=CLOSED, 3=FINALIZED)
    const epoch = await tradeManager.epochs(currentEpoch);
    console.log(`Epoch State: ${epoch.state} (1=OPEN, 2=CLOSED)`);
    console.log(`Epoch End Time: ${new Date(Number(epoch.epochEndTime) * 1000).toISOString()}\n`);

    if (epoch.state !== 1) {
        console.error(`❌ Epoch is not OPEN (state=${epoch.state}). Cannot submit strategy.`);
        process.exit(1);
    }

    // Get current nonce
    const nonce = await provider.getTransactionCount(wallet.address);

    // Submit encrypted strategy
    console.log("📤 Submitting encrypted strategy to TradeManager...");

    try {
        const tx = await tradeManager.submitEncryptedStrategy(
            encoders,
            targets,
            selectors,
            nodeArgs,
            {
                nonce,
                gasLimit: 5000000
            }
        );

        console.log(`  Transaction hash: ${tx.hash}`);
        console.log("  Waiting for confirmation...");

        const receipt = await tx.wait();
        console.log(`  ✅ Confirmed in block ${receipt.blockNumber}`);
        console.log(`  Gas used: ${receipt.gasUsed.toString()}`);

        // Parse StrategySubmitted event
        const event = receipt.logs
            .map((log: any) => {
                try {
                    return tradeManager.interface.parseLog(log);
                } catch {
                    return null;
                }
            })
            .find((e: any) => e && e.name === 'StrategySubmitted');

        if (event) {
            console.log(`\n📋 StrategySubmitted Event:`);
            console.log(`  Epoch: ${event.args.epochNumber}`);
            console.log(`  Trader: ${event.args.trader}`);
            console.log(`  Timestamp: ${event.args.timestamp}`);
        }

        console.log("\n✅ Strategy submitted successfully!");
        console.log("\n🔍 Next steps:");
        console.log("  1. AVS operator should pick up this strategy when epoch closes");
        console.log("  2. Operator will decrypt the strategy nodes");
        console.log("  3. Operator will simulate and calculate APY");
        console.log("  4. Check operator logs to verify decryption and simulation");

    } catch (error: any) {
        console.error("\n❌ Transaction failed:");
        console.error(error.message);
        if (error.reason) {
            console.error(`Reason: ${error.reason}`);
        }
        process.exit(1);
    }
}

main().catch((error) => {
    console.error("Error:", error);
    process.exit(1);
});
