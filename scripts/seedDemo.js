// Local demo data: deploys MedTrace, onboards one wallet per role, and walks
// one batch from factory to pharmacy. Handy for front-end development.
// Usage (in a second terminal after `npx hardhat node`):
//   npx hardhat run scripts/seedDemo.js --network localhost
const { ethers } = require("hardhat");

async function main() {
  const [admin, maker, distributor, pharmacy, regulator, sensor] = await ethers.getSigners();

  const medTrace = await (await ethers.getContractFactory("MedTrace")).deploy(admin.address);
  await medTrace.waitForDeployment();
  console.log("MedTrace:", await medTrace.getAddress());

  // 1. Onboard participants (admin only).
  const roles = [
    [maker, "MANUFACTURER_ROLE", "Acme Pharma"],
    [distributor, "DISTRIBUTOR_ROLE", "FastMed Logistics"],
    [pharmacy, "PHARMACY_ROLE", "Tempe Pharmacy"],
    [regulator, "REGULATOR_ROLE", "Drug Regulator"],
    [sensor, "SENSOR_ROLE", "IoT Simulator"],
  ];
  for (const [signer, roleName, name] of roles) {
    await medTrace.registerParticipant(signer.address, await medTrace[roleName](), name);
    console.log(`  ${name.padEnd(18)} ${roleName.padEnd(18)} ${signer.address}`);
  }

  // 2. Register a cold-chain batch (2.0 C - 8.0 C), valid for one year.
  const block = await ethers.provider.getBlock("latest");
  const expiry = block.timestamp + 365 * 24 * 60 * 60;
  await medTrace.connect(maker).registerBatch("Insulin 100IU", "LOT-2026-001", expiry, 20, 80, "");

  // 3. Regulator certifies, then the batch moves down the chain.
  await medTrace.connect(regulator).certifyBatch(1, "");
  await medTrace.connect(maker).transferCustody(1, distributor.address);
  await medTrace.connect(distributor).confirmReceipt(1);
  await medTrace.connect(distributor).transferCustody(1, pharmacy.address);
  await medTrace.connect(pharmacy).confirmReceipt(1);

  const [exists, safe, status, holder] = await medTrace.verifyBatch(1);
  console.log(`Batch 1 -> exists: ${exists}, safe: ${safe}, status: ${status}, holder: ${holder}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
