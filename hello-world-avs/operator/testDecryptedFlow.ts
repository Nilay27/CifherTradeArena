/**
 * Test the full flow from decrypted values to APY calculation
 * Strategy: PT-sUSDE + Aave USDC Looping
 * 1. Buy 100k PT-sUSDE with USDC (8% APY)
 * 2. Supply 100k PT-sUSDE to Aave as collateral
 * 3. Borrow 80k USDC from Aave (5% cost)
 * 4. Buy 80k more PT-sUSDE with borrowed USDC (8% APY)
 *
 * Expected APY: 100k*8% - 80k*5% + 80k*8% = 8k - 4k + 6.4k = 10.4k = 10.4% APY (1040 bps)
 */

import { simulate, DecryptedNode } from './utils/strategySimulator';
import { getFunctionFromSelector, listAllSelectors, initializeProtocolAddresses, loadMockDeployment } from './utils/protocolMapping';
import { ethers } from 'ethers';

console.log("\n🧪 Testing PT-sUSDE + Aave USDC Looping Strategy\n");

const chainId = 84532; // Base Sepolia

// Initialize protocol addresses
initializeProtocolAddresses(chainId);

// Load deployment addresses
const deployment = loadMockDeployment(chainId);
console.log("Deployed Addresses:");
console.log(`  USDC: ${deployment.tokens.USDC}`);
console.log(`  PT-sUSDE: ${deployment.tokens.PT_sUSDE}`);
console.log(`  PT-sUSDE Market: ${deployment.markets.PT_sUSDE}`);
console.log(`  Pendle: ${deployment.protocols.pendle}`);
console.log(`  Aave: ${deployment.protocols.aave}`);

// First, let's see what selectors are registered
listAllSelectors();

// Simulate what the operator gets after decryption
console.log("\n\n=== Step 1: Simulating Decrypted Values ===\n");

// Pendle swapExactTokenForPt
const pendleSwapSignature = "swapExactTokenForPt(address,address,address,uint256)";
const pendleSwapSelector = ethers.id(pendleSwapSignature).slice(0, 10);
console.log(`Pendle Swap Selector: ${pendleSwapSelector}`);

// Aave supply (deposit)
const aaveSupplySignature = "supply(address,uint256,address,uint16)";
const aaveSupplySelector = ethers.id(aaveSupplySignature).slice(0, 10);
console.log(`Aave Supply Selector: ${aaveSupplySelector}`);

// Aave borrow
const aaveBorrowSignature = "borrow(address,uint256,uint256,uint16,address)";
const aaveBorrowSelector = ethers.id(aaveBorrowSignature).slice(0, 10);
console.log(`Aave Borrow Selector: ${aaveBorrowSelector}`);

console.log("\n\n=== Step 2: Mapping Selectors to Protocol Functions ===\n");

// Test selector mapping
const func1 = getFunctionFromSelector(pendleSwapSelector);
console.log("Pendle Swap Function Info:", func1);

const func2 = getFunctionFromSelector(aaveSupplySelector);
console.log("Aave Supply Function Info:", func2);

const func3 = getFunctionFromSelector(aaveBorrowSelector);
console.log("Aave Borrow Function Info:", func3);

console.log("\n\n=== Step 3: Building DecryptedNode Objects ===\n");

// Build strategy nodes exactly as the operator would
const decryptedNodes: DecryptedNode[] = [];

// Node 0: Pendle buy 100k PT-sUSDE with USDC
const node0Args: any = {
    arg0: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd", // receiver (vault)
    arg1: deployment.markets.PT_sUSDE, // PT-sUSDE market
    arg2: deployment.tokens.USDC, // tokenIn (USDC)
    arg3: 100000000000n, // netTokenIn (100k USDC, 6 decimals)
};

// Map semantic names
if (func1 && func1.argNames) {
    node0Args.receiver = node0Args.arg0;
    node0Args.market = node0Args.arg1;
    node0Args.tokenIn = node0Args.arg2;
    node0Args.netTokenIn = node0Args.arg3;
}

if (!func1 || !func1.protocol || !func1.functionName) {
    throw new Error("Failed to map Pendle swap function from selector!");
}

decryptedNodes.push({
    protocol: func1.protocol,
    functionName: func1.functionName,
    target: deployment.protocols.pendle,
    args: node0Args
});

