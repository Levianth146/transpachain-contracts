import { ethers, run, network } from "hardhat";
import * as fs from "fs";
import * as path from "path";
import * as dotenv from "dotenv";

dotenv.config({ path: path.resolve(__dirname, "../../.env") });

/**
 * Deploy + wire TranspaChain V2 on Avalanche Fuji (43113).
 *
 * Prerequisites:
 *   1. Create Safe:  npx hardhat run hardhat/scripts/create-safe.ts --network fuji
 *   2. Set DISBURSEMENT_SAFE (+ LOSS_SINK, SAFE_OWNERS) in contracts/.env
 *
 *   npx hardhat run hardhat/scripts/deploy-v2.ts --network fuji
 *
 * Env:
 *   DEPLOYER_PRIVATE_KEY, USDC_ADDRESS, DISBURSEMENT_SAFE, LOSS_SINK (required)
 *   SAFE_OWNERS, SAFE_THRESHOLD          — recorded in manifest (optional but recommended)
 *   YIELD_CONTROLLER                     — MockERC4626Vault owner (default: deployer)
 *   VOTING_PERIOD_SECONDS / TIMELOCK_SECONDS / DEMO_ORG_ADDRESS
 *   SKIP_VERIFY=1                        — skip Routescan verification
 *
 * Writes/updates deployments/43113.json → deployments.v2 (keeps v1).
 * Does NOT print private keys or full .env.
 */
const MANIFEST_PATH = path.resolve(__dirname, "../../deployments/43113.json");

type Manifest = {
  chainId: number;
  network: string;
  explorer: string;
  rpc: string;
  usdc: Record<string, unknown>;
  safeCanonical?: Record<string, unknown>;
  deployments: Record<string, unknown>;
};

function requireAddress(name: string): string {
  const v = process.env[name];
  if (!v?.trim()) throw new Error(`${name} is required`);
  if (!ethers.isAddress(v.trim())) throw new Error(`${name} is not a valid address: ${v}`);
  return ethers.getAddress(v.trim());
}

function optionalAddress(name: string): string | undefined {
  const v = process.env[name];
  if (!v?.trim()) return undefined;
  if (!ethers.isAddress(v.trim())) throw new Error(`${name} is not a valid address: ${v}`);
  return ethers.getAddress(v.trim());
}

