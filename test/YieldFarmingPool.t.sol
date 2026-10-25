// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/core/YieldFarmingPool.sol";
import "../src/tokens/GovernanceToken.sol";
import "./mocks/MockERC20.sol";

contract YieldFarmingPoolTest is Test {
    YieldFarmingPool internal yieldPool;
    GovernanceToken internal govToken;
    MockERC20 internal lpToken;

    address internal owner = vm.addr(1);
    address internal user1 = vm.addr(2);
    address internal user2 = vm.addr(3);
    address internal dao = vm.addr(4);

    uint256 internal constant INITIAL_REWARD_RATE = 1e18;
    uint256 internal constant INITIAL_LP_MINT = 1000e18;

    function setUp() public {
        vm.label(owner, "owner");
        vm.label(user1, "user1");
        vm.label(user2, "user2");
        vm.label(dao, "dao");

        lpToken = new MockERC20("LP Token", "LP", 18);
        vm.label(address(lpToken), "lpToken");

        vm.startPrank(owner);
        govToken = new GovernanceToken(1000000e18, "GovFi", "GOV", owner);
        yieldPool = new YieldFarmingPool(address(lpToken), address(govToken), INITIAL_REWARD_RATE, owner);
        yieldPool.setDAO(dao);
        govToken.grantMinterRole(address(yieldPool));
        vm.stopPrank();

        vm.label(address(govToken), "govToken");
        vm.label(address(yieldPool), "yieldPool");

        lpToken.mint(user1, INITIAL_LP_MINT);
        lpToken.mint(user2, INITIAL_LP_MINT);

        vm.startPrank(user1);
        lpToken.approve(address(yieldPool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        lpToken.approve(address(yieldPool), type(uint256).max);
        vm.stopPrank();
    }
}
