// Simulated IoT temperature sensor (owner: Rohan Chandrashekar).
//
// What it does:
//   1. Generates a temperature reading for a batch every few seconds
//      (mostly normal, with an occasional spike to simulate a cold-chain failure).
//   2. Keeps every reading OFF-chain in a local log (cheap).
//   3. When a reading leaves the batch's allowed range, it calls
//      MedTrace.recordTemperatureAlert() from the SENSOR_ROLE wallet (on-chain).
//
// Usage:
//   BATCH_ID=1 node offchain/iot-simulator/simulateSensor.js
// Needs in .env: CONTRACT_ADDRESS, SENSOR_PRIVATE_KEY, RPC_URL (defaults to localhost)
//
// DRAFT: structure and flow are defined; marked TODOs are for the interim demo.
require("dotenv").config();
const { ethers } = require("ethers");

const RPC_URL = process.env.RPC_URL || "http://127.0.0.1:8545";
const BATCH_ID = BigInt(process.env.BATCH_ID || 1);
const INTERVAL_MS = 3000;
const SPIKE_CHANCE = 0.1; // 10% of readings are out of range

// Minimal ABI: only the functions the sensor needs.
const ABI = [
  "function getBatch(uint256) view returns (tuple(uint256 id,string productName,string lotNumber,address manufacturer,address currentHolder,address pendingHolder,uint64 manufactureDate,uint64 expiryDate,int16 minTempTenthsC,int16 maxTempTenthsC,uint8 status,bool certified,bool temperatureBreached))",
  "function recordTemperatureAlert(uint256 batchId, int16 readingTenthsC, string logCid)",
];

/** Returns a reading in tenths of a degree C (e.g. 54 = 5.4 C). */
function nextReading(min, max) {
  if (Math.random() < SPIKE_CHANCE) return max + 20 + Math.floor(Math.random() * 60); // too warm
  return min + Math.floor(Math.random() * (max - min + 1)); // normal
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(process.env.SENSOR_PRIVATE_KEY, provider);
  const medTrace = new ethers.Contract(process.env.CONTRACT_ADDRESS, ABI, wallet);

  const batch = await medTrace.getBatch(BATCH_ID);
  const min = Number(batch.minTempTenthsC);
  const max = Number(batch.maxTempTenthsC);
  console.log(`Monitoring batch ${BATCH_ID} (${batch.productName}), allowed ${min / 10}C - ${max / 10}C`);

  const log = []; // full off-chain log of every reading

  setInterval(async () => {
    const reading = nextReading(min, max);
    log.push({ time: new Date().toISOString(), reading });
    console.log(`reading: ${reading / 10}C`);

    if (reading < min || reading > max) {
      // TODO (interim demo): upload `log` to IPFS via offchain/ipfs/uploadToIpfs.js
      // and pass the real CID instead of an empty string.
      const logCid = "";
      const tx = await medTrace.recordTemperatureAlert(BATCH_ID, reading, logCid);
      await tx.wait();
      console.log(`  ALERT recorded on-chain, tx ${tx.hash}`);
    }
  }, INTERVAL_MS);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
