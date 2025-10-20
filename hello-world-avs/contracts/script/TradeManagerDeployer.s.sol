// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Test.sol";
import {TradeManagerDeploymentLib} from "./utils/TradeManagerDeploymentLib.sol";
import {CoreDeployLib, CoreDeploymentParsingLib} from "./utils/CoreDeploymentParsingLib.sol";
import {UpgradeableProxyLib} from "./utils/UpgradeableProxyLib.sol";
import {StrategyBase} from "@eigenlayer/contracts/strategies/StrategyBase.sol";
import {ERC20Mock} from "../test/ERC20Mock.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {StrategyFactory} from "@eigenlayer/contracts/strategies/StrategyFactory.sol";
import {StrategyManager} from "@eigenlayer/contracts/core/StrategyManager.sol";
import {IRewardsCoordinator} from "@eigenlayer/contracts/interfaces/IRewardsCoordinator.sol";
import {TradeManager} from "../src/TradeManager.sol";

import {
    IECDSAStakeRegistryTypes,
    IStrategy
} from "@eigenlayer-middleware/src/interfaces/IECDSAStakeRegistry.sol";

import "forge-std/Test.sol";

interface IUniversalPrivacyHook {
    function setTradeManager(address _tradeManager) external;
}

contract TradeManagerDeployer is Script, Test {
    using CoreDeployLib for *;
    using UpgradeableProxyLib for address;

    address internal deployer;
    address proxyAdmin;
    address rewardsOwner;
    address rewardsInitiator;
    IStrategy tradeManagerStrategy;
    CoreDeployLib.DeploymentData coreDeployment;
    TradeManagerDeploymentLib.DeploymentData tradeManagerDeployment;
    TradeManagerDeploymentLib.DeploymentConfigData tradeManagerConfig;
    IECDSAStakeRegistryTypes.Quorum internal quorum;
    ERC20Mock token;

    // UniversalPrivacyHook address on Sepolia
    address constant UNIVERSAL_PRIVACY_HOOK = 0x32841c9E0245C4B1a9cc29137d7E1F078e6f0080;

    function setUp() public virtual {
        deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));
        vm.label(deployer, "Deployer");

        tradeManagerConfig =
            TradeManagerDeploymentLib.readDeploymentConfigValues("config/trade-manager/", block.chainid);

        coreDeployment =
            CoreDeploymentParsingLib.readDeploymentJson("deployments/core/", block.chainid);
    }

    function run() external virtual {
        vm.startBroadcast(deployer);
        rewardsOwner = tradeManagerConfig.rewardsOwner;
        rewardsInitiator = tradeManagerConfig.rewardsInitiator;

        token = new ERC20Mock();
        // NOTE: if this fails, it's because the initialStrategyWhitelister is not set to be the StrategyFactory
        tradeManagerStrategy =
            IStrategy(StrategyFactory(coreDeployment.strategyFactory).deployNewStrategy(token));

        quorum.strategies.push(
            IECDSAStakeRegistryTypes.StrategyParams({
                strategy: tradeManagerStrategy,
                multiplier: 10_000
            })
        );

        token.mint(deployer, 2000);
        token.increaseAllowance(address(coreDeployment.strategyManager), 1000);
        StrategyManager(coreDeployment.strategyManager).depositIntoStrategy(
            tradeManagerStrategy, token, 1000
        );

        proxyAdmin = UpgradeableProxyLib.deployProxyAdmin();

        tradeManagerDeployment = TradeManagerDeploymentLib.deployContracts(
            proxyAdmin, coreDeployment, quorum, rewardsInitiator, rewardsOwner
        );

        tradeManagerDeployment.strategy = address(tradeManagerStrategy);
        tradeManagerDeployment.token = address(token);

        // Set the TradeManager address in UniversalPrivacyHook
        console2.log("Setting TradeManager in UniversalPrivacyHook...");
        IUniversalPrivacyHook(UNIVERSAL_PRIVACY_HOOK).setTradeManager(tradeManagerDeployment.TradeManager);
        console2.log("TradeManager set successfully!");

        // Check who the admin is
        console2.log("Checking admin of TradeManager...");
        address currentAdmin = TradeManager(tradeManagerDeployment.TradeManager).admin();
        console2.log("Current admin:", currentAdmin);
        console2.log("Deployer address:", deployer);
        console2.log("RewardsOwner address:", rewardsOwner);
        console2.log("msg.sender:", msg.sender);

        // Also authorize the hook in TradeManager
        console2.log("Authorizing UniversalPrivacyHook in TradeManager...");
        TradeManager(tradeManagerDeployment.TradeManager).authorizeHook(UNIVERSAL_PRIVACY_HOOK);
        console2.log("Hook authorized successfully!");

        vm.stopBroadcast();
        verifyDeployment();
        TradeManagerDeploymentLib.writeDeploymentJson(tradeManagerDeployment);
    }

    function verifyDeployment() internal view {
        require(
            tradeManagerDeployment.stakeRegistry != address(0), "StakeRegistry address cannot be zero"
        );
        require(
            tradeManagerDeployment.TradeManager != address(0),
            "TradeManager address cannot be zero"
        );
        require(tradeManagerDeployment.strategy != address(0), "Strategy address cannot be zero");
        require(proxyAdmin != address(0), "ProxyAdmin address cannot be zero");
        require(
            coreDeployment.delegationManager != address(0),
            "DelegationManager address cannot be zero"
        );
        require(coreDeployment.avsDirectory != address(0), "AVSDirectory address cannot be zero");
    }
}
