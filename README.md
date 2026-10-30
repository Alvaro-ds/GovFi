# GovFi — DAO Governance & Yield Farming Protocol

A fully on-chain governance + yield farming system built with Solidity 0.8.33 and Foundry.
Covers the complete DeFi governance stack: liquidity provision, reward emission, on-chain proposals, timelock execution and treasury management.

## Architecture

```
GovernanceToken (GOV)
  └─ ERC20Votes + ERC20Permit + AccessControl
  └─ Minted exclusively by YieldFarmingPool

LiquidityPool (LP token = ERC20)
  └─ x·y=k AMM, 0.30% swap fee
  └─ 20% of fee → DAOTreasury, 80% stays in reserves

YieldFarmingPool
  └─ Stake LP tokens → earn GOV (Synthetix rewardPerToken model)
  └─ Reward rate configurable by DAO

DAO
  └─ Propose → Vote → Timelock → Execute arbitrary on-chain calls
  └─ Voting power from ERC20Votes snapshots (flash-loan resistant)

DAOTreasury
  └─ Custodian of protocol fees (ETH + ERC20)
  └─ Withdrawals only via approved DAO proposals
```

## Contracts

| Contract | Description |
|---|---|
| `src/tokens/GovernanceToken.sol` | ERC20Votes governance token with supply cap and MINTER_ROLE access control |
| `src/core/LiquidityPool.sol` | x·y=k AMM with fee splitting between reserves and treasury |
| `src/core/YieldFarmingPool.sol` | Synthetix-style staking pool that mints GOV rewards to LP stakers |
| `src/dao/DAO.sol` | On-chain governance: proposal lifecycle, voting, timelock, execution |
| `src/dao/DAOTreasury.sol` | Protocol treasury; withdrawals require a passed DAO proposal |

## Security properties

- **Flash-loan governance**: voting power read from `getPastVotes(snapshotBlock)`, not current balance.
- **Reentrancy**: all state-mutating functions protected by `ReentrancyGuard` + CEI order.
- **Donation attack**: `LiquidityPool` uses accounting reserves (`reserveA`/`reserveB`), not `balanceOf`.
- **LP inflation attack**: `MINIMUM_LIQUIDITY = 1000` permanently locked on first deposit.
- **Ownable2Step**: two-step ownership transfer on DAO and DAOTreasury — a typo cannot brick governance.
- **Zero-quorum / zero-threshold**: `setQuorumBps` and `setProposalThreshold` reject 0, preventing permissionless governance.
- **Immutable treasury**: `LiquidityPool.treasury` is `immutable` — fees cannot be redirected post-deploy.
- **Supply cap**: `GovernanceToken` enforces a hard cap; no mint can exceed it.

## Default governance parameters

| Parameter | Value | Description |
|---|---|---|
| `votingPeriod` | 259200 s (3 days) | Duration of each voting window |
| `timelockDelay` | 86400 s (1 day) | Mandatory delay between vote end and execution |
| `quorumBps` | 400 (4%) | Minimum participation required for a proposal to pass |
| `proposalThreshold` | 1000 GOV | Minimum balance to submit a proposal |
| `feeBps` | 30 (0.30%) | LiquidityPool swap fee |
| `initialRewardRate` | ~0.317 GOV/s | Distributes 10 M GOV over ~1 year |
| `govCap` | 10000000 GOV | Hard supply cap of the governance token |

## Development

**Prerequisites:** [Foundry](https://book.getfoundry.sh/getting-started/installation)

```sh
# Clone with submodules
git clone --recurse-submodules <repo-url>
cd DAO_Governance_YieldFarming

# Build
forge build

# Unit + fuzz tests
forge test

# Invariant tests (slower — ~256 runs × 500 calls each)
forge test --match-test "invariant_"

# Format check
forge fmt --check

# Gas snapshot
forge snapshot
```

## Test coverage

168 tests across 6 test files:

| File | Tests | Coverage |
|---|---|---|
| `GovernanceToken.t.sol` | 19 (+ 3 fuzz) | mint cap, burn, roles, voting snapshots |
| `LiquidityPool.t.sol` | 33 (+ 3 fuzz + 3 invariant) | add/remove liquidity, swaps, k-invariant, fee math |
| `YieldFarmingPool.t.sol` | 23 (+ 3 fuzz + 1 invariant) | stake/unstake/harvest, reward accrual, multi-user proportionality |
| `DAO.t.sol` | 50 (+ 2 fuzz) | full proposal lifecycle, access control, governance setters |
| `DAOTreasury.t.sol` | 25 | ETH/ERC20 withdrawals, DAO-gated access |
| `Integration.t.sol` | 9 | end-to-end: deploy → stake → propose → execute |

## Deployment

**Dry run** (no broadcast, throwaway key):

```sh
DEPLOYER_PRIVATE_KEY=0x0000000000000000000000000000000000000000000000000000000000000001 \
  forge script script/Deploy.s.sol --rpc-url $RPC_URL
```

**Mainnet deploy** (run only after review):

```sh
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify \
  --chain mainnet
```

Before running, edit `script/Deploy.s.sol` to set:
- `tokenA_` / `tokenB_` — token pair addresses for the target chain.
- Governance parameters if you want values different from the defaults.

### Post-deploy steps (manual — cannot be done in the script)

1. Transfer DAO ownership to multisig:
   ```
   dao.transferOwnership(MULTISIG)
   // multisig calls:
   dao.acceptOwnership()
   ```
2. Transfer `DEFAULT_ADMIN_ROLE` of `GovernanceToken` to multisig, then revoke it from deployer:
   ```
   govToken.grantRole(DEFAULT_ADMIN_ROLE, MULTISIG)
   govToken.revokeRole(DEFAULT_ADMIN_ROLE, deployer)
   ```

## Dependencies

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) — ERC20, ERC20Votes, ERC20Permit, AccessControl, Ownable2Step, ReentrancyGuard, SafeERC20
- [forge-std](https://github.com/foundry-rs/forge-std) — Foundry test utilities

## License

MIT
