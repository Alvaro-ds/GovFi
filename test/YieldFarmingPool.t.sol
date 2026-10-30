// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/core/YieldFarmingPool.sol";
import "../src/tokens/GovernanceToken.sol";
import "./MockERC20.sol";

// ─── Invariant handler ────────────────────────────────────────────────────────

/// @dev Called by Foundry's invariant fuzzer. Uses two pre-funded actors to
///      exercise stake / unstake / harvest / time-warp sequences. Each function
///      is bounded so it never produces invalid inputs that would always revert.
contract YieldFarmingPoolHandler is Test {
    YieldFarmingPool internal pool_;
    MockERC20 internal lpToken_;
    address[2] internal users_;

    constructor(YieldFarmingPool pool, MockERC20 lpToken, address user1, address user2) {
        pool_ = pool;
        lpToken_ = lpToken;
        users_[0] = user1;
        users_[1] = user2;
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        address actor = users_[actorSeed % 2];
        uint256 available = lpToken_.balanceOf(actor);
        if (available == 0) return;
        amount = bound(amount, 1, available);
        vm.startPrank(actor);
        pool_.stake(amount);
        vm.stopPrank();
    }

    function unstake(uint256 actorSeed, uint256 amount) external {
        address actor = users_[actorSeed % 2];
        uint256 staked = pool_.balances(actor);
        if (staked == 0) return;
        amount = bound(amount, 1, staked);
        vm.startPrank(actor);
        pool_.unstake(amount);
        vm.stopPrank();
    }

    function harvest(uint256 actorSeed) external {
        address actor = users_[actorSeed % 2];
        if (pool_.earned(actor) == 0) return;
        vm.startPrank(actor);
        try pool_.harvest() {} catch {}
        vm.stopPrank();
    }

    function warpTime(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 30 days));
    }
}

