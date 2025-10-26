export const CHAIN_IDS = {
    BASE_SEPOLIA: 84532,
    ARBITRUM_SEPOLIA: 421614,
} as const;

type AddressMap = Record<string, string>;

interface ChainDeployment {
    tokens: AddressMap;
    protocols: AddressMap;
    markets: AddressMap;
    tradeManager: string;
}

export const CHAIN_DEPLOYMENTS: Record<number, ChainDeployment> = {
    [CHAIN_IDS.BASE_SEPOLIA]: {
        tokens: {
            USDC: "0x9c14aC9E88Eb84Fc341291FBf06B891592E3bcC7",
            USDT: "0x0f1333EaFF107C4d205d2d80b567D003d7870ad5",
            PT_eUSDE: "0xFF9F206B333C902Af93426f7b6630F103cB85309",
            PT_sUSDE: "0x4cabe68B3C6d65F7f12cDDa41998257b6E16DF16",
            PT_USR: "0xfB8C7bE6BAfB392BF2386EBD616916f08e2d5E1f",
        },
        protocols: {
            pendle: "0x81095fCdb1502B986a6A3ce33323412d45167364",
            aave: "0x7cAC40567e1891902eeafE3fD10FfC3ED4043252",
            morpho: "0x909D68D8A57Ab8F62B6391e117a77B215Ab21Dfc",
        },
        markets: {
            PT_eUSDE: "0x757f4cAf00AFcd41F8389Eb5dE4a8a737a262D45",
            PT_sUSDE: "0xfeCb7785CA797A709095F4146140329fCf970FE8",
            PT_USR: "0xB909F6b859910ad59D2F4003cd8610Af4fa41Fef",
        },
        tradeManager: "0xea93e65fefaF6EB63f32BF2Da6739d2Fb2373EE4",
    },
    [CHAIN_IDS.ARBITRUM_SEPOLIA]: {
        tokens: {
            USDC: "0xfE9C3ee7E4ADDfca38C66019E6121FBeeED13b6b",
            USDT: "0xBc5149ff8C82547a5BF4da05bBca673FF6550801",
            PT_eUSDE: "0x522dEC96f85E65F98B838274b6F915e2C070A465",
            PT_sUSDE: "0x56552E8Aed11b0Ad278823568c48B4f4af67Ba81",
            PT_USR: "0x5176a7128A92C522B7f65507A1C127c53C180D12",
        },
        protocols: {
            pendle: "0xdbf367db4979bE1111BA3dfe8f54052419BBbedc",
            aave: "0x0d73a73862D21B55E59736026AFca3b9b78A5dBf",
            morpho: "0x2CF5914AbE87e5db3e1D2F43c1Bb88DDB198CcD8",
        },
        markets: {
            PT_eUSDE: "0x757f4cAf00AFcd41F8389Eb5dE4a8a737a262D45",
            PT_sUSDE: "0xfeCb7785CA797A709095F4146140329fCf970FE8",
            PT_USR: "0xB909F6b859910ad59D2F4003cd8610Af4fa41Fef",
        },
        tradeManager: "0x6eC553091d057012897168b2FA9af1e2EaD09838",
    },
};

// Build lower-case lookup tables for quick mapping
const baseAddresses = (() => {
    const base = CHAIN_DEPLOYMENTS[CHAIN_IDS.BASE_SEPOLIA];
    const map: Record<string, string> = {};
    Object.values(base.tokens).forEach(addr => map[addr.toLowerCase()] = addr);
    Object.values(base.protocols).forEach(addr => map[addr.toLowerCase()] = addr);
    Object.values(base.markets).forEach(addr => map[addr.toLowerCase()] = addr);
    map[base.tradeManager.toLowerCase()] = base.tradeManager;
    return map;
})();

const remapByChain: Record<number, Record<string, string>> = {
    [CHAIN_IDS.ARBITRUM_SEPOLIA]: (() => {
        const base = CHAIN_DEPLOYMENTS[CHAIN_IDS.BASE_SEPOLIA];
        const target = CHAIN_DEPLOYMENTS[CHAIN_IDS.ARBITRUM_SEPOLIA];
        const mapping: Record<string, string> = {};

        for (const key of Object.keys(base.tokens)) {
            const baseAddr = base.tokens[key];
            const targetAddr = target.tokens[key];
            mapping[baseAddr.toLowerCase()] = targetAddr;
        }
        for (const key of Object.keys(base.protocols)) {
            const baseAddr = base.protocols[key];
            const targetAddr = target.protocols[key];
            mapping[baseAddr.toLowerCase()] = targetAddr;
        }
        for (const key of Object.keys(base.markets)) {
            const baseAddr = base.markets[key];
            const targetAddr = target.markets[key];
            mapping[baseAddr.toLowerCase()] = targetAddr;
        }

        mapping[base.tradeManager.toLowerCase()] = target.tradeManager;

        return mapping;
    })(),
};

/**
 * Map a base address to its target-chain counterpart if available.
 * Falls back to the original address if no mapping exists.
 */
export function mapAddressForChain(address: string, targetChainId: number): string {
    if (!address) return address;
    const lower = address.toLowerCase();

    if (targetChainId === CHAIN_IDS.BASE_SEPOLIA) {
        // Ensure checksum casing using stored base address if present
        return baseAddresses[lower] ?? address;
    }

    const mapping = remapByChain[targetChainId];
    if (!mapping) {
        return address;
    }

    return mapping[lower] ?? address;
}

export function getTradeManagerForChain(targetChainId: number): string {
    const deployment = CHAIN_DEPLOYMENTS[targetChainId];
    if (!deployment) {
        throw new Error(`No trade manager deployment found for chain ${targetChainId}`);
    }
    return deployment.tradeManager;
}
