/**
 * Pin tier metadata JSON to IPFS via Pinata, then call setTierMetadataCID on ImpactNFT.
 *
 * Usage (from repo root):
 *   PINATA_API_KEY=... PINATA_SECRET_KEY=... \
 *   IMPACT_NFT_ADDRESS=0x17CcdcF683626B5c914640154464bF64Ca66DB18 \
 *   PRIVATE_KEY=... SEPOLIA_RPC_URL=... \
 *   npx ts-node hardhat/scripts/setTierMetadata.ts
 *
 * Or set TIER_CIDS manually after pinning:
 *   BRONZE_CID=... SILVER_CID=... GOLD_CID=... npx ts-node hardhat/scripts/setTierMetadata.ts --skip-pin
 */
import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import PinataSDK from "@pinata/sdk";

const IMPACT_NFT_ABI = [
  "function setTierMetadataCID(uint8 tier, string calldata cid) external",
  "function getTierMetadataCID(uint8 tier) external view returns (string)",
];

async function pinTier(pinata: PinataSDK, filePath: string, name: string): Promise<string> {
  const json = JSON.parse(fs.readFileSync(filePath, "utf8"));
  const result = await pinata.pinJSONToIPFS(json, { pinataMetadata: { name } });
  console.log(`Pinned ${name}: ${result.IpfsHash}`);
  return result.IpfsHash;
}

async function main() {
  const skipPin = process.argv.includes("--skip-pin");
  const rpc = process.env.SEPOLIA_RPC_URL || process.env.ALCHEMY_SEPOLIA_URL;
  const pk = process.env.PRIVATE_KEY;
  const nftAddress = process.env.IMPACT_NFT_ADDRESS || "0x17CcdcF683626B5c914640154464bF64Ca66DB18";

  if (!rpc || !pk) {
    throw new Error("Set SEPOLIA_RPC_URL (or ALCHEMY_SEPOLIA_URL) and PRIVATE_KEY");
  }

  const metaDir = path.join(__dirname, "../../metadata");
  let bronze = process.env.BRONZE_CID || "";
  let silver = process.env.SILVER_CID || "";
  let gold = process.env.GOLD_CID || "";

  if (!skipPin) {
    if (!process.env.PINATA_API_KEY || !process.env.PINATA_SECRET_KEY) {
      throw new Error("PINATA_API_KEY and PINATA_SECRET_KEY required unless --skip-pin");
    }
    const pinata = new PinataSDK(process.env.PINATA_API_KEY, process.env.PINATA_SECRET_KEY);
    bronze = await pinTier(pinata, path.join(metaDir, "tier-bronze.json"), "tc-impact-bronze");
    silver = await pinTier(pinata, path.join(metaDir, "tier-silver.json"), "tc-impact-silver");
    gold = await pinTier(pinata, path.join(metaDir, "tier-gold.json"), "tc-impact-gold");
  }

  if (!bronze || !silver || !gold) {
    throw new Error("Missing tier CIDs — pin first or set BRONZE_CID/SILVER_CID/GOLD_CID");
  }

  const provider = new ethers.JsonRpcProvider(rpc);
  const wallet = new ethers.Wallet(pk, provider);
  const nft = new ethers.Contract(nftAddress, IMPACT_NFT_ABI, wallet);

  for (const [tier, cid, label] of [
    [0, bronze, "Bronze"],
    [1, silver, "Silver"],
    [2, gold, "Gold"],
  ] as const) {
    const existing = await nft.getTierMetadataCID(tier);
    if (existing === cid) {
      console.log(`${label} CID already set: ${cid}`);
      continue;
    }
    const tx = await nft.setTierMetadataCID(tier, cid);
    console.log(`setTierMetadataCID(${label}) tx: ${tx.hash}`);
    await tx.wait();
  }

  console.log("\nDone. MetaMask should render badges after tokenURI refresh.");
  console.log({ bronze, silver, gold });
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
