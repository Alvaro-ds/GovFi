// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/// @title LiquidityPool
/// @notice AMM liquidity pool for a TokenA/TokenB pair. The contract itself is the LP token.
/// @dev Implements a simplified x·y=k invariant. Charges a configurable swap fee; 80% stays
///      in the pool implicitly via the k formula, and 20% is transferred to DAOTreasury on every swap.
contract LiquidityPool is ERC20, Ownable, ReentrancyGuard {
    /// @notice Address of token A in the pair.
    address public immutable tokenA;

    /// @notice Address of token B in the pair.
    address public immutable tokenB;

    /// @notice Address of the DAOTreasury that receives 20% of every swap fee.
    address public treasury;

    /// @notice Address of the DAO; the only account allowed to change feeBps.
    address public dao;

    /// @notice Accounting reserve for tokenA. Used instead of balanceOf to prevent donation attacks.
    uint256 public reserveA;

    /// @notice Accounting reserve for tokenB. Used instead of balanceOf to prevent donation attacks.
    uint256 public reserveB;

    /// @notice Swap fee in basis points. Default: 30 (0.30%). Valid range: 1-1000.
    uint256 public feeBps;

    /// @notice Denominator for basis-point fee calculations.
    uint256 public constant FEE_DENOMINATOR = 10000;

    /// @notice Percentage of the swap fee forwarded to the treasury (20%).
    uint256 public constant TREASURY_FEE_SHARE = 20;

    /// @notice Minimum LP units permanently locked on the first deposit to prevent the inflation attack.
    uint256 private constant MINIMUM_LIQUIDITY = 1000;

    /// @notice Emitted when liquidity is added to the pool.
    /// @param provider Address that provided the liquidity.
    /// @param amountA Amount of tokenA deposited.
    /// @param amountB Amount of tokenB deposited.
    /// @param lpMinted LP tokens minted to the provider.
    event LiquidityAdded(address indexed provider, uint256 amountA, uint256 amountB, uint256 lpMinted);

    /// @notice Emitted when liquidity is removed from the pool.
    /// @param provider Address that removed the liquidity.
    /// @param amountA Amount of tokenA returned.
    /// @param amountB Amount of tokenB returned.
    /// @param lpBurned LP tokens burned from the provider.
    event LiquidityRemoved(address indexed provider, uint256 amountA, uint256 amountB, uint256 lpBurned);

    /// @notice Emitted on every swap.
    /// @param trader Address that initiated the swap.
    /// @param tokenIn Address of the token sent in.
    /// @param amountIn Amount of tokenIn sent.
    /// @param amountOut Amount of tokenOut received.
    /// @param feeAmount Total fee charged in tokenIn units.
    event Swap(address indexed trader, address indexed tokenIn, uint256 amountIn, uint256 amountOut, uint256 feeAmount);

    /// @notice Emitted when the swap fee is updated by the DAO.
    /// @param oldFeeBps Previous fee in basis points.
    /// @param newFeeBps New fee in basis points.
    event FeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    /// @notice Emitted when the treasury address is updated.
    /// @param oldTreasury Previous treasury address.
    /// @param newTreasury New treasury address.
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /// @notice Emitted when the DAO address is set for the first time.
    /// @param dao Address of the DAO contract.
    event DAOSet(address indexed dao);

    /// @notice Deploys the pool, sets the token pair, treasury, initial owner and default fee.
    /// @param tokenA_ Address of token A.
    /// @param tokenB_ Address of token B.
    /// @param treasury_ Address of the DAOTreasury.
    /// @param initialOwner Address that will own the contract after deployment.
    constructor(address tokenA_, address tokenB_, address treasury_, address initialOwner) Ownable(initialOwner) ERC20("GovFi LP Token", "GFI-LP") {
        require(tokenA_ != tokenB_, "SameToken");
        require(tokenA_ != address(0), "ZeroAddress");
        require(tokenB_ != address(0), "ZeroAddress");
        require(treasury_ != address(0), "ZeroAddress");
        require(initialOwner != address(0), "ZeroAddress");

        tokenA = tokenA_;
        tokenB = tokenB_;
        treasury = treasury_;
        feeBps = 30;
    }

    function setDAO(address dao_) external onlyOwner {
        require(dao_ != address(0), "ZeroAddress");

        dao = dao_;

        emit DAOSet(dao_);
    }
}
