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
}
