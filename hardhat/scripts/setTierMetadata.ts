/**
 * Pin tier SVG images + ERC-721 metadata JSON to IPFS (Pinata), then set CIDs on ImpactNFT.
 *
 * MetaMask requires publicly reachable `image` URLs — we pin SVGs separately and reference
 * `https://gateway.pinata.cloud/ipfs/<imageCid>` in each metadata JSON.
 *
 * Usage (from transpachain-contracts root):
 *   PINATA_API_KEY=... PINATA_SECRET_KEY=... \
 *   IMPACT_NFT_ADDRESS=0x17CcdcF683626B5c914640154464bF64Ca66DB18 \
 *   PRIVATE_KEY=... SEPOLIA_RPC_URL=... \
 *   npx ts-node hardhat/scripts/setTierMetadata.ts
 *
 * Skip pinning if CIDs already known:
 *   BRONZE_CID=... SILVER_CID=... GOLD_CID=... \
 *   npx ts-node hardhat/scripts/setTierMetadata.ts --skip-pin
 *
 * After on-chain update:
 *   1. Refresh NFT in MetaMask (NFT tab → … → Refresh metadata)
 *   2. EC2: docker compose pull frontend && docker compose up -d frontend
 */
import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import PinataSDK from "@pinata/sdk";
import FormData from "form-data";
import axios from "axios";

const IMPACT_NFT_ABI = [
  "function setTierMetadataCID(uint8 tier, string calldata cid) external",
  "function getTierMetadataCID(uint8 tier) external view returns (string)",
];

const GATEWAY = process.env.PINATA_GATEWAY || "https://gateway.pinata.cloud/ipfs";

const TIER_META = [
  {
    tier: 0,
    label: "Bronze",
    imageFile: "tier-bronze.svg",
    name: "TranspaChain Impact — Bronze",
    description:
      "Retro synthwave bronze donor badge. Earned by supporting a TranspaChain campaign on Sepolia.",
    tierValue: "Bronze",
  },
  {
    tier: 1,
    label: "Silver",
    imageFile: "tier-silver.svg",
    name: "TranspaChain Impact — Silver",
    description:
      "Retro synthwave silver donor badge. Earned for meaningful contributions on Sepolia.",
    tierValue: "Silver",
  },
  {
    tier: 2,
    label: "Gold",
    imageFile: "tier-gold.svg",
    name: "TranspaChain Impact — Gold",
    description:
      "Retro synthwave gold donor badge. Top-tier impact recognition on Sepolia.",
    tierValue: "Gold",
  },
] as const;

async function pinFileToIPFS(
  pinata: PinataSDK,
  filePath: string,
  name: string
): Promise<string> {
  const stream = fs.createReadStream(filePath);
  const result = await pinata.pinFileToIPFS(stream, {
    pinataMetadata: { name },
  });
  console.log(`Pinned file ${name}: ${result.IpfsHash}`);
  return result.IpfsHash;
}

async function pinJsonToIPFS(
  pinata: PinataSDK,
  json: Record<string, unknown>,
  name: string
): Promise<string> {
  const result = await pinata.pinJSONToIPFS(json, { pinataMetadata: { name } });
  console.log(`Pinned JSON ${name}: ${result.IpfsHash}`);
  return result.IpfsHash;
}

/** Fallback pin via Pinata REST if SDK stream fails */
async function pinFileViaRest(filePath: string, name: string): Promise<string> {
  const key = process.env.PINATA_API_KEY!;
  const secret = process.env.PINATA_SECRET_KEY!;
  const form = new FormData();
  form.append("file", fs.createReadStream(filePath));
  form.append(
    "pinataMetadata",
    JSON.stringify({ name })
  );
  const res = await axios.post(
    "https://api.pinata.cloud/pinning/pinFileToIPFS",
    form,
    {
      maxBodyLength: Infinity,
      headers: {
        ...form.getHeaders(),
        pinata_api_key: key,
        pinata_secret_api_key: secret,
      },
    }
  );
  console.log(`Pinned file (REST) ${name}: ${res.data.IpfsHash}`);
  return res.data.IpfsHash as string;
}

