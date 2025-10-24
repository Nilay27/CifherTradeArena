// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Test.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockPendle} from "../src/mocks/MockPendle.sol";
import {MockAave} from "../src/mocks/MockAave.sol";
import {MockMorpho} from "../src/mocks/MockMorpho.sol";

/**
 * @title DeployMocks
 * @notice Deploys all mock contracts for CipherTradeArena testnet demo
 */
contract DeployMocks is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        console2.log("\n=== Deploying Mock Tokens (All 6 decimals) ===");

        // Deploy stablecoins
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        console2.log("USDC:", address(usdc));

        MockERC20 usdt = new MockERC20("Tether USD", "USDT", 6);
        console2.log("USDT:", address(usdt));

        // Deploy PT tokens (6 decimals for convenience)
        MockERC20 ptEUSDE = new MockERC20("PT Ethena USDe", "PT-eUSDE", 6);
        console2.log("PT-eUSDE:", address(ptEUSDE));

        MockERC20 ptSUSDE = new MockERC20("PT Staked USDe", "PT-sUSDE", 6);
        console2.log("PT-sUSDE:", address(ptSUSDE));

        MockERC20 ptUSR = new MockERC20("PT Usual USD", "PT-USR", 6);
        console2.log("PT-USR:", address(ptUSR));

        console2.log("\n=== Deploying Mock Protocols ===");

        // Deploy MockPendle
        MockPendle pendle = new MockPendle();
        console2.log("MockPendle:", address(pendle));

        // Register PT markets with discount rates (representing APY)
        // Lower discount = higher APY
        // Market addresses are just identifiers
        address marketEUSDE = address(uint160(uint256(keccak256("market.eUSDE"))));
        address marketSUSDE = address(uint160(uint256(keccak256("market.sUSDE"))));
        address marketUSR = address(uint160(uint256(keccak256("market.USR"))));

        pendle.registerMarket(marketEUSDE, address(ptEUSDE), 9300); // 7% APY
        console2.log("  Market PT-eUSDE:", marketEUSDE, "- 7% APY (93% discount)");

        pendle.registerMarket(marketSUSDE, address(ptSUSDE), 9200); // 8% APY
        console2.log("  Market PT-sUSDE:", marketSUSDE, "- 8% APY (92% discount)");

        pendle.registerMarket(marketUSR, address(ptUSR), 9000); // 10% APY
        console2.log("  Market PT-USR:", marketUSR, "- 10% APY (90% discount)");

        // Fund Pendle with PT tokens (100M each)
        ptEUSDE.mint(address(pendle), 100000000 * 1e6);
        ptSUSDE.mint(address(pendle), 100000000 * 1e6);
        ptUSR.mint(address(pendle), 100000000 * 1e6);

        // Deploy MockAave (accepts PT-eUSDE, PT-sUSDE)
        MockAave aave = new MockAave();
        console2.log("MockAave:", address(aave));

        aave.setSupportedCollateral(address(ptEUSDE), true);
        aave.setSupportedCollateral(address(ptSUSDE), true);
        aave.setBorrowRate(address(usdc), 500); // 5% borrow APY for USDC
        aave.setBorrowRate(address(usdt), 550); // 5.5% borrow APY for USDT
        console2.log("  Collateral: PT-eUSDE, PT-sUSDE");
        console2.log("  Borrow rates: USDC 5%, USDT 5.5%");

        // Fund Aave with liquidity
        usdc.mint(address(aave), 100000000 * 1e6); // 100M USDC
        usdt.mint(address(aave), 100000000 * 1e6); // 100M USDT

        // Deploy MockMorpho (accepts PT-USR, higher rates)
        MockMorpho morpho = new MockMorpho();
        console2.log("MockMorpho:", address(morpho));

        morpho.setBorrowRate(address(ptUSR), 1000); // 10% borrow APY for PT-USR collateral
        console2.log("  Collateral: PT-USR");
        console2.log("  Borrow rate: 10% (higher rate, higher APY collateral)");

        // Fund Morpho with liquidity
        usdc.mint(address(morpho), 100000000 * 1e6); // 100M USDC
        usdt.mint(address(morpho), 100000000 * 1e6); // 100M USDT

        console2.log("\n=== Deployment Complete ===");
        console2.log("\nSummary:");
        console2.log("Tokens (all 6 decimals):");
        console2.log("  USDC:", address(usdc));
        console2.log("  USDT:", address(usdt));
        console2.log("  PT-eUSDE:", address(ptEUSDE));
        console2.log("  PT-sUSDE:", address(ptSUSDE));
        console2.log("  PT-USR:", address(ptUSR));
        console2.log("\nProtocols:");
        console2.log("  Pendle:", address(pendle));
        console2.log("  Aave:", address(aave));
        console2.log("  Morpho:", address(morpho));
        console2.log("\nPendle Markets:");
        console2.log("  PT-eUSDE Market:", marketEUSDE);
        console2.log("  PT-sUSDE Market:", marketSUSDE);
        console2.log("  PT-USR Market:", marketUSR);

        vm.stopBroadcast();

        // Create deployments/mocks directory if it doesn't exist
        string memory deploymentsPath = "deployments/mocks/";
        try vm.createDir(deploymentsPath, true) {} catch {}

        // Save deployment addresses to JSON
        string memory json = string(
            abi.encodePacked(
                '{\n',
                '  "tokens": {\n',
                '    "USDC": "', vm.toString(address(usdc)), '",\n',
                '    "USDT": "', vm.toString(address(usdt)), '",\n',
                '    "PT_eUSDE": "', vm.toString(address(ptEUSDE)), '",\n',
                '    "PT_sUSDE": "', vm.toString(address(ptSUSDE)), '",\n',
                '    "PT_USR": "', vm.toString(address(ptUSR)), '"\n',
                '  },\n',
                '  "protocols": {\n',
                '    "pendle": "', vm.toString(address(pendle)), '",\n',
                '    "aave": "', vm.toString(address(aave)), '",\n',
                '    "morpho": "', vm.toString(address(morpho)), '"\n',
                '  },\n',
                '  "markets": {\n',
                '    "PT_eUSDE": "', vm.toString(marketEUSDE), '",\n',
                '    "PT_sUSDE": "', vm.toString(marketSUSDE), '",\n',
                '    "PT_USR": "', vm.toString(marketUSR), '"\n',
                '  }\n',
                '}'
            )
        );

        vm.writeFile(
            string(abi.encodePacked("deployments/mocks/", vm.toString(block.chainid), ".json")),
            json
        );
    }
}
