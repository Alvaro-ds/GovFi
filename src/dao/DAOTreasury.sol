// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "../../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DAOTreasury
/// @notice Custodian of protocol fees (ETH and ERC20 tokens). Only the DAO may initiate withdrawals.
/// @dev Separation of concerns: the DAO decides, the Treasury executes.
///      Bootstrap sequence: deploy with address(0), then call setDAO after the DAO is deployed.
///      setDAO transfers ownership to the DAO so it self-governs post-setup.
contract DAOTreasury is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Address of the DAO authorized to initiate all treasury withdrawals.
    address public dao;

    /// @notice Emitted whenever the contract receives ETH.
    /// @param sender Address that sent the ETH.
    /// @param amount Amount received in wei.
    event ETHReceived(address indexed sender, uint256 amount);

    /// @notice Emitted on every withdrawal action, whether ETH or ERC20.
    /// @param token address(0) for ETH withdrawals; the ERC20 contract address otherwise.
    /// @param to Recipient of the transferred funds.
    /// @param amount Amount transferred.
    /// @param reason Human-readable reason for the disbursement, stored permanently on-chain.
    event TreasuryAction(address indexed token, address indexed to, uint256 amount, string reason);

    /// @notice Emitted when the DAO address is set or replaced.
    /// @param oldDAO Previous DAO address (address(0) on first set).
    /// @param newDAO New DAO address.
    event DAOSet(address indexed oldDAO, address indexed newDAO);

    /// @notice Deploys the treasury with an optional initial DAO address.
    /// @dev Passing address(0) is valid for the bootstrap sequence where the DAO contract
    ///      does not yet exist. Call setDAO immediately after deploying the DAO.
    /// @param initialDAO DAO address, or address(0) to configure later via setDAO.
    constructor(address initialDAO) Ownable(msg.sender) {
        if (initialDAO != address(0)) {
            dao = initialDAO;
            emit DAOSet(address(0), initialDAO);
        }
    }

    /// @notice Accepts incoming ETH (swap fees forwarded by LiquidityPool, protocol donations).
    /// @dev Emits ETHReceived so off-chain monitoring can track all incoming funds.
    receive() external payable {
        emit ETHReceived(msg.sender, msg.value);
    }

    /// @notice Sets the DAO that governs treasury withdrawals. Single-use: reverts if already set.
    /// @dev Only callable by the owner. Reverts if dao != address(0) to prevent silent replacement.
    ///      Immediately transfers contract ownership to the DAO so no external owner remains.
    /// @param newDAO New DAO contract address. Cannot be address(0).
    function setDAO(address newDAO) external onlyOwner {
        require(newDAO != address(0), "ZeroAddress");
        require(dao == address(0), "DAOAlreadySet");

        address oldDAO = dao;
        dao = newDAO;
        _transferOwnership(newDAO);

        emit DAOSet(oldDAO, newDAO);
    }

    /// @notice Transfers ETH from the treasury to `to`. Only callable by the DAO.
    /// @dev CEI + nonReentrant. Emits TreasuryAction after successful transfer.
    ///      Low-level call is used to support smart-contract recipients with custom receive() logic.
    /// @param to Recipient address. Cannot be address(0).
    /// @param amount ETH to transfer in wei. Must be > 0 and <= address(this).balance.
    /// @param reason Human-readable reason stored on-chain via TreasuryAction event.
    function withdrawETH(address to, uint256 amount, string calldata reason) external nonReentrant {
        require(msg.sender == dao, "OnlyDAO");
        require(to != address(0), "ZeroAddress");
        require(amount > 0, "ZeroAmount");
        require(address(this).balance >= amount, "InsufficientETH");
        require(bytes(reason).length > 0, "InvalidReason");

        (bool success,) = to.call{value: amount}("");
        require(success, "ETHTransferFailed");

        emit TreasuryAction(address(0), to, amount, reason);
    }

    /// @notice Transfers ERC20 tokens from the treasury to `to`. Only callable by the DAO.
    /// @dev Uses SafeERC20.safeTransfer to handle tokens that do not return a bool (e.g. USDT).
    ///      Verify IERC20(token).balanceOf(address(this)) >= amount before transferring.
    /// @param token ERC20 token contract. Cannot be address(0).
    /// @param to Recipient address. Cannot be address(0).
    /// @param amount Amount to transfer. Must be > 0 and <= the treasury's token balance.
    /// @param reason Human-readable reason stored on-chain via TreasuryAction event.
    function withdrawERC20(address token, address to, uint256 amount, string calldata reason) external nonReentrant {
        require(msg.sender == dao, "OnlyDAO");
        require(token != address(0), "ZeroAddress");
        require(to != address(0), "ZeroAddress");
        require(amount > 0, "ZeroAmount");
        require(IERC20(token).balanceOf(address(this)) >= amount, "InsufficientTokenBalance");
        require(bytes(reason).length > 0, "InvalidReason");

        IERC20(token).safeTransfer(to, amount);

        emit TreasuryAction(token, to, amount, reason);
    }

    /// @notice Returns the current ETH balance held by the treasury.
    /// @return balance ETH balance in wei.
    function getETHBalance() external view returns (uint256 balance) {
        balance = address(this).balance;
    }

    /// @notice Returns the treasury's balance of a given ERC20 token.
    /// @param token ERC20 token to query.
    /// @return balance Token balance in the token's smallest unit.
    function getTokenBalance(address token) external view returns (uint256 balance) {
        require(token != address(0), "ZeroAddress");
        balance = IERC20(token).balanceOf(address(this));
    }
}
