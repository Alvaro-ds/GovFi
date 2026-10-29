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
    address internal treasury = vm.addr(6);
    address internal dao = vm.addr(7);

    uint256 internal constant INITIAL_MINT = 1000000e18;

    function setUp() public {
        vm.label(owner, "owner");
        vm.label(lp1, "lp1");
        vm.label(lp2, "lp2");
        vm.label(trader, "trader");
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

    function testOwnerCannotSetANewDAO() public {
        address newDAO = vm.addr(8);

        vm.startPrank(owner);
        vm.expectRevert("DAOAlreadySet");
        pool.setDAO(newDAO);
        vm.stopPrank();
    }

    function testTraderCanAddLiquidity() public {
        uint256 amountA = 50e18;
        uint256 amountB = 50e18;
        uint256 deadline = block.timestamp + 30 seconds;

        uint256 traderTokenABalance = tokenA.balanceOf(trader);
        uint256 traderTokenBBalance = tokenB.balanceOf(trader);

        uint256 minLiquidity = pool.MINIMUM_LIQUIDITY();
        uint256 liquidity = Math.sqrt(amountA * amountB);
        uint256 expectedLp = liquidity - minLiquidity;

        vm.startPrank(trader);
        uint256 lpMinted = pool.addLiquidity(amountA, amountB, 25e18, 25e18, trader, deadline);
        vm.stopPrank();

        assertEq(lpMinted, expectedLp);
        assertEq(tokenA.balanceOf(trader), traderTokenABalance - amountA);
        assertEq(tokenB.balanceOf(trader), traderTokenBBalance - amountB);
        assertEq(pool.balanceOf(trader), expectedLp);
        assertEq(pool.balanceOf(address(1)), minLiquidity);
        assertEq(pool.totalSupply(), liquidity);

        (uint256 reserveA, uint256 reserveB) = pool.getReserves();
        assertEq(reserveA, amountA);
        assertEq(reserveB, amountB);
    }

    function testDeadlineMustBeGreaterThanTimestampToAddLiquidity() public {
        uint256 amountA = 50e18;
        uint256 amountB = 50e18;
        uint256 deadline = block.timestamp + 30 seconds;

        uint256 traderTokenABalance = tokenA.balanceOf(trader);
        uint256 traderTokenBBalance = tokenB.balanceOf(trader);

        vm.warp(deadline + 1);
        vm.startPrank(trader);
        vm.expectRevert("Expired");
        pool.addLiquidity(amountA, amountB, 25e18, 25e18, trader, deadline);
        vm.stopPrank();

        assertEq(traderTokenABalance, tokenA.balanceOf(trader));
        assertEq(traderTokenBBalance, tokenB.balanceOf(trader));
    }

    function testRevertsWhenAmountADesiredIsZero() public {
        uint256 amountA = 0;
        uint256 amountB = 50e18;
        uint256 deadline = block.timestamp + 30 seconds;

        uint256 traderTokenABalance = tokenA.balanceOf(trader);
        uint256 traderTokenBBalance = tokenB.balanceOf(trader);

        vm.startPrank(trader);
        vm.expectRevert("ZeroAmount");
        pool.addLiquidity(amountA, amountB, 25e18, 25e18, trader, deadline);
        vm.stopPrank();

        assertEq(traderTokenABalance, tokenA.balanceOf(trader));
        assertEq(traderTokenBBalance, tokenB.balanceOf(trader));
    }

    function testRevertsWhenAmountBDesiredIsZero() public {
        uint256 amountA = 50e18;
        uint256 amountB = 0;
        uint256 deadline = block.timestamp + 30 seconds;

        uint256 traderTokenABalance = tokenA.balanceOf(trader);
        uint256 traderTokenBBalance = tokenB.balanceOf(trader);

        vm.startPrank(trader);
        vm.expectRevert("ZeroAmount");
        pool.addLiquidity(amountA, amountB, 25e18, 25e18, trader, deadline);
        vm.stopPrank();

        assertEq(traderTokenABalance, tokenA.balanceOf(trader));
        assertEq(traderTokenBBalance, tokenB.balanceOf(trader));
    }

    function testRevertsWhenZeroAddressReceipter() public {
        uint256 amountA = 50e18;
        uint256 amountB = 50e18;
        uint256 deadline = block.timestamp + 30 seconds;

        uint256 traderTokenABalance = tokenA.balanceOf(trader);
        uint256 traderTokenBBalance = tokenB.balanceOf(trader);

        vm.startPrank(trader);
        vm.expectRevert("ZeroAddress");
        pool.addLiquidity(amountA, amountB, 25e18, 25e18, address(0), deadline);
        vm.stopPrank();

        assertEq(traderTokenABalance, tokenA.balanceOf(trader));
        assertEq(traderTokenBBalance, tokenB.balanceOf(trader));
    }

    function testTraderCanRemoveLiquidity() public {
        uint256 amountA = 50e18;
        uint256 amountB = 50e18;
        uint256 deadline = block.timestamp + 30 seconds;

        vm.startPrank(trader);
        pool.addLiquidity(amountA, amountB, 25e18, 25e18, trader, deadline);

        uint256 traderTokenABalance = tokenA.balanceOf(trader);
        uint256 traderTokenBBalance = tokenB.balanceOf(trader);
        uint256 traderLpBalance = pool.balanceOf(trader);
        uint256 lpAmount = (amountA + amountB) / 4;

        pool.removeLiquidity(lpAmount, lpAmount, lpAmount, trader, deadline);
        vm.stopPrank();

        assertEq(tokenA.balanceOf(trader), traderTokenABalance + lpAmount);
        assertEq(tokenB.balanceOf(trader), traderTokenBBalance + lpAmount);
        assertEq(pool.balanceOf(trader), traderLpBalance - lpAmount);
        assertEq(pool.reserveA(), amountA - lpAmount);
        assertEq(pool.reserveB(), amountB - lpAmount);
    }

    // ─── addLiquidity: segundo depósito ───────────────────────────────────────

    function testAddLiquiditySecondDeposit() public {
        uint256 deadline = block.timestamp + 30 seconds;

        vm.startPrank(lp1);
        pool.addLiquidity(50e18, 50e18, 0, 0, lp1, deadline);
        vm.stopPrank();

        uint256 supplyBefore = pool.totalSupply();

        vm.startPrank(lp2);
        uint256 lp2Minted = pool.addLiquidity(25e18, 25e18, 0, 0, lp2, deadline);
        vm.stopPrank();

        // LP minted proporcionalmente: lp2 aporta la mitad de lp1 => lp2Minted ≈ lp1Minted / 2
        assertEq(lp2Minted, (supplyBefore * 25e18) / 50e18);
        assertGt(lp2Minted, 0);
    }

    function testAddLiquiditySlippageExceeded() public {
        uint256 deadline = block.timestamp + 30 seconds;

        vm.startPrank(lp1);
        pool.addLiquidity(50e18, 50e18, 0, 0, lp1, deadline);
        vm.stopPrank();

        // Pool 1:1, intentamos depositar 25e18/25e18 pero exigimos amountAMin imposible
        vm.startPrank(lp2);
        vm.expectRevert("SlippageExceeded");
        pool.addLiquidity(25e18, 25e18, 26e18, 0, lp2, deadline);
        vm.stopPrank();
    }

    // ─── removeLiquidity: errores ─────────────────────────────────────────────

    function testRemoveLiquidityRevertsIfExpired() public {
        uint256 deadline = block.timestamp + 30 seconds;

        vm.startPrank(lp1);
        pool.addLiquidity(50e18, 50e18, 0, 0, lp1, deadline);
        uint256 lpBalance = pool.balanceOf(lp1);
        vm.warp(deadline + 1);
        vm.expectRevert("Expired");
        pool.removeLiquidity(lpBalance / 2, 0, 0, lp1, deadline);
        vm.stopPrank();
    }

    function testRemoveLiquidityRevertsIfZeroAmount() public {
        uint256 deadline = block.timestamp + 30 seconds;

        vm.startPrank(lp1);
        pool.addLiquidity(50e18, 50e18, 0, 0, lp1, deadline);
        vm.expectRevert("ZeroAmount");
        pool.removeLiquidity(0, 0, 0, lp1, deadline);
        vm.stopPrank();
    }

    function testRemoveLiquidityRevertsIfZeroAddress() public {
        uint256 deadline = block.timestamp + 30 seconds;

        vm.startPrank(lp1);
        pool.addLiquidity(50e18, 50e18, 0, 0, lp1, deadline);
        uint256 lpBalance = pool.balanceOf(lp1);
        vm.expectRevert("ZeroAddress");
        pool.removeLiquidity(lpBalance / 2, 0, 0, address(0), deadline);
        vm.stopPrank();
    }

    function testRemoveLiquidityRevertsIfSlippageExceeded() public {
        uint256 deadline = block.timestamp + 30 seconds;

        vm.startPrank(lp1);
        pool.addLiquidity(50e18, 50e18, 0, 0, lp1, deadline);
        uint256 lpBalance = pool.balanceOf(lp1);
        // amountAMin mayor que lo que se recibiría
        vm.expectRevert("SlippageExceeded");
        pool.removeLiquidity(lpBalance / 2, 100e18, 0, lp1, deadline);
        vm.stopPrank();
    }

    // ─── swap ─────────────────────────────────────────────────────────────────

    function _initPool() internal {
        uint256 deadline = block.timestamp + 1 days;
        vm.startPrank(lp1);
        pool.addLiquidity(50000e18, 50000e18, 0, 0, lp1, deadline);
        vm.stopPrank();
    }

    function testSwapAToB() public {
        _initPool();
        uint256 amountIn = 100e18;
        uint256 deadline = block.timestamp + 1 days;

        uint256 balBefore = tokenB.balanceOf(trader);

        vm.startPrank(trader);
        uint256 amountOut = pool.swap(address(tokenA), amountIn, 0, trader, deadline);
        vm.stopPrank();

        assertGt(amountOut, 0);
        assertEq(tokenB.balanceOf(trader), balBefore + amountOut);
    }

    function testSwapBToA() public {
        _initPool();
        uint256 amountIn = 100e18;
        uint256 deadline = block.timestamp + 1 days;

        uint256 balBefore = tokenA.balanceOf(trader);

        vm.startPrank(trader);
        uint256 amountOut = pool.swap(address(tokenB), amountIn, 0, trader, deadline);
        vm.stopPrank();

        assertGt(amountOut, 0);
        assertEq(tokenA.balanceOf(trader), balBefore + amountOut);
    }

    function testSwapRevertsIfExpired() public {
        _initPool();
        uint256 deadline = block.timestamp + 30 seconds;
        vm.warp(deadline + 1);

        vm.startPrank(trader);
        vm.expectRevert("Expired");
        pool.swap(address(tokenA), 100e18, 0, trader, deadline);
        vm.stopPrank();
    }

    function testSwapRevertsIfZeroAmount() public {
        _initPool();
        uint256 deadline = block.timestamp + 1 days;

        vm.startPrank(trader);
        vm.expectRevert("ZeroAmount");
        pool.swap(address(tokenA), 0, 0, trader, deadline);
        vm.stopPrank();
    }

    function testSwapRevertsIfZeroAddress() public {
        _initPool();
        uint256 deadline = block.timestamp + 1 days;

        vm.startPrank(trader);
        vm.expectRevert("ZeroAddress");
        pool.swap(address(tokenA), 100e18, 0, address(0), deadline);
        vm.stopPrank();
    }

    function testSwapRevertsIfInvalidToken() public {
        _initPool();
        uint256 deadline = block.timestamp + 1 days;
        address randomToken = vm.addr(9);

        vm.startPrank(trader);
        vm.expectRevert("InvalidToken");
        pool.swap(randomToken, 100e18, 0, trader, deadline);
        vm.stopPrank();
    }

    function testSwapRevertsIfZeroReserve() public {
        // Pool nuevo sin liquidez
        vm.startPrank(owner);
        LiquidityPool emptyPool = new LiquidityPool(address(tokenA), address(tokenB), treasury, owner);
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 days;

        vm.startPrank(trader);
        tokenA.approve(address(emptyPool), type(uint256).max);
        vm.expectRevert("ZeroReserve");
        emptyPool.swap(address(tokenA), 100e18, 0, trader, deadline);
        vm.stopPrank();
    }

    function testSwapRevertsIfSlippageExceeded() public {
        _initPool();
        uint256 deadline = block.timestamp + 1 days;

        vm.startPrank(trader);
        vm.expectRevert("SlippageExceeded");
        pool.swap(address(tokenA), 100e18, 99999e18, trader, deadline);
        vm.stopPrank();
    }

    function testSwapSendsTreasuryFee() public {
        _initPool();
        uint256 deadline = block.timestamp + 1 days;

        vm.startPrank(trader);
        pool.swap(address(tokenA), 1000e18, 0, trader, deadline);
        vm.stopPrank();

        assertGt(tokenA.balanceOf(treasury), 0);
    }

    // ─── getSpotPrice ─────────────────────────────────────────────────────────

    function testGetSpotPriceTokenA() public {
        _initPool();
        // Pool 1:1 => precio de tokenA en términos de tokenB = 1e18
        uint256 price = pool.getSpotPrice(address(tokenA));
        assertEq(price, 1e18);
    }

    function testGetSpotPriceTokenB() public {
        _initPool();
        uint256 price = pool.getSpotPrice(address(tokenB));
        assertEq(price, 1e18);
    }

    function testGetSpotPriceRevertsIfZeroReserve() public {
        vm.expectRevert("ZeroReserve");
        pool.getSpotPrice(address(tokenA));
    }

    function testGetSpotPriceRevertsIfInvalidToken() public {
        _initPool();
        address randomToken = vm.addr(9);
        vm.expectRevert("InvalidToken");
        pool.getSpotPrice(randomToken);
    }

    // ─── setFeeBps ────────────────────────────────────────────────────────────

    function testSetFeeBps() public {
        uint256 newFee = 50;

        vm.startPrank(dao);
        vm.expectEmit(false, false, false, true);
        emit LiquidityPool.FeeUpdated(30, newFee);
        pool.setFeeBps(newFee);
        vm.stopPrank();

        assertEq(pool.feeBps(), newFee);
    }

    function testSetFeeBpsRevertsIfNotDAO() public {
        vm.startPrank(trader);
        vm.expectRevert("OnlyDAO");
        pool.setFeeBps(50);
        vm.stopPrank();
    }

    function testSetFeeBpsRevertsIfInvalidFee() public {
        vm.startPrank(dao);
        vm.expectRevert("InvalidFee");
        pool.setFeeBps(0);
        vm.stopPrank();

        vm.startPrank(dao);
        vm.expectRevert("InvalidFee");
        pool.setFeeBps(1001);
        vm.stopPrank();
    }

    function testSetFeeBpsRevertsIfSameFee() public {
        vm.startPrank(dao);
        vm.expectRevert("Fee is the same");
        pool.setFeeBps(30);
        vm.stopPrank();
    }
}
