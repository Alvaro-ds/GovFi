// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/tokens/GovernanceToken.sol";
import "../src/core/LiquidityPool.sol";
import "../src/core/YieldFarmingPool.sol";
import "../src/dao/DAO.sol";
import "../src/dao/DAOTreasury.sol";
import "./MockERC20.sol";

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

    // ─── Tests ────────────────────────────────────────────────────────────────

    function testFullLiquidityAndStakingFlow() public {
        uint256 deadline = block.timestamp + 1 days;

        vm.startPrank(lp);
        pool.addLiquidity(50000e18, 50000e18, 0, 0, lp, deadline);
        uint256 lpBalance = pool.balanceOf(lp);
        yieldPool.stake(lpBalance);
        vm.stopPrank();

        vm.warp(block.timestamp + 86400);

        vm.startPrank(lp);
        yieldPool.harvest();
        vm.stopPrank();

        assertGt(govToken.balanceOf(lp), 0);
        assertGt(yieldPool.balances(lp), 0);
    }

    function testSwapGeneratesTreasuryFees() public {
        uint256 deadline = block.timestamp + 1 days;

        vm.startPrank(lp);
        pool.addLiquidity(50000e18, 50000e18, 0, 0, lp, deadline);
        vm.stopPrank();

        vm.startPrank(trader);
        pool.swap(address(tokenA), 1000e18, 0, trader, deadline);
        vm.stopPrank();

        assertGt(tokenA.balanceOf(address(treasury)), 0);
    }

    function testGovernanceProposalFlow() public {
        address dummy = vm.addr(10);
        vm.startPrank(deployer);
        govToken.mint(dummy, 50000e18);
        vm.stopPrank();
        vm.startPrank(dummy);
        govToken.delegate(dummy);
        vm.stopPrank();

        vm.roll(block.number + 1);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);

        targets[0] = address(yieldPool);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSelector(YieldFarmingPool.setRewardRate.selector, 2e18);

        vm.startPrank(voter);
        uint256 proposalId = dao.propose(targets, values, calldatas, "Increase reward rate to 2e18");
        dao.castVote(proposalId, true);
        vm.stopPrank();

        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        DAO.ProposalState proposalState = dao.state(proposalId);
        assertEq(uint256(proposalState), uint256(DAO.ProposalState.Defeated));
    }

    function testFullExitFlow() public {
        uint256 deadline = block.timestamp + 1 days;

        vm.startPrank(lp);
        pool.addLiquidity(50000e18, 50000e18, 0, 0, lp, deadline);
        uint256 lpBalance = pool.balanceOf(lp);
        yieldPool.stake(lpBalance);
        vm.stopPrank();

        vm.warp(block.timestamp + 86400);

        uint256 lpBefore = pool.balanceOf(lp);

        vm.startPrank(lp);
        yieldPool.exit();
        vm.stopPrank();

        assertGt(pool.balanceOf(lp), lpBefore);
        assertGt(govToken.balanceOf(lp), 0);
        assertEq(yieldPool.balances(lp), 0);
    }
}
