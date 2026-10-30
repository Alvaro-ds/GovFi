// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @title IYieldFarmingPool
/// @notice Interface for the GovFi LP staking pool that distributes GovernanceToken rewards.
interface IYieldFarmingPool {
    /// @notice Stakes `amount` LP tokens on behalf of the caller.
    /// @param amount Amount of LP tokens to stake. Must be greater than zero.
    function stake(uint256 amount) external;

    /// @notice Withdraws `amount` staked LP tokens back to the caller.
    /// @param amount Amount to withdraw. Must not exceed the caller's staked balance.
    function unstake(uint256 amount) external;

    /// @notice Claims all accrued GovernanceToken rewards for the caller.
    function harvest() external;

    /// @notice Unstakes all LP tokens and claims all pending rewards in one transaction.
    function exit() external;

    /// @notice Returns the total pending rewards (accrued + uncheckpointed) for a user.
    /// @param user Address of the staker to query.
    /// @return Total reward tokens owed to `user` in govToken wei.
    function earned(address user) external view returns (uint256);

    /// @notice Returns the current accumulated reward per staked LP token, scaled 1e18.
    function rewardPerToken() external view returns (uint256);

    /// @notice Current emission rate: GovernanceToken wei emitted per second across all stakers.
    function rewardRate() external view returns (uint256);

    /// @notice Total amount of LP tokens currently staked in the pool.
    function totalStaked() external view returns (uint256);

    /// @notice Returns the staked LP token balance of a user.
    /// @param user Address of the staker.
    /// @return Staked LP balance in LP token wei.
    function balances(address user) external view returns (uint256);

    /// @notice Updates the reward emission rate. Only callable by the DAO.
    /// @param newRate New emission rate in govToken wei per second.
    function setRewardRate(uint256 newRate) external;
}
