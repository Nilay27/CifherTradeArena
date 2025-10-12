// Configuration for CoFHE mock contracts
// These addresses are set after deploying the mock contracts

export interface CoFHEConfig {
    zkVerifier: string;
    queryDecrypter: string;
    taskManager: string;
    acl: string;
}

// Try to load from deployment file, otherwise use defaults
export function loadCoFHEConfig(): CoFHEConfig | null {
    try {
        const fs = require('fs');
        const path = require('path');
        const configPath = path.resolve(__dirname, '../contracts/deployments/cofhe-mocks/31337.json');
        
        if (fs.existsSync(configPath)) {
            const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
            console.log("Loaded CoFHE mock contract addresses from deployment");
            return config;
        }
    } catch (error) {
        console.log("Could not load CoFHE config:", error);
    }
    
    return null;
}

// Export the loaded config
export const COFHE_CONFIG = loadCoFHEConfig();