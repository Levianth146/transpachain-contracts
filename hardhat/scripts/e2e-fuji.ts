/**
 * TranspaChain V2 — full E2E on Avalanche Fuji (Topic 5 / G4).
 *
 *   npx hardhat run hardhat/scripts/e2e-fuji.ts --network fuji
 *
 * Uses DEPLOYER_PRIVATE_KEY (admin/verifier/yield owner) from contracts/.env. Creates fresh demo wallets
 * (Org, Donor1, Donor2) funded by the deployer and saves them to contracts/.e2e-wallets.local.json
 * (gitignored) so you can import them into MetaMask for the UI/video. Testnet only.
 *
 * Safe 3/5 step:
 *   - default: the script PAUSES and asks 3 Safe owners to sign + execute in the web UI (tests the real UI path);
 *   - or set SAFE_OWNER_KEYS=0x..,0x..,0x.. (3 owner keys) in contracts/.env to sign automatically.
 *     Signatures are also POSTed to the backend (BACKEND_URL, default http://localhost:3001) to test /api/safe.
 *
 * Needs on the deployer: ≥0.01 AVAX (Fuji gas is ~free; org pays 2×0.001 AVAX campaign deposits) and ~9 USDC (Circle Fuji). Takes ~10 min (300 s vote + 120 s timelock).
 * Writes a tx log to ../docs/e2e-run-<timestamp>.md.
 */
import { ethers, network } from "hardhat";
import { NonceManager } from "ethers";
import * as fs from "fs";
import * as path from "path";
import * as crypto from "crypto";
import * as readline from "readline";

const ROOT = path.join(__dirname, "../..");
const DOCS = path.join(ROOT, "..", "docs");
const MANIFEST = path.join(ROOT, "deployments/43113.json");
const WALLETS = path.join(ROOT, ".e2e-wallets.local.json");
const EXPLORER = "https://testnet.snowtrace.io";
const BACKEND = (process.env.BACKEND_URL || "http://localhost:3001").replace(/\/$/, "");
const FRONTEND = (process.env.FRONTEND_URL || "http://localhost:3000").replace(/\/$/, "");
const U = (n: number) => BigInt(Math.round(n * 1e6)); // USDC 6 decimals

