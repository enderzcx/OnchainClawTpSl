// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import "reactive/OnchainClawTpSlCallback.sol";

import "./legacy/LegacyOnchainClawTpSlCallback.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockPair.sol";
import "./mocks/MockRouter.sol";

contract CreateBracketGasComparisonTest is Test {
    address internal user = address(0xBEEF);
    uint256 internal constant COEFFICIENT = 1e18;

    function testGasCurrentCreateBracketOrders() public {
        vm.pauseGasMetering();
        (MockERC20 token0,, MockPair pair, OnchainClawTpSlCallback callback) = _deployCurrent();

        vm.startPrank(user);
        token0.approve(address(callback), type(uint256).max);
        vm.resumeGasMetering();
        callback.createBracketOrders(address(pair), true, 5e18, COEFFICIENT, 1e18, 1e18, 3e18, 15e17);
        vm.stopPrank();
    }

    function testGasLegacyCreateBracketOrders() public {
        vm.pauseGasMetering();
        (MockERC20 token0,, MockPair pair, LegacyOnchainClawTpSlCallback callback) = _deployLegacy();

        vm.startPrank(user);
        token0.approve(address(callback), type(uint256).max);
        vm.resumeGasMetering();
        callback.createBracketOrders(address(pair), true, 5e18, COEFFICIENT, 1e18, 1e18, 3e18, 15e17);
        vm.stopPrank();
    }

    function _deployCurrent()
        internal
        returns (MockERC20 token0, MockERC20 token1, MockPair pair, OnchainClawTpSlCallback callback)
    {
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");
        pair = new MockPair(address(token0), address(token1));
        MockRouter router = new MockRouter();
        callback = new OnchainClawTpSlCallback(address(0xCA11), address(router), true);

        pair.setReserves(1e18, 2e18);
        token0.mint(user, 100e18);
    }

    function _deployLegacy()
        internal
        returns (MockERC20 token0, MockERC20 token1, MockPair pair, LegacyOnchainClawTpSlCallback callback)
    {
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");
        pair = new MockPair(address(token0), address(token1));
        MockRouter router = new MockRouter();
        callback = new LegacyOnchainClawTpSlCallback(address(0xCA11), address(router), true);

        pair.setReserves(1e18, 2e18);
        token0.mint(user, 100e18);
    }
}
