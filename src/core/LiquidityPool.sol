// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import "../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "../../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "../../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @title LiquidityPool
/// @notice AMM liquidity pool for a TokenA/TokenB pair. The contract itself is the LP token.
/// @dev Implements a simplified x·y=k invariant. Charges a configurable swap fee; 80% stays
///      in the pool implicitly via the k formula, and 20% is transferred to DAOTreasury on every swap.
///      Uses accounting reserves (reserveA/reserveB) instead of balanceOf to prevent donation attacks.
contract LiquidityPool is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

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

    /// @notice Sets the DAO address that governs this pool's parameters. One-time only.
    /// @dev Can only be called by the owner once; reverts with "DAOAlreadySet" on subsequent calls.
    ///      Emits DAOSet.
    /// @param dao_ Address of the DAO contract. Cannot be address(0).
    function setDAO(address dao_) external onlyOwner {
        require(dao_ != address(0), "ZeroAddress");
        require(dao == address(0), "DAOAlreadySet");

        dao = dao_;

        emit DAOSet(dao_);
    }

    /// @notice Adds liquidity to the pool in exchange for LP tokens.
    /// @dev First deposit: both desired amounts are used as-is; MINIMUM_LIQUIDITY LP tokens are
    ///      permanently burned to address(1) to prevent the inflation attack; the remainder is
    ///      minted to `to`.
    ///      Subsequent deposits: the optimal tokenB amount is derived from the current A/B ratio
    ///      to preserve the invariant k; actual amounts used may be less than the desired ones.
    ///      LP minted = min(amountA / reserveA, amountB / reserveB) * totalSupply.
    ///      Slippage checks (amountAMin, amountBMin) must be performed against the final computed
    ///      amounts, not against the desired ones.
    ///      Follows CEI: reserves are updated before any tokens are transferred out.
    /// @param amountADesired Desired amount of tokenA to deposit. Must be > 0.
    /// @param amountBDesired Desired amount of tokenB to deposit. Must be > 0.
    /// @param amountAMin Minimum acceptable amount of tokenA actually used. Can be 0 (no slippage guard).
    /// @param amountBMin Minimum acceptable amount of tokenB actually used. Can be 0 (no slippage guard).
    /// @param to Recipient of the minted LP tokens. Cannot be address(0).
    /// @param deadline Unix timestamp after which the transaction reverts with "Expired".
    /// @return lpMinted Amount of LP tokens minted to `to`.
    function addLiquidity(uint256 amountADesired, uint256 amountBDesired, uint256 amountAMin, uint256 amountBMin, address to, uint256 deadline) external nonReentrant returns (uint256 lpMinted) {
        require(deadline >= block.timestamp, "Expired");
        require(amountADesired > 0, "ZeroAmount");
        require(amountBDesired > 0, "ZeroAmount");
        require(to != address(0), "ZeroAddress");

        (uint256 amountA, uint256 amountB) = _computeOptimalAmounts(amountADesired, amountBDesired);
        require(amountA >= amountAMin, "SlippageExceeded");
        require(amountB >= amountBMin, "SlippageExceeded");

        lpMinted = _applyLiquidity(amountA, amountB, to);

        IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, address(this), amountB);

        emit LiquidityAdded(msg.sender, amountA, amountB, lpMinted);
    }

    /// @notice Burns LP tokens in exchange for a proportional share of the pool's reserves.
    /// @dev amountA = lpAmount * reserveA / totalSupply; analogous for tokenB.
    ///      Reverts if either returned amount falls below the respective minimum (slippage guard).
    ///      Burns LP, updates reserves, then transfers tokens out (CEI).
    /// @param lpAmount Amount of LP tokens to burn. Must be greater than zero.
    /// @param amountAMin Minimum amount of tokenA to receive (slippage guard).
    /// @param amountBMin Minimum amount of tokenB to receive (slippage guard).
    /// @param to Recipient of the withdrawn tokens.
    /// @param deadline Unix timestamp after which the transaction reverts with "Expired".
    /// @return amountA Amount of tokenA transferred to `to`.
    /// @return amountB Amount of tokenB transferred to `to`.
    function removeLiquidity(uint256 lpAmount, uint256 amountAMin, uint256 amountBMin, address to, uint256 deadline) external nonReentrant returns (uint256 amountA, uint256 amountB) {
        require(deadline >= block.timestamp, "Expired");
        require(lpAmount > 0, "ZeroAmount");
        require(to != address(0), "ZeroAddress");

        uint256 supply = totalSupply();
        amountA = (lpAmount * reserveA) / supply;
        amountB = (lpAmount * reserveB) / supply;

        require(amountA >= amountAMin, "SlippageExceeded");
        require(amountB >= amountBMin, "SlippageExceeded");
        require(amountA > 0 && amountB > 0, "InsufficientOutputAmount");

        _burn(msg.sender, lpAmount);
        reserveA -= amountA;
        reserveB -= amountB;

        IERC20(tokenA).safeTransfer(to, amountA);
        IERC20(tokenB).safeTransfer(to, amountB);

        emit LiquidityRemoved(msg.sender, amountA, amountB, lpAmount);
    }

    /// @notice Swaps an exact amount of one pool token for the other using the x·y=k formula.
    /// @dev Fee split: feeAmount = amountIn * feeBps / FEE_DENOMINATOR.
    ///      treasuryFee = feeAmount * TREASURY_FEE_SHARE / 100 → sent to treasury.
    ///      Remaining fee (feeAmount - treasuryFee) stays in the pool, accruing to LPs.
    ///      amountOut = reserveOut * amountInNet / (reserveIn + amountInNet)
    ///        where amountInNet = amountIn - feeAmount.
    ///      CEI: reserves are updated BEFORE any token transfers.
    /// @param tokenIn Address of the token being sold. Must be tokenA or tokenB.
    /// @param amountIn Exact amount of tokenIn to sell. Must be greater than zero.
    /// @param minAmountOut Minimum amount of the output token to receive (slippage guard).
    /// @param to Recipient of the output token.
    /// @param deadline Unix timestamp after which the transaction reverts with "Expired".
    /// @return amountOut Amount of the output token sent to `to`.
    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut, address to, uint256 deadline) external nonReentrant returns (uint256 amountOut) {
        require(deadline >= block.timestamp, "Expired");
        require(amountIn > 0, "ZeroAmount");
        require(to != address(0), "ZeroAddress");
        require(tokenIn == tokenA || tokenIn == tokenB, "InvalidToken");

        bool isTokenA = tokenIn == tokenA;
        (uint256 reserveIn, uint256 reserveOut) = isTokenA ? (reserveA, reserveB) : (reserveB, reserveA);
        require(reserveIn > 0 && reserveOut > 0, "ZeroReserve");

        uint256 feeAmount = (amountIn * feeBps) / FEE_DENOMINATOR;
        uint256 treasuryFee = (feeAmount * TREASURY_FEE_SHARE) / 100;
        uint256 amountInNet = amountIn - feeAmount;

        amountOut = (reserveOut * amountInNet) / (reserveIn + amountInNet);
        require(amountOut > 0, "InsufficientOutputAmount");
        require(amountOut >= minAmountOut, "SlippageExceeded");

        if (isTokenA) {
            reserveA = reserveA + amountIn - treasuryFee;
            reserveB = reserveB - amountOut;
        } else {
            reserveB = reserveB + amountIn - treasuryFee;
            reserveA = reserveA - amountOut;
        }

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        if (treasuryFee > 0) {
            IERC20(tokenIn).safeTransfer(treasury, treasuryFee);
        }
        IERC20(isTokenA ? tokenB : tokenA).safeTransfer(to, amountOut);

        emit Swap(msg.sender, tokenIn, amountIn, amountOut, feeAmount);
    }

    /// @notice Returns the instantaneous spot price of tokenIn in terms of the other token, scaled 1e18.
    /// @dev Formula: reserveOut * 1e18 / reserveIn.
    ///      NOT suitable as a price oracle; manipulable via flash loans. Use a TWAP for any
    ///      integration that needs a reliable reference price.
    ///      Reverts with "ZeroReserve" if either reserve is zero.
    /// @param tokenIn Token whose price is requested. Must be tokenA or tokenB.
    /// @return price Spot price with 18-decimal precision.
    function getSpotPrice(address tokenIn) external view returns (uint256 price) {
        require(tokenIn == tokenA || tokenIn == tokenB, "InvalidToken");
        require(reserveA > 0 && reserveB > 0, "ZeroReserve");

        price = tokenIn == tokenA ? (reserveB * 1e18) / reserveA : (reserveA * 1e18) / reserveB;
    }

    /// @notice Updates the swap fee. Only callable by the DAO via an approved proposal.
    /// @dev require(msg.sender == dao, "OnlyDAO"). Valid range: 1–1000 bps. Emits FeeUpdated.
    /// @param newFeeBps New swap fee in basis points.
    function setFeeBps(uint256 newFeeBps) external {
        require(msg.sender == dao, "OnlyDAO");
        require(newFeeBps >= 1 && newFeeBps <= 1000, "InvalidFee");
        require(newFeeBps != feeBps, "Fee is the same");

        uint256 oldFeeBps = feeBps;
        feeBps = newFeeBps;

        emit FeeUpdated(oldFeeBps, newFeeBps);
    }

    /// @notice Returns the current accounting reserves for both tokens.
    /// @return _reserveA Current reserve of tokenA.
    /// @return _reserveB Current reserve of tokenB.
    function getReserves() external view returns (uint256 _reserveA, uint256 _reserveB) {
        _reserveA = reserveA;
        _reserveB = reserveB;
    }

    /// @dev Computes the optimal deposit amounts to preserve the x·y=k invariant.
    ///      On first deposit returns the desired amounts unchanged.
    ///      On subsequent deposits adjusts the smaller side to match the current ratio.
    function _computeOptimalAmounts(uint256 amountADesired, uint256 amountBDesired) private view returns (uint256 amountA, uint256 amountB) {
        if (totalSupply() == 0) {
            return (amountADesired, amountBDesired);
        }
        uint256 amountBOptimal = (amountADesired * reserveB) / reserveA;
        if (amountBOptimal <= amountBDesired) {
            return (amountADesired, amountBOptimal);
        }
        return ((amountBDesired * reserveA) / reserveB, amountBDesired);
    }

    /// @dev Mints LP tokens for a deposit. Updates reserves before minting (CEI).
    ///      On first deposit permanently locks MINIMUM_LIQUIDITY to address(1) to prevent
    ///      the LP inflation attack.
    function _applyLiquidity(uint256 amountA, uint256 amountB, address to) private returns (uint256 lpMinted) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            uint256 liquidity = Math.sqrt(amountA * amountB);
            require(liquidity > MINIMUM_LIQUIDITY, "InsufficientInitialLiquidity");
            lpMinted = liquidity - MINIMUM_LIQUIDITY;
            _mint(address(1), MINIMUM_LIQUIDITY);
        } else {
            uint256 lpA = (amountA * supply) / reserveA;
            uint256 lpB = (amountB * supply) / reserveB;
            lpMinted = lpA < lpB ? lpA : lpB;
        }
        require(lpMinted > 0, "InsufficientInitialLiquidity");
        reserveA += amountA;
        reserveB += amountB;
        _mint(to, lpMinted);
    }
}
