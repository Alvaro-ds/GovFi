// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IDAO
/// @notice Interface for the GovFi governance contract, used by treasury and off-chain tooling.
interface IDAO {
    /// @notice Creates a new governance proposal.
    /// @param targets Contracts to call if the proposal passes.
    /// @param values ETH amounts (wei) to send with each call.
    /// @param calldatas ABI-encoded function calls.
    /// @param description Human-readable proposal description.
    /// @return proposalId Unique identifier of the new proposal.
    function propose(address[] calldata targets, uint256[] calldata values, bytes[] calldata calldatas, string calldata description) external returns (uint256 proposalId);

    /// @notice Casts a vote on an active proposal.
    /// @param proposalId Proposal to vote on.
    /// @param support True to vote in favor; false to vote against.
    function castVote(uint256 proposalId, bool support) external;

    /// @notice Executes a passed proposal after the timelock has elapsed.
    /// @param proposalId Proposal to execute.
    function execute(uint256 proposalId) external;

    /// @notice Cancels a proposal. Only the proposer or the DAO itself may cancel.
    /// @param proposalId Proposal to cancel.
    function cancel(uint256 proposalId) external;

    /// @notice Returns the current lifecycle state of a proposal encoded as uint8.
    /// @dev 0=Pending, 1=Active, 2=Defeated, 3=Succeeded, 4=Queued, 5=Executed, 6=Canceled.
    /// @param proposalId Proposal to query.
    /// @return Encoded ProposalState value.
    function state(uint256 proposalId) external view returns (uint8);

    /// @notice Returns the minimum total votes required to satisfy quorum.
    function quorumVotes() external view returns (uint256);

    /// @notice Total proposals ever created; also the ID for the next proposal.
    function proposalCount() external view returns (uint256);

    /// @notice Duration of the voting window in seconds.
    function votingPeriod() external view returns (uint256);

    /// @notice Delay between vote end and earliest execution, in seconds.
    function timelockDelay() external view returns (uint256);
}
