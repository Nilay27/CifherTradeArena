const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

async function runIntegration() {
    console.log('\n🔄 Running Integration Test...\n');

    const provider = new ethers.JsonRpcProvider('http://localhost:8545');

    // Test wallets - ensure they're properly connected
    const user1Wallet = new ethers.Wallet('0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a');
    const user1 = user1Wallet.connect(provider);
    const user2Wallet = new ethers.Wallet('0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6');
    const user2 = user2Wallet.connect(provider);

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

    // Setup tokens from UniversalPrivacyHook deployment
    const mockERC20ABI = [
        'function mint(address to, uint256 amount) external',
        'function approve(address spender, uint256 amount) external returns (bool)',
        'function balanceOf(address account) external view returns (uint256)'
    ];

    const tokenA = new ethers.Contract(hookAddresses.tokenA, mockERC20ABI, user1);
    const tokenB = new ethers.Contract(hookAddresses.tokenB, mockERC20ABI, user1);

    // Use UniversalPrivacyHook ABI
    // Updated with correct function signatures
    const hookABI = [
        'function deposit(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, address currency, uint256 amount) external',
        'function submitSwapIntent(tuple(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, address tokenIn, address tokenOut, bytes calldata encAmount, uint256 deadline) external returns (bytes32)',
        'event IntentSubmitted(bytes32 indexed poolId, address indexed currency0, address indexed currency1, bytes32 intentId)',
        'event Deposited(bytes32 indexed poolId, address indexed currency, address indexed user, uint256 amount)'
    ];

    const universalHook = new ethers.Contract(
        hookAddresses.universalPrivacyHook,
        hookABI,
        user1
    );

    // Initialize CoFHE for encryption
    const { cofhejs, Encryptable } = require('cofhejs/node');

    console.log('Initializing CoFHE.js...');

    // Create a fresh wallet instance for CoFHE (similar to operator setup)
    const cofheWallet = new ethers.Wallet('0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a', provider);

    try {
        await cofhejs.initializeWithEthers({
            ethersProvider: provider,
            ethersSigner: cofheWallet,
            environment: 'MOCK'
        });
        console.log('✅ CoFHE.js initialized');

        // Try to create a permit for FHE operations
        try {
            await cofhejs.createPermit();
            console.log('✅ Permit created successfully');
        } catch (permitError) {
            console.log('Permit creation failed (not critical for mock):', permitError.message);
        }
    } catch (initError) {
        console.error('Failed to initialize CoFHE.js:', initError);
        throw initError;
    }

    console.log('\n💰 First, minting tokens and depositing to hook...');

    // Mint tokens to user
    const mintAmount = ethers.parseUnits('10000', 18);
    await (await tokenA.mint(user1.address, mintAmount)).wait();
    await (await tokenB.mint(user1.address, mintAmount)).wait();
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

    // Approve and deposit to hook
    const depositAmount = ethers.parseUnits('1000', 18);
    await (await tokenA.approve(hookAddresses.universalPrivacyHook, depositAmount)).wait();
    await (await universalHook.deposit(poolKey, hookAddresses.tokenA, depositAmount)).wait();
    console.log('✅ Deposited tokens to hook');

    console.log('\n📝 Submitting encrypted swap intent...');

    // Encrypt amount for swap
    const swapAmount = BigInt(100 * 1e18); // 100 tokens
    console.log('Encrypting amount:', swapAmount.toString());

    let encResult;
    try {
        encResult = await cofhejs.encrypt([Encryptable.uint128(swapAmount)]);
        console.log('Encryption result:', encResult);
    } catch (encError) {
        console.error('Encryption error:', encError);
        throw encError;
    }

    if (!encResult || !encResult.success) {
        console.error('Encryption failed. Result:', encResult);
        throw new Error('Encryption failed');
    }

    // console.log('Encrypted successfully, ctHash:', encResult.data[0].ctHash);
    // const encryptedAmount = ethers.AbiCoder.defaultAbiCoder().encode(
    //     ['uint256'],
    //     [encResult.data[0].ctHash]
    // );

    // Submit swap intent to UniversalPrivacyHook
    const deadline = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now
    const tx = await universalHook.submitSwapIntent(
        poolKey,
        hookAddresses.tokenA,
        hookAddresses.tokenB,
        encResult.data[0],
        deadline,
        { gasLimit: 5000000 }
    );

    console.log('Transaction hash:', tx.hash);
    const receipt = await tx.wait();
    console.log('✅ Intent submitted successfully!');

    // Wait for batch processing
    console.log('\n⏳ Waiting for AVS to process batch...');

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

        // Timeout after 20 seconds
        setTimeout(() => {
            console.log('⚠️  Timeout waiting for batch');
            resolve();
        }, 20000);
    });

    console.log('\n✅ Integration test complete!');
}

runIntegration().catch(console.error);
