/**
 * Test the full flow from decrypted values to APY calculation
 */

import { simulate, DecryptedNode } from './utils/strategySimulator';
import { getProtocolFunction, getFunctionFromSelector, listAllSelectors } from './utils/protocolMapping';
import { ethers } from 'ethers';

console.log("\n🧪 Testing Decrypted Strategy Flow\n");

// First, let's see what selectors are registered
listAllSelectors();

// Simulate what the operator gets after decryption
console.log("\n\n=== Step 1: Simulating Decrypted Values ===\n");

// Example: Pendle swapExactTokenForPt function
const pendleSwapSignature = "swapExactTokenForPt(address,address,address,uint256)";
const pendleSwapSelector = ethers.id(pendleSwapSignature).slice(0, 10);
console.log(`Pendle Swap Selector: ${pendleSwapSelector}`);

// Example: Morpho supply function
const morphoSupplySignature = "supply(address,uint256,address)";
const morphoSupplySelector = ethers.id(morphoSupplySignature).slice(0, 10);
console.log(`Morpho Supply Selector: ${morphoSupplySelector}`);

// Example: Morpho borrow function
const morphoBorrowSignature = "borrow(address,address,uint256,uint256,address,address)";
const morphoBorrowSelector = ethers.id(morphoBorrowSignature).slice(0, 10);
console.log(`Morpho Borrow Selector: ${morphoBorrowSelector}`);

// Simulate decrypted strategy nodes
const mockTarget1 = "0x1234567890123456789012345678901234567890"; // Pendle market
const mockTarget2 = "0x3456789012345678901234567890123456789012"; // Morpho

console.log("\n\n=== Step 2: Mapping Selectors to Protocol Functions ===\n");

// Test selector mapping
const func1 = getFunctionFromSelector(pendleSwapSelector);
console.log("Pendle Swap Function Info:", func1);

const func2 = getFunctionFromSelector(morphoSupplySelector);
console.log("Morpho Supply Function Info:", func2);

const func3 = getFunctionFromSelector(morphoBorrowSelector);
console.log("Morpho Borrow Function Info:", func3);

console.log("\n\n=== Step 3: Building DecryptedNode Objects ===\n");

// Build strategy nodes exactly as the operator would
const decryptedNodes: DecryptedNode[] = [];

// Node 0: Pendle buy 100k PT
const node0Args: any = {
    arg0: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd", // receiver
    arg1: "0x1234567890123456789012345678901234567890", // market
    arg2: "0xa0b86a33e6789e48ace7e9a89a9de7e1e1b9c8de", // tokenIn (USDC)
    arg3: 100000000000n, // netTokenIn (100k USDC)
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
    target: mockTarget1,
    args: node0Args
});

console.log("Node 0 (Pendle Swap):", {
    protocol: decryptedNodes[0].protocol,
    functionName: decryptedNodes[0].functionName,
    args: decryptedNodes[0].args
});

// Node 1: Morpho supply 100k PT as collateral
const node1Args: any = {
    arg0: "0xpttokenaddressplaceholder0000000000000000", // collateralToken
    arg1: 100000000000n, // collateralTokenAmount
    arg2: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd", // onBehalf
};

if (func2 && func2.argNames) {
    node1Args.collateralToken = node1Args.arg0;
    node1Args.collateralTokenAmount = node1Args.arg1;
    node1Args.onBehalf = node1Args.arg2;
}

if (!func2 || !func2.protocol || !func2.functionName) {
    throw new Error("Failed to map Morpho supply function from selector!");
}

decryptedNodes.push({
    protocol: func2.protocol,
    functionName: func2.functionName,
    target: mockTarget2,
    args: node1Args
});

console.log("\nNode 1 (Morpho Supply):", {
    protocol: decryptedNodes[1].protocol,
    functionName: decryptedNodes[1].functionName,
    args: decryptedNodes[1].args
});

// Node 2: Morpho borrow 80k USDC
const node2Args: any = {
    arg0: "0xa0b86a33e6789e48ace7e9a89a9de7e1e1b9c8de", // loanToken (USDC)
    arg1: "0xpttokenaddressplaceholder0000000000000000", // collateralToken
    arg2: 850000000000000000n, // lltv (85%)
    arg3: 80000000000n, // assets (80k USDC)
    arg4: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd", // onBehalf
    arg5: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd", // receiver
};

if (func3 && func3.argNames) {
    node2Args.loanToken = node2Args.arg0;
    node2Args.collateralToken = node2Args.arg1;
    node2Args.lltv = node2Args.arg2;
    node2Args.assets = node2Args.arg3;
    node2Args.onBehalf = node2Args.arg4;
    node2Args.receiver = node2Args.arg5;
}

if (!func3 || !func3.protocol || !func3.functionName) {
    throw new Error("Failed to map Morpho borrow function from selector!");
}

decryptedNodes.push({
    protocol: func3.protocol,
    functionName: func3.functionName,
    target: mockTarget2,
    args: node2Args
});

console.log("\nNode 2 (Morpho Borrow):", {
    protocol: decryptedNodes[2].protocol,
    functionName: decryptedNodes[2].functionName,
    args: decryptedNodes[2].args
});

// Node 3: Pendle buy 80k PT (loop)
const node3Args: any = {
    arg0: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd", // receiver
    arg1: "0x1234567890123456789012345678901234567890", // market
    arg2: "0xa0b86a33e6789e48ace7e9a89a9de7e1e1b9c8de", // tokenIn
    arg3: 80000000000n, // netTokenIn (80k USDC)
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
    target: mockTarget1,
    args: node3Args
});

console.log("\nNode 3 (Pendle Swap #2):", {
    protocol: decryptedNodes[3].protocol,
    functionName: decryptedNodes[3].functionName,
    args: decryptedNodes[3].args
});

console.log("\n\n=== Step 4: Simulating Strategy ===\n");

const initialCapital = 100000000000n; // 100k USDC
const calculatedAPY = simulate(decryptedNodes, initialCapital);

console.log(`\n\n=== Final Result ===`);
console.log(`Expected APY: 19% (1900 bps)`);
console.log(`Calculated APY: ${calculatedAPY / 100}% (${calculatedAPY} bps)`);
console.log(`Match: ${calculatedAPY === 1900 ? '✅' : '❌'}`);
