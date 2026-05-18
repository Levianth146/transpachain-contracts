import { ethers } from "hardhat";

// ── Contract addresses sau khi deploy ──────────────────────────
// Fill in deployed contract addresses
const CHARITY_CORE_ADDRESS   = process.env.CHARITY_CORE_ADDRESS   || "";
const DONATION_VAULT_ADDRESS = process.env.DONATION_VAULT_ADDRESS || "";
const GOVERNANCE_DAO_ADDRESS = process.env.GOVERNANCE_DAO_ADDRESS || "";
const IMPACT_NFT_ADDRESS     = process.env.IMPACT_NFT_ADDRESS     || "";

if (!CHARITY_CORE_ADDRESS || !DONATION_VAULT_ADDRESS) {
  console.error("❌ Please set contract addresses in .env file");
  process.exit(1);
}

// ── ABIs (minimal) ─────────────────────────────────────────────
const CORE_ABI = [
  "function verifyOrg(address) external",
  "function createCampaign(string,uint256,uint256,uint8,uint8,string) external payable returns (uint256)",
  "function getCampaign(uint256) external view returns (tuple(uint256,address,string,uint256,uint256,uint256,uint8,uint8,uint8,uint8,string,uint256,uint256))",
  "function getCharityProgress(uint256) external view returns (uint256,uint256,uint256,uint256,bool,uint256)",
  "function finalizeCampaign(uint256) external",
  "function isOrgVerified(address) external view returns (bool)",
];

const VAULT_ABI = [
  "function donate(uint256) external payable",
  "function submitMilestoneProof(uint256,uint8,string) external",
  "function getCampaignEscrowBalance(uint256) external view returns (uint256)",
  "function getDonorAmount(uint256,address) external view returns (uint256)",
  "function getMilestone(uint256,uint8) external view returns (tuple(string,uint256,bool,uint256))",
  "function canRefund(uint256,address) external view returns (bool,uint256,uint256)",
  "function claimRefund(uint256) external",
];

const DAO_ABI = [
  "function castVote(uint256,uint8) external",
  "function queueProposal(uint256) external",
  "function executeProposal(uint256) external",
  "function getProposal(uint256) external view returns (tuple(uint256,uint256,uint8,string,address,uint256,uint256,uint256,uint256,uint256,uint256,uint8,uint256,uint256))",
  "function getProposalState(uint256) external view returns (uint8)",
  "function getActiveProposal(uint256) external view returns (uint256)",
  "function hasVoted(uint256,address) external view returns (bool)",
];

const NFT_ABI = [
  "function getDonorNFTs(address) external view returns (uint256[])",
  "function getNFTMetadata(uint256) external view returns (tuple(uint256,address,uint8,uint256,uint256,bool,string,uint8))",
  "function hasMintedForCampaign(address,uint256) external view returns (bool)",
];

const PROPOSAL_STATES = ["Pending","Active","Defeated","Queued","Executed","Cancelled"];
const TIER_NAMES      = ["Bronze","Silver","Gold"];

function sleep(ms: number) { return new Promise(r => setTimeout(r, ms)); }
function formatEth(wei: bigint) { return ethers.formatEther(wei) + " ETH"; }
function separator(title: string) {
  console.log("\n" + "=".repeat(60));
  console.log(`  ${title}`);
  console.log("=".repeat(60));
}

