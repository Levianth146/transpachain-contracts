# TranspaChain Baseline Report (PR-01 / T0)

**Date:** 2026-11-20  
**Scope:** Fuji migration baseline before Module A/B/C (V2) work  
**Workspace:** `D:\Projects\transpachain-fresh`

## 1. Gate results

| Gate | Command | Result |
|---|---|---|
| G1 contracts | `forge test` (WSL Ubuntu-24.04) | **315/315 passed** |
| G1 sizes | `forge build --sizes` | CharityCore 11,340 · DonationVault 14,095 · GovernanceDAO 9,035 · ImpactNFT 10,867 (all &lt; 24 KB) |
| G2 backend | `npx tsc --noEmit` | **pass** (exit 0) |
| G3 frontend | `npm run build` | **pass** (exit 0) |

## 2. Live Fuji v1 deployment

Recorded in `contracts/deployments/43113.json` → `deployments.v1`.

| Contract | Address |
|---|---|
| CharityCore | `0xB1dE316be780D4c779f93A5EE37A9D44d3344de9` |
| DonationVault | `0xf1A52fa0fA5d88387a00B59aa35040E48b7a709C` |
| GovernanceDAO | `0xeb5C41b35111943AF1395Da6337B3147c3f5cCa3` |
| ImpactNFT | `0xD52B2385a3853e4C97928e59E8012569723C50DF` |
| USDC (Circle Fuji) | `0x5425890298aed601595a70AB815c96711a31Bc65` |

- Deploy block: **61361175**
- Governance periods on this deploy: **300 s voting / 120 s timelock**
- Explorer: https://testnet.snowtrace.io

Legacy Sepolia v3 addresses: `contracts/deployments/11155111.json`.

## 3. Safe availability on Fuji (spec §3.1)

**Verdict: Safe v1.4.1 canonical deployments ARE present on chainId 43113.**  
We can create the demo Safe via `@safe-global/protocol-kit` against these addresses. No need to redeploy Safe singletons.

Source: `@safe-global/safe-deployments`. On-chain check: `eth_getCode` via `https://api.avax-test.network/ext/bc/C/rpc` (2026-11-20).

| Contract | Address | `eth_getCode` |
|---|---|---|
| Safe singleton | `0x41675C099F32341bf84BFc5382aF534df5C7461a` | present (codeLen ≈ 47k) |
| SafeL2 singleton | `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762` | present (codeLen ≈ 49k) |
| SafeProxyFactory | `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67` | present |
| CompatibilityFallbackHandler | `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99` | present |
| MultiSend | `0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526` | present |
| MultiSendCallOnly | `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` | present |

Notes for later PRs:

- Safe Transaction Service / Safe{Wallet} UI likely unavailable on Fuji → collect EIP-712 signatures in our app (spec §3.1.4).
- Ash Wallet may support Fuji; app must work without it.
- Demo honesty: 5 owner keys = 5 team MetaMask accounts (document in README/video).

## 4. Known inconsistency — USDC NFT tier thresholds (do NOT silent-fix)

Mint-time tier (`DonationVault._tierUSDC`) and upgrade-time tier (`ImpactNFT.upgradeTier` USDC branch) disagree:

| Step | Bronze | Silver | Gold |
|---|---|---|---|
| **Mint** (`DonationVault._tierUSDC`) | &lt; 10 USDC | ≥ **10e6** ($10) | ≥ **100e6** ($100) |
| **Upgrade** (`ImpactNFT` constants) | &lt; 25 USDC | ≥ **25e6** ($25) → Silver | ≥ **250e6** ($250) → Gold |
| Native AVAX (both paths) | &lt; 0.01 | ≥ 0.01 | ≥ 0.1 | aligned |

ImpactNFT constant names are also misleading: `BRONZE_THRESHOLD_USDC` is the gate **into Silver**, `SILVER_THRESHOLD_USDC` is the gate **into Gold**.

**Decision requested before changing:** keep as-is for V1 honesty, or align both to one table in V2. Default for UniHack: document only; do not change unless product owner picks a table.

## 5. PR-01 contents committed

- Contracts: timestamp-based DAO (`endTime`), Fuji RPC/Hardhat, vendored `forge-std`, emptied `.gitmodules`, Deploy scripts, metadata JSON Avalanche labels, `deployments/*.json`.
- Backend: chain-agnostic RPC, Proposal `endTime`, Fuji `.env.example`, `/health` chain fields.
- Frontend: `lib/chain.ts`, Fuji default wagmi, AVAX labels, wrong-network switch, Founding Team removed.

## 6. Next

**T1 / PR-02 — Module A:** GovernanceDAO approval-only, DonationVault `approveMilestone`/`payoutMilestone`, DisbursementController, Safe 3/5 + anti-bypass tests.
