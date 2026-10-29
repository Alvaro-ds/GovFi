// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "../../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../../lib/openzeppelin-contracts/contracts/governance/utils/IVotes.sol";

/// @title DAO
/// @notice Custom governance contract managing the full proposal lifecycle:
///         creation → voting → timelock → execution of arbitrary on-chain calls.
/// @dev Intentionally does not extend OZ Governor to stay self-contained and auditable.
///      Flash-loan governance attack is mitigated by reading voting power from ERC20Votes
///      snapshots at proposal.snapshotBlock (block N-1 relative to proposal creation).
contract DAO is Ownable2Step, ReentrancyGuard {
    /// @notice Lifecycle states a proposal can occupy at any point in time.
    enum ProposalState {
        Pending,
        Active,
        Defeated,
        Succeeded,
        Queued,
        Executed,
        Canceled
    }

    /// @notice Complete on-chain record for a single governance proposal.
    /// @dev Contains a mapping, so Proposal structs can only live in storage.
    ///      The proposals state variable is therefore declared internal; add an explicit
    ///      getter returning non-mapping fields if external reads are needed.
    struct Proposal {
        /// @dev Monotonic proposal identifier.
        uint256 id;
        /// @dev Address that submitted the proposal.
        address proposer;
        /// @dev Contracts to call if the proposal passes.
        address[] targets;
        /// @dev ETH amounts (wei) to send with each call.
        uint256[] values;
        /// @dev ABI-encoded function calls to execute.
        bytes[] calldatas;
        /// @dev Human-readable description stored on-chain.
        string description;
        /// @dev Block number used to snapshot voting power (set to block.number - 1 at proposal creation).
        uint256 snapshotBlock;
        /// @dev Unix timestamp when voting opens (set to block.timestamp at proposal creation).
        uint256 startTime;
        /// @dev Unix timestamp when voting closes (startTime + votingPeriod).
        uint256 endTime;
        /// @dev Earliest Unix timestamp at which execution is allowed (endTime + timelockDelay).
        uint256 executionTime;
        /// @dev Cumulative votes in favor, weighted by ERC20Votes snapshot.
        uint256 forVotes;
        /// @dev Cumulative votes against, weighted by ERC20Votes snapshot.
        uint256 againstVotes;
        /// @dev True once execute() has been called successfully.
        bool executed;
        /// @dev True once cancel() has been called.
        bool canceled;
        /// @dev Tracks which addresses have already voted to prevent double-voting.
        mapping(address => bool) hasVoted;
    }

    /// @notice GovernanceToken used to read voting power via getPastVotes.
    address public immutable govToken;

    /// @notice DAOTreasury governed by this DAO.
    address public immutable treasury;

    /// @dev Internal because Proposal contains a mapping; the public getter cannot be auto-generated.
    mapping(uint256 => Proposal) internal proposals;

    /// @notice Total number of proposals ever created; also the ID for the next proposal.
    uint256 public proposalCount;

    /// @notice Duration of the voting window in seconds. Default: 259200 (3 days).
    uint256 public votingPeriod;

    /// @notice Delay between end of voting and earliest execution timestamp. Default: 86400 (1 day).
    uint256 public timelockDelay;

    /// @notice Minimum fraction of total supply required for quorum, in basis points (e.g. 400 = 4%).
    uint256 public quorumBps;

    /// @notice Minimum voting power (govToken wei) an address must hold to create a proposal.
    uint256 public proposalThreshold;

    /// @notice Emitted when a new proposal is created.
    /// @param id Unique monotonic proposal identifier.
    /// @param proposer Address that submitted the proposal.
    /// @param description Human-readable description.
    /// @param startTime Unix timestamp when voting opens.
    /// @param endTime Unix timestamp when voting closes.
    event ProposalCreated(uint256 indexed id, address indexed proposer, string description, uint256 startTime, uint256 endTime);

    /// @notice Emitted when a vote is cast on a proposal.
    /// @param proposalId Proposal being voted on.
    /// @param voter Address of the voter.
    /// @param support True for in-favor; false for against.
    /// @param weight Voting power applied (from ERC20Votes snapshot at snapshotBlock).
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);

    /// @notice Emitted when a proposal is executed successfully.
    /// @param id Proposal identifier.
    event ProposalExecuted(uint256 indexed id);

    /// @notice Emitted when a proposal is canceled.
    /// @param id Proposal identifier.
    event ProposalCanceled(uint256 indexed id);

    /// @notice Emitted when a governance parameter is updated via an executed proposal.
    /// @param param Name of the updated parameter.
    /// @param oldValue Value before the update.
    /// @param newValue Value after the update.
    event ParameterUpdated(string indexed param, uint256 oldValue, uint256 newValue);

    /// @notice Deploys the DAO and sets all governance parameters.
    /// @param govToken_ GovernanceToken address. Cannot be address(0).
    /// @param treasury_ DAOTreasury address. Cannot be address(0).
    /// @param votingPeriod_ Voting window in seconds. Must be > 0.
    /// @param timelockDelay_ Delay between vote end and execution in seconds. Must be > 0.
    /// @param quorumBps_ Quorum as fraction of total supply in bps. Must be <= 10000.
    /// @param proposalThreshold_ Minimum govToken balance (wei) required to submit proposals.
    /// @param initialOwner Address that will own the contract after deployment.
    constructor(address govToken_, address treasury_, uint256 votingPeriod_, uint256 timelockDelay_, uint256 quorumBps_, uint256 proposalThreshold_, address initialOwner) Ownable(initialOwner) {
        require(govToken_ != address(0), "ZeroAddress");
        require(treasury_ != address(0), "ZeroAddress");
        require(quorumBps_ <= 10000, "InvalidQuorum");
        require(votingPeriod_ > 0, "ZeroVotingPeriod");
        require(timelockDelay_ > 0, "ZeroTimelockDelay");
        govToken = govToken_;
        treasury = treasury_;
        votingPeriod = votingPeriod_;
        timelockDelay = timelockDelay_;
        quorumBps = quorumBps_;
        proposalThreshold = proposalThreshold_;
    }

    /// @notice Creates a new governance proposal.
    /// @dev Caller must hold at least proposalThreshold voting power at block.number - 1
    ///      (getPastVotes). snapshotBlock = block.number - 1 so the snapshot is already final
    ///      when the first vote is cast. executionTime = endTime + timelockDelay.
    ///      Limit the targets array to a maximum of 10 to prevent unbounded gas cost in execute().
    /// @param targets Contracts to call if the proposal passes. Must not be empty, max 10.
    /// @param values ETH amounts (wei) to forward with each call. Length must match targets.
    /// @param calldatas ABI-encoded calls. Length must match targets.
    /// @param description Human-readable proposal description stored on-chain.
    /// @return proposalId Monotonically increasing identifier of the new proposal.
    function propose(address[] calldata targets, uint256[] calldata values, bytes[] memory calldatas, string calldata description) external returns (uint256 proposalId) {
        require(IVotes(govToken).getPastVotes(msg.sender, block.number - 1) >= proposalThreshold, "BelowProposalThreshold");
        require(bytes(description).length > 0, "EmptyProposal");
        require(targets.length > 0, "EmptyProposal");
        require(targets.length <= 10, "TooManyTargets");
        require(values.length == targets.length, "ArityMismatch");
        require(calldatas.length == targets.length, "ArityMismatch");

        proposalId = proposalCount++;
        Proposal storage proposal = proposals[proposalId];

        proposal.id = proposalId;
        proposal.calldatas = calldatas;
        proposal.description = description;
        proposal.targets = targets;
        proposal.values = values;
        proposal.proposer = msg.sender;
        proposal.snapshotBlock = block.number - 1;
        proposal.startTime = block.timestamp;
        proposal.endTime = block.timestamp + votingPeriod;
        proposal.executionTime = proposal.endTime + timelockDelay;

        emit ProposalCreated(proposalId, msg.sender, description, block.timestamp, block.timestamp + votingPeriod);
    }

    /// @notice Casts a vote for or against an active proposal.
    /// @dev Weight = govToken.getPastVotes(msg.sender, proposal.snapshotBlock).
    ///      Each address may vote at most once per proposal (hasVoted guard).
    ///      Reverts with "NoVotingPower" if the snapshot weight is zero.
    /// @param proposalId Proposal to vote on. Must currently be in Active state.
    /// @param support True to vote in favor; false to vote against.
    function castVote(uint256 proposalId, bool support) external {
        Proposal storage proposal = proposals[proposalId];

        require(proposal.proposer != address(0), "ProposalNotFound");
        require(block.timestamp >= proposal.startTime, "VotingNotActive");
        require(block.timestamp < proposal.endTime, "VotingNotActive");
        require(!proposal.hasVoted[msg.sender], "AlreadyVoted");
        require(!proposal.canceled, "ProposalCanceled");
        require(!proposal.executed, "AlreadyExecuted");

        uint256 votes = IVotes(govToken).getPastVotes(msg.sender, proposal.snapshotBlock);
        require(votes > 0, "NoVotingPower");

        proposal.hasVoted[msg.sender] = true;

        if (support) {
            proposal.forVotes += votes;
        } else {
            proposal.againstVotes += votes;
        }

        emit VoteCast(proposalId, msg.sender, support, votes);
    }

    /// @notice Executes the calls of a passed proposal once the timelock has elapsed.
    /// @dev CEI: proposal.executed = true is set BEFORE any external call to prevent reentrancy.
    ///      Each action: (bool ok,) = targets[i].call{value: values[i]}(calldatas[i]); require(ok, "ExecutionFailed").
    ///      If any call reverts the whole transaction reverts, undoing the executed flag; proposal can be retried.
    /// @param proposalId Proposal to execute. Must be in Succeeded state and past executionTime.
    function execute(uint256 proposalId) external nonReentrant {
        Proposal storage proposal = proposals[proposalId];

        require(proposal.proposer != address(0), "ProposalNotFound");
        require(!proposal.canceled, "ProposalCanceled");
        require(!proposal.executed, "AlreadyExecuted");
        require(block.timestamp >= proposal.executionTime, "TimelockNotElapsed");
        require(proposal.forVotes > proposal.againstVotes, "ProposalDefeated");
        require(proposal.forVotes + proposal.againstVotes >= IVotes(govToken).getPastTotalSupply(proposal.snapshotBlock) * quorumBps / 10000, "QuorumNotReached");

        proposal.executed = true;

        for (uint256 i = 0; i < proposal.targets.length; i++) {
            (bool ok,) = proposal.targets[i].call{value: proposal.values[i]}(proposal.calldatas[i]);
            require(ok, "ExecutionFailed");
        }

        emit ProposalExecuted(proposalId);
    }

    /// @notice Cancels a proposal. Only the original proposer or the DAO itself may cancel.
    /// @dev Cannot cancel a proposal that has already been executed.
    ///      Sets canceled = true; proposal permanently transitions to Canceled state.
    /// @param proposalId Proposal to cancel.
    function cancel(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];

        require(proposal.proposer != address(0), "ProposalNotFound");
        require(msg.sender == address(this) || msg.sender == proposal.proposer, "NotAuthorized");
        require(!proposal.executed, "AlreadyExecuted");
        require(!proposal.canceled, "AlreadyCanceled");

        proposal.canceled = true;

        emit ProposalCanceled(proposalId);
    }

    /// @notice Returns the current lifecycle state of a proposal.
    /// @dev State machine (priority order):
    ///      Canceled if canceled flag is set.
    ///      Executed if executed flag is set.
    ///      Pending  if block.timestamp < startTime.
    ///      Active   if startTime <= block.timestamp < endTime.
    ///      Defeated if endTime reached AND (quorum not met OR forVotes <= againstVotes).
    ///      Queued   if passed AND block.timestamp < executionTime (in timelock).
    ///      Succeeded if passed AND block.timestamp >= executionTime (ready to execute).
    /// @param proposalId Proposal to query. Reverts with "ProposalNotFound" if it does not exist.
    /// @return ProposalState enum value representing the current state.
    function state(uint256 proposalId) external view returns (ProposalState) {
        Proposal storage proposal = proposals[proposalId];

        require(proposal.proposer != address(0), "ProposalNotFound");

        if (proposal.canceled) return ProposalState.Canceled;
        if (proposal.executed) return ProposalState.Executed;
        if (block.timestamp < proposal.startTime) return ProposalState.Pending;
        if (block.timestamp < proposal.endTime) return ProposalState.Active;

        bool quorum = proposal.forVotes + proposal.againstVotes >= IVotes(govToken).getPastTotalSupply(proposal.snapshotBlock) * quorumBps / 10000;
        if (!quorum || proposal.forVotes <= proposal.againstVotes) return ProposalState.Defeated;
        if (block.timestamp < proposal.executionTime) return ProposalState.Queued;
        return ProposalState.Succeeded;
    }

    /// @notice Returns whether quorum has been reached for a proposal.
    /// @dev Uses the total supply snapshot at snapshotBlock, not the current supply.
    /// @param proposalId Proposal to check.
    /// @return True if quorum is satisfied.
    function quorumReached(uint256 proposalId) public view returns (bool) {
        Proposal storage proposal = proposals[proposalId];

        require(proposal.proposer != address(0), "ProposalNotFound");

        uint256 required = IVotes(govToken).getPastTotalSupply(proposal.snapshotBlock) * quorumBps / 10000;
        return proposal.forVotes + proposal.againstVotes >= required;
    }

    /// @notice Returns the minimum total votes required to satisfy quorum at the current moment.
    /// @dev Uses the current total supply, not a snapshot. For execution checks, the snapshot-based
    ///      calculation in execute() and state() is authoritative.
    /// @return Minimum votes required for quorum based on current supply.
    function quorumVotes() public view returns (uint256) {
        return IERC20(govToken).totalSupply() * quorumBps / 10000;
    }

    /// @notice Updates the voting period. Only executable via an approved proposal (msg.sender == address(this)).
    /// @param newPeriod New voting window duration in seconds. Must be > 0.
    function setVotingPeriod(uint256 newPeriod) external {
        require(msg.sender == address(this), "OnlyDAO");
        require(newPeriod > 0, "ZeroVotingPeriod");

        uint256 oldPeriod = votingPeriod;
        votingPeriod = newPeriod;

        emit ParameterUpdated("votingPeriod", oldPeriod, newPeriod);
    }

    /// @notice Updates the timelock delay. Only executable via an approved proposal.
    /// @param newDelay New delay between vote end and execution in seconds. Must be > 0.
    function setTimelockDelay(uint256 newDelay) external {
        require(msg.sender == address(this), "OnlyDAO");
        require(newDelay > 0, "ZeroTimelockDelay");

        uint256 oldTimeLockDelay = timelockDelay;
        timelockDelay = newDelay;

        emit ParameterUpdated("timelockDelay", oldTimeLockDelay, newDelay);
    }

    /// @notice Updates the quorum threshold. Only executable via an approved proposal.
    /// @param newQuorumBps New quorum fraction in basis points. Must be <= 10000.
    function setQuorumBps(uint256 newQuorumBps) external {
        require(msg.sender == address(this), "OnlyDAO");
        require(newQuorumBps <= 10000, "InvalidQuorum");

        uint256 oldQuorumBps = quorumBps;
        quorumBps = newQuorumBps;

        emit ParameterUpdated("quorumBps", oldQuorumBps, newQuorumBps);
    }

    /// @notice Updates the proposal threshold. Only executable via an approved proposal.
    /// @param newThreshold New minimum govToken balance (wei) required to create proposals.
    function setProposalThreshold(uint256 newThreshold) external {
        require(msg.sender == address(this), "OnlyDAO");

        uint256 oldProposalThreshold = proposalThreshold;
        proposalThreshold = newThreshold;

        emit ParameterUpdated("proposalThreshold", oldProposalThreshold, newThreshold);
    }

    /// @notice Allows the DAO to receive ETH needed for proposals that forward value to targets.
    receive() external payable {}
}
