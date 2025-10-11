import { ethers } from 'ethers';
import { exec } from 'child_process';
import { promisify } from 'util';
import fs from 'fs';
import path from 'path';
import dotenv from 'dotenv';

// Load environment variables
dotenv.config();

const execAsync = promisify(exec);

// Configuration
const RPC_URL = process.env.RPC_URL || 'http://localhost:8545';
const CHAIN_ID = 31337;

// Test wallets (Anvil default accounts)
const DEPLOYER_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const OPERATOR_KEY = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d';
const USER1_KEY = '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a';
const USER2_KEY = '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6';

// Contract ABIs will be loaded dynamically
interface DeploymentAddresses {
    // Universal Privacy Hook contracts
    poolManager?: string;
    universalPrivacyHook?: string;
    positionManager?: string;
    modifyLiquidityRouter?: string;
    swapRouter?: string;
    quoter?: string;
    permit2?: string;
    tokenA?: string;
    tokenB?: string;

    // AVS contracts
    swapManager?: string;
    mockPrivacyHook?: string;
    serviceManager?: string;
    stakeRegistry?: string;
}

class E2ETestRunner {
    private provider: ethers.JsonRpcProvider;
    private deployerWallet: ethers.Wallet;
    private operatorWallet: ethers.Wallet;
    private user1Wallet: ethers.Wallet;
    private user2Wallet: ethers.Wallet;
    private addresses: DeploymentAddresses = {};

    constructor() {
        this.provider = new ethers.JsonRpcProvider(RPC_URL);
        this.deployerWallet = new ethers.Wallet(DEPLOYER_KEY, this.provider);
        this.operatorWallet = new ethers.Wallet(OPERATOR_KEY, this.provider);
        this.user1Wallet = new ethers.Wallet(USER1_KEY, this.provider);
        this.user2Wallet = new ethers.Wallet(USER2_KEY, this.provider);
    }

    // Step 1: Deploy Universal Privacy Hook contracts
    async deployUniversalPrivacyHook() {
        console.log('\n🚀 Deploying Universal Privacy Hook contracts...');

        try {
            // Use Forge to deploy the contracts
            const deployCmd = `cd universal-privacy-hook && forge script script/Anvil.s.sol:CounterScript --rpc-url ${RPC_URL} --broadcast --private-key ${DEPLOYER_KEY}`;

            const { stdout, stderr } = await execAsync(deployCmd);
            console.log('Deploy output:', stdout);
            if (stderr) console.error('Deploy stderr:', stderr);

            // Parse the deployment output to get addresses
            // This is a simplified version - you'd need to parse the actual forge output
            // For now, let's check if there's a broadcast file
            const broadcastDir = path.join('universal-privacy-hook', 'broadcast', 'Anvil.s.sol', `${CHAIN_ID}`);
            const runLatest = path.join(broadcastDir, 'run-latest.json');

            if (fs.existsSync(runLatest)) {
                const broadcastData = JSON.parse(fs.readFileSync(runLatest, 'utf8'));

                // Extract deployed contract addresses from broadcast data
                for (const tx of broadcastData.transactions) {
                    if (tx.contractName === 'PoolManager') {
                        this.addresses.poolManager = tx.contractAddress;
                    } else if (tx.contractName === 'UniversalPrivacyHook') {
                        this.addresses.universalPrivacyHook = tx.contractAddress;
                    } else if (tx.contractName === 'PositionManager') {
                        this.addresses.positionManager = tx.contractAddress;
                    } else if (tx.contractName === 'MockERC20' && !this.addresses.tokenA) {
                        this.addresses.tokenA = tx.contractAddress;
                    } else if (tx.contractName === 'MockERC20' && this.addresses.tokenA) {
                        this.addresses.tokenB = tx.contractAddress;
                    }
                }

                // Save addresses to file
                this.saveAddresses('universal-privacy-hook');
            }

            console.log('✅ Universal Privacy Hook deployed');
            console.log('   PoolManager:', this.addresses.poolManager);
            console.log('   Hook:', this.addresses.universalPrivacyHook);

        } catch (error) {
            console.error('Error deploying Universal Privacy Hook:', error);
            throw error;
        }
    }

