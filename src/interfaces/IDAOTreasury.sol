// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @title IDAOTreasury
/// @notice Interface for the GovFi treasury; used by the DAO when executing withdrawal proposals.
interface IDAOTreasury {
    /// @notice Transfers ETH from the treasury to `to`. Only callable by the DAO.
    /// @param to Recipient address.
    /// @param amount Amount of ETH in wei.
    /// @param reason Human-readable reason logged on-chain.
    function withdrawETH(address to, uint256 amount, string calldata reason) external;

    /// @notice Transfers ERC20 tokens from the treasury to `to`. Only callable by the DAO.
    /// @param token ERC20 token to transfer.
    /// @param to Recipient address.
    /// @param amount Amount of tokens.
    /// @param reason Human-readable reason logged on-chain.
    function withdrawERC20(address token, address to, uint256 amount, string calldata reason) external;

    /// @notice Returns the current ETH balance of the treasury.
    function getETHBalance() external view returns (uint256);

    /// @notice Returns the treasury's balance of a given ERC20 token.
    /// @param token ERC20 token to query.
    function getTokenBalance(address token) external view returns (uint256);

    /// @notice Sets or replaces the governing DAO address. Only callable by the owner.
    /// @param newDAO New DAO address.
    function setDAO(address newDAO) external;
}
