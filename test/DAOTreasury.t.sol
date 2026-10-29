// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/dao/DAOTreasury.sol";
import "./mocks/MockERC20.sol";

contract DAOTreasuryTest is Test {
    DAOTreasury internal treasury;
    MockERC20 internal token;

    address internal owner = vm.addr(1);
    address internal dao = vm.addr(2);
    address internal receiver = vm.addr(3);
    address internal attacker = vm.addr(4);

    function setUp() public {
        vm.label(owner, "owner");
        vm.label(dao, "dao");
        vm.label(receiver, "receiver");
        vm.label(attacker, "attacker");

        token = new MockERC20("Mock Token", "MCK", 18);
        vm.label(address(token), "token");

        vm.startPrank(owner);
        treasury = new DAOTreasury(address(0));
        treasury.setDAO(dao);
        vm.stopPrank();

        vm.label(address(treasury), "treasury");

        vm.deal(address(treasury), 10 ether);
        token.mint(address(treasury), 1000e18);
    }

    // ─── constructor ────────────────────────────────────────────────────────────

    function testConstructorWithInitialDAO() public {
        address initialDAO = vm.addr(10);
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, false);
        emit DAOTreasury.DAOSet(address(0), initialDAO);
        DAOTreasury freshTreasury = new DAOTreasury(initialDAO);
        vm.stopPrank();
        assertEq(freshTreasury.dao(), initialDAO);
    }

    function testConstructorWithoutDAO() public {
        vm.startPrank(owner);
        DAOTreasury freshTreasury = new DAOTreasury(address(0));
        vm.stopPrank();
        assertEq(freshTreasury.dao(), address(0));
    }

    // ─── setDAO ─────────────────────────────────────────────────────────────────

    function testSetDAORevertsIfAlreadySet() public {
        vm.startPrank(dao);
        vm.expectRevert(bytes("DAOAlreadySet"));
        treasury.setDAO(vm.addr(10));
        vm.stopPrank();
    }

    function testSetDARevertsIfZeroAddress() public {
        vm.startPrank(owner);
        DAOTreasury freshTreasury = new DAOTreasury(address(0));
        vm.expectRevert(bytes("ZeroAddress"));
        freshTreasury.setDAO(address(0));
        vm.stopPrank();
    }

    function testSetDAOTransfersOwnership() public view {
        assertEq(treasury.owner(), dao);
    }

    function testSetDAOEmitEvent() public {
        vm.startPrank(owner);
        DAOTreasury freshTreasury = new DAOTreasury(address(0));
        address newDAO = vm.addr(10);
        vm.expectEmit(true, true, false, false);
        emit DAOTreasury.DAOSet(address(0), newDAO);
        freshTreasury.setDAO(newDAO);
        vm.stopPrank();
    }

    // ─── receive() ──────────────────────────────────────────────────────────────

    function testReceiveETH() public {
        uint256 balanceBefore = address(treasury).balance;
        vm.startPrank(attacker);
        vm.deal(attacker, 1 ether);
        vm.expectEmit(true, false, false, true);
        emit DAOTreasury.ETHReceived(attacker, 1 ether);
        (bool ok,) = address(treasury).call{value: 1 ether}("");
        vm.stopPrank();
        assertTrue(ok);
        assertEq(address(treasury).balance, balanceBefore + 1 ether);
    }

    // ─── withdrawETH ────────────────────────────────────────────────────────────

    function testWithdrawETH() public {
        uint256 treasuryBefore = address(treasury).balance;
        uint256 receiverBefore = receiver.balance;
        vm.startPrank(dao);
        treasury.withdrawETH(receiver, 1 ether, "grant");
        vm.stopPrank();
        assertEq(address(treasury).balance, treasuryBefore - 1 ether);
        assertEq(receiver.balance, receiverBefore + 1 ether);
    }

    function testWithdrawETHRevertsIfNotDAO() public {
        vm.startPrank(attacker);
        vm.expectRevert(bytes("OnlyDAO"));
        treasury.withdrawETH(receiver, 1 ether, "grant");
        vm.stopPrank();
    }

    function testWithdrawETHRevertsIfZeroAddress() public {
        vm.startPrank(dao);
        vm.expectRevert(bytes("ZeroAddress"));
        treasury.withdrawETH(address(0), 1 ether, "grant");
        vm.stopPrank();
    }

    function testWithdrawETHRevertsIfZeroAmount() public {
        vm.startPrank(dao);
        vm.expectRevert(bytes("ZeroAmount"));
        treasury.withdrawETH(receiver, 0, "grant");
        vm.stopPrank();
    }

    function testWithdrawETHRevertsIfInsufficientBalance() public {
        vm.startPrank(dao);
        vm.expectRevert(bytes("InsufficientETH"));
        treasury.withdrawETH(receiver, 100 ether, "grant");
        vm.stopPrank();
    }

    function testWithdrawETHRevertsIfEmptyReason() public {
        vm.startPrank(dao);
        vm.expectRevert(bytes("InvalidReason"));
        treasury.withdrawETH(receiver, 1 ether, "");
        vm.stopPrank();
    }

    function testWithdrawETHEmitsTreasuryAction() public {
        vm.startPrank(dao);
        vm.expectEmit(true, true, false, true);
        emit DAOTreasury.TreasuryAction(address(0), receiver, 1 ether, "grant");
        treasury.withdrawETH(receiver, 1 ether, "grant");
        vm.stopPrank();
    }

    // ─── withdrawERC20 ──────────────────────────────────────────────────────────

    function testWithdrawERC20() public {
        uint256 treasuryBefore = token.balanceOf(address(treasury));
        uint256 receiverBefore = token.balanceOf(receiver);
        vm.startPrank(dao);
        treasury.withdrawERC20(address(token), receiver, 100e18, "reward");
        vm.stopPrank();
        assertEq(token.balanceOf(address(treasury)), treasuryBefore - 100e18);
        assertEq(token.balanceOf(receiver), receiverBefore + 100e18);
    }

    function testWithdrawERC20RevertsIfNotDAO() public {
        vm.startPrank(attacker);
        vm.expectRevert(bytes("OnlyDAO"));
        treasury.withdrawERC20(address(token), receiver, 100e18, "reward");
        vm.stopPrank();
    }

    function testWithdrawERC20RevertsIfZeroToken() public {
        vm.startPrank(dao);
        vm.expectRevert(bytes("ZeroAddress"));
        treasury.withdrawERC20(address(0), receiver, 100e18, "reward");
        vm.stopPrank();
    }

    function testWithdrawERC20RevertsIfZeroRecipient() public {
        vm.startPrank(dao);
        vm.expectRevert(bytes("ZeroAddress"));
        treasury.withdrawERC20(address(token), address(0), 100e18, "reward");
        vm.stopPrank();
    }

    function testWithdrawERC20RevertsIfZeroAmount() public {
        vm.startPrank(dao);
        vm.expectRevert(bytes("ZeroAmount"));
        treasury.withdrawERC20(address(token), receiver, 0, "reward");
        vm.stopPrank();
    }

    function testWithdrawERC20RevertsIfInsufficientBalance() public {
        vm.startPrank(dao);
        vm.expectRevert(bytes("InsufficientTokenBalance"));
        treasury.withdrawERC20(address(token), receiver, 9999e18, "reward");
        vm.stopPrank();
    }

    function testWithdrawERC20RevertsIfEmptyReason() public {
        vm.startPrank(dao);
        vm.expectRevert(bytes("InvalidReason"));
        treasury.withdrawERC20(address(token), receiver, 100e18, "");
        vm.stopPrank();
    }

    function testWithdrawERC20EmitsTreasuryAction() public {
        vm.startPrank(dao);
        vm.expectEmit(true, true, false, true);
        emit DAOTreasury.TreasuryAction(address(token), receiver, 100e18, "reward");
        treasury.withdrawERC20(address(token), receiver, 100e18, "reward");
        vm.stopPrank();
    }

    // ─── getETHBalance / getTokenBalance ────────────────────────────────────────

    function testGetETHBalance() public view {
        assertEq(treasury.getETHBalance(), 10 ether);
    }

    function testGetTokenBalance() public view {
        assertEq(treasury.getTokenBalance(address(token)), 1000e18);
    }

    function testGetTokenBalanceRevertsIfZeroAddress() public {
        vm.expectRevert(bytes("ZeroAddress"));
        treasury.getTokenBalance(address(0));
    }
}
