# TranspaChain Redeploy Checklist (v2 — campaign lifecycle fix)

## What changed (requires full redeploy)

- **CharityCore**: finalize when goal met OR deadline passed; cancel anytime; `canFinalize()` view
- **DonationVault**: block donations at goal; cancel refunds; resubmit milestone proof after defeated vote
- **GovernanceDAO**: quorum based on participating voters (cast weight), not all donors

## Pre-deploy

```bash
cd /root/projects/transpachain-contracts
forge test   # expect 303+ passing
```

## Sepolia deploy (Hardhat)

```bash
cd /root/projects/transpachain-contracts
# Ensure .env has SEPOLIA_RPC_URL, DEPLOYER_PRIVATE_KEY, USDC_ADDRESS, ETHERSCAN_API_KEY
npx hardhat run hardhat/scripts/deploy.ts --network sepolia
```

Save printed addresses — update **all** of:

| Env var | Where |
|---------|--------|
| `CHARITY_CORE_ADDRESS` | backend `.env`, EC2 |
| `DONATION_VAULT_ADDRESS` | backend `.env`, EC2 |
| `GOVERNANCE_DAO_ADDRESS` | backend `.env`, EC2 |
| `IMPACT_NFT_ADDRESS` | backend `.env` (if used) |
| `NEXT_PUBLIC_CHARITY_CORE_ADDRESS` | frontend `.env` / Vercel |
| `NEXT_PUBLIC_DONATION_VAULT_ADDRESS` | frontend |
| `NEXT_PUBLIC_GOVERNANCE_DAO_ADDRESS` | frontend |
| `NEXT_PUBLIC_IMPACT_NFT_ADDRESS` | frontend |
| `DEPLOY_FROM_BLOCK` | backend — set to deploy tx block, then `0` after first sync |

## Post-deploy on-chain wiring (if not in script)

1. `core.setTrustedContracts(vault, dao)`
2. `nft.setTrustedContracts(vault, core)`
3. `dao.setDonationVault(vault)`
4. `dao.setVerifier(verifierWallet)` — same as CharityCore VERIFIER_ROLE holder
5. Verify org wallets: `core.verifyOrg(orgAddress)`

## Post-deploy: Impact NFT tier metadata (required for MetaMask / Etherscan)

The site dashboard renders badges from local SVGs + on-chain `tier`; wallets read `tokenURI` → IPFS JSON with an `image` field.

**Without this step**, minted badges point at **campaign** metadata (`imageUrl`, not ERC-721 `image`) and MetaMask shows a broken image.

```bash
cd /root/projects/transpachain-contracts
# From .env: ALCHEMY_SEPOLIA_URL, DEPLOYER_PRIVATE_KEY, PINATA_* , IMPACT_NFT_ADDRESS

# First deploy — pin SVGs + JSON to Pinata, set tier CIDs on-chain:
npx ts-node hardhat/scripts/setTierMetadata.ts

# Reuse existing Pinata CIDs (faster, same art as previous deploy):
BRONZE_CID=QmRdCrwKKam2GLjojmEHC5D4G7WtA3DRXTLZ4uXicgJC1g \
SILVER_CID=QmTZeB6tS3MUDd2WWyfJPU3qBEfhioE1AkvQZ25HmZnWKD \
GOLD_CID=Qma2kvdRAr7E3nQYeUWDms19Lygoikvw6QbTveUk2kqqgG \
IMPACT_NFT_ADDRESS=0xD651d3531a44ee7941bFE257c79F41d274E180A6 \
npx ts-node hardhat/scripts/setTierMetadata.ts --skip-pin

# Repair badges minted before tier CIDs were set (e.g. tokens #1–#4):
npx ts-node hardhat/scripts/setTierMetadata.ts --skip-pin --refresh-tokens
```

After running, tell users: MetaMask → NFT → **⋯ → Refresh metadata**.

Verify Bronze JSON: `https://gateway.pinata.cloud/ipfs/<BRONZE_CID>` must include `"image": "https://..."`.

## EC2 / production restart

```bash
# On EC2 backend host
cd transpachain-backend && git pull && npm ci && npm run build
# Update .env with new addresses + DEPLOY_FROM_BLOCK
pm2 restart transpachain-backend   # or your process manager
```

## Verification checklist

- [ ] Goal reached → donate reverts `Vault: goal reached`
- [ ] Goal reached → org can finalize **before** deadline (no `CharityCore: not expired`)
- [ ] Org cancel with donors → donors can `claimRefund`
- [ ] Single voter For passes quorum (among voters, not all donors)
- [ ] Defeated milestone → org can submit new proof CID
- [ ] Frontend Finalize disabled until `canFinalize` true; clear error messages
- [ ] `setTierMetadata.ts` run for new `IMPACT_NFT_ADDRESS`; `--refresh-tokens` if badges minted before
- [ ] MetaMask shows badge image after **Refresh metadata**

## Current Sepolia

- CharityCore: `0x8a5e023b16ab13939260492dAe72a0be1E597e1a`
- DonationVault: `0x68Bb9f5E1414b1a62372EbF02fdEe4c09fFc7C32`
- GovernanceDAO: `0xCcAEaF248E536850877B9f948cB237Fe7885b513`
- ImpactNFT: `0xD651d3531a44ee7941bFE257c79F41d274E180A6`
- Deploy block: `11102718` (`DEPLOY_FROM_BLOCK`)

## Previous Sepolia (deprecated)

- CharityCore: `0xA13344e56a2421322bb2985ffE37b07DB80B760d`
- DonationVault: `0x72116A0BCe20473FE1BfcC2da9D2337A6D39Ed5c`
- GovernanceDAO: `0x290770c85B42c3a32365f6f6350587878dCbe2D5`
- ImpactNFT: `0x17CcdcF683626B5c914640154464bF64Ca66DB18`
