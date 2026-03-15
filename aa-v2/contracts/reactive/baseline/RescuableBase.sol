// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract RescuableBase {
    using SafeERC20 for IERC20;

    event ETHRescued(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    function _rescueRecipient() internal view virtual returns (address);

    function _rescueETH(uint256 amount) internal {
        uint256 balance = address(this).balance;
        uint256 rescueAmount = amount == 0 ? balance : amount;
        require(rescueAmount <= balance, "insufficient_eth_balance");
        require(rescueAmount > 0, "no_eth_to_rescue");

        address recipient = _rescueRecipient();
        (bool success, ) = payable(recipient).call{value: rescueAmount}("");
        require(success, "eth_transfer_failed");

        emit ETHRescued(recipient, rescueAmount);
    }

    function _rescueERC20(address token, uint256 amount) internal {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 rescueAmount = amount == 0 ? balance : amount;
        require(rescueAmount <= balance, "insufficient_token_balance");
        require(rescueAmount > 0, "no_tokens_to_rescue");

        address recipient = _rescueRecipient();
        IERC20(token).safeTransfer(recipient, rescueAmount);

        emit ERC20Rescued(token, recipient, rescueAmount);
    }

    function rescueETH(uint256 amount) external virtual {
        require(amount > 0, "amount_required");
        _rescueETH(amount);
    }

    function rescueAllETH() external virtual {
        _rescueETH(0);
    }

    function rescueERC20(address token, uint256 amount) external virtual {
        require(amount > 0, "amount_required");
        _rescueERC20(token, amount);
    }

    function rescueAllERC20(address token) external virtual {
        _rescueERC20(token, 0);
    }
}
