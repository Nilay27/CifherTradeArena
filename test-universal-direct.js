#!/usr/bin/env node

const { ethers } = require('ethers');
const fs = require('fs');

async function test() {
    const provider = new ethers.JsonRpcProvider('http://localhost:8545');
    const wallet = new ethers.Wallet('0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80', provider);

    // Load addresses
    const hookDeployment = JSON.parse(
        fs.readFileSync('./universal-privacy-hook/deployments/latest.json', 'utf8')
    );

    // Load ABI
    const hookArtifact = JSON.parse(
        fs.readFileSync('./universal-privacy-hook/out/UniversalPrivacyHook.sol/UniversalPrivacyHook.json', 'utf8')
    );

    console.log('Hook address:', hookDeployment.universalPrivacyHook);
    console.log('ABI functions:', hookArtifact.abi.filter(x => x.type === 'function').map(x => x.name));

    // Create contract instance
    const hook = new ethers.Contract(hookDeployment.universalPrivacyHook, hookArtifact.abi, wallet);

    console.log('Hook interface:', hook.interface ? 'exists' : 'undefined');
    if (hook.interface) {
        console.log('Contract methods available:', Object.keys(hook.interface.functions || {}));
    }
    console.log('submitIntent exists?', typeof hook.submitIntent);
    console.log('Hook object keys:', Object.keys(hook).slice(0, 10));

    // Try to encode a call
    const poolKey = {
        currency0: hookDeployment.tokenA,
        currency1: hookDeployment.tokenB,
        fee: 3000,
        tickSpacing: 60,
        hooks: hookDeployment.universalPrivacyHook
    };

    const encryptedAmount = {
        ctHash: ethers.toBigInt('0x1234'),
        securityZone: 0,
        utype: 6,
        signature: '0x' + '00'.repeat(65)
    };

    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);

    try {
        // Try to encode the function call
        const data = hook.interface.encodeFunctionData('submitIntent', [
            poolKey,
            hookDeployment.tokenA,
            hookDeployment.tokenB,
            encryptedAmount,
            deadline
        ]);
        console.log('Encoded data:', data.slice(0, 100) + '...');
        console.log('Data length:', data.length);

        // Try to actually call it
        console.log('\nTrying actual call...');
        const tx = await hook.submitIntent(
            poolKey,
            hookDeployment.tokenA,
            hookDeployment.tokenB,
            encryptedAmount,
            deadline,
            { gasLimit: 5000000 }
        );
        console.log('Transaction hash:', tx.hash);

    } catch (error) {
        console.error('Error:', error.message);
        if (error.transaction) {
            console.log('Transaction data:', error.transaction.data);
        }
    }
}

test().catch(console.error);