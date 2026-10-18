// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @title DAO
/// @notice Custom governance contract managing the full proposal lifecycle:
///         creation → voting → timelock → execution of arbitrary on-chain calls.
/// @dev Intentionally does not extend OZ Governor to stay self-contained and auditable.
///      Flash-loan governance attack is mitigated by reading voting power from ERC20Votes
///      snapshots at proposal.snapshotBlock (block N-1 relative to proposal creation).
contract DAO is Ownable, ReentrancyGuard {
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
        /// @dev Block number used to snapshot voting power (set to block.number at proposal creation).
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
    /// @param votingPeriod_ Voting window in seconds.
    /// @param timelockDelay_ Delay between vote end and execution in seconds.
    /// @param quorumBps_ Quorum as fraction of total supply in bps. Must be <= 10000.
    /// @param proposalThreshold_ Minimum govToken balance (wei) required to submit proposals.
    /// @param initialOwner Address that will own the contract after deployment.
    constructor(address govToken_, address treasury_, uint256 votingPeriod_, uint256 timelockDelay_, uint256 quorumBps_, uint256 proposalThreshold_, address initialOwner) Ownable(initialOwner) {
        require(govToken_ != address(0), "ZeroAddress");
        require(treasury_ != address(0), "ZeroAddress");
        require(quorumBps_ <= 10000, "InvalidQuorum");
        govToken = govToken_;
        treasury = treasury_;
        votingPeriod = votingPeriod_;
        timelockDelay = timelockDelay_;
        quorumBps = quorumBps_;
        proposalThreshold = proposalThreshold_;
    }

    /// @notice Creates a new governance proposal.
    /// @dev Caller must hold at least proposalThreshold voting power at block.number - 1
    ///      (getPastVotes). snapshotBlock = block.number so the snapshot is already final
    ///      when the first vote is cast. executionTime = endTime + timelockDelay.
    ///      Limit the targets array to a reasonable maximum (e.g. 10) to prevent unbounded
    ///      gas cost in execute().
    /// @param targets Contracts to call if the proposal passes. Must not be empty.
    /// @param values ETH amounts (wei) to forward with each call. Length must match targets.
    /// @param calldatas ABI-encoded calls. Length must match targets.
    /// @param description Human-readable proposal description stored on-chain.
    /// @return proposalId Monotonically increasing identifier of the new proposal.
    function propose(address[] calldata targets, uint256[] calldata values, bytes[] calldata calldatas, string calldata description) external returns (uint256 proposalId) {}

    /// @notice Casts a vote for or against an active proposal.
    /// @dev Weight = govToken.getPastVotes(msg.sender, proposal.snapshotBlock).
    ///      Each address may vote at most once per proposal (hasVoted guard).
    ///      Reverts with "NoVotingPower" if the snapshot weight is zero.
    /// @param proposalId Proposal to vote on. Must currently be in Active state.
    /// @param support True to vote in favor; false to vote against.
    function castVote(uint256 proposalId, bool support) external {}

    /// @notice Executes the calls of a passed proposal once the timelock has elapsed.
    /// @dev CEI: proposal.executed = true is set BEFORE any external call to prevent reentrancy.
    ///      Each action: (bool ok,) = targets[i].call{value: values[i]}(calldatas[i]); require(ok, "ExecutionFailed").
    ///      If any call reverts the whole transaction reverts; proposal remains marked executed.
    /// @param proposalId Proposal to execute. Must be in Succeeded state and past executionTime.
    function execute(uint256 proposalId) external nonReentrant {}

    /// @notice Cancels a proposal. Only the original proposer or the DAO itself may cancel.
    /// @dev Cannot cancel a proposal that has already been executed.
    ///      Sets canceled = true; proposal permanently transitions to Canceled state.
    /// @param proposalId Proposal to cancel.
    function cancel(uint256 proposalId) external {}

    /// @notice Returns the current lifecycle state of a proposal.
    /// @dev State machine:
    ///      Pending  → Active (startTime reached, not canceled)
    ///      Active   → Defeated | Succeeded (endTime reached)
    ///      Succeeded→ Queued (before executionTime) or directly executable (after executionTime)
    ///      Any state → Canceled (if canceled flag is set)
    /// @param proposalId Proposal to query. Reverts with "ProposalNotFound" if it does not exist.
    /// @return currentState Current ProposalState enum value.
    function state(uint256 proposalId) external view returns (ProposalState currentState) {}

    /// @notice Returns whether quorum has been reached for a proposal.
    /// @dev Condition: forVotes + againstVotes >= quorumVotes().
    /// @param proposalId Proposal to check.
    /// @return reached True if quorum is satisfied.
    function quorumReached(uint256 proposalId) public view returns (bool reached) {}

    /// @notice Returns the minimum total votes (for + against) required to satisfy quorum.
    /// @dev Calculated as govToken.totalSupply() * quorumBps / 10000 at call time.
    /// @return votes Minimum votes required for quorum.
    function quorumVotes() public view returns (uint256 votes) {}

    /// @notice Updates the voting period. Only executable via an approved proposal (msg.sender == address(this)).
    /// @dev require(msg.sender == address(this), "OnlyDAO")
    /// @param newPeriod New voting window duration in seconds.
    function setVotingPeriod(uint256 newPeriod) external {}

    /// @notice Updates the timelock delay. Only executable via an approved proposal.
    /// @dev require(msg.sender == address(this), "OnlyDAO")
    /// @param newDelay New delay between vote end and execution in seconds.
    function setTimelockDelay(uint256 newDelay) external {}

    /// @notice Updates the quorum threshold. Only executable via an approved proposal.
    /// @dev require(msg.sender == address(this), "OnlyDAO"); newQuorumBps must be <= 10000.
    /// @param newQuorumBps New quorum fraction in basis points.
    function setQuorumBps(uint256 newQuorumBps) external {}

    /// @notice Updates the proposal threshold. Only executable via an approved proposal.
    /// @dev require(msg.sender == address(this), "OnlyDAO")
    /// @param newThreshold New minimum govToken balance (wei) required to create proposals.
    function setProposalThreshold(uint256 newThreshold) external {}
}
