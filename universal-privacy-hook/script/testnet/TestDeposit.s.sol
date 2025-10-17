// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {UniversalPrivacyHook} from "../../src/UniversalPrivacyHook.sol";
import {IFHERC20} from "../../src/interfaces/IFHERC20.sol";
import {AddressConfig} from "./AddressConfig.sol";

/// @notice Test deposit script that deposits tokens and retrieves encrypted token addresses
/// @dev Reads deployment addresses from environment and performs deposits to trigger encrypted token creation
contract TestDeposit is Script {
    using PoolIdLibrary for PoolKey;

    address public deployer;
    UniversalPrivacyHook public hook;
    IERC20 public mockUSDC;
    IERC20 public mockUSDT;
    PoolKey public poolKey;
    bytes32 public poolId;

    function setUp() public {}

    function run() public {
        // Load deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);

        uint256 chainId = block.chainid;
        console.log("Running test deposit on chain:", chainId);
        console.log("Network:", AddressConfig.getNetworkName(chainId));
        console.log("Deployer address:", deployer);

        // Load deployment addresses from JSON file created by DeployTestnet.s.sol
        string memory filename = string(abi.encodePacked("./deployments/testnet-", vm.toString(chainId), ".json"));
        console.log("\nReading deployment info from:", filename);

        string memory json = vm.readFile(filename);

        // Parse JSON to get addresses
        address hookAddress = vm.parseJsonAddress(json, ".universalPrivacyHook");
        address mockUSDCAddress = vm.parseJsonAddress(json, ".mockUSDC");
        address mockUSDTAddress = vm.parseJsonAddress(json, ".mockUSDT");

        console.log("Loaded addresses:");
        console.log("UniversalPrivacyHook:", hookAddress);
        console.log("Mock USDC:", mockUSDCAddress);
        console.log("Mock USDT:", mockUSDTAddress);

        // Initialize contracts
        hook = UniversalPrivacyHook(hookAddress);
        mockUSDC = IERC20(mockUSDCAddress);
        mockUSDT = IERC20(mockUSDTAddress);

        // Reconstruct pool key (tokens must be sorted)
        (address token0, address token1) = mockUSDCAddress < mockUSDTAddress
            ? (mockUSDCAddress, mockUSDTAddress)
            : (mockUSDTAddress, mockUSDCAddress);

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });

        poolId = PoolId.unwrap(poolKey.toId());
        console.log("Pool ID:", vm.toString(poolId));

        vm.startBroadcast(deployerPrivateKey);

        console.log("\n=== Step 1: Checking Balances ===");
        checkBalances();

        console.log("\n=== Step 2: Depositing to Hook ===");
        performDeposits();

        console.log("\n=== Step 3: Retrieving Encrypted Token Addresses ===");
        getEncryptedTokenAddresses(chainId);

        vm.stopBroadcast();

        console.log("\n=== Test Deposit Complete ===");
    }

    function checkBalances() internal view {
        uint256 usdcBalance = mockUSDC.balanceOf(deployer);
        uint256 usdtBalance = mockUSDT.balanceOf(deployer);

        console.log("Deployer USDC balance:", usdcBalance / 10**6, "tokens");
        console.log("Deployer USDT balance:", usdtBalance / 10**6, "tokens");

        require(usdcBalance > 0, "No USDC balance. Run DeployTestnet.s.sol first");
        require(usdtBalance > 0, "No USDT balance. Run DeployTestnet.s.sol first");
    }

    function performDeposits() internal {
        uint256 depositAmount = 100 * 10**6; // 10,000 tokens (6 decimals)

        console.log("Depositing", depositAmount / 10**6, "of each token to hook...");

        // Approve hook to spend tokens (infinite allowance)
        mockUSDC.approve(address(hook), type(uint256).max);
        mockUSDT.approve(address(hook), type(uint256).max);
        console.log("Approved infinite allowance to hook");

        // Deposit USDC
        console.log("\nDepositing USDC...");
        hook.deposit(poolKey, Currency.wrap(address(mockUSDC)), depositAmount);
        console.log("USDC deposited successfully");

        // Deposit USDT
        console.log("Depositing USDT...");
        hook.deposit(poolKey, Currency.wrap(address(mockUSDT)), depositAmount);
        console.log("USDT deposited successfully");

        // Verify encrypted balances exist (hook stores by PoolId and Currency)
        console.log("\nDeposits complete!");
    }

    function getEncryptedTokenAddresses(uint256 chainId) internal {
        // Get encrypted token addresses from hook storage
        // Hook stores: mapping(PoolId => mapping(Currency => IFHERC20)) public poolEncryptedTokens

        IFHERC20 encryptedUSDC = hook.poolEncryptedTokens(poolKey.toId(), poolKey.currency0);
        IFHERC20 encryptedUSDT = hook.poolEncryptedTokens(poolKey.toId(), poolKey.currency1);

        address encUSDCAddress = address(encryptedUSDC);
        address encUSDTAddress = address(encryptedUSDT);

        console.log("\nEncrypted Token Addresses:");
        console.log("Encrypted USDC (currency0):", encUSDCAddress);
        console.log("Encrypted USDT (currency1):", encUSDTAddress);

        // Determine which is which
        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);

        console.log("\nMapping:");
        if (token0 == address(mockUSDC)) {
            console.log("Mock USDC ->", encUSDCAddress);
            console.log("Mock USDT ->", encUSDTAddress);
        } else {
            console.log("Mock USDT ->", encUSDCAddress);
            console.log("Mock USDC ->", encUSDTAddress);
        }

        // Save to updated JSON
        saveUpdatedDeploymentInfo(chainId, encUSDCAddress, encUSDTAddress);
    }

    function saveUpdatedDeploymentInfo(uint256 chainId, address encUSDC, address encUSDT) internal {
        // Read the original JSON to preserve all fields
        string memory filename = string(abi.encodePacked("./deployments/testnet-", vm.toString(chainId), ".json"));
        string memory originalJson = vm.readFile(filename);

        // Parse existing values
        string memory networkName = vm.parseJsonString(originalJson, ".network");
        address poolManager = vm.parseJsonAddress(originalJson, ".poolManager");

        // Determine correct mapping
        address token0 = Currency.unwrap(poolKey.currency0);
        address encryptedUSDCAddr;
        address encryptedUSDTAddr;

        if (token0 == address(mockUSDC)) {
            encryptedUSDCAddr = encUSDC;
            encryptedUSDTAddr = encUSDT;
        } else {
            encryptedUSDTAddr = encUSDC;
            encryptedUSDCAddr = encUSDT;
        }

        // Create updated JSON with full deployment info including encrypted tokens
        string memory json = string(
            abi.encodePacked(
                '{\n',
                '  "network": "', networkName, '",\n',
                '  "chainId": ', vm.toString(chainId), ',\n',
                '  "poolManager": "', vm.toString(poolManager), '",\n',
                '  "universalPrivacyHook": "', vm.toString(address(hook)), '",\n',
                '  "mockUSDC": "', vm.toString(address(mockUSDC)), '",\n',
                '  "mockUSDT": "', vm.toString(address(mockUSDT)), '",\n',
                '  "encryptedUSDC": "', vm.toString(encryptedUSDCAddr), '",\n',
                '  "encryptedUSDT": "', vm.toString(encryptedUSDTAddr), '",\n',
                '  "poolId": "', vm.toString(poolId), '",\n',
                '  "poolKey": {\n',
                '    "currency0": "', vm.toString(Currency.unwrap(poolKey.currency0)), '",\n',
                '    "currency1": "', vm.toString(Currency.unwrap(poolKey.currency1)), '",\n',
                '    "fee": ', vm.toString(poolKey.fee), ',\n',
                '    "tickSpacing": ', vm.toString(int256(poolKey.tickSpacing)), ',\n',
                '    "hooks": "', vm.toString(address(poolKey.hooks)), '"\n',
                '  },\n',
                '  "status": "complete",\n',
                '  "notes": "All tokens deployed, liquidity added, encrypted tokens created"\n',
                '}'
            )
        );

        // Overwrite the same file with complete info
        try vm.writeFile(filename, json) {
            console.log("\nUpdated deployment info saved to:", filename);
            console.log("   (overwrote with complete info including encrypted tokens)");
        } catch {
            console.log("\nCould not write file, but here's the complete deployment info:");
            console.log(json);
        }

        console.log("\nAdd these to your operator configuration:");
        console.log("UNIVERSAL_PRIVACY_HOOK=", address(hook));
        console.log("MOCK_USDC=", address(mockUSDC));
        console.log("MOCK_USDT=", address(mockUSDT));
        console.log("ENCRYPTED_USDC=", encryptedUSDCAddr);
        console.log("ENCRYPTED_USDT=", encryptedUSDTAddr);
        console.log("POOL_ID=", vm.toString(poolId));
    }
}
