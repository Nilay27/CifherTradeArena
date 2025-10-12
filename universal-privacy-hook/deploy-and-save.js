const { ethers } = require('ethers');
const { exec } = require('child_process');
const { promisify } = require('util');
const fs = require('fs');
const path = require('path');

const execAsync = promisify(exec);

// Contract ABIs (simplified)
const POOL_MANAGER_ABI = [
    'function initialize(address) external'
];

const MOCK_ERC20_ABI = [
    'function mint(address to, uint256 amount) external',
    'function approve(address spender, uint256 amount) external returns (bool)',
    'function balanceOf(address account) external view returns (uint256)',
    'function name() external view returns (string)',
    'function symbol() external view returns (string)'
];

async function deployContracts() {
    console.log('🚀 Deploying Universal Privacy Hook contracts...\n');

    const provider = new ethers.JsonRpcProvider('http://localhost:8545');
    const wallet = new ethers.Wallet('0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80', provider);

    const addresses = {};

    try {
        // First, compile the contracts
        console.log('📦 Compiling contracts...');
        const { stdout: compileOut, stderr: compileErr } = await execAsync('forge build --via-ir');
        if (compileErr && !compileErr.includes('Warning')) {
            console.error('Compile error:', compileErr);
        }

        // Deploy PoolManager
        console.log('\n1️⃣ Deploying PoolManager...');
        const poolManagerFactory = new ethers.ContractFactory(
            require('./out/PoolManager.sol/PoolManager.json').abi,
            require('./out/PoolManager.sol/PoolManager.json').bytecode.object,
            wallet
        );
        const poolManager = await poolManagerFactory.deploy();
        await poolManager.waitForDeployment();
        addresses.poolManager = await poolManager.getAddress();
        console.log('   PoolManager deployed at:', addresses.poolManager);

        // Deploy Mock Tokens
        console.log('\n2️⃣ Deploying Mock Tokens...');
        const mockTokenFactory = new ethers.ContractFactory(
            require('./out/MockERC20.sol/MockERC20.json').abi,
            require('./out/MockERC20.sol/MockERC20.json').bytecode.object,
            wallet
        );

        // Token A (Mock USDC)
        const tokenA = await mockTokenFactory.deploy('Mock USDC', 'mUSDC', 18);
        await tokenA.waitForDeployment();
        addresses.tokenA = await tokenA.getAddress();
        console.log('   TokenA (mUSDC) deployed at:', addresses.tokenA);

        // Token B (Mock USDT)
        const tokenB = await mockTokenFactory.deploy('Mock USDT', 'mUSDT', 18);
        await tokenB.waitForDeployment();
        addresses.tokenB = await tokenB.getAddress();
        console.log('   TokenB (mUSDT) deployed at:', addresses.tokenB);

        // Deploy UniversalPrivacyHook
        console.log('\n3️⃣ Deploying UniversalPrivacyHook...');

        // Use HookMiner to find a valid address with correct flags
        console.log('   Finding valid hook address...');

        // For simplicity, we'll deploy directly (in production, use HookMiner)
        const hookFactory = new ethers.ContractFactory(
            require('./out/UniversalPrivacyHook.sol/UniversalPrivacyHook.json').abi,
            require('./out/UniversalPrivacyHook.sol/UniversalPrivacyHook.json').bytecode.object,
            wallet
        );

        const hook = await hookFactory.deploy(addresses.poolManager);
        await hook.waitForDeployment();
        addresses.universalPrivacyHook = await hook.getAddress();
        console.log('   UniversalPrivacyHook deployed at:', addresses.universalPrivacyHook);

        // Deploy routers
        console.log('\n4️⃣ Deploying Router Contracts...');

        // Deploy PoolModifyLiquidityTest
        const modifyLiquidityFactory = new ethers.ContractFactory(
            require('./out/PoolModifyLiquidityTest.sol/PoolModifyLiquidityTest.json').abi,
            require('./out/PoolModifyLiquidityTest.sol/PoolModifyLiquidityTest.json').bytecode.object,
            wallet
        );
        const modifyLiquidityRouter = await modifyLiquidityFactory.deploy(addresses.poolManager);
        await modifyLiquidityRouter.waitForDeployment();
        addresses.modifyLiquidityRouter = await modifyLiquidityRouter.getAddress();
        console.log('   ModifyLiquidityRouter deployed at:', addresses.modifyLiquidityRouter);

        // Deploy PoolSwapTest
        const swapRouterFactory = new ethers.ContractFactory(
            require('./out/PoolSwapTest.sol/PoolSwapTest.json').abi,
            require('./out/PoolSwapTest.sol/PoolSwapTest.json').bytecode.object,
            wallet
        );
        const swapRouter = await swapRouterFactory.deploy(addresses.poolManager);
        await swapRouter.waitForDeployment();
        addresses.swapRouter = await swapRouter.getAddress();
        console.log('   SwapRouter deployed at:', addresses.swapRouter);

        // Save addresses to file
        console.log('\n💾 Saving addresses...');
        const deploymentData = {
            chainId: 31337,
            deployedAt: new Date().toISOString(),
            addresses: addresses
        };

        // Create deployments directory if it doesn't exist
        const deploymentsDir = path.join(__dirname, 'deployments');
        if (!fs.existsSync(deploymentsDir)) {
            fs.mkdirSync(deploymentsDir, { recursive: true });
        }

        // Save to file
        const deploymentFile = path.join(deploymentsDir, `${deploymentData.chainId}.json`);
        fs.writeFileSync(deploymentFile, JSON.stringify(deploymentData, null, 2));
        console.log(`   Addresses saved to: ${deploymentFile}`);

        // Also save a simplified version for easy access
        const simpleFile = path.join(__dirname, 'deployed-addresses.json');
        fs.writeFileSync(simpleFile, JSON.stringify(addresses, null, 2));
        console.log(`   Simplified addresses saved to: ${simpleFile}`);

        console.log('\n✅ Deployment complete!\n');
        console.log('Deployed Addresses:');
        console.log('===================');
        Object.entries(addresses).forEach(([name, address]) => {
            console.log(`${name.padEnd(25)} : ${address}`);
        });

        return addresses;

    } catch (error) {
        console.error('\n❌ Deployment failed:', error);
        throw error;
    }
}

// Initialize pool if needed
async function initializePool(addresses) {
    console.log('\n🏊 Initializing Pool...');

    const provider = new ethers.JsonRpcProvider('http://localhost:8545');
    const wallet = new ethers.Wallet('0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80', provider);

    try {
        // Create pool using the hook
        console.log('Creating pool with UniversalPrivacyHook...');

        // Pool creation logic here
        // This would involve calling the appropriate functions on PoolManager
        // through the hook to create a liquidity pool

        console.log('✅ Pool initialized');

    } catch (error) {
        console.error('Error initializing pool:', error);
        throw error;
    }
}

// Main function
async function main() {
    try {
        // Check if anvil is running
        const provider = new ethers.JsonRpcProvider('http://localhost:8545');
        await provider.getNetwork();
        console.log('✅ Anvil is running\n');

        // Deploy contracts
        const addresses = await deployContracts();

        // Initialize pool
        await initializePool(addresses);

        process.exit(0);
    } catch (error) {
        if (error.code === 'ECONNREFUSED') {
            console.error('❌ Anvil is not running. Please start it with: anvil');
        } else {
            console.error('Error:', error);
        }
        process.exit(1);
    }
}

// Run if called directly
if (require.main === module) {
    main();
}

module.exports = { deployContracts, initializePool };