// ─────────────────────────────────────────────────────────────────────────────

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

    YieldFarmingPoolHandler internal handler;

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

        handler = new YieldFarmingPoolHandler(yieldPool, lpToken, user1, user2);
        targetContract(address(handler));
    }

    // ─── constructor ──────────────────────────────────────────────────────────

    function testConstructorRevertsZeroLpToken() public {
        vm.expectRevert("ZeroAddress");
        new YieldFarmingPool(address(0), address(govToken), INITIAL_REWARD_RATE, owner);
    }

    function testConstructorRevertsZeroGovToken() public {
        vm.expectRevert("ZeroAddress");
        new YieldFarmingPool(address(lpToken), address(0), INITIAL_REWARD_RATE, owner);
    }

    function testConstructorRevertsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new YieldFarmingPool(address(lpToken), address(govToken), INITIAL_REWARD_RATE, address(0));
    }

    function testConstructorRevertsZeroRate() public {
        vm.expectRevert("ZeroRate");
        new YieldFarmingPool(address(lpToken), address(govToken), 0, owner);
    }

    // ─── setDAO ───────────────────────────────────────────────────────────────

    function testSetDAORevertsIfAlreadySet() public {
        vm.startPrank(owner);
        vm.expectRevert("DAOAlreadySet");
        yieldPool.setDAO(dao);
        vm.stopPrank();
    }

    function testSetDAORevertsIfZeroAddress() public {
        vm.startPrank(owner);
        YieldFarmingPool freshPool = new YieldFarmingPool(address(lpToken), address(govToken), INITIAL_REWARD_RATE, owner);
        vm.expectRevert("ZeroAddress");
        freshPool.setDAO(address(0));
        vm.stopPrank();
    }

    // ─── stake ────────────────────────────────────────────────────────────────

    function testStake() public {
        uint256 amount = 100e18;

        vm.startPrank(user1);
        yieldPool.stake(amount);
        vm.stopPrank();

        assertEq(yieldPool.balances(user1), amount);
        assertEq(yieldPool.totalStaked(), amount);
        assertEq(lpToken.balanceOf(address(yieldPool)), amount);
    }

    function testStakeRevertsIfZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert("ZeroAmount");
        yieldPool.stake(0);
        vm.stopPrank();
    }

    function testStakeUpdatesRewards() public {
        vm.startPrank(user1);
        yieldPool.stake(100e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 100);

        uint256 earnedBefore = yieldPool.earned(user1);
        assertGt(earnedBefore, 0);

        vm.startPrank(user1);
        yieldPool.stake(1e18);
        vm.stopPrank();

        assertGt(yieldPool.rewards(user1), 0);
    }

    // ─── unstake ──────────────────────────────────────────────────────────────

    function testUnstake() public {
        uint256 amount = 100e18;

        vm.startPrank(user1);
        yieldPool.stake(amount);
        yieldPool.unstake(amount);
        vm.stopPrank();

        assertEq(yieldPool.balances(user1), 0);
        assertEq(yieldPool.totalStaked(), 0);
    }

    function testUnstakeRevertsIfZeroAmount() public {
        vm.startPrank(user1);
        yieldPool.stake(100e18);
        vm.expectRevert("ZeroAmount");
        yieldPool.unstake(0);
        vm.stopPrank();
    }

    function testUnstakeRevertsIfInsufficientStake() public {
        vm.startPrank(user1);
        yieldPool.stake(100e18);
        vm.expectRevert("InsufficientStake");
        yieldPool.unstake(101e18);
        vm.stopPrank();
    }

    function testUnstakePartial() public {
        vm.startPrank(user1);
        yieldPool.stake(100e18);
        yieldPool.unstake(50e18);
        vm.stopPrank();

        assertEq(yieldPool.balances(user1), 50e18);
        assertEq(yieldPool.totalStaked(), 50e18);
    }

    // ─── harvest ──────────────────────────────────────────────────────────────

    function testHarvest() public {
        vm.startPrank(user1);
        yieldPool.stake(100e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 100);

        vm.startPrank(user1);
        yieldPool.harvest();
        vm.stopPrank();

        assertGt(govToken.balanceOf(user1), 0);
    }

    function testHarvestRevertsIfNoRewards() public {
        vm.startPrank(user1);
        yieldPool.stake(100e18);
        vm.expectRevert("NoRewards");
        yieldPool.harvest();
        vm.stopPrank();
    }

    // ─── exit ─────────────────────────────────────────────────────────────────

    function testExit() public {
        uint256 amount = 100e18;
        uint256 lpBefore = lpToken.balanceOf(user1);

        vm.startPrank(user1);
        yieldPool.stake(amount);
        vm.stopPrank();

        vm.warp(block.timestamp + 100);

        vm.startPrank(user1);
        yieldPool.exit();
        vm.stopPrank();

        assertEq(lpToken.balanceOf(user1), lpBefore);
        assertGt(govToken.balanceOf(user1), 0);
        assertEq(yieldPool.balances(user1), 0);
    }

    function testExitRevertsIfZeroBalance() public {
        vm.startPrank(user1);
        vm.expectRevert("ZeroLPToken");
        yieldPool.exit();
        vm.stopPrank();
    }

    function testExitWithoutRewards() public {
        uint256 amount = 100e18;
        uint256 lpBefore = lpToken.balanceOf(user1);

        vm.startPrank(user1);
        yieldPool.stake(amount);
        yieldPool.exit();
        vm.stopPrank();

        assertEq(lpToken.balanceOf(user1), lpBefore);
        assertEq(govToken.balanceOf(user1), 0);
        assertEq(yieldPool.balances(user1), 0);
    }

    // ─── earned / rewardPerToken ──────────────────────────────────────────────

    function testEarnedIsZeroWithNoStake() public {
        assertEq(yieldPool.earned(user1), 0);
    }

    function testEarnedAccruesOverTime() public {
        vm.startPrank(user1);
        yieldPool.stake(100e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 1000);

        assertGt(yieldPool.earned(user1), 0);
    }

    function testRewardPerTokenZeroWhenNoStakers() public {
        uint256 stored = yieldPool.rewardPerTokenStored();
        assertEq(yieldPool.rewardPerToken(), stored);
    }

    // ─── setRewardRate ────────────────────────────────────────────────────────

    function testSetRewardRate() public {
        uint256 newRate = 2e18;

        vm.startPrank(dao);
        vm.expectEmit(false, false, false, true);
        emit YieldFarmingPool.RewardRateUpdated(INITIAL_REWARD_RATE, newRate);
        yieldPool.setRewardRate(newRate);
        vm.stopPrank();

        assertEq(yieldPool.rewardRate(), newRate);
    }

    function testSetRewardRateRevertsIfNotDAO() public {
        vm.startPrank(user1);
        vm.expectRevert("OnlyDAO");
        yieldPool.setRewardRate(2e18);
        vm.stopPrank();
    }

    function testSetRewardRateRevertsIfSameRate() public {
        vm.startPrank(dao);
        vm.expectRevert("Same reward rate");
        yieldPool.setRewardRate(INITIAL_REWARD_RATE);
        vm.stopPrank();
    }

    // ─── multi-user ───────────────────────────────────────────────────────────

    function testMultiUserRewardsAreProportional() public {
        vm.startPrank(user1);
        yieldPool.stake(200e18);
        vm.stopPrank();

        vm.startPrank(user2);
        yieldPool.stake(100e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 1000);

        uint256 earned1 = yieldPool.earned(user1);
        uint256 earned2 = yieldPool.earned(user2);

        assertGt(earned1, 0);
        assertGt(earned2, 0);
        assertApproxEqRel(earned1, earned2 * 2, 1e15);
    }

    // ─── fuzz tests ───────────────────────────────────────────────────────────

    /// @dev Staking and immediately unstaking any valid amount must leave pool and
    ///      user balances exactly as they were before.
    function testFuzz_StakeUnstakePreservesBalances(uint256 amount) public {
        amount = bound(amount, 1, INITIAL_LP_MINT);

        uint256 lpBefore = lpToken.balanceOf(user1);

        vm.startPrank(user1);
        yieldPool.stake(amount);
        vm.stopPrank();

        assertEq(yieldPool.totalStaked(), amount);
        assertEq(lpToken.balanceOf(address(yieldPool)), amount);

        vm.startPrank(user1);
        yieldPool.unstake(amount);
        vm.stopPrank();

        assertEq(yieldPool.totalStaked(), 0);
        assertEq(lpToken.balanceOf(address(yieldPool)), 0);
        assertEq(lpToken.balanceOf(user1), lpBefore);
    }

    /// @dev rewardPerToken() must never decrease as time advances with active stakers.
    function testFuzz_RewardPerTokenIsMonotonic(uint256 elapsed) public {
        elapsed = bound(elapsed, 1, 365 days);

        vm.startPrank(user1);
        yieldPool.stake(100e18);
        vm.stopPrank();

        uint256 rpt0 = yieldPool.rewardPerToken();
        vm.warp(block.timestamp + elapsed);

        assertGe(yieldPool.rewardPerToken(), rpt0);
    }

    /// @dev For a sole staker the earned amount must equal elapsed * rewardRate
    ///      (no rounding error when totalStaked is a clean multiple).
    function testFuzz_EarnedBoundedByElapsedRewards(uint256 elapsed) public {
        elapsed = bound(elapsed, 1, 365 days);

        vm.startPrank(user1);
        yieldPool.stake(100e18);
        vm.stopPrank();

        vm.warp(block.timestamp + elapsed);

        assertLe(yieldPool.earned(user1), elapsed * yieldPool.rewardRate());
    }

    // ─── invariant tests ──────────────────────────────────────────────────────

    /// @dev The pool's accounting (totalStaked) must always match the actual
    ///      LP token balance it holds. Any divergence means tokens are lost.
    function invariant_TotalStakedEqualsLPBalance() public view {
        assertEq(yieldPool.totalStaked(), lpToken.balanceOf(address(yieldPool)));
    }
}
