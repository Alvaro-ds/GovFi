// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/tokens/GovernanceToken.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract GovernanceTokenTest is Test {
    GovernanceToken internal govToken;

    address internal owner = vm.addr(1);
    address internal minter = vm.addr(2);
    address internal user = vm.addr(3);
    address internal attacker = vm.addr(4);

    uint256 internal constant MAX_SUPPLY = 1000000e18;

    function setUp() public {
        vm.label(owner, "owner");
        vm.label(minter, "minter");
        vm.label(user, "user");
        vm.label(attacker, "attacker");

        vm.startPrank(owner);
        govToken = new GovernanceToken(MAX_SUPPLY, "GovFi", "GOV", owner);
        govToken.grantMinterRole(minter);
        vm.stopPrank();

        vm.label(address(govToken), "govToken");
    }

    function testMinterRoleCanMint() public {
       address to = user;
       uint256 amount = 500e18;

       vm.startPrank(minter);
       govToken.mint(to, amount);
       vm.stopPrank();
    }

    function testUserCannotMint() public {
        address to = user;
        uint256 amount = 500e18;
        bytes32 minterRole = govToken.MINTER_ROLE();

        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, minterRole));
        govToken.mint(to, amount);
        vm.stopPrank();
    }

    function testAmountAndTotalSupplyShouldBeSmallerThanMaxSupply() public {
        address to = user;
        uint256 amount = MAX_SUPPLY - 10e18;

        vm.startPrank(minter);
        govToken.mint(to, amount);

        uint256 amountToExceed = 11e18;
        
        vm.expectRevert("SupplyExceeded");
        govToken.mint(to, amountToExceed);
        vm.stopPrank();

        assertEq(govToken.totalSupply(), amount);
    }

    function testUserCanBurn() public{
        address to = user;
        uint256 amountMinted = 500e18;
        uint256 amountBurned = amountMinted / 2e18;

        vm.startPrank(minter);
        govToken.mint(to, amountMinted);
        vm.stopPrank();

        vm.startPrank(user);
        govToken.burn(amountBurned);
        vm.stopPrank();

        vm.assertEq(govToken.balanceOf(user), amountMinted - amountBurned);
    }

    function testUserCannotBurnWithoutGovTokensMinted() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, 0, 50e18));
        govToken.burn(50e18);
        vm.stopPrank();
    }

    function testMinterRoleIsGrantedCorrectly() public{
        vm.startPrank(owner);
        govToken.grantMinterRole(user);
        vm.stopPrank();

        assertTrue(govToken.hasRole(govToken.MINTER_ROLE(), user));
    }

    function testUserCannotGrantMinterRole() public{
        vm.startPrank(user);
        vm.expectRevert();
        govToken.grantMinterRole(user);
        vm.stopPrank();

        assertFalse(govToken.hasRole(govToken.MINTER_ROLE(), user));
    }

    function testMinterCannotGrantMinterRole() public{
        vm.startPrank(minter);
        vm.expectRevert();
        govToken.grantMinterRole(user);
        vm.stopPrank();

        assertFalse(govToken.hasRole(govToken.MINTER_ROLE(), user));
    }

    function testCannotGrantMinterRoleToZeroAddress() public{
        vm.startPrank(owner);
        vm.expectRevert("ZeroAddress");
        govToken.grantMinterRole(address(0));
        vm.stopPrank();

        assertFalse(govToken.hasRole(govToken.MINTER_ROLE(), address(0)));
    }

    function testOwnerCanRevokeMinterRole() public {
        vm.startPrank(owner);
        govToken.revokeMinterRole(minter);
        vm.stopPrank();

        assertFalse(govToken.hasRole(govToken.MINTER_ROLE(), minter));
    }

    function testUserCannotRevokeMinterRole() public {
        vm.startPrank(user);
        vm.expectRevert();
        govToken.revokeMinterRole(minter);
        vm.stopPrank();

        assertTrue(govToken.hasRole(govToken.MINTER_ROLE(), minter));
    }
}
