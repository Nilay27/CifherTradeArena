// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Test.sol";
import {TradeManager} from "../src/TradeManager.sol";
import {ECDSAStakeRegistry} from "@eigenlayer-middleware/src/unaudited/ECDSAStakeRegistry.sol";
import {CoreDeployLib, CoreDeploymentParsingLib} from "./utils/CoreDeploymentParsingLib.sol";
import {TradeManagerDeploymentLib} from "./utils/TradeManagerDeploymentLib.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {SimpleBoringVault} from "../src/SimpleBoringVault.sol";


interface IUniversalPrivacyHook {
    function setTradeManager(address _swapManager) external;
    function owner() external view returns (address);
}

/**
 * @title DeployTradeManagerDirect
 * @notice Deploys TradeManager as a NON-UPGRADEABLE contract (no proxy)
 * @dev This fixes the SepoliaConfig immutable variable issue with proxies
 */
contract DeployTradeManagerDirect is Script {
    using stdJson for string;

    address internal deployer;
    CoreDeployLib.DeploymentData coreDeployment;
    TradeManagerDeploymentLib.DeploymentConfigData swapManagerConfig;
    address payable boringVault;

    // UniversalPrivacyHook address on Sepolia
    address constant UNIVERSAL_PRIVACY_HOOK = 0x2b9fDfbbDBD418Be2bD5d8c0baA73357FF214080;

    function setUp() public virtual {
        deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));
        vm.label(deployer, "Deployer");

        swapManagerConfig =
            TradeManagerDeploymentLib.readDeploymentConfigValues("config/swap-manager/", block.chainid);

        coreDeployment =
            CoreDeploymentParsingLib.readDeploymentJson("deployments/core/", block.chainid);

        // Load BoringVault address
        string memory boringVaultPath = string.concat("deployments/boring-vault/", vm.toString(block.chainid), ".json");
        require(vm.exists(boringVaultPath), "BoringVault deployment file does not exist");
        string memory boringVaultJson = vm.readFile(boringVaultPath);

        boringVault = payable(boringVaultJson.readAddress(".addresses.SimpleBoringVault"));
    }

    function run() external virtual {
        vm.startBroadcast(deployer);

        console2.log("\n=== Deploying NON-UPGRADEABLE TradeManager ===");
        console2.log("Deployer:", deployer);
        console2.log("Rewards Owner:", swapManagerConfig.rewardsOwner);
        console2.log("Rewards Initiator:", swapManagerConfig.rewardsInitiator);

        // Read existing deployment to get stake registry
        TradeManagerDeploymentLib.DeploymentData memory existingDeployment =
            TradeManagerDeploymentLib.readDeploymentJson("deployments/swap-manager/", block.chainid);

        console2.log("\nUsing existing StakeRegistry:", existingDeployment.stakeRegistry);

        // Deploy TradeManager directly (NO PROXY)
        TradeManager tradeManager = new TradeManager(
            coreDeployment.avsDirectory,
            existingDeployment.stakeRegistry,
            coreDeployment.rewardsCoordinator,
            coreDeployment.delegationManager,
            coreDeployment.allocationManager,
            deployer // admin
        );

        console2.log("\nTradeManager deployed at:", address(tradeManager));

        // Verify admin
        console2.log("\nVerifying admin...");
        address currentAdmin = tradeManager.admin();
        console2.log("Current admin:", currentAdmin);
        require(currentAdmin == deployer, "Admin mismatch");

        // Link the existing BoringVault
        tradeManager.setBoringVault(boringVault);
        console2.log("BoringVault linked:", boringVault);

        // Authorize TradeManager as executor within the vault (requires deployer to be current vault tradeManager)
        SimpleBoringVault(boringVault).setExecutor(address(tradeManager), true);
        console2.log("TradeManager authorized inside SimpleBoringVault");

        vm.stopBroadcast();

        console2.log("\n=== Deployment Complete ===");
        console2.log("TradeManager (non-upgradeable):", address(tradeManager));
        console2.log("StakeRegistry:", existingDeployment.stakeRegistry);
        console2.log("UniversalPrivacyHook:", UNIVERSAL_PRIVACY_HOOK);
        console2.log("SimpleBoringVault:", boringVault);

        // Write deployment info
        writeDeploymentInfo(address(tradeManager), existingDeployment);
    }

    function writeDeploymentInfo(
        address tradeManager,
        TradeManagerDeploymentLib.DeploymentData memory existingDeployment
    ) internal {
        string memory outputPath = "deployments/trade-manager/";
        string memory fileName = string.concat(outputPath, vm.toString(block.chainid), ".json");

        string memory json = string.concat(
            '{"lastUpdate":{"timestamp":"',
            vm.toString(block.timestamp),
            '","block_number":"',
            vm.toString(block.number),
            '"},"addresses":{"TradeManager":"',
            vm.toString(tradeManager),
            '","TradeManagerType":"direct-non-upgradeable","stakeRegistry":"',
            vm.toString(existingDeployment.stakeRegistry),
            '","universalPrivacyHook":"',
            vm.toString(UNIVERSAL_PRIVACY_HOOK),
            '","boringVault":"',
            vm.toString(boringVault),
            '","strategy":"',
            vm.toString(existingDeployment.strategy),
            '","token":"',
            vm.toString(existingDeployment.token),
            '"}}'
        );

        if (!vm.exists(outputPath)) {
            vm.createDir(outputPath, true);
        }

        vm.writeFile(fileName, json);
        console2.log("\nDeployment info written to:", fileName);
    }
}
