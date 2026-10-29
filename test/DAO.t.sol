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

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _propose() internal returns (uint256 proposalId) {
        address[] memory targets = new address[](1);
        targets[0] = address(dao);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("setVotingPeriod(uint256)", 200000);
        vm.startPrank(proposer);
        proposalId = dao.propose(targets, values, calldatas, "Change voting period");
        vm.stopPrank();
    }

    function _vote(uint256 proposalId, bool support1, bool support2) internal {
        vm.startPrank(voter1);
        dao.castVote(proposalId, support1);
        vm.stopPrank();
        vm.startPrank(voter2);
        dao.castVote(proposalId, support2);
        vm.stopPrank();
    }

    function _advanceToExecutable(uint256 proposalId) internal {
        // advance past endTime + timelockDelay
        vm.warp(block.timestamp + VOTING_PERIOD + TIMELOCK_DELAY + 1);
        // suppress unused-parameter warning
        proposalId;
    }

    function _proposeVoteAndWarp() internal returns (uint256 proposalId) {
        proposalId = _propose();
        _vote(proposalId, true, true);
        _advanceToExecutable(proposalId);
    }

    // ─── constructor ──────────────────────────────────────────────────────────

    function testConstructorRevertsZeroGovToken() public {
        vm.expectRevert(bytes("ZeroAddress"));
        new DAO(address(0), address(treasury), VOTING_PERIOD, TIMELOCK_DELAY, QUORUM_BPS, PROPOSAL_THRESHOLD, owner);
    }

    function testConstructorRevertsZeroTreasury() public {
        vm.expectRevert(bytes("ZeroAddress"));
        new DAO(address(govToken), address(0), VOTING_PERIOD, TIMELOCK_DELAY, QUORUM_BPS, PROPOSAL_THRESHOLD, owner);
    }

    function testConstructorRevertsInvalidQuorum() public {
        vm.expectRevert(bytes("InvalidQuorum"));
        new DAO(address(govToken), address(treasury), VOTING_PERIOD, TIMELOCK_DELAY, 10001, PROPOSAL_THRESHOLD, owner);
    }

    function testConstructorRevertsZeroVotingPeriod() public {
        vm.expectRevert(bytes("ZeroVotingPeriod"));
        new DAO(address(govToken), address(treasury), 0, TIMELOCK_DELAY, QUORUM_BPS, PROPOSAL_THRESHOLD, owner);
    }

    function testConstructorRevertsZeroTimelockDelay() public {
        vm.expectRevert(bytes("ZeroTimelockDelay"));
        new DAO(address(govToken), address(treasury), VOTING_PERIOD, 0, QUORUM_BPS, PROPOSAL_THRESHOLD, owner);
    }

    // ─── propose ──────────────────────────────────────────────────────────────

    function testPropose() public {
        uint256 proposalId = _propose();
        assertEq(proposalId, 0);
        assertEq(dao.proposalCount(), 1);
        assertEq(uint8(dao.state(proposalId)), uint8(DAO.ProposalState.Active));
    }

    function testProposeRevertsIfBelowThreshold() public {
        address[] memory targets = new address[](1);
        targets[0] = address(dao);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("setVotingPeriod(uint256)", 200000);
        vm.startPrank(attacker);
        vm.expectRevert(bytes("BelowProposalThreshold"));
        dao.propose(targets, values, calldatas, "Attack");
        vm.stopPrank();
    }

    function testProposeRevertsIfEmptyDescription() public {
        address[] memory targets = new address[](1);
        targets[0] = address(dao);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("setVotingPeriod(uint256)", 200000);
        vm.startPrank(proposer);
        vm.expectRevert(bytes("EmptyProposal"));
        dao.propose(targets, values, calldatas, "");
        vm.stopPrank();
    }

    function testProposeRevertsIfEmptyTargets() public {
        address[] memory targets = new address[](0);
        uint256[] memory values = new uint256[](0);
        bytes[] memory calldatas = new bytes[](0);
        vm.startPrank(proposer);
        vm.expectRevert(bytes("EmptyProposal"));
        dao.propose(targets, values, calldatas, "No targets");
        vm.stopPrank();
    }

    function testProposeRevertsIfTooManyTargets() public {
        address[] memory targets = new address[](11);
        uint256[] memory values = new uint256[](11);
        bytes[] memory calldatas = new bytes[](11);
        for (uint256 i = 0; i < 11; i++) {
            targets[i] = address(dao);
            calldatas[i] = abi.encodeWithSignature("setVotingPeriod(uint256)", 200000);
        }
        vm.startPrank(proposer);
        vm.expectRevert(bytes("TooManyTargets"));
        dao.propose(targets, values, calldatas, "Too many");
        vm.stopPrank();
    }

    function testProposeRevertsIfValuesMismatch() public {
        address[] memory targets = new address[](1);
        targets[0] = address(dao);
        uint256[] memory values = new uint256[](2);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("setVotingPeriod(uint256)", 200000);
        vm.startPrank(proposer);
        vm.expectRevert(bytes("ArityMismatch"));
        dao.propose(targets, values, calldatas, "Mismatch");
        vm.stopPrank();
    }

    function testProposeRevertsIfCalldatasMismatch() public {
        address[] memory targets = new address[](1);
        targets[0] = address(dao);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](2);
        calldatas[0] = abi.encodeWithSignature("setVotingPeriod(uint256)", 200000);
        calldatas[1] = abi.encodeWithSignature("setVotingPeriod(uint256)", 200000);
        vm.startPrank(proposer);
        vm.expectRevert(bytes("ArityMismatch"));
        dao.propose(targets, values, calldatas, "Mismatch calldatas");
        vm.stopPrank();
    }

    // ─── castVote ─────────────────────────────────────────────────────────────

    function testCastVoteFor() public {
        uint256 pid = _propose();
        vm.startPrank(voter1);
        dao.castVote(pid, true);
        vm.stopPrank();
        assertTrue(dao.quorumReached(pid));
    }

    function testCastVoteAgainst() public {
        uint256 pid = _propose();
        vm.startPrank(voter1);
        dao.castVote(pid, false);
        vm.stopPrank();
        // quorum reached (3000e18 > 400e18) but votes are against
        assertTrue(dao.quorumReached(pid));
    }

    function testCastVoteRevertsIfProposalNotFound() public {
        vm.startPrank(voter1);
        vm.expectRevert(bytes("ProposalNotFound"));
        dao.castVote(999, true);
        vm.stopPrank();
    }

    function testCastVoteRevertsIfVotingEnded() public {
        uint256 pid = _propose();
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.startPrank(voter1);
        vm.expectRevert(bytes("VotingNotActive"));
        dao.castVote(pid, true);
        vm.stopPrank();
    }

    function testCastVoteRevertsIfAlreadyVoted() public {
        uint256 pid = _propose();
        vm.startPrank(voter1);
        dao.castVote(pid, true);
        vm.expectRevert(bytes("AlreadyVoted"));
        dao.castVote(pid, true);
        vm.stopPrank();
    }

    function testCastVoteRevertsIfProposalCanceled() public {
        uint256 pid = _propose();
        vm.startPrank(proposer);
        dao.cancel(pid);
        vm.stopPrank();
        vm.startPrank(voter1);
        vm.expectRevert(bytes("ProposalCanceled"));
        dao.castVote(pid, true);
        vm.stopPrank();
    }

    function testCastVoteRevertsIfNoVotingPower() public {
        uint256 pid = _propose();
        vm.startPrank(attacker);
        vm.expectRevert(bytes("NoVotingPower"));
        dao.castVote(pid, true);
        vm.stopPrank();
    }

    // ─── execute ──────────────────────────────────────────────────────────────

    function testExecute() public {
        uint256 pid = _proposeVoteAndWarp();
        dao.execute(pid);
        assertEq(uint8(dao.state(pid)), uint8(DAO.ProposalState.Executed));
        assertEq(dao.votingPeriod(), 200000);
    }

    function testExecuteRevertsIfProposalNotFound() public {
        vm.expectRevert(bytes("ProposalNotFound"));
        dao.execute(999);
    }

    function testExecuteRevertsIfTimelockNotElapsed() public {
        uint256 pid = _propose();
        _vote(pid, true, true);
        // warp past voting period but not past timelock
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        vm.expectRevert(bytes("TimelockNotElapsed"));
        dao.execute(pid);
    }

    function testExecuteRevertsIfProposalDefeated() public {
        uint256 pid = _propose();
        // more against than for
        vm.startPrank(voter1);
        dao.castVote(pid, false);
        vm.stopPrank();
        vm.startPrank(voter2);
        dao.castVote(pid, true);
        vm.stopPrank();
        // voter1 has 3000e18 against, voter2 has 2000e18 for → defeated
        _advanceToExecutable(pid);
        vm.expectRevert(bytes("ProposalDefeated"));
        dao.execute(pid);
    }

    function testExecuteRevertsIfQuorumNotReached() public {
        // smallVoter gets 200e18; after roll snapshotBlock totalSupply = 5500+200 = 5700e18
        // quorum = 5700 * 400 / 10000 = 228e18 > 200e18 → QuorumNotReached
        address smallVoter = vm.addr(6);
        vm.startPrank(owner);
        govToken.mint(smallVoter, 200e18);
        vm.stopPrank();
        vm.startPrank(smallVoter);
        govToken.delegate(smallVoter);
        vm.stopPrank();
        vm.roll(block.number + 1);

        uint256 pid = _propose();
        vm.startPrank(smallVoter);
        dao.castVote(pid, true);
        vm.stopPrank();

        _advanceToExecutable(pid);
        vm.expectRevert(bytes("QuorumNotReached"));
        dao.execute(pid);
    }

    function testExecuteRevertsIfAlreadyExecuted() public {
        uint256 pid = _proposeVoteAndWarp();
        dao.execute(pid);
        vm.expectRevert(bytes("AlreadyExecuted"));
        dao.execute(pid);
    }

    function testExecuteRevertsIfCanceled() public {
        uint256 pid = _propose();
        _vote(pid, true, true);
        vm.startPrank(proposer);
        dao.cancel(pid);
        vm.stopPrank();
        _advanceToExecutable(pid);
        vm.expectRevert(bytes("ProposalCanceled"));
        dao.execute(pid);
    }

    // ─── cancel ───────────────────────────────────────────────────────────────

    function testCancelByProposer() public {
        uint256 pid = _propose();
        vm.startPrank(proposer);
        dao.cancel(pid);
        vm.stopPrank();
        assertEq(uint8(dao.state(pid)), uint8(DAO.ProposalState.Canceled));
    }

    function testCancelRevertsIfNotAuthorized() public {
        uint256 pid = _propose();
        vm.startPrank(attacker);
        vm.expectRevert(bytes("NotAuthorized"));
        dao.cancel(pid);
        vm.stopPrank();
    }

    function testCancelRevertsIfAlreadyExecuted() public {
        uint256 pid = _proposeVoteAndWarp();
        dao.execute(pid);
        vm.startPrank(proposer);
        vm.expectRevert(bytes("AlreadyExecuted"));
        dao.cancel(pid);
        vm.stopPrank();
    }

    function testCancelRevertsIfAlreadyCanceled() public {
        uint256 pid = _propose();
        vm.startPrank(proposer);
        dao.cancel(pid);
        vm.expectRevert(bytes("AlreadyCanceled"));
        dao.cancel(pid);
        vm.stopPrank();
    }

    function testCancelRevertsIfProposalNotFound() public {
        vm.startPrank(proposer);
        vm.expectRevert(bytes("ProposalNotFound"));
        dao.cancel(999);
        vm.stopPrank();
    }

    // ─── state ────────────────────────────────────────────────────────────────

    function testStateActive() public {
        uint256 pid = _propose();
        assertEq(uint8(dao.state(pid)), uint8(DAO.ProposalState.Active));
    }

    function testStateDefeated() public {
        uint256 pid = _propose();
        // nobody votes → quorum not reached → Defeated after endTime
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint8(dao.state(pid)), uint8(DAO.ProposalState.Defeated));
    }

    function testStateQueued() public {
        uint256 pid = _propose();
        _vote(pid, true, true);
        // past endTime but before executionTime
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertEq(uint8(dao.state(pid)), uint8(DAO.ProposalState.Queued));
    }

    function testStateSucceeded() public {
        uint256 pid = _propose();
        _vote(pid, true, true);
        _advanceToExecutable(pid);
        assertEq(uint8(dao.state(pid)), uint8(DAO.ProposalState.Succeeded));
    }

    function testStateExecuted() public {
        uint256 pid = _proposeVoteAndWarp();
        dao.execute(pid);
        assertEq(uint8(dao.state(pid)), uint8(DAO.ProposalState.Executed));
    }

    function testStateCanceled() public {
        uint256 pid = _propose();
        vm.startPrank(proposer);
        dao.cancel(pid);
        vm.stopPrank();
        assertEq(uint8(dao.state(pid)), uint8(DAO.ProposalState.Canceled));
    }

    // ─── quorumReached / quorumVotes ──────────────────────────────────────────

    function testQuorumReachedTrue() public {
        uint256 pid = _propose();
        vm.startPrank(voter1);
        dao.castVote(pid, true);
        vm.stopPrank();
        assertTrue(dao.quorumReached(pid));
    }

    function testQuorumReachedFalse() public {
        uint256 pid = _propose();
        assertFalse(dao.quorumReached(pid));
    }

    function testQuorumVotes() public view {
        // totalSupply = 10000e18 (full cap was minted by setUp setup: owner minted 500+3000+2000 = 5500e18, rest uncapped)
        // Actually totalSupply = 5500e18 (only what was minted), quorum = 5500e18 * 400 / 10000 = 220e18
        uint256 expected = govToken.totalSupply() * QUORUM_BPS / 10000;
        assertEq(dao.quorumVotes(), expected);
    }

    // ─── governance setters (OnlyDAO) ─────────────────────────────────────────

    function testSetVotingPeriodRevertsIfNotDAO() public {
        vm.startPrank(attacker);
        vm.expectRevert(bytes("OnlyDAO"));
        dao.setVotingPeriod(100000);
        vm.stopPrank();
    }

    function testSetTimelockDelayRevertsIfNotDAO() public {
        vm.startPrank(attacker);
        vm.expectRevert(bytes("OnlyDAO"));
        dao.setTimelockDelay(100000);
        vm.stopPrank();
    }

    function testSetQuorumBpsRevertsIfNotDAO() public {
        vm.startPrank(attacker);
        vm.expectRevert(bytes("OnlyDAO"));
        dao.setQuorumBps(500);
        vm.stopPrank();
    }

    function testSetProposalThresholdRevertsIfNotDAO() public {
        vm.startPrank(attacker);
        vm.expectRevert(bytes("OnlyDAO"));
        dao.setProposalThreshold(200e18);
        vm.stopPrank();
    }

    function testSetVotingPeriodRevertsIfZero() public {
        vm.startPrank(address(dao));
        vm.expectRevert(bytes("ZeroVotingPeriod"));
        dao.setVotingPeriod(0);
        vm.stopPrank();
    }

    function testSetQuorumBpsRevertsIfInvalid() public {
        vm.startPrank(address(dao));
        vm.expectRevert(bytes("InvalidQuorum"));
        dao.setQuorumBps(10001);
        vm.stopPrank();
    }

    function testSetVotingPeriodViaProposal() public {
        uint256 newPeriod = 172800;
        address[] memory targets = new address[](1);
        targets[0] = address(dao);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeWithSignature("setVotingPeriod(uint256)", newPeriod);
        vm.startPrank(proposer);
        uint256 pid = dao.propose(targets, values, calldatas, "Set voting period 2 days");
        vm.stopPrank();
        _vote(pid, true, true);
        _advanceToExecutable(pid);
        dao.execute(pid);
        assertEq(dao.votingPeriod(), newPeriod);
    }

    function testSetTimelockDelayRevertsIfZero() public {
        vm.startPrank(address(dao));
        vm.expectRevert(bytes("ZeroTimelockDelay"));
        dao.setTimelockDelay(0);
        vm.stopPrank();
    }

    function testSetProposalThresholdViaDAO() public {
        vm.startPrank(address(dao));
        dao.setProposalThreshold(50e18);
        vm.stopPrank();
        assertEq(dao.proposalThreshold(), 50e18);
    }

    function testSetQuorumBpsViaDAO() public {
        vm.startPrank(address(dao));
        dao.setQuorumBps(500);
        vm.stopPrank();
        assertEq(dao.quorumBps(), 500);
    }

    function testReceiveETH() public {
        vm.deal(voter1, 1 ether);
        vm.startPrank(voter1);
        (bool ok,) = address(dao).call{value: 1 ether}("");
        vm.stopPrank();
        assertTrue(ok);
        assertEq(address(dao).balance, 1 ether);
    }
}
