// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/core/LiquidityPool.sol";
import "./mocks/MockERC20.sol";

contract LiquidityPoolTest is Test {
    LiquidityPool internal pool;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal owner = vm.addr(1);
    address internal lp1 = vm.addr(2);
    address internal lp2 = vm.addr(3);
    address internal trader = vm.addr(4);
    address internal attacker = vm.addr(5);
    address internal treasury = vm.addr(6);
    address internal dao = vm.addr(7);

    uint256 internal constant INITIAL_MINT = 1000000e18;

    function setUp() public {
        vm.label(owner, "owner");
        vm.label(lp1, "lp1");
        vm.label(lp2, "lp2");
        vm.label(trader, "trader");
        vm.label(attacker, "attacker");
        vm.label(treasury, "treasury");
        vm.label(dao, "dao");

        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        vm.label(address(tokenA), "tokenA");
        vm.label(address(tokenB), "tokenB");

        vm.startPrank(owner);
        pool = new LiquidityPool(address(tokenA), address(tokenB), treasury, owner);
        pool.setDAO(dao);
        vm.stopPrank();
        vm.label(address(pool), "pool");

        tokenA.mint(lp1, INITIAL_MINT);
        tokenB.mint(lp1, INITIAL_MINT);
        tokenA.mint(lp2, INITIAL_MINT);
        tokenB.mint(lp2, INITIAL_MINT);
        tokenA.mint(trader, INITIAL_MINT);
        tokenB.mint(trader, INITIAL_MINT);

        vm.startPrank(lp1);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(lp2);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(trader);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }
}
