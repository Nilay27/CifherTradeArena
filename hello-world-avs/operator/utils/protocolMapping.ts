/**
 * Protocol and Function Mapping
 * Maps contract addresses and function selectors to protocol names and function names
 */

import { ethers } from 'ethers';

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
        functionName: "deposit",
        signature: "deposit(address,uint256,address,uint16)",
        selector: getSelector("deposit(address,uint256,address,uint16)"),
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
 * Target address → protocol mapping (example addresses)
 */
export const PROTOCOL_ADDRESSES: Record<string, string> = {
    // Pendle contracts (examples - replace with real addresses)
    "0x1234567890123456789012345678901234567890": "pendle",

    // Morpho contracts
    "0x3456789012345678901234567890123456789012": "morpho",

    // Aave V3 Pool
    "0x87870bca3f3fd6335c3f4ce8392d69350b4fa4e2": "aave", // Ethereum mainnet

    // Compound V3
    "0xc3d688b66703497daa19211eedff47f25384cdc3": "compound", // USDC on Ethereum
};

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
