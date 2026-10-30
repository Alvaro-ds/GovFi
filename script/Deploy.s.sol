// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Script.sol";

import "../src/tokens/GovernanceToken.sol";
import "../src/core/LiquidityPool.sol";
import "../src/core/YieldFarmingPool.sol";
import "../src/dao/DAO.sol";
import "../src/dao/DAOTreasury.sol";

/// @title Deploy
/// @notice Deploys the full GovFi protocol and wires every contract together.
///         Prerequisites before running:
///           1. Set DEPLOYER_PRIVATE_KEY in the environment.
///           2. Edit tokenA_ / tokenB_ below for the target chain.
///           3. Confirm all governance parameters (votingPeriod_, etc.).
///         Post-deploy manual steps (cannot be done in the script):
///           a. Transfer DAO ownership to multisig:
///              dao.transferOwnership(MULTISIG) → multisig calls dao.acceptOwnership().
///           b. Transfer govToken DEFAULT_ADMIN_ROLE to multisig:
///              govToken.grantRole(DEFAULT_ADMIN_ROLE, MULTISIG)
///              govToken.revokeRole(DEFAULT_ADMIN_ROLE, deployer)
contract Deploy is Script {
    function run() external returns (GovernanceToken govToken, LiquidityPool pool, YieldFarmingPool yieldPool, DAO dao, DAOTreasury treasury) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer_ = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // ── Token pair (edit per chain) ────────────────────────────────────────
        address tokenA_ = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC en Arbitrum
        address tokenB_ = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH en Arbitrum

        // ── GovernanceToken ───────────────────────────────────────────────────
        uint256 govCap_ = 10000000e18; // 10 M GOV total supply cap
        string memory govName_ = "GovFi";
        string memory govSymbol_ = "GOV";

        // ── DAO governance params ─────────────────────────────────────────────
        uint256 votingPeriod_ = 259200; // 3 days in seconds
        uint256 timelockDelay_ = 86400; // 1 day in seconds
        uint256 quorumBps_ = 400; // 4 % of total supply
        uint256 proposalThreshold_ = 1000e18; // 1 000 GOV to submit a proposal

        // ── YieldFarmingPool reward emission ──────────────────────────────────
        // 10 M GOV distributed over ~1 year  →  10000000e18 / 31536000 ≈ 317097919837645865 wei/s
        uint256 initialRewardRate_ = 317097919837645865;

        // ── Deploy (order matters — each contract needs the previous addresses) ─
        govToken = new GovernanceToken(govCap_, govName_, govSymbol_, deployer_);
        treasury = new DAOTreasury(address(0));
        pool = new LiquidityPool(tokenA_, tokenB_, address(treasury), deployer_);
        yieldPool = new YieldFarmingPool(address(pool), address(govToken), initialRewardRate_, deployer_);
        dao = new DAO(address(govToken), address(treasury), votingPeriod_, timelockDelay_, quorumBps_, proposalThreshold_, deployer_);

        // ── Wiring ────────────────────────────────────────────────────────────
        // Grant yieldPool the sole minting right; revoke the deployer's minter role.
        govToken.grantMinterRole(address(yieldPool));
        govToken.revokeMinterRole(deployer_);

        // Hand each contract's governance knobs to the DAO.
        // treasury.setDAO also transfers treasury ownership to the DAO (Ownable2Step bypass).
        treasury.setDAO(address(dao));
        pool.setDAO(address(dao));
        yieldPool.setDAO(address(dao));

        // Transfer remaining owner roles to the DAO so no EOA can call onlyOwner after deploy.
        pool.transferOwnership(address(dao));
        yieldPool.transferOwnership(address(dao));
        // govToken DEFAULT_ADMIN_ROLE and DAO ownership must be transferred to a multisig
        // via the manual post-deploy steps described in the contract NatSpec above.

        vm.stopBroadcast();
    }
}
