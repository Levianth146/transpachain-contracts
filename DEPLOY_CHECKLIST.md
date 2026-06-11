# TranspaChain Redeploy Checklist

## When redeploy is required

Redeploy **GovernanceDAO** (and re-wire trusted addresses) after:

- Quadratic voting (`quadraticWeight`, updated `totalVotingPower`)
- `closeProposal(proposalId, reason)` for admin/verifier
- `getDonorLinearAmount` view helper

No redeploy needed for frontend/backend-only changes (admin close off-chain, UI, indexer).

## Deploy steps

1. `cd contracts && forge test` — all tests green
2. Deploy new `GovernanceDAO` via existing script
3. `dao.setDonationVault(vaultAddress)`
4. `dao.setVerifier(verifierWallet)` — match CharityCore VERIFIER_ROLE holder
5. `vault` / `core`: update `governanceDAO` pointer (see `CharityCore.setTrustedContracts`)
6. Update env:
   - `GOVERNANCE_DAO_ADDRESS`
   - `NEXT_PUBLIC_GOVERNANCE_DAO_ADDRESS`
7. Restart backend indexer (historical sync for open proposals optional)
8. Verify on Sepolia: create campaign → donate → submit proof → vote → queue → execute

## Post-deploy verification

- [ ] `getVotingPower` returns sqrt weight
- [ ] `closeProposal` callable by verifier wallet
- [ ] Frontend governance hub shows on-chain QV totals
- [ ] Admin approve flow still gates public listing
