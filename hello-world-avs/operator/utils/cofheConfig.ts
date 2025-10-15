/**
 * CoFHE.js Network Configuration
 * Provides network-specific configurations for different environments
 */

export type CoFHEEnvironment = 'LOCAL' | 'TESTNET' | 'MAINNET';

export interface CoFHENetworkConfig {
    name: string;
    chainId: number;
    rpcUrl: string;
    environment: CoFHEEnvironment;
}

/**
 * Mock/Local Network Configuration
 * Used for local development with mock FHE
 */
export const LocalConfig: CoFHENetworkConfig = {
    name: 'Local',
    chainId: 31337,
    rpcUrl: 'http://127.0.0.1:8545',
    environment: 'LOCAL',
};

/**
 * Sepolia Testnet Configuration
 */
export const SepoliaConfig: CoFHENetworkConfig = {
    name: 'Sepolia',
    chainId: 11155111,
    rpcUrl: process.env.SEPOLIA_RPC_URL || 'https://eth-sepolia.public.blastapi.io',
    environment: 'TESTNET',
};

/**
 * Arbitrum Sepolia Testnet Configuration
 */
export const ArbitrumSepoliaConfig: CoFHENetworkConfig = {
    name: 'Arbitrum Sepolia',
    chainId: 421614,
    rpcUrl: process.env.ARB_SEPOLIA_RPC_URL || 'https://sepolia-rollup.arbitrum.io/rpc',
    environment: 'TESTNET',
};

/**
 * Base Sepolia Testnet Configuration
 */
export const BaseSepoliaConfig: CoFHENetworkConfig = {
    name: 'Base Sepolia',
    chainId: 84532,
    rpcUrl: process.env.BASE_SEPOLIA_RPC_URL || 'https://sepolia.base.org',
    environment: 'TESTNET',
};

/**
 * Get network configuration based on chain ID
 */
export const getNetworkConfig = (chainId: number): CoFHENetworkConfig => {
    switch (chainId) {
        case 31337:
            return LocalConfig;
        case 11155111:
            return SepoliaConfig;
        case 421614:
            return ArbitrumSepoliaConfig;
        case 84532:
            return BaseSepoliaConfig;
        default:
            throw new Error(`Unsupported chain ID: ${chainId}`);
    }
};

/**
 * Get network configuration based on environment name
 */
export const getNetworkConfigByName = (networkName: string): CoFHENetworkConfig => {
    const normalizedName = networkName.toLowerCase();

    switch (normalizedName) {
        case 'local':
        case 'localhost':
            return LocalConfig;
        case 'sepolia':
            return SepoliaConfig;
        case 'arbitrum-sepolia':
        case 'arbsepolia':
            return ArbitrumSepoliaConfig;
        case 'base-sepolia':
        case 'basesepolia':
            return BaseSepoliaConfig;
        default:
            throw new Error(`Unsupported network name: ${networkName}`);
    }
};
