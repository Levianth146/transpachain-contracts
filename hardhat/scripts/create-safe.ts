/**
 * Create (or predict) a Gnosis Safe 3/5 on Avalanche Fuji for DisbursementController.
 *
 *   npx hardhat run hardhat/scripts/create-safe.ts --network fuji
 *
 * Env (contracts/.env):
 *   DEPLOYER_PRIVATE_KEY   — pays gas for SafeProxyFactory.createProxyWithNonce
 *   FUJI_RPC_URL           — optional (defaults to public Fuji RPC)
 *   SAFE_OWNERS            — five comma-separated EOA addresses
 *   SAFE_THRESHOLD         — default 3
 *   SAFE_SALT_NONCE        — optional uint string for deterministic address (default: timestamp)
 *   PREDICT_ONLY=1         — print predicted address only; do not broadcast
 *
 * Prints DISBURSEMENT_SAFE=<address> for contracts/.env then deploy-v2.ts.
 *
 * Requires: @safe-global/protocol-kit + @safe-global/safe-deployments (already in package.json).
 * Fallback if protocol-kit cannot run: create the Safe in Ash Wallet (wallet.ash.center) or
 * Safe CLI against the canonical Fuji addresses in deployments/43113.json → safeCanonical,
 * then set DISBURSEMENT_SAFE manually.
 */
import { ethers, network } from "hardhat";
import Safe, {
  getSafeAddressFromDeploymentTx,
  type PredictedSafeProps,
} from "@safe-global/protocol-kit";
import {
  getSafeSingletonDeployment,
  getSafeL2SingletonDeployment,
  getProxyFactoryDeployment,
  getCompatibilityFallbackHandlerDeployment,
} from "@safe-global/safe-deployments";
import * as dotenv from "dotenv";
import path from "path";

dotenv.config({ path: path.resolve(__dirname, "../../.env") });

const FUJI_CHAIN_ID = 43113;
const SAFE_VERSION = "1.4.1" as const;

function parseOwners(raw: string | undefined): string[] {
  if (!raw?.trim()) {
    throw new Error(
      "SAFE_OWNERS is required (five comma-separated addresses). Example:\n" +
        "  SAFE_OWNERS=0xA...,0xB...,0xC...,0xD...,0xE..."
    );
  }
  const owners = raw.split(",").map((s) => s.trim()).filter(Boolean);
  if (owners.length !== 5) {
    throw new Error(`SAFE_OWNERS must have exactly 5 addresses, got ${owners.length}`);
  }
  for (const o of owners) {
    if (!ethers.isAddress(o)) throw new Error(`Invalid owner address: ${o}`);
  }
  return owners.map((o) => ethers.getAddress(o));
}

function pkForProtocolKit(pk: string): string {
  return pk.startsWith("0x") ? pk : `0x${pk}`;
}

async function assertCanonicalDeployments(chainId: number) {
  const filter = { version: SAFE_VERSION, network: String(chainId) };
  const l1 = getSafeSingletonDeployment(filter);
  const l2 = getSafeL2SingletonDeployment(filter);
  const factory = getProxyFactoryDeployment(filter);
  const fallback = getCompatibilityFallbackHandlerDeployment(filter);

  const addrs = [
    ["Safe", l1?.networkAddresses?.[String(chainId)]],
    ["SafeL2", l2?.networkAddresses?.[String(chainId)]],
    ["SafeProxyFactory", factory?.networkAddresses?.[String(chainId)]],
    ["CompatibilityFallbackHandler", fallback?.networkAddresses?.[String(chainId)]],
  ] as const;

  for (const [name, addr] of addrs) {
    if (!addr) throw new Error(`safe-deployments missing ${name} for chain ${chainId}`);
    const code = await ethers.provider.getCode(addr);
    if (code === "0x") {
      throw new Error(
        `${name} at ${addr} has no code on chain ${chainId}. ` +
          "Fallback: deploy official Safe v1.4.1 from @safe-global/safe-smart-account artifacts, " +
          "or create the Safe via Ash Wallet and set DISBURSEMENT_SAFE manually."
      );
    }
  }
  console.log(`Canonical Safe ${SAFE_VERSION} singletons/factory OK on chain ${chainId}`);
}

