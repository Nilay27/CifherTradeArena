/**
 * APY Configuration for different protocols, functions, and tokens
 * All APY values in basis points (10000 = 100%)
 */

export interface APYRate {
    protocol: string;
    function: string;
    token?: string;
    market?: string;
    apy: number; // basis points (10000 = 100%)
    type: 'supply' | 'borrow' | 'swap' | 'yield';
}

export const APY_CONFIG: APYRate[] = [
    // Pendle PT purchases (yield-bearing tokens)
    {
        protocol: "pendle",
        function: "swapExactTokenForPt",
        market: "0x1234567890123456789012345678901234567890", // PT-sUSDe market
        apy: 1500, // 15%
        type: "yield"
    },
    {
        protocol: "pendle",
        function: "swapExactTokenForPt",
        market: "0x2345678901234567890123456789012345678901", // PT-eETH market
        apy: 1200, // 12%
        type: "yield"
    },

    // Morpho supply (collateral)
    {
        protocol: "morpho",
        function: "supply",
        token: "0xpttokenaddressplaceholder0000000000000000", // PT tokens
        apy: 0, // No yield on collateral
        type: "supply"
    },

    // Morpho borrow (debt - simulator applies negative based on type)
    {
        protocol: "morpho",
        function: "borrow",
        token: "0xa0b86a33e6789e48ace7e9a89a9de7e1e1b9c8de", // USDC
        apy: 1000, // 10% borrowing cost
        type: "borrow"
    },
    {
        protocol: "morpho",
        function: "borrow",
        token: "0xdac17f958d2ee523a2206206994597c13d831ec7", // USDT
        apy: 950, // 9.5% borrowing cost
        type: "borrow"
    },

    // Aave supply
    {
        protocol: "aave",
        function: "deposit",
        token: "0xa0b86a33e6789e48ace7e9a89a9de7e1e1b9c8de", // USDC
        apy: 500, // 5%
        type: "supply"
    },

    // Compound supply
    {
        protocol: "compound",
        function: "supply",
        token: "0xa0b86a33e6789e48ace7e9a89a9de7e1e1b9c8de", // USDC
        apy: 450, // 4.5%
        type: "supply"
    }
];

/**
 * Get APY rate for a specific protocol operation
 */
export function getAPYRate(
    protocol: string,
    functionName: string,
    tokenOrMarket: string
): number {
    // Try exact match first
    let rate = APY_CONFIG.find(
        r => r.protocol.toLowerCase() === protocol.toLowerCase() &&
             r.function.toLowerCase() === functionName.toLowerCase() &&
             (r.token?.toLowerCase() === tokenOrMarket.toLowerCase() ||
              r.market?.toLowerCase() === tokenOrMarket.toLowerCase())
    );

    // Fallback: match protocol + function only
    if (!rate) {
        rate = APY_CONFIG.find(
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
    protocol: string,
    functionName: string
): 'supply' | 'borrow' | 'swap' | 'yield' {
    const rate = APY_CONFIG.find(
        r => r.protocol.toLowerCase() === protocol.toLowerCase() &&
             r.function.toLowerCase() === functionName.toLowerCase()
    );
    return rate?.type || 'supply';
}
