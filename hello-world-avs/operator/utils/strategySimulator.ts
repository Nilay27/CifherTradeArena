/**
 * Strategy Simulator - calculates APY from decrypted strategy nodes
 */

import { getAPYRate, getOperationType } from './apyConfig';

export interface DecryptedNode {
    protocol: string;      // e.g., "pendle", "morpho", "aave"
    functionName: string;  // e.g., "swapExactTokenForPt", "supply"
    target: string;        // Protocol contract address
    args: {
        token?: string;    // Token address
        market?: string;   // Market address
        amount?: bigint;   // Amount in wei
        [key: string]: any; // Other params
    };
}

interface YieldPosition {
    amount: bigint;
    apyBps: number;
    type: 'supply' | 'borrow' | 'yield' | 'swap';
}

/**
 * Simulate a strategy and calculate overall APY
 * @param nodes - Array of decrypted strategy nodes
 * @param initialCapital - Starting capital in wei
 * @returns APY in basis points (10000 = 100%)
 */
export function simulate(nodes: DecryptedNode[], initialCapital: bigint): number {
    console.log("\n=== Strategy Simulation ===");
    console.log(`Initial Capital: ${initialCapital.toString()}`);
    console.log(`Strategy Steps: ${nodes.length}`);

    const positions: YieldPosition[] = [];
    let totalYieldPerYear = 0n;

    // Process each node
    for (let i = 0; i < nodes.length; i++) {
        const node = nodes[i];
        console.log(`\nStep ${i}: ${node.protocol}.${node.functionName}`);

        // Get APY rate for this operation
        const tokenOrMarket = node.args.market || node.args.token || node.args.collateralToken || node.args.loanToken || '';
        const apyBps = getAPYRate(node.protocol, node.functionName, tokenOrMarket);
        const opType = getOperationType(node.protocol, node.functionName);

        // Get amount from various possible arg names
        const amount = node.args.amount ||
                      node.args.netTokenIn ||
                      node.args.collateralTokenAmount ||
                      node.args.assets ||
                      0n;

        console.log(`  Amount: ${amount.toString()}`);
        console.log(`  APY: ${apyBps / 100}%`);
        console.log(`  Type: ${opType}`);

        if (amount > 0n) {
            positions.push({ amount, apyBps, type: opType });

            // Calculate yield for this position
            const yearlyYield = (amount * BigInt(apyBps)) / 10000n;

            if (opType === 'borrow') {
                // Borrowing is a cost (negative yield)
                totalYieldPerYear -= yearlyYield;
                console.log(`  Yearly Cost: -${yearlyYield.toString()}`);
            } else {
                // Supply/yield is positive
                totalYieldPerYear += yearlyYield;
                console.log(`  Yearly Yield: +${yearlyYield.toString()}`);
            }
        }
    }

    // Calculate overall APY
    if (initialCapital === 0n) {
        console.log("\n⚠️ Initial capital is 0, returning 0% APY");
        return 0;
    }

    const overallAPYBps = Number((totalYieldPerYear * 10000n) / initialCapital);

    console.log("\n=== Simulation Results ===");
    console.log(`Total Yearly Yield: ${totalYieldPerYear.toString()}`);
    console.log(`Overall APY: ${overallAPYBps / 100}% (${overallAPYBps} bps)`);

    return overallAPYBps;
}

/**
 * Example usage and test
 */
export function testSimulation() {
    // Example: 100k PT at 15%, borrow 80k at 10%, buy 80k PT at 15%
    const nodes: DecryptedNode[] = [
        {
            protocol: "pendle",
            functionName: "swapExactTokenForPt",
            target: "0x1234...",
            args: {
                market: "0x1234567890123456789012345678901234567890",
                netTokenIn: 100000000000n, // 100k USDC (6 decimals)
            }
        },
        {
            protocol: "morpho",
            functionName: "supply",
            target: "0x2345...",
            args: {
                collateralToken: "0xpttokenaddressplaceholder0000000000000000",
                collateralTokenAmount: 100000000000n, // 100k PT
            }
        },
        {
            protocol: "morpho",
            functionName: "borrow",
            target: "0x3456...",
            args: {
                loanToken: "0xa0b86a33e6789e48ace7e9a89a9de7e1e1b9c8de", // USDC
                assets: 80000000000n, // 80k USDC
            }
        },
        {
            protocol: "pendle",
            functionName: "swapExactTokenForPt",
            target: "0x1234...",
            args: {
                market: "0x1234567890123456789012345678901234567890",
                netTokenIn: 80000000000n, // 80k USDC
            }
        }
    ];

    const initialCapital = 100000000000n; // 100k
    const apy = simulate(nodes, initialCapital);

    console.log(`\n✅ Expected APY: 19% (1900 bps)`);
    console.log(`📊 Calculated APY: ${apy / 100}% (${apy} bps)`);
}
