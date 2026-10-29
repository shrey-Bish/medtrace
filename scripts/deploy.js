// Deploys MedTrace and makes the deployer the admin.
// Usage:
//   npx hardhat run scripts/deploy.js --network localhost
//   npx hardhat run scripts/deploy.js --network amoy
const { ethers, network } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`Deploying MedTrace to "${network.name}" from ${deployer.address}`);

  const MedTrace = await ethers.getContractFactory("MedTrace");
  const medTrace = await MedTrace.deploy(deployer.address);
  await medTrace.waitForDeployment();

  const address = await medTrace.getAddress();
  console.log(`MedTrace deployed at: ${address}`);
  console.log("Next: copy this address into frontend/.env and offchain/.env (CONTRACT_ADDRESS).");
  // TODO (interim demo): write the address + ABI to frontend/src/contract.json automatically.
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
