// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../tokens/GovernanceToken.sol";

/// @title YieldFarmingPool
/// @notice LP token staking pool that distributes GovernanceToken rewards to stakers.
/// @dev Uses the accumulated reward-per-token pattern (Synthetix/MasterChef style) for O(1)
///      per-user accounting regardless of staker count. The DAO governs the emission rate.
///      Critical invariant: _updateReward MUST be called before any change to balances or totalStaked.
contract YieldFarmingPool is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /// @notice LP token that users stake into this contract.
    address public immutable lpToken;

    /// @notice GovernanceToken minted or distributed as reward to stakers.
    address public immutable govToken;

    /// @notice DAO address; the only account that may call setRewardRate.
    address public dao;

    /// @notice Reward tokens emitted per second across all stakers, in govToken wei.
    uint256 public rewardRate;

    /// @notice Global accumulated reward per staked LP token, scaled 1e18. Grows monotonically.
    uint256 public rewardPerTokenStored;

    /// @notice Unix timestamp of the last global accumulator update.
    uint256 public lastUpdateTime;

    /// @notice Total LP tokens currently staked across all users.
    uint256 public totalStaked;

    /// @notice Staked LP balance per user address.
    mapping(address => uint256) public balances;

    /// @notice Checkpoint of rewardPerTokenStored at the last time each user's rewards were synced.
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice Accumulated but unclaimed reward tokens per user.
    mapping(address => uint256) public rewards;

    /// @notice Emitted when a user stakes LP tokens.
    /// @param user Address of the staker.
    /// @param amount Amount of LP tokens staked.
    event Staked(address indexed user, uint256 amount);

    /// @notice Emitted when a user withdraws staked LP tokens.
    /// @param user Address of the staker.
    /// @param amount Amount of LP tokens withdrawn.
    event Unstaked(address indexed user, uint256 amount);

    /// @notice Emitted when a user claims their accrued GovernanceToken rewards.
    /// @param user Address of the claimer.
    /// @param reward Amount of GovernanceToken transferred.
    event RewardHarvested(address indexed user, uint256 reward);

    /// @notice Emitted when the DAO updates the reward emission rate.
    /// @param oldRate Previous emission rate in govToken wei per second.
    /// @param newRate New emission rate in govToken wei per second.
    event RewardRateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Emitted when the DAO address is configured.
    /// @param dao Address of the DAO contract.
    event DAOSet(address indexed dao);

    /// @notice Deploys the pool and sets immutable token references.
    /// @param lpToken_ LP token stakers will deposit. Cannot be address(0).
    /// @param govToken_ GovernanceToken minted as reward. Cannot be address(0).
    /// @param initialRewardRate Initial emission rate in govToken wei per second.
    /// @param initialOwner Address that will own the contract after deployment.
    constructor(address lpToken_, address govToken_, uint256 initialRewardRate, address initialOwner) Ownable(initialOwner) {
        require(lpToken_ != address(0), "ZeroAddress");
        require(govToken_ != address(0), "ZeroAddress");
        require(initialOwner != address(0), "ZeroAddress");
        require(initialRewardRate > 0, "ZeroRate");
        lpToken = lpToken_;
        govToken = govToken_;
        rewardRate = initialRewardRate;
        lastUpdateTime = block.timestamp;
    }

    /// @notice Sets the DAO address that governs this pool's reward rate.
    /// @dev Callable once by the owner during ecosystem setup. Emits DAOSet.
    /// @param dao_ Address of the DAO contract. Cannot be address(0).
    function setDAO(address dao_) external onlyOwner {
        require(dao_ != address(0), "ZeroAddress");
        require(dao == address(0), "DAOAlreadySet");

        dao = dao_;

        emit DAOSet(dao_);
    }

    /// @notice Stakes `amount` LP tokens and begins accruing GovernanceToken rewards.
    /// @dev Operation order (invariant — must not change):
    ///      1. require(amount > 0)
    ///      2. _updateReward(msg.sender)   — sync accumulator BEFORE modifying balances
    ///      3. balances[msg.sender] += amount
    ///      4. totalStaked += amount
    ///      5. IERC20(lpToken).safeTransferFrom(msg.sender, address(this), amount)
    ///      6. emit Staked
    /// @param amount Amount of LP tokens to stake. Must be greater than zero.
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "ZeroAmount");

        _updateReward(msg.sender);

        balances[msg.sender] += amount;
        totalStaked += amount;

        IERC20(lpToken).safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    /// @notice Withdraws `amount` staked LP tokens back to the caller.
    /// @dev Operation order (invariant — must not change):
    ///      1. require(amount > 0) and require(balances[msg.sender] >= amount)
    ///      2. _updateReward(msg.sender)
    ///      3. balances[msg.sender] -= amount
    ///      4. totalStaked -= amount
    ///      5. IERC20(lpToken).safeTransfer(msg.sender, amount)
    ///      6. emit Unstaked
    ///      Does NOT harvest rewards; call harvest() separately or use exit().
    /// @param amount Amount of LP tokens to withdraw. Must not exceed balances[msg.sender].
    function unstake(uint256 amount) external nonReentrant {
        require(amount > 0, "ZeroAmount");
        require(balances[msg.sender] >= amount, "InsufficientStake");

        _updateReward(msg.sender);

        balances[msg.sender] -= amount;
        totalStaked -= amount;

        IERC20(lpToken).safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    /// @notice Claims all pending GovernanceToken rewards for the caller.
    /// @dev CEI: rewards[msg.sender] is zeroed BEFORE the external mint call to prevent
    ///      reentrancy-based double-claim. Reverts with "NoRewards" if pending balance is zero.
    ///      The minted amount is capped by the GovernanceToken supply cap (see _safeRewardTransfer).
    function harvest() external nonReentrant {
        _updateReward(msg.sender);
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "NoRewards");

        rewards[msg.sender] = 0;

        uint256 paid = _safeRewardTransfer(msg.sender, reward);

        emit RewardHarvested(msg.sender, paid);
    }

    /// @notice Withdraws all staked LP tokens and claims all pending rewards in one transaction.
    /// @dev Internally reuses unstake + harvest logic without redundant external calls.
    ///      Equivalent to unstake(balances[msg.sender]) followed by harvest().
    function exit() external nonReentrant {
        require(balances[msg.sender] > 0, "ZeroLPToken");
        _updateReward(msg.sender);

        uint256 userBalance = balances[msg.sender];
        uint256 userRewards = rewards[msg.sender];

        balances[msg.sender] = 0;
        rewards[msg.sender] = 0;
        totalStaked -= userBalance;

        IERC20(lpToken).safeTransfer(msg.sender, userBalance);

        if (userRewards > 0) {
            uint256 paid = _safeRewardTransfer(msg.sender, userRewards);
            emit RewardHarvested(msg.sender, paid);
        }

        emit Unstaked(msg.sender, userBalance);
    }

    /// @notice Returns the total pending rewards (accrued + uncheckpointed) for a user.
    /// @dev Formula: rewards[user] + balances[user] * (rewardPerToken() - userRewardPerTokenPaid[user]) / 1e18.
    ///      Pure view; does not modify state.
    /// @param user Address of the staker to query.
    /// @return pending Total reward tokens owed to `user` in govToken wei.
    function earned(address user) public view returns (uint256 pending) {
        pending = rewards[user] + balances[user] * (rewardPerToken() - userRewardPerTokenPaid[user]) / 1e18;
        return pending;
    }

    /// @notice Returns the current accumulated reward per staked LP token, scaled 1e18.
    /// @dev Returns rewardPerTokenStored unchanged when totalStaked == 0 to avoid division by zero.
    ///      Formula (when totalStaked > 0):
    ///      rewardPerTokenStored + (block.timestamp - lastUpdateTime) * rewardRate * 1e18 / totalStaked
    /// @return rpt Current reward-per-token accumulator value.
    function rewardPerToken() public view returns (uint256 rpt) {
        if (totalStaked == 0) return rewardPerTokenStored;

        rpt = rewardPerTokenStored + (block.timestamp - lastUpdateTime) * rewardRate * 1e18 / totalStaked;
        return rpt;
    }

    /// @notice Updates the reward emission rate. Only callable by the DAO.
    /// @dev MUST call _updateReward(address(0)) first to checkpoint the accumulator at the old
    ///      rate before switching; otherwise the new rate would be applied retroactively.
    /// @param newRate New emission rate in govToken wei per second. May be zero to pause emissions.
    function setRewardRate(uint256 newRate) external {
        require(msg.sender == dao, "OnlyDAO");
        require(newRate != rewardRate, "Same reward rate");

        _updateReward(address(0));
        uint256 oldRate = rewardRate;
        rewardRate = newRate;

        emit RewardRateUpdated(oldRate, newRate);
    }

    /// @dev Checkpoints the global accumulator and, if user != address(0), syncs the user's rewards.
    ///      Must be called before any modification to balances or totalStaked. Steps:
    ///      1. rewardPerTokenStored = rewardPerToken()
    ///      2. lastUpdateTime = block.timestamp
    ///      3. if user != address(0): rewards[user] = earned(user); userRewardPerTokenPaid[user] = rewardPerTokenStored
    /// @param user Address whose rewards to sync, or address(0) to update only global state.
    function _updateReward(address user) internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;

        if (user != address(0)) {
            rewards[user] = earned(user);
            userRewardPerTokenPaid[user] = rewardPerTokenStored;
        }
    }

    /// @dev Mints `amount` govToken to `to`, capped at the GovernanceToken's remaining mintable supply
    ///      (maxSupply - totalSupply) so harvest() and exit() never revert once the cap is reached.
    ///      Skips the mint entirely if the capped amount is zero. Callers must zero the user's
    ///      rewards before calling (CEI); any amount above the cap is forfeited.
    ///      Requires this contract to hold MINTER_ROLE on the GovernanceToken.
    /// @param to Recipient of the reward tokens.
    /// @param amount Desired mint amount; capped to the remaining supply if insufficient.
    /// @return paid Amount of govToken actually minted to `to`.
    function _safeRewardTransfer(address to, uint256 amount) internal returns (uint256 paid) {
        GovernanceToken token = GovernanceToken(govToken);
        uint256 available = token.maxSupply() - token.totalSupply();
        paid = amount > available ? available : amount;

        if (paid > 0) token.mint(to, paid); 
    }
}