async function main() {
  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  if (network.name === "fuji" && chainId !== FUJI_CHAIN_ID) {
    throw new Error(`Expected Fuji ${FUJI_CHAIN_ID}, got chainId ${chainId}`);
  }

  const owners = parseOwners(process.env.SAFE_OWNERS);
  const threshold = Number(process.env.SAFE_THRESHOLD || 3);
  if (threshold < 1 || threshold > owners.length) {
    throw new Error(`SAFE_THRESHOLD must be 1..${owners.length}, got ${threshold}`);
  }

  const pk = process.env.DEPLOYER_PRIVATE_KEY;
  if (!pk) throw new Error("DEPLOYER_PRIVATE_KEY is required");

  const rpc =
    process.env.FUJI_RPC_URL ||
    (network.config as { url?: string }).url ||
    "https://api.avax-test.network/ext/bc/C/rpc";

  await assertCanonicalDeployments(chainId);

  const saltNonce = process.env.SAFE_SALT_NONCE || String(Date.now());
  const predictedSafe: PredictedSafeProps = {
    safeAccountConfig: { owners, threshold },
    safeDeploymentConfig: {
      saltNonce,
      safeVersion: SAFE_VERSION,
      deploymentType: "canonical",
    },
  };

  // Avalanche uses the L2 singleton (SafeL2) — leave isL1SafeSingleton unset/false.
  const protocolKit = await Safe.init({
    provider: rpc,
    signer: pkForProtocolKit(pk),
    predictedSafe,
  });

  const predicted = await protocolKit.getAddress();
  console.log(`Network:   ${network.name} (chainId ${chainId})`);
  console.log(`Owners:    ${owners.join(", ")}`);
  console.log(`Threshold: ${threshold}`);
  console.log(`SaltNonce: ${saltNonce}`);
  console.log(`Predicted: ${predicted}`);

  if (process.env.PREDICT_ONLY === "1") {
    console.log("\nPREDICT_ONLY=1 — no broadcast.");
    console.log(`\nDISBURSEMENT_SAFE=${predicted}`);
    return;
  }

  if (await protocolKit.isSafeDeployed()) {
    console.log("Safe already deployed at predicted address.");
    console.log(`\nDISBURSEMENT_SAFE=${predicted}`);
    return;
  }

  const [deployer] = await ethers.getSigners();
  const bal = await ethers.provider.getBalance(deployer.address);
  console.log(`Deployer:  ${deployer.address}  balance ${ethers.formatEther(bal)} AVAX`);

  const deploymentTx = await protocolKit.createSafeDeploymentTransaction();
  const tx = await deployer.sendTransaction({
    to: deploymentTx.to,
    value: BigInt(deploymentTx.value),
    data: deploymentTx.data as `0x${string}`,
  });
  console.log(`Broadcast: ${tx.hash}`);
  const receipt = await tx.wait();
  if (!receipt) throw new Error("Safe deployment tx mined without receipt");

  let safeAddress = predicted;
  try {
    // protocol-kit expects a viem-style receipt; fall back to predicted on parse failure
    safeAddress = getSafeAddressFromDeploymentTx(receipt as never, SAFE_VERSION);
  } catch {
    safeAddress = predicted;
  }

  const code = await ethers.provider.getCode(safeAddress);
  if (code === "0x") {
    throw new Error(
      `Safe address ${safeAddress} has no code after deploy tx. ` +
        "Check the tx on Snowtrace or create the Safe manually (Ash Wallet / Safe CLI)."
    );
  }

  console.log(`\nSafe deployed: ${safeAddress}`);
  console.log(`Snowtrace: https://testnet.snowtrace.io/address/${safeAddress}`);
  console.log(`\n=== Add to contracts/.env ===`);
  console.log(`DISBURSEMENT_SAFE=${safeAddress}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