    // Step 2: Deploy AVS contracts
    async deployAVSContracts() {
        console.log('\n🚀 Deploying AVS contracts...');

        try {
            // Deploy AVS contracts
            const deployCmd = `cd hello-world-avs && npm run deploy:core`;
            const { stdout, stderr } = await execAsync(deployCmd);

            console.log('AVS deploy output:', stdout);
            if (stderr) console.error('AVS deploy stderr:', stderr);

            // Load AVS deployment addresses
            const avsDeploymentPath = path.join('hello-world-avs', 'contracts', 'deployments', 'swap-manager', `${CHAIN_ID}.json`);
            if (fs.existsSync(avsDeploymentPath)) {
                const avsDeployment = JSON.parse(fs.readFileSync(avsDeploymentPath, 'utf8'));
                this.addresses.swapManager = avsDeployment.addresses.SwapManager;
                this.addresses.serviceManager = avsDeployment.addresses.serviceManager;
                this.addresses.stakeRegistry = avsDeployment.addresses.stakeRegistry;
            }

            console.log('✅ AVS contracts deployed');
            console.log('   SwapManager:', this.addresses.swapManager);

        } catch (error) {
            console.error('Error deploying AVS:', error);
            throw error;
        }
    }

    // Step 3: Connect Universal Privacy Hook to AVS
    async connectHookToAVS() {
        console.log('\n🔗 Connecting Universal Privacy Hook to AVS...');

        try {
            // Instead of using MockPrivacyHook, we'll configure the real UniversalPrivacyHook
            // to work with the SwapManager

            // Load contract ABIs
            const swapManagerABI = JSON.parse(
                fs.readFileSync(path.join('hello-world-avs', 'abis', 'SwapManager.json'), 'utf8')
            );

            const swapManager = new ethers.Contract(
                this.addresses.swapManager!,
                swapManagerABI,
                this.deployerWallet
            );

            // Authorize the UniversalPrivacyHook in SwapManager
            console.log('Authorizing UniversalPrivacyHook in SwapManager...');
            const authTx = await swapManager.authorizeHook(this.addresses.universalPrivacyHook);
            await authTx.wait();

            console.log('✅ Hook connected to AVS');

        } catch (error) {
            console.error('Error connecting hook to AVS:', error);
            throw error;
        }
    }

    // Step 4: Setup tokens and liquidity
    async setupTokensAndLiquidity() {
        console.log('\n💰 Setting up tokens and liquidity...');

        try {
            // Mint tokens to users
            const mockERC20ABI = [
                'function mint(address to, uint256 amount) external',
                'function approve(address spender, uint256 amount) external returns (bool)',
                'function balanceOf(address account) external view returns (uint256)',
                'function transfer(address to, uint256 amount) external returns (bool)'
            ];

            const tokenA = new ethers.Contract(this.addresses.tokenA!, mockERC20ABI, this.deployerWallet);
            const tokenB = new ethers.Contract(this.addresses.tokenB!, mockERC20ABI, this.deployerWallet);

            // Mint tokens to users
            const mintAmount = ethers.parseUnits('10000', 18);

            console.log('Minting tokens to User1...');
            await (await tokenA.mint(this.user1Wallet.address, mintAmount)).wait();
            await (await tokenB.mint(this.user1Wallet.address, mintAmount)).wait();

            console.log('Minting tokens to User2...');
            await (await tokenA.mint(this.user2Wallet.address, mintAmount)).wait();
            await (await tokenB.mint(this.user2Wallet.address, mintAmount)).wait();

            // Check balances
            const user1BalanceA = await tokenA.balanceOf(this.user1Wallet.address);
            const user1BalanceB = await tokenB.balanceOf(this.user1Wallet.address);

            console.log('✅ Tokens setup complete');
            console.log(`   User1: ${ethers.formatUnits(user1BalanceA, 18)} TokenA, ${ethers.formatUnits(user1BalanceB, 18)} TokenB`);

        } catch (error) {
            console.error('Error setting up tokens:', error);
            throw error;
        }
    }

