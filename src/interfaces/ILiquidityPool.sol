// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @title ILiquidityPool
/// @notice Interface for the GovFi AMM liquidity pool, used by other protocol contracts.
/// @dev Does not include administrative functions (setFeeBps, setDAO).
interface ILiquidityPool {
    /// @notice Adds liquidity to the pool and mints LP tokens to `to`.
    /// @param amountADesired Desired amount of tokenA to deposit.
    /// @param amountBDesired Desired amount of tokenB to deposit.
    /// @param amountAMin Minimum acceptable amount of tokenA (slippage guard).
    /// @param amountBMin Minimum acceptable amount of tokenB (slippage guard).
    /// @param to Recipient of the minted LP tokens.
    /// @param deadline Unix timestamp after which the transaction reverts.
    /// @return lpMinted Amount of LP tokens minted to `to`.
    function addLiquidity(uint256 amountADesired, uint256 amountBDesired, uint256 amountAMin, uint256 amountBMin, address to, uint256 deadline) external returns (uint256 lpMinted);

    /// @notice Burns LP tokens and returns the underlying tokens proportionally to `to`.
    /// @param lpAmount Amount of LP tokens to burn.
    /// @param amountAMin Minimum amount of tokenA to receive (slippage guard).
    /// @param amountBMin Minimum amount of tokenB to receive (slippage guard).
    /// @param to Recipient of the withdrawn tokens.
    /// @param deadline Unix timestamp after which the transaction reverts.
    /// @return amountA Amount of tokenA returned to `to`.
    /// @return amountB Amount of tokenB returned to `to`.
    function removeLiquidity(uint256 lpAmount, uint256 amountAMin, uint256 amountBMin, address to, uint256 deadline) external returns (uint256 amountA, uint256 amountB);

    /// @notice Swaps an exact amount of one pool token for the other using x·y=k.
    /// @param tokenIn Address of the token being sold (must be tokenA or tokenB).
    /// @param amountIn Exact amount of tokenIn to sell.
    /// @param minAmountOut Minimum output amount (slippage guard).
    /// @param to Recipient of the output token.
    /// @param deadline Unix timestamp after which the transaction reverts.
    /// @return amountOut Amount of the output token sent to `to`.
    function swap(address tokenIn, uint256 amountIn, uint256 minAmountOut, address to, uint256 deadline) external returns (uint256 amountOut);

    /// @notice Returns the current accounting reserves for both tokens.
    /// @return reserveA Current reserve of tokenA.
    /// @return reserveB Current reserve of tokenB.
    function getReserves() external view returns (uint256 reserveA, uint256 reserveB);

    /// @notice Returns the instantaneous spot price of tokenIn in terms of the other token, scaled 1e18.
    /// @dev Not suitable as a price oracle; manipulable via flash loans.
    /// @param tokenIn Token whose price is requested.
    /// @return price Spot price with 18-decimal precision.
    function getSpotPrice(address tokenIn) external view returns (uint256 price);

    /// @notice Current swap fee in basis points.
    function feeBps() external view returns (uint256);

    /// @notice Address of token A in the pair.
    function tokenA() external view returns (address);

    /// @notice Address of token B in the pair.
    function tokenB() external view returns (address);
}
