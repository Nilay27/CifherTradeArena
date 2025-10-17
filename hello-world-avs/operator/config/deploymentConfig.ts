/**
 * Deployment Configuration Loader
 * Dynamically loads deployment addresses from JSON files based on chain ID
 */

import * as fs from 'fs';
import * as path from 'path';

export interface SwapManagerDeployment {
    SwapManager: string;
    SwapManagerType: string;
    stakeRegistry: string;
    universalPrivacyHook: string;
    strategy: string;
    token: string;
}

export interface UniversalPrivacyHookDeployment {
    network: string;
    chainId: number;
    poolManager: string;
    universalPrivacyHook: string;
    mockUSDC: string;
    mockUSDT: string;
    encryptedUSDC: string;
    encryptedUSDT: string;
    poolId: string;
    poolKey: {
        currency0: string;
        currency1: string;
        fee: number;
        tickSpacing: number;
        hooks: string;
    };
    status?: string;
    notes?: string;
}

export interface DeploymentConfig {
    chainId: number;
    network: string;
    swapManager: string;
    universalPrivacyHook: string;
    mockUSDC: string;
    mockUSDT: string;
    encryptedUSDC: string;
    encryptedUSDT: string;
    poolId: string;
    poolManager: string;
    boringVault?: string;
}

/**
 * Load deployment configuration for a given chain ID
 * @param chainId The chain ID to load config for
 * @returns Deployment configuration object
 */
export function loadDeploymentConfig(chainId: number): DeploymentConfig {
    // Load SwapManager deployment
    const swapManagerPath = path.resolve(
        __dirname,
        `../../contracts/deployments/swap-manager/${chainId}.json`
    );

    if (!fs.existsSync(swapManagerPath)) {
        throw new Error(`SwapManager deployment not found for chain ${chainId} at ${swapManagerPath}`);
    }

    const swapManagerData = JSON.parse(fs.readFileSync(swapManagerPath, 'utf8'));
    const swapManagerAddresses: SwapManagerDeployment = swapManagerData.addresses;

    // Load UniversalPrivacyHook deployment
    const hookPath = path.resolve(
        __dirname,
        `../../../universal-privacy-hook/deployments/testnet-${chainId}.json`
    );

    if (!fs.existsSync(hookPath)) {
        throw new Error(`UniversalPrivacyHook deployment not found for chain ${chainId} at ${hookPath}`);
    }

    const hookData: UniversalPrivacyHookDeployment = JSON.parse(fs.readFileSync(hookPath, 'utf8'));

    // Validate that addresses match
    if (swapManagerAddresses.universalPrivacyHook !== hookData.universalPrivacyHook) {
        console.warn(
            `Warning: UniversalPrivacyHook address mismatch!\n` +
            `  SwapManager config: ${swapManagerAddresses.universalPrivacyHook}\n` +
            `  Hook deployment: ${hookData.universalPrivacyHook}\n` +
            `  Using address from Hook deployment.`
        );
    }

    // Load BoringVault deployment (optional)
    let boringVault: string | undefined;
    const boringVaultPath = path.resolve(
        __dirname,
        `../../contracts/deployments/boring-vault/${chainId}.json`
    );

    if (fs.existsSync(boringVaultPath)) {
        const boringVaultData = JSON.parse(fs.readFileSync(boringVaultPath, 'utf8'));
        boringVault = boringVaultData.addresses?.SimpleBoringVault;
        console.log("Boring vault found at ", boringVault);
    }

    return {
        chainId: hookData.chainId,
        network: hookData.network,
        swapManager: swapManagerAddresses.SwapManager,
        universalPrivacyHook: hookData.universalPrivacyHook,
        mockUSDC: hookData.mockUSDC,
        mockUSDT: hookData.mockUSDT,
        encryptedUSDC: hookData.encryptedUSDC,
        encryptedUSDT: hookData.encryptedUSDT,
        poolId: hookData.poolId,
        poolManager: hookData.poolManager,
        boringVault,
    };
}

/**
 * Get supported chain IDs
 * @returns Array of supported chain IDs
 */
export function getSupportedChainIds(): number[] {
    const swapManagerDir = path.resolve(__dirname, '../../contracts/deployments/swap-manager');

    if (!fs.existsSync(swapManagerDir)) {
        return [];
    }

    const files = fs.readdirSync(swapManagerDir);
    return files
        .filter(f => f.endsWith('.json'))
        .map(f => parseInt(f.replace('.json', '')))
        .filter(id => !isNaN(id));
}

/**
 * Get network name for chain ID
 * @param chainId The chain ID
 * @returns Network name
 */
export function getNetworkName(chainId: number): string {
    const names: { [key: number]: string } = {
        11155111: 'Sepolia',
        84532: 'Base Sepolia',
        421614: 'Arbitrum Sepolia',
    };
    return names[chainId] || `Chain ${chainId}`;
}