    // Step 5: Register operator
    async registerOperator() {
        console.log('\n👷 Registering operator...');

        try {
            const registerCmd = `cd hello-world-avs && npm run register:operator`;
            const { stdout, stderr } = await execAsync(registerCmd);

            console.log('Register output:', stdout);
            if (stderr && !stderr.includes('warning')) {
                console.error('Register stderr:', stderr);
            }

            console.log('✅ Operator registered');

        } catch (error) {
            console.error('Error registering operator:', error);
            throw error;
        }
    }

    // Step 6: Start operator monitoring (in background)
    async startOperator() {
        console.log('\n🤖 Starting operator in background...');

        try {
            // Start the operator in background
            exec('cd hello-world-avs && npm run start:operator', (error, stdout, stderr) => {
                if (error) {
                    console.error('Operator error:', error);
                }
                console.log('Operator output:', stdout);
                if (stderr) console.error('Operator stderr:', stderr);
            });

            // Give operator time to start
            await this.sleep(3000);

            console.log('✅ Operator started');

        } catch (error) {
            console.error('Error starting operator:', error);
            throw error;
        }
    }

    // Step 7: User deposits to privacy hook
    async userDeposit() {
        console.log('\n💵 User depositing to privacy hook...');

        try {
            // Load hook ABI and create contract instance
            // This would need the actual UniversalPrivacyHook ABI
            const hookABI = [
                'function deposit(address token, uint256 amount) external',
                'function getEncryptedBalance(address user, address token) external view returns (uint256)'
            ];

            const hook = new ethers.Contract(
                this.addresses.universalPrivacyHook!,
                hookABI,
                this.user1Wallet
            );

            // Approve and deposit tokens
            const tokenA = new ethers.Contract(
                this.addresses.tokenA!,
                ['function approve(address spender, uint256 amount) external returns (bool)'],
                this.user1Wallet
            );

            const depositAmount = ethers.parseUnits('1000', 18);

            console.log('Approving tokens...');
            await (await tokenA.approve(this.addresses.universalPrivacyHook!, depositAmount)).wait();

            console.log('Depositing tokens...');
            await (await hook.deposit(this.addresses.tokenA!, depositAmount)).wait();

            console.log('✅ Deposit complete');

        } catch (error) {
            console.error('Error depositing:', error);
            throw error;
        }
    }

    // Step 8: Submit encrypted swap
    async submitEncryptedSwap() {
        console.log('\n🔐 Submitting encrypted swap...');

        try {
            // Initialize CoFHE for encryption
            const { cofhejs, Encryptable } = require('cofhejs/node');

            await cofhejs.initializeWithEthers({
                ethersProvider: this.provider,
                ethersSigner: this.user1Wallet,
                environment: 'MOCK'
            });

            // Encrypt swap amount
            const swapAmount = BigInt(100 * 1e18); // 100 tokens
            const encResult = await cofhejs.encrypt([Encryptable.uint128(swapAmount)]);

            if (!encResult.success) {
                throw new Error('Encryption failed');
            }

            // Submit encrypted swap intent
            const hookABI = [
                'function submitSwapIntent(address tokenIn, address tokenOut, bytes encryptedAmount) external'
            ];

            const hook = new ethers.Contract(
                this.addresses.universalPrivacyHook!,
                hookABI,
                this.user1Wallet
            );

            const encryptedAmount = ethers.AbiCoder.defaultAbiCoder().encode(
                ['uint256'],
                [encResult.data[0].ctHash]
            );

            console.log('Submitting swap intent...');
            const tx = await hook.submitSwapIntent(
                this.addresses.tokenA!,
                this.addresses.tokenB!,
                encryptedAmount
            );
            await tx.wait();

            console.log('✅ Encrypted swap submitted');

        } catch (error) {
            console.error('Error submitting swap:', error);
            throw error;
        }
    }

