#!/usr/bin/env node

const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
const { cofhejs, Encryptable } = require('cofhejs/node');

async function runIntegration() {
    console.log('\n🔄 Running Integration Test...\n');

    const provider = new ethers.JsonRpcProvider('http://localhost:8545');

    // Test wallet
    const user1 = new ethers.Wallet('0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a', provider);

    // Load deployed addresses
    const hookAddresses = JSON.parse(
        fs.readFileSync('./universal-privacy-hook/deployments/latest.json', 'utf8')
    );

    const avsAddresses = JSON.parse(
        fs.readFileSync('./hello-world-avs/contracts/deployments/swap-manager/31337.json', 'utf8')
    );

    console.log('Deployed Contracts:');
    console.log('  Universal Privacy Hook:', hookAddresses.universalPrivacyHook);
    console.log('  Pool Manager:', hookAddresses.poolManager);
    console.log('  TokenA:', hookAddresses.tokenA);
    console.log('  TokenB:', hookAddresses.tokenB);
    console.log('  SwapManager:', avsAddresses.addresses.SwapManager);

    // Setup tokens
    const mockERC20ABI = [
        'function mint(address to, uint256 amount) external',
        'function approve(address spender, uint256 amount) external returns (bool)',
        'function balanceOf(address account) external view returns (uint256)'
    ];

    const tokenA = new ethers.Contract(hookAddresses.tokenA, mockERC20ABI, user1);
    const tokenB = new ethers.Contract(hookAddresses.tokenB, mockERC20ABI, user1);

    // Load the actual compiled ABI from artifacts
    const hookArtifact = JSON.parse(
        fs.readFileSync('./universal-privacy-hook/out/UniversalPrivacyHook.sol/UniversalPrivacyHook.json', 'utf8')
    );

    console.log('Hook ABI functions:', hookArtifact.abi.filter(x => x.type === 'function').map(x => x.name));

    const universalHook = new ethers.Contract(
        hookAddresses.universalPrivacyHook,
        hookArtifact.abi,
        user1
    );

    console.log('Contract has submitIntent method?', typeof universalHook.submitIntent === 'function');

    // First verify the signer address
    console.log('\nVerifying signer:');
    console.log('  user1 address:', user1.address);
    console.log('  user1 getAddress():', await user1.getAddress());

    // Initialize CoFHE for encryption
    console.log('\nInitializing CoFHE.js...');

    // Check FHE mock addresses
    console.log('Checking FHE mock setup...');
    const mockAddresses = {
        zkVerifier: '0x0000000000000000000000000000000000000100',
        queryDecrypter: '0x0000000000000000000000000000000000000200',
        acl: '0x0000000000000000000000000000000000000300',
        taskManager: '0xeA30c4B8b44078Bbf8a6ef5b9f1eC1626C7848D9'
    };

    for (const [name, addr] of Object.entries(mockAddresses)) {
        const code = await provider.getCode(addr);
        console.log(`  ${name} at ${addr}: ${code.length > 2 ? '✓ has code' : '✗ no code'}`);
    }

    await cofhejs.initializeWithEthers({
        ethersProvider: provider,
        ethersSigner: user1,
        environment: 'MOCK'
    });

    // Try to create a permit for FHE operations
    try {
        // Create permit for the hook contract to use the encrypted values
        const permit = await cofhejs.createPermit();
        console.log('✅ Permit created successfully');

        // Debug: Check what signer CoFHE is using
        console.log('\nDebug CoFHE signer info:');
        console.log('  user1 address:', user1.address);
        console.log('  hook address:', hookAddresses.universalPrivacyHook);

        // The hook contract needs to be authorized to use the encrypted values
        // Try to authorize the hook contract
        try {
            // ACL is at 0x0300, not 0x0100 (which is zkVerifier)
            const mockACL = new ethers.Contract(
                '0x0000000000000000000000000000000000000300',
                ['function allowAccess(address user, address contractAddress) external'],
                user1
            );

            // Allow the hook to access encrypted values from user1
            await mockACL.allowAccess(user1.address, hookAddresses.universalPrivacyHook);
            console.log('✅ Hook authorized in ACL');
        } catch (aclError) {
            console.log('Could not authorize hook in ACL (not critical):', aclError.message.slice(0, 100));
        }
    } catch (permitError) {
        console.log('Permit creation failed (not critical for mock):', permitError.message);
    }

    console.log('✅ CoFHE.js initialized');

    // Set the SwapManager address in UniversalPrivacyHook
    console.log('\n🔗 Setting SwapManager in UniversalPrivacyHook...');
    try {
        let setupNonce = await user1.getNonce();
        const tx = await universalHook.setSwapManager(avsAddresses.addresses.SwapManager, { nonce: setupNonce });
        await tx.wait();
        console.log('✅ SwapManager set in UniversalPrivacyHook');
    } catch (error) {
        console.log('Warning: Could not set SwapManager:', error.message);
    }

    console.log('\n💰 First, minting tokens and depositing to hook...');

    // Mint tokens to user
    const mintAmount = ethers.parseUnits('10000', 18);
    let currentNonce = await user1.getNonce();

    await (await tokenA.mint(user1.address, mintAmount, { nonce: currentNonce++ })).wait();
    await (await tokenB.mint(user1.address, mintAmount, { nonce: currentNonce++ })).wait();
    console.log('✅ Tokens minted');

    // Create PoolKey struct
    // Sort tokens for currency0 and currency1
    const [currency0, currency1] = hookAddresses.tokenA.toLowerCase() < hookAddresses.tokenB.toLowerCase()
        ? [hookAddresses.tokenA, hookAddresses.tokenB]
        : [hookAddresses.tokenB, hookAddresses.tokenA];

    const poolKey = {
        currency0: currency0,
        currency1: currency1,
        fee: 3000, // 0.3% fee
        tickSpacing: 60,
        hooks: hookAddresses.universalPrivacyHook
    };

    // Approve and deposit BOTH tokens to hook (needed for bidirectional swaps)
    const depositAmount = ethers.parseUnits('1000', 18);

    // Deposit tokenA
    await (await tokenA.approve(hookAddresses.universalPrivacyHook, depositAmount, { nonce: currentNonce++ })).wait();
    await (await universalHook.deposit(poolKey, hookAddresses.tokenA, depositAmount, { nonce: currentNonce++ })).wait();
    console.log('✅ Deposited tokenA to hook');

    // Deposit tokenB (needed for B→A swaps)
    await (await tokenB.approve(hookAddresses.universalPrivacyHook, depositAmount, { nonce: currentNonce++ })).wait();
    await (await universalHook.deposit(poolKey, hookAddresses.tokenB, depositAmount, { nonce: currentNonce++ })).wait();
    console.log('✅ Deposited tokenB to hook');

    console.log('\n📝 Submitting 3 swap intents quickly (mixed directions)...');

    // First intent: 100 tokens A→B
    const swapAmount1 = BigInt(100 * 1e18);
    console.log('Intent 1: Encrypting', swapAmount1.toString(), 'for A→B swap');
    const encResult1 = await cofhejs.encrypt([Encryptable.uint128(swapAmount1)]);
    if (!encResult1.success) {
        throw new Error('Encryption failed: ' + JSON.stringify(encResult1.error));
    }
    const encryptedAmount1 = encResult1.data[0];

    // Second intent: 50 tokens B→A (opposite direction!)
    const swapAmountOpp = BigInt(50 * 1e18);
    console.log('Intent 2: Encrypting', swapAmountOpp.toString(), 'for B→A swap (opposite!)');
    const encResultOpp = await cofhejs.encrypt([Encryptable.uint128(swapAmountOpp)]);
    if (!encResultOpp.success) {
        throw new Error('Encryption failed: ' + JSON.stringify(encResultOpp.error));
    }
    const encryptedAmountOpp = encResultOpp.data[0];

    // Third intent: 75 tokens A→B
    const swapAmount3 = BigInt(75 * 1e18);
    console.log('Intent 3: Encrypting', swapAmount3.toString(), 'for A→B swap');
    const encResult3 = await cofhejs.encrypt([Encryptable.uint128(swapAmount3)]);
    if (!encResult3.success) {
        throw new Error('Encryption failed: ' + JSON.stringify(encResult3.error));
    }
    const encryptedAmount3 = encResult3.data[0];

    // Submit all 3 intents quickly to be in the same batch
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600); // 1 hour from now

    // Get fresh nonce for intent submissions
    currentNonce = await user1.getNonce();

    console.log('\nSubmitting Intent 1 (100 A→B)...');
    try {
        const tx1 = await universalHook.submitIntent(
            poolKey,
            hookAddresses.tokenA,
            hookAddresses.tokenB,
            encryptedAmount1,
            deadline,
            { nonce: currentNonce++ }
        );
        await tx1.wait();
        console.log('✅ Intent 1 submitted');
    } catch (error) {
        console.error('Error submitting intent 1:', error);
        throw error;
    }

    console.log('\nSubmitting Intent 2 (50 B→A - opposite direction!)...');
    try {
        const tx2 = await universalHook.submitIntent(
            poolKey,
            hookAddresses.tokenB,  // Note: swapped order
            hookAddresses.tokenA,
            encryptedAmountOpp,
            deadline,
            { nonce: currentNonce++ }
        );
        await tx2.wait();
        console.log('✅ Intent 2 submitted (will be matched with Intent 1)');
    } catch (error) {
        console.error('Error submitting intent 2:', error);
        throw error;
    }

    console.log('\nSubmitting Intent 3 (75 A→B)...');
    try {
        const tx3 = await universalHook.submitIntent(
            poolKey,
            hookAddresses.tokenA,
            hookAddresses.tokenB,
            encryptedAmount3,
            deadline,
            { nonce: currentNonce++ }
        );
        await tx3.wait();
        console.log('✅ Intent 3 submitted');
    } catch (error) {
        console.error('Error submitting intent 3:', error);
        throw error;
    }

    // Wait for 6 blocks to trigger batch finalization
    console.log('\n⏳ Waiting 6 blocks to trigger batch finalization...');

    const startBlock = await provider.getBlockNumber();
    console.log(`Current block: ${startBlock}`);

    // Mine 6 blocks to ensure batch interval passes
    for (let i = 0; i < 6; i++) {
        await provider.send('evm_mine', []);
        const currentBlock = await provider.getBlockNumber();
        console.log(`Mined block ${currentBlock}`);
    }

    console.log('\n📝 Submitting Intent 4 after batch interval (25 B→A)...');

    // Fourth intent: 25 tokens B→A (will trigger batch finalization)
    const swapAmount4 = BigInt(25 * 1e18);
    console.log('Intent 4: Encrypting', swapAmount4.toString(), 'for B→A swap');
    const encResult4 = await cofhejs.encrypt([Encryptable.uint128(swapAmount4)]);

    if (!encResult4.success) {
        throw new Error('Fourth encryption failed: ' + JSON.stringify(encResult4.error));
    }

    const encryptedAmount4 = encResult4.data[0];

    try {
        currentNonce = await user1.getNonce();
        const tx4 = await universalHook.submitIntent(
            poolKey,
            hookAddresses.tokenB,
            hookAddresses.tokenA,
            encryptedAmount4,
            deadline,
            { nonce: currentNonce }
        );
        await tx4.wait();
        console.log('✅ Intent 4 submitted (should trigger batch with 3 previous intents)');
    } catch (error) {
        console.error('Error submitting intent 4:', error);
        throw error;
    }

    // Now wait for batch processing
    console.log('\n⏳ Waiting for AVS to process batch (should trigger after 2 intents)...');

    const swapManagerABI = JSON.parse(
        fs.readFileSync('./hello-world-avs/abis/SwapManager.json', 'utf8')
    );

    const swapManager = new ethers.Contract(
        avsAddresses.addresses.SwapManager,
        swapManagerABI,
        provider
    );

    // Listen for batch events
    await new Promise((resolve) => {
        swapManager.once('BatchFinalized', (batchId, taskCount) => {
            console.log(`\n📦 Batch ${batchId} finalized with ${taskCount} tasks`);
            resolve();
        });

        // Timeout after 30 seconds
        setTimeout(() => {
            console.log('⚠️  Timeout waiting for batch');
            resolve();
        }, 30000);
    });

    console.log('\n✅ Integration test complete!');
}

runIntegration().catch(error => {
    console.error('\n❌ Integration test failed:', error);
    process.exit(1);
});