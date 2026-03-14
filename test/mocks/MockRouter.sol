// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockRouter {
    uint256 public nextAmountOut;
    uint256 public lastAmountIn;
    uint256 public lastAmountOutMin;

    function setNextAmountOut(uint256 amountOut) external {
        nextAmountOut = amountOut;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        require(path.length == 2, "path_length");
        lastAmountIn = amountIn;
        lastAmountOutMin = amountOutMin;
        require(nextAmountOut >= amountOutMin, "insufficient_amount_out");

        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        IERC20(path[1]).transfer(to, nextAmountOut);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = nextAmountOut;
    }
}
