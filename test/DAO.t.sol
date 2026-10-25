// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/dao/DAO.sol";
import "../src/tokens/GovernanceToken.sol";
import "../src/dao/DAOTreasury.sol";

contract DAOTest is Test {
    DAO internal dao;
    GovernanceToken internal govToken;
    DAOTreasury internal treasury;

    address internal owner = vm.addr(1);
    address internal proposer = vm.addr(2);
    address internal voter1 = vm.addr(3);
    address internal voter2 = vm.addr(4);
    address internal attacker = vm.addr(5);

    uint256 internal constant VOTING_PERIOD = 259200;
    uint256 internal constant TIMELOCK_DELAY = 86400;
    uint256 internal constant QUORUM_BPS = 400;
    uint256 internal constant PROPOSAL_THRESHOLD = 100e18;

    function setUp() public {
        vm.label(owner, "owner");
        vm.label(proposer, "proposer");
        vm.label(voter1, "voter1");
        vm.label(voter2, "voter2");
        vm.label(attacker, "attacker");

        vm.startPrank(owner);
        govToken = new GovernanceToken(10000e18, "GovFi", "GOV", owner);
        treasury = new DAOTreasury(address(0));
        dao = new DAO(address(govToken), address(treasury), VOTING_PERIOD, TIMELOCK_DELAY, QUORUM_BPS, PROPOSAL_THRESHOLD, owner);
        treasury.setDAO(address(dao));
        govToken.mint(proposer, 500e18);
        govToken.mint(voter1, 3000e18);
        govToken.mint(voter2, 2000e18);
        vm.stopPrank();

        vm.label(address(govToken), "govToken");
        vm.label(address(treasury), "treasury");
        vm.label(address(dao), "dao");

        vm.startPrank(proposer);
        govToken.delegate(proposer);
        vm.stopPrank();

        vm.startPrank(voter1);
        govToken.delegate(voter1);
        vm.stopPrank();

        vm.startPrank(voter2);
        govToken.delegate(voter2);
        vm.stopPrank();

        vm.roll(block.number + 1);
    }
}
