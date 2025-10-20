// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Test.sol";
import {SimpleBoringVault} from "../src/SimpleBoringVault.sol";

interface ITradeManager {
    function setBoringVault(address payable _vault) external;
    function admin() external view returns (address);
}

interface IERC20 {
    function mint(address to, uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
}

/**
 * @title DeployBoringVault
 * @notice Deploys SimpleBoringVault and configures it with TradeManager
 */
contract DeployBoringVault is Script {
    address internal deployer;

    // Deployed contract addresses on Sepolia
    address constant UNIVERSAL_PRIVACY_HOOK = 0x2b9fDfbbDBD418Be2bD5d8c0baA73357FF214080;
    address constant SWAP_MANAGER = 0x628c7202678d099e95E89084a9FE5b73E2a88464;
    address constant USDC = 0x478700f3a33818eeBc3d9D41D4da8C54FDAEaD4b;
    address constant USDT = 0x2213f46EF0395026760cf8E3AD4a3a8f8ad7D0B0;

    function setUp() public virtual {
        deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));
        vm.label(deployer, "Deployer");
    }

    function run() external virtual {
        vm.startBroadcast(deployer);

        console2.log("\n=== Deploying SimpleBoringVault ===");
        console2.log("Deployer:", deployer);
        console2.log("UniversalPrivacyHook:", UNIVERSAL_PRIVACY_HOOK);
        console2.log("TradeManager:", SWAP_MANAGER);

        // Deploy SimpleBoringVault
        // Constructor params: hook, tradeManager
        // Set tradeManager = deployer so we can manage executors in the future
        SimpleBoringVault vault = new SimpleBoringVault(
            UNIVERSAL_PRIVACY_HOOK,
            deployer  // tradeManager = deployer (for flexibility)
        );

        console2.log("\nSimpleBoringVault deployed at:", address(vault));

        // Verify configuration
        console2.log("\nVerifying vault configuration...");
        require(vault.hook() == UNIVERSAL_PRIVACY_HOOK, "Hook mismatch");
        require(vault.tradeManager() == deployer, "TradeManager mismatch");
        console2.log("Hook:", vault.hook());
        console2.log("TradeManager (deployer):", vault.tradeManager());

        // Authorize TradeManager as executor
        console2.log("\nAuthorizing TradeManager as executor...");
        vault.setExecutor(SWAP_MANAGER, true);
        console2.log("TradeManager authorized as executor");

        // Verify TradeManager is authorized
        require(vault.isAuthorized(SWAP_MANAGER), "TradeManager not authorized");
        console2.log("TradeManager authorized:", vault.isAuthorized(SWAP_MANAGER));

        // Set BoringVault address in TradeManager
        console2.log("\nSetting BoringVault in TradeManager...");
        ITradeManager(SWAP_MANAGER).setBoringVault(payable(address(vault)));
        console2.log("BoringVault set in TradeManager");

        // mint usdc and usdt to vault
        console2.log("\nMinting tokens to vault...");
        IERC20(USDC).mint(address(vault), 100_000 * 10**6);
        console2.log("Minted 100,000 USDC to vault");

        IERC20(USDT).mint(address(vault), 100_000 * 10**6);
        console2.log("Minted 100,000 USDT to vault");

        vm.stopBroadcast();

        console2.log("\n=== Deployment Complete ===");
        console2.log("SimpleBoringVault:", address(vault));
        console2.log("\nAuthorization Summary:");
        console2.log("- Hook can execute:", vault.isAuthorized(UNIVERSAL_PRIVACY_HOOK));
        console2.log("- TradeManager can execute:", vault.isAuthorized(SWAP_MANAGER));
        console2.log("\nIntegration Status:");
        console2.log("- Hook can deposit: vault.deposit(token, amount)");
        console2.log("- TradeManager can execute UEI: vault.execute(target, data, value)");
        console2.log("- TradeManager.processUEI() -> vault.execute() -> target protocol");

        // Write deployment info
        writeDeploymentInfo(address(vault));
    }

    function writeDeploymentInfo(address vault) internal {
        string memory outputPath = "deployments/boring-vault/";
        string memory fileName = string.concat(outputPath, vm.toString(block.chainid), ".json");

        string memory json = string.concat(
            '{"lastUpdate":{"timestamp":"',
            vm.toString(block.timestamp),
            '","block_number":"',
            vm.toString(block.number),
            '"},"addresses":{"SimpleBoringVault":"',
            vm.toString(vault),
            '","hook":"',
            vm.toString(UNIVERSAL_PRIVACY_HOOK),
            '","tradeManager":"',
            vm.toString(SWAP_MANAGER),
            '"}}'
        );

        if (!vm.exists(outputPath)) {
            vm.createDir(outputPath, true);
        }

        vm.writeFile(fileName, json);
        console2.log("\nDeployment info written to:", fileName);
    }
}