    // Step 9: Wait for AVS to process
    async waitForAVSProcessing() {
        console.log('\n⏳ Waiting for AVS to process batch...');

        try {
            // Monitor for BatchSettled event
            const swapManagerABI = JSON.parse(
                fs.readFileSync(path.join('hello-world-avs', 'abis', 'SwapManager.json'), 'utf8')
            );

            const swapManager = new ethers.Contract(
                this.addresses.swapManager!,
                swapManagerABI,
                this.provider
            );

            return new Promise((resolve) => {
                swapManager.once('BatchSettled', (batchId: string, success: boolean) => {
                    console.log(`✅ Batch ${batchId} settled: ${success ? 'SUCCESS' : 'FAILED'}`);
                    resolve(success);
                });

                // Timeout after 30 seconds
                setTimeout(() => {
                    console.log('⚠️  Timeout waiting for batch settlement');
                    resolve(false);
                }, 30000);
            });

        } catch (error) {
            console.error('Error waiting for AVS:', error);
            throw error;
        }
    }

    // Step 10: Verify final balances
    async verifyBalances() {
        console.log('\n📊 Verifying final balances...');

        try {
            const mockERC20ABI = [
                'function balanceOf(address account) external view returns (uint256)'
            ];

            const tokenA = new ethers.Contract(this.addresses.tokenA!, mockERC20ABI, this.provider);
            const tokenB = new ethers.Contract(this.addresses.tokenB!, mockERC20ABI, this.provider);

            const user1BalanceA = await tokenA.balanceOf(this.user1Wallet.address);
            const user1BalanceB = await tokenB.balanceOf(this.user1Wallet.address);

            const user2BalanceA = await tokenA.balanceOf(this.user2Wallet.address);
            const user2BalanceB = await tokenB.balanceOf(this.user2Wallet.address);

            console.log('Final Balances:');
            console.log(`  User1: ${ethers.formatUnits(user1BalanceA, 18)} TokenA, ${ethers.formatUnits(user1BalanceB, 18)} TokenB`);
            console.log(`  User2: ${ethers.formatUnits(user2BalanceA, 18)} TokenA, ${ethers.formatUnits(user2BalanceB, 18)} TokenB`);

            // Also check encrypted balances in the hook
            const hookABI = [
                'function getEncryptedBalance(address user, address token) external view returns (uint256)'
            ];

            const hook = new ethers.Contract(
                this.addresses.universalPrivacyHook!,
                hookABI,
                this.provider
            );

            const user1EncryptedA = await hook.getEncryptedBalance(this.user1Wallet.address, this.addresses.tokenA!);
            const user1EncryptedB = await hook.getEncryptedBalance(this.user1Wallet.address, this.addresses.tokenB!);

            console.log('\nEncrypted Balances in Hook:');
            console.log(`  User1: ${ethers.formatUnits(user1EncryptedA, 18)} TokenA, ${ethers.formatUnits(user1EncryptedB, 18)} TokenB`);

        } catch (error) {
            console.error('Error verifying balances:', error);
            throw error;
        }
    }

    // Helper functions
    private saveAddresses(project: string) {
        const addressFile = path.join(project, 'deployed-addresses.json');
        fs.writeFileSync(addressFile, JSON.stringify(this.addresses, null, 2));
        console.log(`Addresses saved to ${addressFile}`);
    }

    private loadAddresses(project: string) {
        const addressFile = path.join(project, 'deployed-addresses.json');
        if (fs.existsSync(addressFile)) {
            const loaded = JSON.parse(fs.readFileSync(addressFile, 'utf8'));
            this.addresses = { ...this.addresses, ...loaded };
        }
    }

    private sleep(ms: number): Promise<void> {
        return new Promise(resolve => setTimeout(resolve, ms));
    }

    // Main test flow
    async runE2ETest() {
        console.log('🧪 Starting E2E Test for Encrypted Swaps');
        console.log('=====================================\n');

        try {
            // Deploy everything
            await this.deployUniversalPrivacyHook();
            await this.deployAVSContracts();
            await this.connectHookToAVS();

            // Setup
            await this.setupTokensAndLiquidity();
            await this.registerOperator();
            await this.startOperator();

            // Run swap flow
            await this.userDeposit();
            await this.submitEncryptedSwap();
            await this.waitForAVSProcessing();
            await this.verifyBalances();

            console.log('\n✅ E2E Test Complete!');

        } catch (error) {
            console.error('\n❌ E2E Test Failed:', error);
            process.exit(1);
        }
    }
}

// Run the test
async function main() {
    const tester = new E2ETestRunner();
    await tester.runE2ETest();
}

main().catch(console.error);