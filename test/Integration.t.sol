// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/tokens/GovernanceToken.sol";
import "../src/core/LiquidityPool.sol";
import "../src/core/YieldFarmingPool.sol";
import "../src/dao/DAO.sol";
import "../src/dao/DAOTreasury.sol";
import "./mocks/MockERC20.sol";

contract IntegrationTest is Test {
    GovernanceToken internal govToken;
    LiquidityPool internal pool;
    YieldFarmingPool internal yieldPool;
    DAO internal dao;
    DAOTreasury internal treasury;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal deployer = vm.addr(1);
    address internal lp = vm.addr(2);
    address internal trader = vm.addr(3);
    address internal voter = vm.addr(4);

    uint256 internal constant VOTING_PERIOD = 259200;
    uint256 internal constant TIMELOCK_DELAY = 86400;
    uint256 internal constant QUORUM_BPS = 400;
    uint256 internal constant PROPOSAL_THRESHOLD = 100e18;
    uint256 internal constant INITIAL_REWARD_RATE = 1e18;

    function setUp() public {
        vm.label(deployer, "deployer");
        vm.label(lp, "lp");
        vm.label(trader, "trader");
        vm.label(voter, "voter");

        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        vm.label(address(tokenA), "tokenA");
        vm.label(address(tokenB), "tokenB");

        vm.startPrank(deployer);
        govToken = new GovernanceToken(10000000e18, "GovFi Token", "GOV", deployer);
        treasury = new DAOTreasury(address(0));
        pool = new LiquidityPool(address(tokenA), address(tokenB), address(treasury), deployer);
        yieldPool = new YieldFarmingPool(address(pool), address(govToken), INITIAL_REWARD_RATE, deployer);
        dao = new DAO(address(govToken), address(treasury), VOTING_PERIOD, TIMELOCK_DELAY, QUORUM_BPS, PROPOSAL_THRESHOLD, deployer);
        treasury.setDAO(address(dao));
        govToken.grantMinterRole(address(yieldPool));
        pool.setDAO(address(dao));
        yieldPool.setDAO(address(dao));
        govToken.mint(voter, 500e18);
        vm.stopPrank();

        vm.label(address(govToken), "govToken");
        vm.label(address(treasury), "treasury");
        vm.label(address(pool), "pool");
        vm.label(address(yieldPool), "yieldPool");
        vm.label(address(dao), "dao");

        tokenA.mint(lp, 1000000e18);
        tokenB.mint(lp, 1000000e18);
        tokenA.mint(trader, 100000e18);
        tokenB.mint(trader, 100000e18);

        vm.startPrank(lp);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        lpToken().approve(address(yieldPool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(trader);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(voter);
        govToken.delegate(voter);
        vm.stopPrank();

        vm.roll(block.number + 1);
    }

    function lpToken() internal view returns (IERC20) {
        return IERC20(address(pool));
    }
}
