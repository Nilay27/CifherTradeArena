#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

// Parse addresses from forge script output
function parseDeploymentFromOutput(output) {
    const addresses = {};

    // Parse each contract address from the logs
    const patterns = {
        poolManager: /PoolManager deployed at:\s*(0x[a-fA-F0-9]{40})/,
        tokenA: /TokenA deployed at:\s*(0x[a-fA-F0-9]{40})/,
        tokenB: /TokenB deployed at:\s*(0x[a-fA-F0-9]{40})/,
        universalPrivacyHook: /UniversalPrivacyHook deployed at:\s*(0x[a-fA-F0-9]{40})/,
        positionManager: /PositionManager deployed at:\s*(0x[a-fA-F0-9]{40})/,
        lpRouter: /LPRouter deployed at:\s*(0x[a-fA-F0-9]{40})/,
        swapRouter: /SwapRouter deployed at:\s*(0x[a-fA-F0-9]{40})/
    };

    for (const [key, pattern] of Object.entries(patterns)) {
        const match = output.match(pattern);
        if (match) {
            addresses[key] = match[1];
        }
    }

    return addresses;
}

// Read from stdin or from a file passed as argument
let input = '';

if (process.argv[2]) {
    // Read from file
    input = fs.readFileSync(process.argv[2], 'utf8');
} else {
    // Read from stdin
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', chunk => {
        input += chunk;
    });

    process.stdin.on('end', () => {
        processInput(input);
    });
}

function processInput(input) {
    const addresses = parseDeploymentFromOutput(input);

    if (Object.keys(addresses).length === 0) {
        console.error('No addresses found in output');
        process.exit(1);
    }

    // Create deployments directory if it doesn't exist
    const deploymentsDir = path.join(__dirname, 'deployments');
    if (!fs.existsSync(deploymentsDir)) {
        fs.mkdirSync(deploymentsDir, { recursive: true });
    }

    // Save to latest.json
    const deploymentFile = path.join(deploymentsDir, 'latest.json');
    fs.writeFileSync(deploymentFile, JSON.stringify(addresses, null, 2));

    console.log('Deployment addresses saved to:', deploymentFile);
    console.log('Addresses:', addresses);
}

// If we have a file argument, process it immediately
if (process.argv[2]) {
    processInput(input);
}