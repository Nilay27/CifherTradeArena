/**
 * Protocol and Function Mapping
 * Maps contract addresses and function selectors to protocol names and function names
 */

import { ethers } from 'ethers';
import * as fs from 'fs';
import * as path from 'path';

interface MockDeployment {
    tokens: {
        USDC: string;
        USDT: string;
        PT_eUSDE: string;
        PT_sUSDE: string;
        PT_USR: string;
    };
    protocols: {
        pendle: string;
        aave: string;
        morpho: string;
    };
    markets: {
        PT_eUSDE: string;
        PT_sUSDE: string;
        PT_USR: string;
    };
}

let mockDeployment: MockDeployment | null = null;

/**
 * Load mock deployment addresses from file
 */
export function loadMockDeployment(chainId: number): MockDeployment {
    if (mockDeployment) return mockDeployment;

    const deploymentPath = path.resolve(
        __dirname,
        `../../contracts/deployments/mocks/${chainId}.json`
    );

    if (!fs.existsSync(deploymentPath)) {
        throw new Error(`Mock deployment not found for chain ${chainId} at ${deploymentPath}`);
    }

    const data = fs.readFileSync(deploymentPath, 'utf8');
    mockDeployment = JSON.parse(data);

    console.log(`✅ Loaded mock deployment for chain ${chainId}`);
    return mockDeployment!;
}

interface ProtocolFunction {
    protocol: string;
    functionName: string;
    signature: string;
    selector: string;
    argNames: string[]; // Semantic names for arguments in order
}

/**
 * Calculate function selector from signature
 */
function getSelector(signature: string): string {
    return ethers.id(signature).slice(0, 10);
}

/**
 * Protocol function definitions with real signatures
 */
const PROTOCOL_FUNCTIONS: ProtocolFunction[] = [
    // Pendle
    {
        protocol: "pendle",
        functionName: "swapExactTokenForPt",
        signature: "swapExactTokenForPt(address,address,address,uint256)",
        selector: getSelector("swapExactTokenForPt(address,address,address,uint256)"),
        argNames: ["receiver", "market", "tokenIn", "netTokenIn"]
    },
    {
        protocol: "pendle",
        functionName: "swapExactPtForToken",
        signature: "swapExactPtForToken(address,address,uint256,address)",
        selector: getSelector("swapExactPtForToken(address,address,uint256,address)"),
        argNames: ["receiver", "market", "exactPtIn", "tokenOut"]
    },

    // Morpho
    {
        protocol: "morpho",
        functionName: "supply",
        signature: "supply(address,uint256,address)",
        selector: getSelector("supply(address,uint256,address)"),
        argNames: ["collateralToken", "collateralTokenAmount", "onBehalf"]
    },
    {
        protocol: "morpho",
        functionName: "borrow",
        signature: "borrow(address,address,uint256,uint256,address,address)",
        selector: getSelector("borrow(address,address,uint256,uint256,address,address)"),
        argNames: ["loanToken", "collateralToken", "lltv", "assets", "onBehalf", "receiver"]
    },
    {
        protocol: "morpho",
        functionName: "withdraw",
        signature: "withdraw(address,uint256,address,address)",
        selector: getSelector("withdraw(address,uint256,address,address)"),
        argNames: ["asset", "amount", "onBehalf", "receiver"]
    },
    {
        protocol: "morpho",
        functionName: "repay",
        signature: "repay(address,address,uint256,address)",
        selector: getSelector("repay(address,address,uint256,address)"),
        argNames: ["loanToken", "collateralToken", "assets", "onBehalf"]
    },

    // Aave V3
    {
        protocol: "aave",
        functionName: "supply",
        signature: "supply(address,uint256,address,uint16)",
        selector: getSelector("supply(address,uint256,address,uint16)"),
        argNames: ["asset", "amount", "onBehalfOf", "referralCode"]
    },
    {
        protocol: "aave",
        functionName: "withdraw",
        signature: "withdraw(address,uint256,address)",
        selector: getSelector("withdraw(address,uint256,address)"),
        argNames: ["asset", "amount", "to"]
    },
    {
        protocol: "aave",
        functionName: "borrow",
        signature: "borrow(address,uint256,uint256,uint16,address)",
        selector: getSelector("borrow(address,uint256,uint256,uint16,address)"),
        argNames: ["asset", "amount", "interestRateMode", "referralCode", "onBehalfOf"]
    },
    {
        protocol: "aave",
        functionName: "repay",
        signature: "repay(address,uint256,uint256,address)",
        selector: getSelector("repay(address,uint256,uint256,address)"),
        argNames: ["asset", "amount", "interestRateMode", "onBehalfOf"]
    },

    // Compound V3
    {
        protocol: "compound",
        functionName: "supply",
        signature: "supply(address,uint256)",
        selector: getSelector("supply(address,uint256)"),
        argNames: ["asset", "amount"]
    },
    {
        protocol: "compound",
        functionName: "withdraw",
        signature: "withdraw(address,uint256)",
        selector: getSelector("withdraw(address,uint256)"),
        argNames: ["asset", "amount"]
    },
];

/**
 * Build selector lookup map
 */
const SELECTOR_MAP: Record<string, ProtocolFunction> = {};
PROTOCOL_FUNCTIONS.forEach(fn => {
    SELECTOR_MAP[fn.selector.toLowerCase()] = fn;
});

/**
 * Target address → protocol mapping
 * This will be populated dynamically from deployment file
 */
export let PROTOCOL_ADDRESSES: Record<string, string> = {};

/**
 * Initialize protocol addresses from mock deployment
 */
export function initializeProtocolAddresses(chainId: number) {
    const deployment = loadMockDeployment(chainId);

    PROTOCOL_ADDRESSES = {
        [deployment.protocols.pendle.toLowerCase()]: "pendle",
        [deployment.protocols.aave.toLowerCase()]: "aave",
        [deployment.protocols.morpho.toLowerCase()]: "morpho",
    };

    console.log("✅ Protocol addresses initialized:");
    console.log(`  Pendle: ${deployment.protocols.pendle}`);
    console.log(`  Aave: ${deployment.protocols.aave}`);
    console.log(`  Morpho: ${deployment.protocols.morpho}`);
}

/**
 * Get protocol name from target address
 */
export function getProtocolFromAddress(address: string): string {
    const normalized = address.toLowerCase();
    return PROTOCOL_ADDRESSES[normalized] || "unknown";
}

/**
 * Get function info from selector
 */
export function getFunctionFromSelector(selector: string): ProtocolFunction | null {
    const normalized = selector.toLowerCase();
    return SELECTOR_MAP[normalized] || null;
}

/**
 * Get both protocol and function name from address and selector
 */
export function getProtocolFunction(
    targetAddress: string,
    selector: string
): { protocol: string; functionName: string } {
    // Try to get from selector first (most accurate)
    const funcInfo = getFunctionFromSelector(selector);
    if (funcInfo) {
        return {
            protocol: funcInfo.protocol,
            functionName: funcInfo.functionName
        };
    }

    // Fallback: get protocol from address
    const protocol = getProtocolFromAddress(targetAddress);
    return {
        protocol,
        functionName: "unknown"
    };
}

/**
 * List all registered function selectors (for debugging)
 */
export function listAllSelectors(): void {
    console.log("\n=== Registered Function Selectors ===");
    PROTOCOL_FUNCTIONS.forEach(fn => {
        console.log(`${fn.selector} → ${fn.protocol}.${fn.functionName}`);
        console.log(`  Signature: ${fn.signature}`);
    });
}