console.log("Node 0 (Buy PT-sUSDE):", {
    protocol: decryptedNodes[0].protocol,
    functionName: decryptedNodes[0].functionName,
    target: decryptedNodes[0].target,
    args: decryptedNodes[0].args
});

// Node 1: Aave supply 100k PT-sUSDE as collateral
const node1Args: any = {
    arg0: deployment.tokens.PT_sUSDE, // asset (PT-sUSDE)
    arg1: 100000000000n, // amount (100k PT-sUSDE, 6 decimals)
    arg2: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd", // onBehalfOf (vault)
    arg3: BigInt(0), // referralCode
};

if (func2 && func2.argNames) {
    node1Args.asset = node1Args.arg0;
    node1Args.amount = node1Args.arg1;
    node1Args.onBehalfOf = node1Args.arg2;
    node1Args.referralCode = node1Args.arg3;
}

if (!func2 || !func2.protocol || !func2.functionName) {
    throw new Error("Failed to map Aave supply function from selector!");
}

decryptedNodes.push({
    protocol: func2.protocol,
    functionName: func2.functionName,
    target: deployment.protocols.aave,
    args: node1Args
});

console.log("\nNode 1 (Supply PT-sUSDE to Aave):", {
    protocol: decryptedNodes[1].protocol,
    functionName: decryptedNodes[1].functionName,
    target: decryptedNodes[1].target,
    args: decryptedNodes[1].args
});

// Node 2: Aave borrow 80k USDC
const node2Args: any = {
    arg0: deployment.tokens.USDC, // asset (USDC)
    arg1: 80000000000n, // amount (80k USDC, 6 decimals)
    arg2: BigInt(2), // interestRateMode (2 = variable rate)
    arg3: BigInt(0), // referralCode
    arg4: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd", // onBehalfOf (vault)
};

if (func3 && func3.argNames) {
    node2Args.asset = node2Args.arg0;
    node2Args.amount = node2Args.arg1;
    node2Args.interestRateMode = node2Args.arg2;
    node2Args.referralCode = node2Args.arg3;
    node2Args.onBehalfOf = node2Args.arg4;
}

if (!func3 || !func3.protocol || !func3.functionName) {
    throw new Error("Failed to map Aave borrow function from selector!");
}

decryptedNodes.push({
    protocol: func3.protocol,
    functionName: func3.functionName,
    target: deployment.protocols.aave,
    args: node2Args
});

console.log("\nNode 2 (Borrow USDC from Aave):", {
    protocol: decryptedNodes[2].protocol,
    functionName: decryptedNodes[2].functionName,
    target: decryptedNodes[2].target,
    args: decryptedNodes[2].args
});

// Node 3: Pendle buy 80k more PT-sUSDE with borrowed USDC
const node3Args: any = {
    arg0: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd", // receiver (vault)
    arg1: deployment.markets.PT_sUSDE, // PT-sUSDE market
    arg2: deployment.tokens.USDC, // tokenIn (USDC)
    arg3: 80000000000n, // netTokenIn (80k USDC, 6 decimals)
};

if (func1 && func1.argNames) {
    node3Args.receiver = node3Args.arg0;
    node3Args.market = node3Args.arg1;
    node3Args.tokenIn = node3Args.arg2;
    node3Args.netTokenIn = node3Args.arg3;
}

if (!func1 || !func1.protocol || !func1.functionName) {
    throw new Error("Failed to map Pendle swap function from selector (node 3)!");
}

decryptedNodes.push({
    protocol: func1.protocol,
    functionName: func1.functionName,
    target: deployment.protocols.pendle,
    args: node3Args
});

console.log("\nNode 3 (Buy more PT-sUSDE with borrowed USDC):", {
    protocol: decryptedNodes[3].protocol,
    functionName: decryptedNodes[3].functionName,
    target: decryptedNodes[3].target,
    args: decryptedNodes[3].args
});

console.log("\n\n=== Step 4: Simulating Strategy ===\n");

const initialCapital = 100000000000n; // 100k USDC
const calculatedAPY = simulate(chainId, decryptedNodes, initialCapital);

console.log(`\n\n=== Final Result ===`);
console.log(`Expected APY: 10.4% (1040 bps)`);
console.log(`Calculated APY: ${calculatedAPY / 100}% (${calculatedAPY} bps)`);
console.log(`Match: ${calculatedAPY === 1040 ? '✅' : '❌'}`);
