// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Constants} from "@uniswap/v4-core/src/../test/utils/Constants.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {UniversalPrivacyHook} from "../../src/UniversalPrivacyHook.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {AddressConfig} from "./AddressConfig.sol";

/// @notice Deploys mock tokens, UniversalPrivacyHook, initializes pool and adds liquidity on testnet
/// @dev Uses existing PoolManager and PoolModifyLiquidityTest from the network
contract DeployTestnet is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);

    IPoolManager public manager;
    PoolModifyLiquidityTest public modifyLiquidityRouter;
    UniversalPrivacyHook public hook;
    MockERC20 public mockUSDC;
    MockERC20 public mockUSDT;
    PoolKey public poolKey;
    bytes32 public poolId;
    address public deployer;

    function setUp() public {}

    function run() public {
        // Load deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);

        uint256 chainId = block.chainid;
        console.log("Deploying on chain:", chainId);
        console.log("Network:", AddressConfig.getNetworkName(chainId));
        console.log("Deployer address:", deployer);
        console.log("Balance of Deployer:", deployer.balance);

        // Load network configuration
        AddressConfig.NetworkConfig memory config = AddressConfig.getConfig(chainId);

        // Use existing contracts from the network
        manager = IPoolManager(config.poolManager);
        modifyLiquidityRouter = PoolModifyLiquidityTest(config.poolModifyLiquidityTest);

        console.log("Using PoolManager at:", address(manager));
        console.log("Using PoolModifyLiquidityTest at:", address(modifyLiquidityRouter));

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy Mock Tokens
        console.log("\n=== Step 1: Deploying Mock Tokens ===");
        deployMockTokens();

        // Step 2: Deploy UniversalPrivacyHook with address mining
        console.log("\n=== Step 2: Deploying UniversalPrivacyHook ===");
        deployHook();

        // Step 3: Initialize Pool
        console.log("\n=== Step 3: Initializing Pool ===");
        initializePool();

        // Step 4: Add Liquidity
        console.log("\n=== Step 4: Adding Liquidity ===");
        addLiquidity();

        vm.stopBroadcast();

        // Step 5: Save deployment info to JSON
        console.log("\n=== Step 5: Saving Deployment Info ===");
        saveDeploymentInfo(chainId);
    }

    function deployMockTokens() internal {
        // Deploy mock USDC (6 decimals like real USDC)
        mockUSDC = new MockERC20("Mock USDC", "mUSDC", 6);
        console.log("Mock USDC deployed at:", address(mockUSDC));

        // Deploy mock USDT (6 decimals like real USDT)
        mockUSDT = new MockERC20("Mock USDT", "mUSDT", 6);
        console.log("Mock USDT deployed at:", address(mockUSDT));

        // Mint initial supply to deployer for testing
        uint256 initialSupply = 1_000_000 * 10**6; // 1M tokens (6 decimals)
        mockUSDC.mint(deployer, initialSupply);
        mockUSDT.mint(deployer, initialSupply);

        console.log("Minted", initialSupply / 10**6, "tokens each to deployer:", deployer);
    }

    function deployHook() internal {
        // UniversalPrivacyHook needs BEFORE_SWAP_FLAG
        uint160 permissions = uint160(Hooks.BEFORE_SWAP_FLAG);
        AddressConfig.NetworkConfig memory config = AddressConfig.getConfig(block.chainid);

        // Mine a salt that will produce a hook address with the correct permissions
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            permissions,
            type(UniversalPrivacyHook).creationCode,
            abi.encode(address(manager), deployer) // Include admin parameter (deployer from private key)
        );

        console.log("Expected hook address:", hookAddress);
        console.log("Salt found:", uint256(salt));

        // Deploy the hook using CREATE2 (deployer from private key is admin)
        hook = new UniversalPrivacyHook{salt: salt}(manager, deployer);
        require(address(hook) == hookAddress, "Hook address mismatch");

        console.log("UniversalPrivacyHook deployed at:", address(hook));

        // Set batch interval (default to 30 seconds for testnet)
        uint256 batchInterval = vm.envOr("BATCH_INTERVAL", uint256(config.batchInterval));
        hook.setBatchInterval(batchInterval);
        console.log("Batch interval set to:", batchInterval, "seconds");

        // Set SwapManager address if available from environment
        address swapManager = config.swapManager;
        if (swapManager != address(0)) {
            hook.setSwapManager(swapManager);
            console.log("SwapManager set to:", swapManager);
        } else {
            console.log("Warning: SWAP_MANAGER not set. Set it later with hook.setSwapManager()");
        }
    }

    function initializePool() internal {
        // Sort tokens to ensure currency0 < currency1
        (address token0, address token1) = address(mockUSDC) < address(mockUSDT)
            ? (address(mockUSDC), address(mockUSDT))
            : (address(mockUSDT), address(mockUSDC));

        console.log("Token0 (lower address):", token0);
        console.log("Token1 (higher address):", token1);

        // Create the pool key with sorted tokens
        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000, // 0.3% fee
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Calculate pool ID
        poolId = PoolId.unwrap(poolKey.toId());
        console.log("Pool ID:", vm.toString(poolId));

        // Initialize the pool at 1:1 price
        manager.initialize(poolKey, Constants.SQRT_PRICE_1_1);
        console.log("Pool initialized at 1:1 price");
        console.log("Fee: 0.3%");
        console.log("Tick Spacing: 60");
    }

    function addLiquidity() internal {
        // Add 10,000 of each token as liquidity
        uint256 token0Amount = 100_000 * 10**6; // 10k tokens (6 decimals)
        uint256 token1Amount = 100_000 * 10**6; // 10k tokens (6 decimals)

        console.log("Adding liquidity:", token0Amount / 10**6, "tokens each");

        // Approve infinite allowance to PoolModifyLiquidityTest router
        mockUSDC.approve(address(modifyLiquidityRouter), type(uint256).max);
        mockUSDT.approve(address(modifyLiquidityRouter), type(uint256).max);
        console.log("Approved infinite allowance to router");

        // Add liquidity using full range (tick -887220 to 887220)
        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        console.log("Tick range:", vm.toString(int256(tickLower)), "to", vm.toString(int256(tickUpper)));

        // Get current pool price
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolKey.toId());
        console.log("Current sqrtPriceX96:", sqrtPriceX96);

        // Calculate liquidity from token amounts using Uniswap's formula
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            token0Amount,
            token1Amount
        );

        console.log("Calculated liquidity:", liquidity);

        // Modify liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams(
                tickLower,
                tickUpper,
                int256(uint256(liquidity)), // Convert uint128 to int256
                bytes32(0)
            ),
            ""
        );

        console.log("Liquidity added successfully!");
    }

    function saveDeploymentInfo(uint256 chainId) internal {
        string memory networkName = AddressConfig.getNetworkName(chainId);

        // Create JSON with deployment info
        string memory json = string(
            abi.encodePacked(
                '{\n',
                '  "network": "', networkName, '",\n',
                '  "chainId": ', vm.toString(chainId), ',\n',
                '  "poolManager": "', vm.toString(address(manager)), '",\n',
                '  "universalPrivacyHook": "', vm.toString(address(hook)), '",\n',
                '  "mockUSDC": "', vm.toString(address(mockUSDC)), '",\n',
                '  "mockUSDT": "', vm.toString(address(mockUSDT)), '",\n',
                '  "poolId": "', vm.toString(poolId), '",\n',
                '  "poolKey": {\n',
                '    "currency0": "', vm.toString(Currency.unwrap(poolKey.currency0)), '",\n',
                '    "currency1": "', vm.toString(Currency.unwrap(poolKey.currency1)), '",\n',
                '    "fee": ', vm.toString(poolKey.fee), ',\n',
                '    "tickSpacing": ', vm.toString(int256(poolKey.tickSpacing)), ',\n',
                '    "hooks": "', vm.toString(address(poolKey.hooks)), '"\n',
                '  },\n',
                '  "notes": "Liquidity added. Run TestDeposit.s.sol to deposit and get encrypted token addresses"\n',
                '}'
            )
        );

        // Write to chain-specific file
        string memory filename = string(abi.encodePacked("./deployments/testnet-", vm.toString(chainId), ".json"));

        try vm.writeFile(filename, json) {
            console.log("Deployment info saved to:", filename);
        } catch {
            console.log("Could not write deployment file, but contracts deployed successfully");
            console.log("\nDeployment Summary:");
            console.log("===================");
            console.log("Network:", networkName);
            console.log("Chain ID:", chainId);
            console.log("PoolManager:", address(manager));
            console.log("UniversalPrivacyHook:", address(hook));
            console.log("Mock USDC:", address(mockUSDC));
            console.log("Mock USDT:", address(mockUSDT));
            console.log("Pool ID:", vm.toString(poolId));
        }

        console.log("\n=== Deployment Complete ===");
        console.log("Next steps:");
        console.log("1. Set SWAP_MANAGER in .env if not already set");
        console.log("2. Run TestDeposit.s.sol to deposit and get encrypted token addresses");
        console.log("3. Update your operator with these addresses");
    }
}
