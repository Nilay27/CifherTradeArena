#!/usr/bin/env node

const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

// CoFHE.js expects these exact addresses
const EXPECTED_ADDRESSES = {
    zkVerifier: '0x0000000000000000000000000000000000000100',
    queryDecrypter: '0x0000000000000000000000000000000000000200',
    taskManager: '0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9',  // Expected by FHE.sol
    acl: '0x0000000000000000000000000000000000000300'
};

// Read deployed addresses from file (required)
const deploymentFile = path.resolve(__dirname, '../contracts/deployments/cofhe-mocks/31337.json');
let DEPLOYED_ADDRESSES;

try {
    const deployment = JSON.parse(fs.readFileSync(deploymentFile, 'utf8'));
    DEPLOYED_ADDRESSES = {
        zkVerifier: deployment.zkVerifier,
        queryDecrypter: deployment.queryDecrypter,
        taskManager: deployment.taskManager,
        acl: deployment.acl
    };
    console.log('Loaded deployed addresses from:', deploymentFile);
} catch (e) {
    console.error('ERROR: CoFHE mock contracts deployment file not found!');
    console.error('Please run: npm run deploy:cofhe-mocks');
    console.error('Expected file:', deploymentFile);
    process.exit(1);
}

async function setupCoFHEonAnvil() {
    const provider = new ethers.JsonRpcProvider('http://localhost:8545');
    const wallet = new ethers.Wallet('0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80', provider);

    console.log('Setting up CoFHE mock contracts on Anvil...\n');
    
    // Get the bytecode from deployed contracts
    const zkVerifierCode = await provider.getCode(DEPLOYED_ADDRESSES.zkVerifier);
    const queryDecrypterCode = await provider.getCode(DEPLOYED_ADDRESSES.queryDecrypter);
    const taskManagerCode = await provider.getCode(DEPLOYED_ADDRESSES.taskManager);
    const aclCode = await provider.getCode(DEPLOYED_ADDRESSES.acl);
    
    console.log('Got bytecode from deployed contracts');
    console.log('ZkVerifier code length:', zkVerifierCode.length);
    console.log('QueryDecrypter code length:', queryDecrypterCode.length);
    console.log('TaskManager code length:', taskManagerCode.length);
    console.log('ACL code length:', aclCode.length);
    
    // Use Anvil's setCode to place the bytecode at expected addresses
    try {
        // Set ZkVerifier code at expected address
        await provider.send('anvil_setCode', [
            EXPECTED_ADDRESSES.zkVerifier,
            zkVerifierCode
        ]);
        console.log(`✅ Set ZkVerifier code at ${EXPECTED_ADDRESSES.zkVerifier}`);
        
        // Set QueryDecrypter code at expected address
        await provider.send('anvil_setCode', [
            EXPECTED_ADDRESSES.queryDecrypter,
            queryDecrypterCode
        ]);
        console.log(`✅ Set QueryDecrypter code at ${EXPECTED_ADDRESSES.queryDecrypter}`);
        
        // Set TaskManager code at expected address (required by ZkVerifier)
        await provider.send('anvil_setCode', [
            EXPECTED_ADDRESSES.taskManager,
            taskManagerCode
        ]);
        console.log(`✅ Set TaskManager code at ${EXPECTED_ADDRESSES.taskManager}`);
        
        // Set ACL code at expected address
        await provider.send('anvil_setCode', [
            EXPECTED_ADDRESSES.acl,
            aclCode
        ]);
        console.log(`✅ Set ACL code at ${EXPECTED_ADDRESSES.acl}`);

        // Initialize and configure the TaskManager
        console.log('\nInitializing and configuring TaskManager...');
        const taskManagerABI = [
            'function initialize(address initialOwner) public',
            'function setACLContract(address _acl) external',
            'function setSecurityZoneMin(int32 _min) external',
            'function setSecurityZoneMax(int32 _max) external',
            'function setVerifierSigner(address _signer) external'
        ];
        const taskManager = new ethers.Contract(EXPECTED_ADDRESSES.taskManager, taskManagerABI, wallet);

        // Initialize TaskManager - just try to initialize, will revert if already done
        try {
            const initTx = await taskManager.initialize(wallet.address);
            await initTx.wait();
            console.log('✅ TaskManager initialized');
        } catch (initError) {
            console.log('TaskManager initialization skipped (may already be initialized)');
        }

        // Configure TaskManager like in CoFheTest
        try {
            // Set ACL contract
            await (await taskManager.setACLContract(EXPECTED_ADDRESSES.acl)).wait();
            console.log('✅ ACL contract set in TaskManager');

            // Set security zones
            await (await taskManager.setSecurityZoneMin(0)).wait();
            await (await taskManager.setSecurityZoneMax(1)).wait();
            console.log('✅ Security zones configured');

            // Set verifier signer (using the same address as in MockCoFHE.sol and cofhejs)
            // Both MockCoFHE.sol and cofhejs use the same private key which gives this address
            const SIGNER_ADDRESS = '0x6E12D8C87503D4287c294f2Fdef96ACd9DFf6bd2';
            await (await taskManager.setVerifierSigner(SIGNER_ADDRESS)).wait();
            console.log('✅ Verifier signer set to:', SIGNER_ADDRESS);
        } catch (configError) {
            console.log('TaskManager configuration error:', configError.message);
        }

        // Initialize ACL
        console.log('\nInitializing ACL...');
        const aclABI = ['function initialize(address owner) public'];
        const acl = new ethers.Contract(EXPECTED_ADDRESSES.acl, aclABI, wallet);

        try {
            await (await acl.initialize(wallet.address)).wait();
            console.log('✅ ACL initialized');
        } catch (aclError) {
            console.log('ACL initialization skipped (may already be initialized)');
        }

        // Verify the code is set
        const verifyZk = await provider.getCode(EXPECTED_ADDRESSES.zkVerifier);
        const verifyQd = await provider.getCode(EXPECTED_ADDRESSES.queryDecrypter);
        const verifyTm = await provider.getCode(EXPECTED_ADDRESSES.taskManager);
        const verifyAcl = await provider.getCode(EXPECTED_ADDRESSES.acl);

        console.log('\nVerification:');
        console.log('ZkVerifier at expected address:', verifyZk.length > 2 ? '✅' : '❌');
        console.log('QueryDecrypter at expected address:', verifyQd.length > 2 ? '✅' : '❌');
        console.log('TaskManager at expected address:', verifyTm.length > 2 ? '✅' : '❌');
        console.log('ACL at expected address:', verifyAcl.length > 2 ? '✅' : '❌');

        console.log('\n✅ All CoFHE mock contracts set at expected addresses');
        console.log('CoFHE.js should now work with real FHE encryption/decryption');
        
    } catch (error) {
        console.error('Error setting code:', error);
        console.log('\n⚠️  Make sure Anvil is running with proper permissions');
    }
}

setupCoFHEonAnvil().catch(console.error);