import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/** Read-only sanity check of the V2 Fuji deployment (no transactions). */
async function main() {
  const m = JSON.parse(fs.readFileSync(path.join(__dirname, "../../deployments/43113.json"), "utf8"));
  const v = m.deployments.v2, c = v.contracts;
  const p = ethers.provider;
  const at = (addr: string, abi: string[]) => new ethers.Contract(addr, abi, p);
  const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
  let ok = true;
  const check = (label: string, cond: boolean, detail = "") => {
    console.log(`${cond ? "✓" : "✗"} ${label}${detail ? "  " + detail : ""}`);
    if (!cond) ok = false;
  };

  for (const [name, addr] of Object.entries<string>({ ...c, Safe: v.safe.address })) {
    check(`${name} has code`, (await p.getCode(addr)) !== "0x", addr);
  }

  const safe = at(v.safe.address, ["function getOwners() view returns (address[])", "function getThreshold() view returns (uint256)"]);
  const owners: string[] = await safe.getOwners();
  const threshold = Number(await safe.getThreshold());
  check("Safe threshold == 3", threshold === 3, `got ${threshold}`);
  check("Safe has 5 owners", owners.length === 5, owners.join(", "));
  check("Safe owners match manifest", owners.length === v.safe.owners.length &&
    v.safe.owners.every((o: string) => owners.some((x) => eq(x, o))));

  const ctrl = at(c.DisbursementController, ["function safe() view returns (address)", "function vault() view returns (address)"]);
  check("Controller.safe == Safe", eq(await ctrl.safe(), v.safe.address));
  check("Controller.vault == Vault", eq(await ctrl.vault(), c.DonationVault));

  const vault = at(c.DonationVault, ["function disbursementController() view returns (address)", "function yieldManager() view returns (address)",
    "function governanceDAO() view returns (address)", "function charityCore() view returns (address)"]);
  check("Vault.disbursementController == Controller", eq(await vault.disbursementController(), c.DisbursementController));
  check("Vault.yieldManager == YieldManager", eq(await vault.yieldManager(), c.YieldManager));
  check("Vault.governanceDAO == DAO", eq(await vault.governanceDAO(), c.GovernanceDAO));

  const dao = at(c.GovernanceDAO, ["function donationVault() view returns (address)", "function votingPeriod() view returns (uint256)", "function timelockDelay() view returns (uint256)"]);
  check("DAO.donationVault == Vault", eq(await dao.donationVault(), c.DonationVault));
  console.log(`  DAO votingPeriod=${await dao.votingPeriod()}s timelockDelay=${await dao.timelockDelay()}s`);

  const core = at(c.CharityCore, ["function donationVault() view returns (address)", "function governanceDAO() view returns (address)"]);
  check("Core.donationVault == Vault", eq(await core.donationVault(), c.DonationVault));
  check("Core.governanceDAO == DAO", eq(await core.governanceDAO(), c.GovernanceDAO));

  const nft = at(c.ImpactNFT, ["function donationVault() view returns (address)", "function charityCore() view returns (address)"]);
  check("NFT.donationVault == Vault", eq(await nft.donationVault(), c.DonationVault));
  check("NFT.charityCore == Core", eq(await nft.charityCore(), c.CharityCore));

  const ym = at(c.YieldManager, ["function vault() view returns (address)", "function yieldVault() view returns (address)"]);
  check("YM.vault == Vault", eq(await ym.vault(), c.DonationVault));
  check("YM.yieldVault == Mock4626", eq(await ym.yieldVault(), c.MockERC4626Vault));

  const mv = at(c.MockERC4626Vault, ["function LOSS_SINK() view returns (address)", "function asset() view returns (address)"]);
  check("Mock4626.LOSS_SINK == 0x…dEaD", eq(await mv.LOSS_SINK(), "0x000000000000000000000000000000000000dEaD"));
  console.log(`  Mock4626.asset=${await mv.asset()}`);

  console.log(ok ? "\nALL CHECKS PASSED" : "\nSOME CHECKS FAILED");
  if (!ok) process.exit(1);
}
main().catch((e) => { console.error(e); process.exit(1); });
