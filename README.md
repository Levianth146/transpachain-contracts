# TranspaChain — Contracts

Solidity protocol for escrowed charity campaigns on **Avalanche Fuji**: donations, quadratic governance, Safe-gated disbursement, Impact NFTs, and mock USDC yield.

**Product docs (start here):** [../README.md](../README.md)  
**Deploy runbook:** [../docs/fuji-deployment.md](../docs/fuji-deployment.md)  
**ADRs:** [../docs/adr/](../docs/adr/)

| | |
|---|---|
| **Tooling** | Foundry (tests) · Hardhat (Fuji scripts) · OpenZeppelin |
| **Active deploy** | V2 · block `61364951` · `deployments/43113.json` |
| **Assets** | AVAX native · Circle USDC `0x5425…Bc65` |

## Core contracts

| Contract | Role |
|---|---|
| `CharityCore` | Campaign lifecycle, org roles |
| `DonationVault` | Escrow, donations, refunds, approve/payout hooks |
| `GovernanceDAO` | Quadratic voting, quorum, timelock, milestone **approval** |
| `DisbursementController` | Payout requests + receipt commitments |
| `ImpactNFT` | Donor tier badges |
| `YieldManager` + `MockERC4626Vault` | Opt-in USDC mock yield (Module C) |

## Develop

```bash
forge test
# Fuji Safe + V2 deploy: see docs/fuji-deployment.md
```

Never commit private keys. Use `contracts/.env` locally only.
