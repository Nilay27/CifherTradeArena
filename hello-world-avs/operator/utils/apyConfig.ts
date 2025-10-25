/**
 * APY Configuration for different protocols, functions, and tokens
 * All APY values in basis points (10000 = 100%)
 */

import { loadMockDeployment } from './protocolMapping';

export interface APYRate {
    protocol: string;
    function: string;
    token?: string;
    market?: string;
    apy: number; // basis points (10000 = 100%)
    type: 'supply' | 'borrow' | 'swap' | 'yield';
}

let APY_CONFIG_CACHE: APYRate[] | null = null;

/**
 * Get APY configuration with real deployed addresses
 */
export function getAPYConfig(chainId: number): APYRate[] {
    if (APY_CONFIG_CACHE) return APY_CONFIG_CACHE;

    const deployment = loadMockDeployment(chainId);

    APY_CONFIG_CACHE = [
        // Pendle PT purchases (yield-bearing tokens)
        {
            protocol: "pendle",
            function: "swapExactTokenForPt",
            market: deployment.markets.PT_eUSDE, // PT-eUSDE market (7% APY)
            apy: 1300,
            type: "yield"
        },
        {
            protocol: "pendle",
            function: "swapExactTokenForPt",
            market: deployment.markets.PT_sUSDE, // PT-sUSDE market (8% APY)
            apy: 1400,
            type: "yield"
        },
        {
            protocol: "pendle",
            function: "swapExactTokenForPt",
            market: deployment.markets.PT_USR, // PT-USR market (10% APY)
            apy: 1700,
            type: "yield"
        },

        // Morpho supply (collateral)
        {
            protocol: "morpho",
            function: "supply",
            token: deployment.tokens.PT_USR, // PT-USR
            apy: 0, // No yield on collateral
            type: "supply"
        },

        // Morpho borrow (debt - simulator applies negative based on type)
        {
            protocol: "morpho",
            function: "borrow",
            token: deployment.tokens.USDC,
            apy: 900, // 10% borrowing cost
            type: "borrow"
        },
        {
            protocol: "morpho",
            function: "borrow",
            token: deployment.tokens.USDT,
            apy: 900, // 10% borrowing cost
            type: "borrow"
        },

        // Aave supply (PT-eUSDE, PT-sUSDE)
        {
            protocol: "aave",
            function: "supply",
            token: deployment.tokens.PT_eUSDE,
            apy: 0, // No yield on collateral
            type: "supply"
        },
        {
            protocol: "aave",
            function: "supply",
            token: deployment.tokens.PT_sUSDE,
            apy: 0, // No yield on collateral
            type: "supply"
        },

        // Aave borrow
        {
            protocol: "aave",
            function: "borrow",
            token: deployment.tokens.USDC,
            apy: 500, // 5%
            type: "borrow"
        },
        {
            protocol: "aave",
            function: "borrow",
            token: deployment.tokens.USDT,
            apy: 550, // 5.5%
            type: "borrow"
        },
    ];

    return APY_CONFIG_CACHE;
}

/**
 * Get APY rate for a specific protocol operation
 */
export function getAPYRate(
    chainId: number,
    protocol: string,
    functionName: string,
    tokenOrMarket: string
): number {
    const config = getAPYConfig(chainId);

    // Try exact match first
    let rate = config.find(
        r => r.protocol.toLowerCase() === protocol.toLowerCase() &&
             r.function.toLowerCase() === functionName.toLowerCase() &&
             (r.token?.toLowerCase() === tokenOrMarket.toLowerCase() ||
              r.market?.toLowerCase() === tokenOrMarket.toLowerCase())
    );

    // Fallback: match protocol + function only
    if (!rate) {
        rate = config.find(
            r => r.protocol.toLowerCase() === protocol.toLowerCase() &&
                 r.function.toLowerCase() === functionName.toLowerCase()
        );
    }

    return rate ? rate.apy : 0;
}

/**
 * Get operation type (supply, borrow, yield)
 */
export function getOperationType(
    chainId: number,
    protocol: string,
    functionName: string
): 'supply' | 'borrow' | 'swap' | 'yield' {
    const config = getAPYConfig(chainId);
    const rate = config.find(
        r => r.protocol.toLowerCase() === protocol.toLowerCase() &&
             r.function.toLowerCase() === functionName.toLowerCase()
    );
    return rate?.type || 'supply';
}