const log: string[] = [];
function rec(step: string, hash?: string, extra = "") {
  const line = hash ? `| ${step} | [${hash.slice(0, 10)}…](${EXPLORER}/tx/${hash}) | ${extra} |` : `| ${step} | — | ${extra} |`;
  log.push(line);
  console.log(`✓ ${step}${hash ? "  " + EXPLORER + "/tx/" + hash : ""}${extra ? "  " + extra : ""}`);
}
async function send(step: string, p: Promise<any>, extra = "") {
  const tx = await p;
  const r = await tx.wait();
  if (r.status !== 1) throw new Error(`${step} reverted (${tx.hash})`);
  rec(step, tx.hash, extra);
  return r;
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function waitUntil(ts: bigint, label: string) {
  for (;;) {
    const now = BigInt((await ethers.provider.getBlock("latest"))!.timestamp);
    if (now > ts) return;
    const left = Number(ts - now) + 3;
    console.log(`  … waiting ${left}s for ${label}`);
    await sleep(Math.min(left, 30) * 1000);
  }
}
async function backendPost(pathname: string, body: unknown) {
  try {
    const r = await fetch(`${BACKEND}${pathname}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
    return { ok: r.ok, status: r.status, json: await r.json().catch(() => ({})) };
  } catch (e) { return { ok: false, status: 0, json: { error: (e as Error).message } }; }
}
async function pinJSON(meta: Record<string, unknown>, fallback: string) {
  const r = await backendPost("/ipfs/metadata", meta);
  if (r.ok && (r.json as any).cid) return (r.json as any).cid as string;
  console.log(`  ! IPFS via backend failed (${r.status} ${(r.json as any).error ?? ""}) → using placeholder CID`);
  return fallback;
}

async function main() {
  if (network.name !== "fuji") throw new Error("Run with --network fuji");
  const m = JSON.parse(fs.readFileSync(MANIFEST, "utf8")).deployments.v2;
  const c = m.contracts;
  const [deployer] = await ethers.getSigners();
  const usdcAddr = process.env.USDC_ADDRESS || "0x5425890298aed601595a70AB815c96711a31Bc65";

  const usdc: any = await ethers.getContractAt("@openzeppelin/contracts/token/ERC20/IERC20.sol:IERC20", usdcAddr);
  const core = await ethers.getContractAt("CharityCore", c.CharityCore);
  const vault = await ethers.getContractAt("DonationVault", c.DonationVault);
  const dao = await ethers.getContractAt("GovernanceDAO", c.GovernanceDAO);
  const ctrl = await ethers.getContractAt("DisbursementController", c.DisbursementController);
  const ym = await ethers.getContractAt("YieldManager", c.YieldManager);
  const mock = await ethers.getContractAt("MockERC4626Vault", c.MockERC4626Vault);
  const safe = new ethers.Contract(m.safe.address, [
    "function nonce() view returns (uint256)",
    "function getOwners() view returns (address[])",
    "function getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256) view returns (bytes32)",
    "function execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes) payable returns (bool)",
  ], ethers.provider);

  const avax = await ethers.provider.getBalance(deployer.address);
  const usdcBal = await usdc.balanceOf(deployer.address);
  console.log(`Deployer ${deployer.address}: ${ethers.formatEther(avax)} AVAX, ${ethers.formatUnits(usdcBal, 6)} USDC`);
  const NEED_USDC = U(8.5);
  if (usdcBal < NEED_USDC) throw new Error(`Deployer needs ≥ 8.5 USDC (faucet.circle.com → Avalanche Fuji). Has ${ethers.formatUnits(usdcBal, 6)}`);
  if (avax < ethers.parseEther("0.01")) throw new Error("Deployer needs ≥ 0.01 AVAX");

  // ── demo wallets ────────────────────────────────────────────────────────────
  let saved: Record<string, string> = {};
  if (fs.existsSync(WALLETS)) saved = JSON.parse(fs.readFileSync(WALLETS, "utf8"));
  const mk = (k: string) => { if (!saved[k]) saved[k] = ethers.Wallet.createRandom().privateKey; return new ethers.Wallet(saved[k], ethers.provider); };
  const org = mk("org"), d1 = mk("donor1"), d2 = mk("donor2");
  fs.writeFileSync(WALLETS, JSON.stringify(saved, null, 2));
  // Load-balanced public RPCs can return a stale pending nonce right after a tx is mined
  // ("nonce too low"). Track nonces locally per wallet instead of asking the RPC each time.
  const managers = new Map<string, NonceManager>();
  const S = (w: { address: string }) => {
    const k = w.address.toLowerCase();
    if (!managers.has(k)) managers.set(k, new NonceManager(w as any));
    return managers.get(k)!;
  };
  console.log(`Demo wallets (keys in ${path.basename(WALLETS)}): org ${org.address}, donor1 ${d1.address}, donor2 ${d2.address}`);
  log.push(`Demo wallets: Org \`${org.address}\`, Donor1 \`${d1.address}\`, Donor2 \`${d2.address}\`, Safe \`${m.safe.address}\``, "", "| Step | Tx | Detail |", "|---|---|---|");

  for (const [w, a] of [[org, "0.02"], [d1, "0.005"], [d2, "0.005"]] as const) {
    if ((await ethers.provider.getBalance(w.address)) < ethers.parseEther(a) / 2n)
      await send(`Fund ${w.address.slice(0, 8)} with ${a} AVAX`, S(deployer).sendTransaction({ to: w.address, value: ethers.parseEther(a) }));
  }
  for (const [w, amt] of [[d1, U(4)], [d2, U(4)]] as const) {
    const bal = await usdc.balanceOf(w.address);
    if (bal < amt) await send(`Fund ${w.address.slice(0, 8)} with USDC`, usdc.connect(S(deployer)).transfer(w.address, amt - bal));
  }
  if (!(await core.isOrgVerified(org.address))) await send("Admin verifies org", core.connect(S(deployer)).verifyOrg(org.address));

  // ── Campaign A: USDC, yield on, milestone paid via DAO + Safe ────────────────
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 7 * 86400);
  const cidA = await pinJSON({ title: "E2E · Thư viện cho trẻ em vùng cao", description: "Demo campaign for Topic 5 E2E (USDC + yield + Safe payout).", category: "Education", orgName: "TranspaChain Demo Org", goalAmount: "50" }, "bafkreie2etranspachaindemocampaignaplaceholder");
  const rA = await send("Org creates USDC campaign A", core.connect(S(org)).createCampaign(cidA, U(50), deadline, 2, 1, "Education", { value: ethers.parseEther("0.001") }));
  const campA = (rA.logs.map((l: any) => { try { return core.interface.parseLog(l); } catch { return null; } }).find((e: any) => e?.name === "CampaignCreated") as any).args.campaignId as bigint;
  rec("Campaign A id", undefined, `#${campA} — ${FRONTEND}/campaigns/${campA}`);

  for (const [w, amt, name] of [[d1, U(3), "Donor1"], [d2, U(3), "Donor2"]] as const) {
    await send(`${name} approves USDC`, usdc.connect(S(w)).approve(c.DonationVault, amt));
    await send(`${name} donates ${ethers.formatUnits(amt, 6)} USDC to A`, vault.connect(S(w)).donateUSDC(campA, amt));
  }
  rec("Escrow A after donations", undefined, `${ethers.formatUnits(await vault.getCampaignEscrowBalance(campA), 6)} USDC (net of 1% fee)`);

  await send("Org enables yield on A", ym.connect(S(org)).setYieldEnabled(campA, true));
  const investable = await ym.previewInvestable(campA);
  if (investable > 0n) {
    const minShares = ((await mock.previewDeposit(investable)) * 99n) / 100n;
    await send(`Admin allocates ${ethers.formatUnits(investable, 6)} USDC to Mock ERC-4626`, ym.connect(S(deployer)).allocate(campA, investable, minShares));
    const yieldAmt = U(0.2);
    await send("Mock controller approves yield top-up", usdc.connect(S(deployer)).approve(c.MockERC4626Vault, yieldAmt));
    await send("simulateYield +0.20 USDC (MOCK)", mock.connect(S(deployer)).simulateYield(yieldAmt));
    rec("Position A value", undefined, `${ethers.formatUnits(await ym.positionValue(campA), 6)} USDC vs principal ${ethers.formatUnits((await ym.getPosition(campA)).principal, 6)}`);
  } else console.log("  ! previewInvestable = 0, skipping allocation");

  const proofCid = await pinJSON({ title: "E2E milestone 0 proof", description: "Invoice + photos for milestone 0 (demo).", category: "proof", orgName: "TranspaChain Demo Org", goalAmount: "0" }, "bafkreie2etranspachainmilestone0proofplaceholder");
  await send("Org submits milestone 0 proof", vault.connect(S(org)).submitMilestoneProof(campA, 0, proofCid));
  const pid = await dao.getActiveProposal(campA);
  const ms = await vault.getMilestone(campA, 0);
  rec("Proposal created", undefined, `#${pid}, releaseAmount ${ethers.formatUnits(ms.releaseAmount, 6)} USDC — ${FRONTEND}/governance/${pid}`);

  await send("Donor1 votes For", dao.connect(S(d1)).castVote(pid, 1));
  await send("Donor2 votes For", dao.connect(S(d2)).castVote(pid, 1));
  const prop = await dao.getProposal(pid);
  await waitUntil(prop.endTime, "voting window");
  await send("Queue proposal (quorum + majority)", dao.connect(S(deployer)).queueProposal(pid));
  const queued = await dao.getProposal(pid);
  await waitUntil(queued.executeAfter, "timelock");
  await send("Execute proposal → milestone APPROVED (no transfer)", dao.connect(S(deployer)).executeProposal(pid));
  const orgBefore = await usdc.balanceOf(org.address);
  rec("Org USDC before payout", undefined, ethers.formatUnits(orgBefore, 6));

  const receipt = `TranspaChain E2E receipt\ncampaign ${campA} milestone 0\namount ${ethers.formatUnits(ms.releaseAmount, 6)} USDC\n${new Date().toISOString()}\n`;
  fs.mkdirSync(DOCS, { recursive: true });
  const receiptPath = path.join(DOCS, `e2e-receipt-campaign${campA}.txt`);
  fs.writeFileSync(receiptPath, receipt);
  const receiptHash = "0x" + crypto.createHash("sha256").update(Buffer.from(receipt)).digest("hex");
  const validUntil = BigInt(Math.floor(Date.now() / 1000) + 3 * 86400);
  await send("Org requests disbursement (receipt SHA-256 committed)", ctrl.connect(S(org)).requestDisbursement(campA, 0, receiptHash, "e2e-local-receipt", validUntil), `sha256 ${receiptHash.slice(0, 18)}… file docs/${path.basename(receiptPath)}`);
  const requestId = await ctrl.getPendingRequestId(campA, 0);
  rec("Disbursement request", undefined, `#${requestId} — ${FRONTEND}/expenses/${requestId}`);

  // ── Safe 3/5 ────────────────────────────────────────────────────────────────
  const ownerKeys = (process.env.SAFE_OWNER_KEYS || "").split(",").map((s) => s.trim()).filter(Boolean);
  if (ownerKeys.length >= 3) {
    const data = ctrl.interface.encodeFunctionData("executeDisbursement", [requestId]);
    const ZERO = ethers.ZeroAddress;
    const nonce = await safe.nonce();
    const safeTxHash: string = await safe.getTransactionHash(c.DisbursementController, 0, data, 0, 0, 0, 0, ZERO, ZERO, nonce);
    const owners = (await safe.getOwners()).map((a: string) => a.toLowerCase());
    const sigs: { signer: string; signature: string }[] = [];
    for (const k of ownerKeys.slice(0, 3)) {
      const w = new ethers.Wallet(k);
      if (!owners.includes(w.address.toLowerCase())) throw new Error(`SAFE_OWNER_KEYS contains a non-owner ${w.address}`);
      const b = ethers.getBytes(await w.signMessage(ethers.getBytes(safeTxHash)));
      b[64] += 4; // Safe eth_sign convention (same as frontend/lib/safe.ts)
      const signature = ethers.hexlify(b);
      sigs.push({ signer: w.address, signature });
      const post = await backendPost(`/api/safe/${requestId}/signatures`, { signer: w.address, signature, safeTxHash });
      rec(`Owner ${w.address.slice(0, 8)} signs (off-chain)`, undefined, post.ok ? "stored by backend ✓" : `backend ${post.status} ${(post.json as any).error ?? ""}`);
    }
    sigs.sort((a, b) => a.signer.toLowerCase().localeCompare(b.signer.toLowerCase()));
    const packed = "0x" + sigs.map((s) => s.signature.slice(2)).join("");
    await send("Safe execTransaction → executeDisbursement (3/5)", (safe.connect(S(deployer)) as any).execTransaction(c.DisbursementController, 0, data, 0, 0, 0, 0, ZERO, ZERO, packed));
  } else {
    console.log(`\n>>> SAFE STEP — do this in the web UI now:
    1. Open ${FRONTEND}/campaigns/${campA} → Disbursement panel (request #${requestId}).
    2. Switch MetaMask to Safe Owner 1 → Sign. Repeat with Owner 2 and Owner 3.
    3. With any account that has AVAX → Execute.
    The script continues automatically once the request is Executed (checks every 15 s, up to 45 min).\n`);
    const t0 = Date.now();
    for (;;) {
      const r = await ctrl.getRequest(requestId);
      if (Number(r.status) === 1) { rec("Safe 3/5 executed via web UI", undefined, `request #${requestId}`); break; }
      if (Date.now() - t0 > 45 * 60_000) throw new Error("Timed out waiting for Safe execution");
      await sleep(15_000);
    }
  }
  const orgAfter = await usdc.balanceOf(org.address);
  rec("Org USDC after payout", undefined, `${ethers.formatUnits(orgAfter, 6)} (+${ethers.formatUnits(orgAfter - orgBefore, 6)}; yield redeemed for shortfall if needed)`);

  // ── Campaign B: refund after yield ──────────────────────────────────────────
  const cidB = await pinJSON({ title: "E2E · Campaign bị huỷ (refund demo)", description: "Cancelled to demonstrate fair refunds after yield.", category: "Community", orgName: "TranspaChain Demo Org", goalAmount: "50" }, "bafkreie2etranspachaindemocampaignbplaceholder");
  const rB = await send("Org creates USDC campaign B", core.connect(S(org)).createCampaign(cidB, U(50), deadline, 2, 1, "Community", { value: ethers.parseEther("0.001") }));
  const campB = (rB.logs.map((l: any) => { try { return core.interface.parseLog(l); } catch { return null; } }).find((e: any) => e?.name === "CampaignCreated") as any).args.campaignId as bigint;
  for (const [w, name] of [[d1, "Donor1"], [d2, "Donor2"]] as const) {
    await send(`${name} approves USDC (B)`, usdc.connect(S(w)).approve(c.DonationVault, U(1)));
    await send(`${name} donates 1 USDC to B`, vault.connect(S(w)).donateUSDC(campB, U(1)));
  }
  await send("Org enables yield on B", ym.connect(S(org)).setYieldEnabled(campB, true));
  const invB = await ym.previewInvestable(campB);
  if (invB > 0n) await send(`Admin allocates ${ethers.formatUnits(invB, 6)} USDC (B)`, ym.connect(S(deployer)).allocate(campB, invB, ((await mock.previewDeposit(invB)) * 99n) / 100n));
  await send("Org cancels campaign B", core.connect(S(org)).cancelCampaign(campB));
  if (invB > 0n) {
    try { await vault.connect(S(d1)).claimRefund.staticCall(campB); console.log("  ! claimRefund did NOT revert before settlement (unexpected)"); }
    catch { rec("claimRefund blocked until yield settled", undefined, "RefundPendingLiquidity ✓"); }
    await send("Anyone settles yield for refund (redeemAll)", vault.connect(S(d1)).settleYieldForRefund(campB));
  }
  for (const [w, name] of [[d1, "Donor1"], [d2, "Donor2"]] as const) {
    const before = await usdc.balanceOf(w.address);
    await send(`${name} claims refund (B)`, vault.connect(S(w)).claimRefund(campB));
    rec(`${name} refunded`, undefined, `${ethers.formatUnits((await usdc.balanceOf(w.address)) - before, 6)} USDC`);
  }

  // ── backend reconciliation ─────────────────────────────────────────────────
  for (const id of [campA, campB]) {
    try {
      const r = await fetch(`${BACKEND}/api/campaigns/${id}/reconciliation`);
      rec(`Backend reconciliation campaign ${id}`, undefined, `HTTP ${r.status} ${JSON.stringify(await r.json()).slice(0, 160)}`);
    } catch (e) { rec(`Backend reconciliation campaign ${id}`, undefined, `unreachable: ${(e as Error).message}`); }
  }

  const out = path.join(DOCS, `e2e-run-${new Date().toISOString().replace(/[:.]/g, "-")}.md`);
  fs.writeFileSync(out, [`# E2E run on Avalanche Fuji (${new Date().toISOString()})`, "", `Manifest v2, block ${m.deployBlock}.`, "", ...log, "", `Public pages (no wallet): ${FRONTEND}/transparency · ${FRONTEND}/expenses/${requestId}`, ""].join("\n"));
  console.log(`\nE2E COMPLETE → ${out}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
