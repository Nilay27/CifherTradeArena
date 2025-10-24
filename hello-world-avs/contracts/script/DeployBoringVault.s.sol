// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Test.sol";
import {SimpleBoringVault} from "../src/SimpleBoringVault.sol";
import {stdJson} from "forge-std/StdJson.sol";

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
 * @dev Now uses dynamic addresses from deployment files
 */
contract DeployBoringVault is Script {
    using stdJson for string;

    address internal deployer;
    address internal tradeManager;
    address internal usdc;
    address internal usdt;

    function setUp() public virtual {
        deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));
        vm.label(deployer, "Deployer");

        // Load addresses from deployment files
        loadDeploymentAddresses();
    }

    function loadDeploymentAddresses() internal {
        uint256 chainId = block.chainid;

        // Load mock token addresses
        string memory mocksPath = string.concat("deployments/mocks/", vm.toString(chainId), ".json");
        require(vm.exists(mocksPath), "Mock deployment file does not exist");
        string memory mocksJson = vm.readFile(mocksPath);

        usdc = mocksJson.readAddress(".tokens.USDC");
        usdt = mocksJson.readAddress(".tokens.USDT");

        // Load TradeManager address
        string memory tradeManagerPath = string.concat("deployments/trade-manager/", vm.toString(chainId), ".json");
        require(vm.exists(tradeManagerPath), "TradeManager deployment file does not exist");
        string memory tradeManagerJson = vm.readFile(tradeManagerPath);

        tradeManager = tradeManagerJson.readAddress(".addresses.TradeManager");

        console2.log("\n=== Loaded Deployment Addresses ===");
        console2.log("USDC:", usdc);
        console2.log("USDT:", usdt);
        console2.log("TradeManager:", tradeManager);
    }

    function run() external virtual {
        vm.startBroadcast(deployer);

        console2.log("\n=== Deploying SimpleBoringVault ===");
        console2.log("Deployer:", deployer);
        console2.log("TradeManager:", tradeManager);

        // Deploy SimpleBoringVault
        // Constructor params: tradeManager
        SimpleBoringVault vault = new SimpleBoringVault(
            deployer  // tradeManager = deployer (for flexibility)
        );

        console2.log("\nSimpleBoringVault deployed at:", address(vault));

        // Verify configuration
        console2.log("\nVerifying vault configuration...");
        require(vault.tradeManager() == deployer, "TradeManager mismatch");
        console2.log("TradeManager (deployer):", vault.tradeManager());

        // Authorize TradeManager as executor
        console2.log("\nAuthorizing TradeManager as executor...");
        vault.setExecutor(tradeManager, true);
        console2.log("TradeManager authorized as executor");

        // Verify TradeManager is authorized
        require(vault.isAuthorized(tradeManager), "TradeManager not authorized");
        console2.log("TradeManager authorized:", vault.isAuthorized(tradeManager));

        // Set BoringVault address in TradeManager
        console2.log("\nSetting BoringVault in TradeManager...");
        ITradeManager(tradeManager).setBoringVault(payable(address(vault)));
        console2.log("BoringVault set in TradeManager");

        // Mint 10M USDC and USDT to vault
        console2.log("\nMinting tokens to vault...");
        IERC20(usdc).mint(address(vault), 10_000_000 * 10**6);
        console2.log("Minted 10,000,000 USDC to vault");

        IERC20(usdt).mint(address(vault), 10_000_000 * 10**6);
        console2.log("Minted 10,000,000 USDT to vault");

        vm.stopBroadcast();

        console2.log("\n=== Deployment Complete ===");
        console2.log("SimpleBoringVault:", address(vault));
        console2.log("\nAuthorization Summary:");
        console2.log("- TradeManager can execute:", vault.isAuthorized(tradeManager));
        console2.log("\nFunding Summary:");
        console2.log("- USDC: 10,000,000");
        console2.log("- USDT: 10,000,000");
        console2.log("\nIntegration Status:");
        console2.log("- Anyone can deposit: vault.deposit(token, amount)");
        console2.log("- Anyone can withdraw: vault.withdraw(token, amount, to)");
        console2.log("- TradeManager can execute: vault.execute(target, data, value)");

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
            '","tradeManager":"',
            vm.toString(tradeManager),
            '","usdc":"',
            vm.toString(usdc),
            '","usdt":"',
            vm.toString(usdt),
            '"}}'
        );

        if (!vm.exists(outputPath)) {
            vm.createDir(outputPath, true);
        }

        vm.writeFile(fileName, json);
        console2.log("\nDeployment info written to:", fileName);
    }
}