function parseOwners(): string[] | null {
  const raw = process.env.SAFE_OWNERS;
  if (!raw?.trim()) return null;
  return raw.split(",").map((s) => ethers.getAddress(s.trim())).filter(Boolean);
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const usdc = requireAddress("USDC_ADDRESS");
  const safeAddr = requireAddress("DISBURSEMENT_SAFE");
  const lossSink = requireAddress("LOSS_SINK");
  // simulateLoss() sends vault USDC to LOSS_SINK. If LOSS_SINK were a team wallet, "simulated losses"
  // would be a way to take donor money. Enforce the burn address unless explicitly overridden.
  const BURN = "0x000000000000000000000000000000000000dEaD";
  if (lossSink.toLowerCase() !== BURN.toLowerCase() && process.env.ALLOW_CUSTOM_LOSS_SINK !== "1") {
    throw new Error(`LOSS_SINK must be the burn address ${BURN} (set ALLOW_CUSTOM_LOSS_SINK=1 to override)`);
  }
  const yieldController = optionalAddress("YIELD_CONTROLLER") ?? deployer.address;

  const chainId = Number((await ethers.provider.getNetwork()).chainId);
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`Network:  ${network.name} (chainId ${chainId})`);
  console.log(`Deployer: ${deployer.address}  balance ${ethers.formatEther(balance)} AVAX`);

  if ((await ethers.provider.getCode(usdc)) === "0x") {
    throw new Error(`USDC_ADDRESS ${usdc} has no code on chain ${chainId}`);
  }
  const usdcToken = await ethers.getContractAt(
    ["function symbol() view returns (string)"],
    usdc
  );
  console.log(`USDC:     ${usdc} (${await usdcToken.symbol()})`);

  if ((await ethers.provider.getCode(safeAddr)) === "0x") {
    throw new Error(
      `DISBURSEMENT_SAFE ${safeAddr} has no code. Run create-safe.ts first (or set a deployed Safe).`
    );
  }
  console.log(`Safe:     ${safeAddr}`);
  console.log(`LossSink: ${lossSink}`);
  console.log(`YieldCtl: ${yieldController}`);

  // ── Core stack ───────────────────────────────────────────────────────────
  const core = await (await ethers.getContractFactory("CharityCore")).deploy(deployer.address);
  await core.waitForDeployment();
  const nft = await (await ethers.getContractFactory("ImpactNFT")).deploy(deployer.address);
  await nft.waitForDeployment();
  const dao = await (await ethers.getContractFactory("GovernanceDAO")).deploy(deployer.address);
  await dao.waitForDeployment();
  const vault = await (await ethers.getContractFactory("DonationVault")).deploy(
    deployer.address,
    await core.getAddress(),
    await dao.getAddress(),
    await nft.getAddress(),
    usdc
  );
  await vault.waitForDeployment();

  await (await core.setTrustedContracts(await vault.getAddress(), await dao.getAddress())).wait();
  await (await nft.setTrustedContracts(await vault.getAddress(), await core.getAddress())).wait();
  await (await dao.setDonationVault(await vault.getAddress())).wait();

  // ── Module A: DisbursementController ─────────────────────────────────────
  const controller = await (await ethers.getContractFactory("DisbursementController")).deploy(
    deployer.address,
    await vault.getAddress(),
    await core.getAddress(),
    safeAddr
  );
  await controller.waitForDeployment();
  await (await vault.setDisbursementController(await controller.getAddress())).wait();

  // ── Module C: MockERC4626 + YieldManager ─────────────────────────────────
  const mockVault = await (await ethers.getContractFactory("MockERC4626Vault")).deploy(
    usdc,
    lossSink,
    yieldController
  );
  await mockVault.waitForDeployment();

  const ym = await (await ethers.getContractFactory("YieldManager")).deploy(
    deployer.address,
    await vault.getAddress(),
    await core.getAddress(),
    await mockVault.getAddress(),
    usdc
  );
  await ym.waitForDeployment();
  await (await vault.setYieldManager(await ym.getAddress())).wait();

  console.log("Contracts wired (core + controller + yield).");

  const vp = Number(process.env.VOTING_PERIOD_SECONDS || 0);
  const tl = Number(process.env.TIMELOCK_SECONDS || 0);
  if (vp > 0 && tl > 0) {
    await (await dao.setGovernancePeriods(vp, tl)).wait();
    console.log(`Governance periods set: voting ${vp}s, timelock ${tl}s`);
  }

  const demoOrg = optionalAddress("DEMO_ORG_ADDRESS");
  if (demoOrg) {
    await (await core.verifyOrg(demoOrg)).wait();
    console.log(`Verified demo org ${demoOrg}`);
  }

  const coreRcpt = await core.deploymentTransaction()?.wait();
  const deployBlock = coreRcpt?.blockNumber ?? (await ethers.provider.getBlockNumber());

  const a = {
    CharityCore: await core.getAddress(),
    DonationVault: await vault.getAddress(),
    GovernanceDAO: await dao.getAddress(),
    ImpactNFT: await nft.getAddress(),
    DisbursementController: await controller.getAddress(),
    YieldManager: await ym.getAddress(),
    MockERC4626Vault: await mockVault.getAddress(),
  };

  // ── Manifest (keep v1) ───────────────────────────────────────────────────
  let manifest: Manifest;
  if (fs.existsSync(MANIFEST_PATH)) {
    manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, "utf8")) as Manifest;
  } else {
    manifest = {
      chainId,
      network: "avalanche-fuji",
      explorer: "https://testnet.snowtrace.io",
      rpc: "https://api.avax-test.network/ext/bc/C/rpc",
      usdc: { address: usdc },
      deployments: {},
    };
  }
  if (!manifest.deployments) manifest.deployments = {};

  const owners = parseOwners();
  const threshold = Number(process.env.SAFE_THRESHOLD || 3);

  manifest.deployments.v2 = {
    version: "2",
    deployBlock,
    deployedAt: new Date().toISOString().slice(0, 10),
    governance: {
      votingPeriodSeconds: vp > 0 ? vp : null,
      timelockSeconds: tl > 0 ? tl : null,
    },
    contracts: a,
    safe: {
      address: safeAddr,
      owners: owners,
      threshold,
    },
    yieldVault: a.MockERC4626Vault,
    lossSink,
    yieldController,
    note: "V2: DAO approve-only + DisbursementController (Safe 3/5) + YieldManager/MockERC4626.",
  };

  fs.mkdirSync(path.dirname(MANIFEST_PATH), { recursive: true });
  fs.writeFileSync(MANIFEST_PATH, JSON.stringify(manifest, null, 2) + "\n");
  console.log(`Manifest updated: ${MANIFEST_PATH} (deployments.v2)`);

  // ── Env blocks (no secrets) ──────────────────────────────────────────────
  console.log("\n=== backend/.env ===");
  console.log(`CHARITY_CORE_ADDRESS=${a.CharityCore}`);
  console.log(`DONATION_VAULT_ADDRESS=${a.DonationVault}`);
  console.log(`GOVERNANCE_DAO_ADDRESS=${a.GovernanceDAO}`);
  console.log(`IMPACT_NFT_ADDRESS=${a.ImpactNFT}`);
  console.log(`DISBURSEMENT_CONTROLLER_ADDRESS=${a.DisbursementController}`);
  console.log(`YIELD_MANAGER_ADDRESS=${a.YieldManager}`);
  console.log(`MOCK_ERC4626_VAULT_ADDRESS=${a.MockERC4626Vault}`);
  console.log(`DISBURSEMENT_SAFE=${safeAddr}`);
  console.log(`DEPLOY_FROM_BLOCK=${deployBlock}`);
  console.log(`CONTRACT_DEPLOY_BLOCK=${deployBlock}`);

  console.log("\n=== frontend/.env.local ===");
  console.log(`NEXT_PUBLIC_CHARITY_CORE_ADDRESS=${a.CharityCore}`);
  console.log(`NEXT_PUBLIC_DONATION_VAULT_ADDRESS=${a.DonationVault}`);
  console.log(`NEXT_PUBLIC_GOVERNANCE_DAO_ADDRESS=${a.GovernanceDAO}`);
  console.log(`NEXT_PUBLIC_IMPACT_NFT_ADDRESS=${a.ImpactNFT}`);
  console.log(`NEXT_PUBLIC_DISBURSEMENT_CONTROLLER_ADDRESS=${a.DisbursementController}`);
  console.log(`NEXT_PUBLIC_YIELD_MANAGER_ADDRESS=${a.YieldManager}`);
  console.log(`NEXT_PUBLIC_MOCK_ERC4626_VAULT_ADDRESS=${a.MockERC4626Vault}`);
  console.log(`NEXT_PUBLIC_DISBURSEMENT_SAFE=${safeAddr}`);

  console.log(`\nSnowtrace vault: https://testnet.snowtrace.io/address/${a.DonationVault}`);

  if (network.name === "fuji" && process.env.SKIP_VERIFY !== "1") {
    console.log("\nVerifying on Snowtrace (Routescan)...");
    const jobs: [string, string, unknown[]][] = [
      ["CharityCore", a.CharityCore, [deployer.address]],
      ["ImpactNFT", a.ImpactNFT, [deployer.address]],
      ["GovernanceDAO", a.GovernanceDAO, [deployer.address]],
      [
        "DonationVault",
        a.DonationVault,
        [deployer.address, a.CharityCore, a.GovernanceDAO, a.ImpactNFT, usdc],
      ],
      [
        "DisbursementController",
        a.DisbursementController,
        [deployer.address, a.DonationVault, a.CharityCore, safeAddr],
      ],
      ["MockERC4626Vault", a.MockERC4626Vault, [usdc, lossSink, yieldController]],
      [
        "YieldManager",
        a.YieldManager,
        [deployer.address, a.DonationVault, a.CharityCore, a.MockERC4626Vault, usdc],
      ],
    ];
    for (const [name, addr, args] of jobs) {
      try {
        await run("verify:verify", { address: addr, constructorArguments: args });
        console.log(`  ✓ ${name}`);
      } catch (e) {
        console.log(`  ⚠ ${name}: ${(e as Error).message.split("\n")[0]}`);
      }
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