async function pinTierBundle(
  pinata: PinataSDK,
  metaDir: string,
  spec: (typeof TIER_META)[number]
): Promise<string> {
  const imagePath = path.join(metaDir, "images", spec.imageFile);
  if (!fs.existsSync(imagePath)) {
    throw new Error(`Missing image: ${imagePath}`);
  }

  let imageCid: string;
  try {
    imageCid = await pinFileToIPFS(pinata, imagePath, `tc-impact-${spec.label.toLowerCase()}-image`);
  } catch {
    imageCid = await pinFileViaRest(imagePath, `tc-impact-${spec.label.toLowerCase()}-image`);
  }

  const imageUrl = `${GATEWAY}/${imageCid}`;
  const metadata = {
    name: spec.name,
    description: spec.description,
    image: imageUrl,
    external_url: "https://transpachain.site",
    attributes: [
      { trait_type: "Tier", value: spec.tierValue },
      { trait_type: "Style", value: "Retro Synthwave" },
      { trait_type: "Network", value: "Sepolia" },
    ],
  };

  return pinJsonToIPFS(pinata, metadata, `tc-impact-${spec.label.toLowerCase()}`);
}

async function main() {
  const skipPin = process.argv.includes("--skip-pin");
  const rpc = process.env.SEPOLIA_RPC_URL || process.env.ALCHEMY_SEPOLIA_URL;
  const pk = process.env.PRIVATE_KEY;
  const nftAddress =
    process.env.IMPACT_NFT_ADDRESS || "0x17CcdcF683626B5c914640154464bF64Ca66DB18";

  if (!rpc || !pk) {
    throw new Error("Set SEPOLIA_RPC_URL (or ALCHEMY_SEPOLIA_URL) and PRIVATE_KEY");
  }

  const metaDir = path.join(__dirname, "../../metadata");
  const cids: Record<string, string> = {
    Bronze: process.env.BRONZE_CID || "",
    Silver: process.env.SILVER_CID || "",
    Gold: process.env.GOLD_CID || "",
  };

  if (!skipPin) {
    if (!process.env.PINATA_API_KEY || !process.env.PINATA_SECRET_KEY) {
      throw new Error("PINATA_API_KEY and PINATA_SECRET_KEY required unless --skip-pin");
    }
    const pinata = new PinataSDK(process.env.PINATA_API_KEY, process.env.PINATA_SECRET_KEY);

    for (const spec of TIER_META) {
      cids[spec.label] = await pinTierBundle(pinata, metaDir, spec);
    }
  }

  if (!cids.Bronze || !cids.Silver || !cids.Gold) {
    throw new Error("Missing tier CIDs — pin first or set BRONZE_CID/SILVER_CID/GOLD_CID");
  }

  const provider = new ethers.JsonRpcProvider(rpc);
  const wallet = new ethers.Wallet(pk, provider);
  const nft = new ethers.Contract(nftAddress, IMPACT_NFT_ABI, wallet);

  for (const spec of TIER_META) {
    const cid = cids[spec.label];
    const existing = await nft.getTierMetadataCID(spec.tier);
    if (existing === cid) {
      console.log(`${spec.label} CID already set: ${cid}`);
      continue;
    }
    const tx = await nft.setTierMetadataCID(spec.tier, cid);
    console.log(`setTierMetadataCID(${spec.label}) tx: ${tx.hash}`);
    await tx.wait();
  }

  console.log("\n✓ Tier metadata CIDs set on ImpactNFT:", nftAddress);
  console.log("  Bronze:", cids.Bronze);
  console.log("  Silver:", cids.Silver);
  console.log("  Gold:", cids.Gold);
  console.log("\nMetaMask: open NFT → ⋯ → Refresh metadata");
  console.log("OpenSea Sepolia: https://testnets.opensea.io/assets/sepolia/" + nftAddress);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