async function main() {
  const signers = await ethers.getSigners();
  const admin  = signers[0];
  // On Sepolia only 1 signer available — use same account for all roles
  const org    = signers[1]  ?? signers[0];
  const donor1 = signers[2]  ?? signers[0];
  const donor2 = signers[3]  ?? signers[0];

  console.log("👤 Admin: ", admin.address);
  console.log("🏢 Org:   ", org.address);
  console.log("💰 Donor1:", donor1.address);
  console.log("💰 Donor2:", donor2.address);

  const core  = new ethers.Contract(CHARITY_CORE_ADDRESS,   CORE_ABI,  admin);
  const vault = new ethers.Contract(DONATION_VAULT_ADDRESS, VAULT_ABI, admin);
  const dao   = new ethers.Contract(GOVERNANCE_DAO_ADDRESS, DAO_ABI,   admin);
  const nft   = new ethers.Contract(IMPACT_NFT_ADDRESS,     NFT_ABI,   admin);

  // ══════════════════════════════════════════════════════════════
  separator("STEP 1 — Verify Org");
  // ══════════════════════════════════════════════════════════════

  const isVerified = await core.isOrgVerified(org.address);
  if (!isVerified) {
    const tx = await core.verifyOrg(org.address);
    await tx.wait();
    console.log("✅ Org verified:", org.address);
  } else {
    console.log("ℹ️  Org already verified");
  }

  // ══════════════════════════════════════════════════════════════
  separator("STEP 2 — Create Campaign");
  // ══════════════════════════════════════════════════════════════

  const deadline     = Math.floor(Date.now() / 1000) + 30 * 24 * 3600; // 30 days
  const goalAmount   = ethers.parseEther("0.01"); // small goal for demo
  const coreAsOrg    = core.connect(org) as typeof core;

  const createTx = await coreAsOrg.createCampaign(
    "QmDemoMetadataCID",
    goalAmount,
    deadline,
    2,        // 2 milestones
    0,        // ETH payment
    "education",
    { value: ethers.parseEther("0.001") }
  );
  const createReceipt = await createTx.wait();

  // Parse campaignId from CampaignCreated event
  const coreInterface = new ethers.Interface([
    "event CampaignCreated(uint256 indexed campaignId, address indexed org, uint256 goal, uint256 deadline)"
  ]);
  let campaignId = 1n;
  for (const log of createReceipt!.logs) {
    try {
      const parsed = coreInterface.parseLog(log);
      if (parsed?.name === "CampaignCreated") {
        campaignId = parsed.args.campaignId;
        break;
      }
    } catch {}
  }
  console.log("✅ Campaign created! ID:", campaignId.toString());

  const campaign = await core.getCampaign(campaignId);
  console.log("   Goal:       ", formatEth(campaign[3]));
  console.log("   Milestones: ", campaign[7].toString());
  console.log("   Status:     ", ["Active","Successful","Failed","Cancelled"][campaign[6]]);

  // ══════════════════════════════════════════════════════════════
  separator("STEP 3 — Donors Donate");
  // ══════════════════════════════════════════════════════════════

  const vaultAsDonor1 = vault.connect(donor1) as typeof vault;
  const vaultAsDonor2 = vault.connect(donor2) as typeof vault;

  const donate1Tx = await vaultAsDonor1.donate(campaignId, { value: ethers.parseEther("0.006") });
  await donate1Tx.wait();
  console.log("✅ Donor1 donated 0.006 ETH");

  const donate2Tx = await vaultAsDonor2.donate(campaignId, { value: ethers.parseEther("0.006") });
  await donate2Tx.wait();
  console.log("✅ Donor2 donated 0.006 ETH");

  const escrow = await vault.getCampaignEscrowBalance(campaignId);
  console.log("   Escrow balance:", formatEth(escrow));

  // Check NFTs
  const donor1NFTs = await nft.getDonorNFTs(donor1.address);
  const donor2NFTs = await nft.getDonorNFTs(donor2.address);
  console.log("   Donor1 NFTs:  ", donor1NFTs.length.toString(), "token(s)");
  console.log("   Donor2 NFTs:  ", donor2NFTs.length.toString(), "token(s)");

  if (donor1NFTs.length > 0) {
    const meta = await nft.getNFTMetadata(donor1NFTs[0]);
    console.log("   Donor1 Tier:  ", TIER_NAMES[meta[2]]);
  }

  // ══════════════════════════════════════════════════════════════
  separator("STEP 4 — Submit Milestone Proof");
  // ══════════════════════════════════════════════════════════════

  const vaultAsOrg = vault.connect(org) as typeof vault;
  const proofTx = await vaultAsOrg.submitMilestoneProof(
    campaignId, 0, "QmMilestone0ProofCID"
  );
  await proofTx.wait();
  console.log("✅ Milestone 0 proof submitted");

  const milestone = await vault.getMilestone(campaignId, 0);
  const proposalId = milestone[3];
  console.log("   Proof CID:    ", milestone[0]);
  console.log("   Release amt:  ", formatEth(milestone[1]));
  console.log("   Proposal ID:  ", proposalId.toString());

  // ══════════════════════════════════════════════════════════════
  separator("STEP 5 — Vote on Proposal");
  // ══════════════════════════════════════════════════════════════

  const daoAsDonor1 = dao.connect(donor1) as typeof dao;
  const daoAsDonor2 = dao.connect(donor2) as typeof dao;

  const vote1Tx = await daoAsDonor1.castVote(proposalId, 1); // For
  await vote1Tx.wait();
  console.log("✅ Donor1 voted: For");

  if (donor2.address !== donor1.address) {
    const vote2Tx = await daoAsDonor2.castVote(proposalId, 1); // For
    await vote2Tx.wait();
    console.log("✅ Donor2 voted: For");
  } else {
    console.log("ℹ️  Skipping Donor2 vote (same address as Donor1 on Sepolia)");
  }

  const proposal = await dao.getProposal(proposalId);
  console.log("   For votes:    ", formatEth(proposal[7]));
  console.log("   Against:      ", formatEth(proposal[8]));
  console.log("   Total power:  ", formatEth(proposal[10]));

  // ══════════════════════════════════════════════════════════════
  separator("STEP 6 — Queue & Execute Proposal");
  // ══════════════════════════════════════════════════════════════

  console.log("⏳ Fast-forwarding past voting period (21600 blocks)...");
  // Note: on Sepolia we can't fast-forward blocks — this step requires waiting
  // For local testing use: await ethers.provider.send("hardhat_mine", ["0x5460"])
  // On Sepolia: run queueProposal manually after voting period ends (~3 days)

  try {
    // Try to mine blocks (works on local Hardhat node)
    await ethers.provider.send("hardhat_mine", ["0x5460"]);
    console.log("✅ Blocks fast-forwarded (local node)");

    const queueTx = await dao.queueProposal(proposalId);
    await queueTx.wait();
    const state = await dao.getProposalState(proposalId);
    console.log("✅ Proposal queued. State:", PROPOSAL_STATES[state]);

    // Fast-forward timelock (24h)
    await ethers.provider.send("evm_increaseTime", [86401]);
    await ethers.provider.send("evm_mine", []);

    const executeTx = await dao.executeProposal(proposalId);
    await executeTx.wait();
    console.log("✅ Proposal executed! Funds released to org.");

    const milestoneAfter = await vault.getMilestone(campaignId, 0);
    console.log("   Milestone released:", milestoneAfter[2]);

  } catch {
    console.log("ℹ️  On Sepolia: manually call queueProposal() after ~3 days voting period");
    console.log("   Then call executeProposal() after 24h timelock");
    console.log("   ProposalId:", proposalId.toString());
  }

  // ══════════════════════════════════════════════════════════════
  separator("STEP 7 — Check Progress");
  // ══════════════════════════════════════════════════════════════

  const [raised, goal, progressBps, , isExpired, timeLeft] =
    await core.getCharityProgress(campaignId);

  console.log("📊 Campaign Progress:");
  console.log("   Raised:    ", formatEth(raised));
  console.log("   Goal:      ", formatEth(goal));
  console.log("   Progress:  ", (Number(progressBps) / 100).toFixed(2) + "%");
  console.log("   Expired:   ", isExpired);
  console.log("   Time left: ", (Number(timeLeft) / 3600).toFixed(1) + " hours");

  separator("✅ Demo Complete!");
  console.log("\nContract addresses:");
  console.log("  CharityCore:  ", CHARITY_CORE_ADDRESS);
  console.log("  DonationVault:", DONATION_VAULT_ADDRESS);
  console.log("  GovernanceDAO:", GOVERNANCE_DAO_ADDRESS);
  console.log("  ImpactNFT:    ", IMPACT_NFT_ADDRESS);
  console.log("\nView on Etherscan (Sepolia):");
  console.log(`  https://sepolia.etherscan.io/address/${DONATION_VAULT_ADDRESS}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
