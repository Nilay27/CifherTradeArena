// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Constants} from "@uniswap/v4-core/src/../test/utils/Constants.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {EasyPosm} from "../test/utils/EasyPosm.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "../test/utils/forks/DeployPermit2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPositionDescriptor} from "v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {UniversalPrivacyHook} from "../src/privacy/UniversalPrivacyHook.sol";

/// @notice Deploys UniversalPrivacyHook with proper address mining
contract DeployUniversalPrivacyHook is Script, DeployPermit2 {
    using EasyPosm for IPositionManager;

    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    IPoolManager public manager;
    IPositionManager public posm;
    PoolModifyLiquidityTest public lpRouter;
    PoolSwapTest public swapRouter;
    UniversalPrivacyHook public hook;
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        // Deploy PoolManager
        manager = deployPoolManager();
        console.log("PoolManager deployed at:", address(manager));

        // Deploy tokens
        tokenA = new MockERC20("Mock USDC", "mUSDC", 18);
        tokenB = new MockERC20("Mock USDT", "mUSDT", 18);
        console.log("TokenA deployed at:", address(tokenA));
        console.log("TokenB deployed at:", address(tokenB));

        // UniversalPrivacyHook needs BEFORE_SWAP_FLAG
        uint160 permissions = uint160(Hooks.BEFORE_SWAP_FLAG);

        // Mine a salt that will produce a hook address with the correct permissions
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            permissions,
            type(UniversalPrivacyHook).creationCode,
            abi.encode(address(manager))
        );

        console.log("Expected hook address:", hookAddress);
        console.log("Salt found:", uint256(salt));

        // Deploy the hook using CREATE2
        hook = new UniversalPrivacyHook{salt: salt}(manager);
        require(address(hook) == hookAddress, "Hook address mismatch");

        console.log("UniversalPrivacyHook deployed at:", address(hook));

        // Deploy additional helpers
        posm = deployPosm(manager);
        (lpRouter, swapRouter,) = deployRouters(manager);

        console.log("PositionManager deployed at:", address(posm));
        console.log("LPRouter deployed at:", address(lpRouter));
        console.log("SwapRouter deployed at:", address(swapRouter));

        // Initialize a pool
        initializePool();

        vm.stopBroadcast();

        // Write deployment info to file
        writeDeploymentInfo();
    }

    function deployPoolManager() internal returns (IPoolManager) {
        return IPoolManager(address(new PoolManager(address(0))));
    }

    function deployRouters(IPoolManager _manager)
        internal
        returns (PoolModifyLiquidityTest _lpRouter, PoolSwapTest _swapRouter, PoolDonateTest _donateRouter)
    {
        _lpRouter = new PoolModifyLiquidityTest(_manager);
        _swapRouter = new PoolSwapTest(_manager);
        _donateRouter = new PoolDonateTest(_manager);
    }

    function deployPosm(IPoolManager poolManager) internal returns (IPositionManager) {
        anvilPermit2();
        return IPositionManager(
            new PositionManager(poolManager, permit2, 300_000, IPositionDescriptor(address(0)), IWETH9(address(0)))
        );
    }

    function initializePool() internal {
        // Sort tokens to ensure currency0 < currency1
        address token0;
        address token1;
        if (address(tokenA) < address(tokenB)) {
            token0 = address(tokenA);
            token1 = address(tokenB);
        } else {
            token0 = address(tokenB);
            token1 = address(tokenA);
        }

        // Create the pool key with sorted tokens
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000, // 0.3% fee
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize the pool
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        console.log("Pool initialized");

        // Set the SwapManager address (if available from environment)
        // This should be the deployed SwapManager from hello-world-avs
        address swapManager = vm.envOr("SWAP_MANAGER", address(0));
        if (swapManager != address(0)) {
            hook.setSwapManager(swapManager);
            console.log("SwapManager set to:", swapManager);
        }

        // Add initial liquidity
        uint256 liquidityAmount = 1000 ether;

        // Mint tokens to the deployer for adding liquidity
        tokenA.mint(msg.sender, liquidityAmount);
        tokenB.mint(msg.sender, liquidityAmount);

        // Approve tokens to lpRouter
        tokenA.approve(address(lpRouter), liquidityAmount);
        tokenB.approve(address(lpRouter), liquidityAmount);

        console.log("Initial liquidity setup complete");
    }

    function writeDeploymentInfo() internal {
        string memory json = string(
            abi.encodePacked(
                '{\n',
                '  "poolManager": "', vm.toString(address(manager)), '",\n',
                '  "universalPrivacyHook": "', vm.toString(address(hook)), '",\n',
                '  "positionManager": "', vm.toString(address(posm)), '",\n',
                '  "lpRouter": "', vm.toString(address(lpRouter)), '",\n',
                '  "swapRouter": "', vm.toString(address(swapRouter)), '",\n',
                '  "tokenA": "', vm.toString(address(tokenA)), '",\n',
                '  "tokenB": "', vm.toString(address(tokenB)), '"\n',
                '}'
            )
        );

        // Try to write, but don't fail if it doesn't work
        try vm.writeFile("./deployments/latest.json", json) {
            console.log("Deployment info written to deployments/latest.json");
        } catch {
            console.log("Could not write deployment file, but contracts deployed successfully");
            console.log("Deployment addresses:");
            console.log(json);
        }
    }
}