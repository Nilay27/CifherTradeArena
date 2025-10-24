// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockPendle
 * @notice Mock Pendle protocol for swapping tokens to PT tokens
 * @dev Simulates PT token purchases with configurable discount rates (representing APY)
 */
contract MockPendle {
    // PT token addresses and their discount rates (basis points)
    // Lower discount = higher effective APY
    mapping(address => uint256) public ptDiscountRate; // in basis points (10000 = 100%)

    // Market to PT token mapping
    mapping(address => address) public marketToPT;

    event PTSwapped(
        address indexed user,
        address indexed market,
        address tokenIn,
        uint256 amountIn,
        address ptOut,
        uint256 ptAmount
    );

    /**
     * @notice Register a PT market with discount rate
     * @param market Market identifier address
     * @param ptToken PT token address
     * @param discountBps Discount in basis points (e.g., 9300 = 93% = 7% APY)
     */
    function registerMarket(address market, address ptToken, uint256 discountBps) external {
        require(discountBps <= 10000, "Invalid discount");
        marketToPT[market] = ptToken;
        ptDiscountRate[ptToken] = discountBps;
    }

    /**
     * @notice Swap exact tokens for PT tokens
     * @param receiver Address to receive PT tokens
     * @param market Market identifier
     * @param tokenIn Input token address (e.g., USDC)
     * @param netTokenIn Amount of input tokens
     * @return ptAmount Amount of PT tokens received
     */
    function swapExactTokenForPt(
        address receiver,
        address market,
        address tokenIn,
        uint256 netTokenIn
    ) external returns (uint256 ptAmount) {
        address ptToken = marketToPT[market];
        require(ptToken != address(0), "Market not registered");

        // Pull input tokens from sender
        IERC20(tokenIn).transferFrom(msg.sender, address(this), netTokenIn);

        // Calculate PT amount based on discount rate
        // PT is "cheaper" than underlying, so you get more PT
        // Example: 93% discount means 1 USDC = 1/0.93 = 1.0753 PT
        uint256 discountBps = ptDiscountRate[ptToken];
        ptAmount = (netTokenIn * 10000) / discountBps;

        // Mint/transfer PT tokens to receiver
        IERC20(ptToken).transfer(receiver, ptAmount);

        emit PTSwapped(msg.sender, market, tokenIn, netTokenIn, ptToken, ptAmount);
    }

    /**
     * @notice Swap exact PT tokens for underlying tokens
     * @param receiver Address to receive underlying tokens
     * @param market Market identifier
     * @param exactPtIn Amount of PT tokens to swap
     * @param tokenOut Output token address
     * @return amountOut Amount of underlying tokens received
     */
    function swapExactPtForToken(
        address receiver,
        address market,
        uint256 exactPtIn,
        address tokenOut
    ) external returns (uint256 amountOut) {
        address ptToken = marketToPT[market];
        require(ptToken != address(0), "Market not registered");

        // Pull PT tokens from sender
        IERC20(ptToken).transferFrom(msg.sender, address(this), exactPtIn);

        // Calculate underlying amount (PT worth less than underlying)
        uint256 discountBps = ptDiscountRate[ptToken];
        amountOut = (exactPtIn * discountBps) / 10000;

        // Transfer underlying tokens to receiver
        IERC20(tokenOut).transfer(receiver, amountOut);
    }

    /**
     * @notice Get PT amount for a given input amount
     */
    function getPtAmount(address market, uint256 tokenInAmount) external view returns (uint256) {
        address ptToken = marketToPT[market];
        require(ptToken != address(0), "Market not registered");

        uint256 discountBps = ptDiscountRate[ptToken];
        return (tokenInAmount * 10000) / discountBps;
    }

    /**
     * @notice Fund contract with tokens (for testing)
     */
    function fundContract(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}
