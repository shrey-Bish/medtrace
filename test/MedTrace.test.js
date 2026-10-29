// Draft test suite for MedTrace (owner: Neric Joel, Testing & Deployment Lead).
// Covers the main happy path plus the key permission and state rules.
// TODO (interim demo): add tests for documents, expiry edge cases and gas usage.
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("MedTrace", function () {
  let medTrace, admin, maker, distributor, pharmacy, regulator, sensor, stranger;
  const ONE_YEAR = 365 * 24 * 60 * 60;
  const Status = { Created: 0, InTransit: 1, Received: 2, Dispensed: 3, Recalled: 4 };

  // Deploy a fresh contract and onboard one wallet per role before each test.
  beforeEach(async function () {
    [admin, maker, distributor, pharmacy, regulator, sensor, stranger] = await ethers.getSigners();
    const MedTrace = await ethers.getContractFactory("MedTrace");
    medTrace = await MedTrace.deploy(admin.address);

    await medTrace.registerParticipant(maker.address, await medTrace.MANUFACTURER_ROLE(), "Acme Pharma");
    await medTrace.registerParticipant(distributor.address, await medTrace.DISTRIBUTOR_ROLE(), "FastMed Logistics");
    await medTrace.registerParticipant(pharmacy.address, await medTrace.PHARMACY_ROLE(), "Tempe Pharmacy");
    await medTrace.registerParticipant(regulator.address, await medTrace.REGULATOR_ROLE(), "Drug Regulator");
    await medTrace.registerParticipant(sensor.address, await medTrace.SENSOR_ROLE(), "IoT Simulator");
  });

  // Helper: manufacturer registers a cold-chain batch (2.0 C to 8.0 C).
  async function registerSampleBatch() {
    const expiry = (await time.latest()) + ONE_YEAR;
    await medTrace.connect(maker).registerBatch("Insulin 100IU", "LOT-001", expiry, 20, 80, "QmCoaCid");
    return 1n;
  }

  it("registers a batch with the manufacturer as first holder", async function () {
    const id = await registerSampleBatch();
    const batch = await medTrace.getBatch(id);
    expect(batch.manufacturer).to.equal(maker.address);
    expect(batch.currentHolder).to.equal(maker.address);
    expect(batch.status).to.equal(Status.Created);
    expect(await medTrace.totalBatches()).to.equal(1n);
  });

  it("blocks batch registration from non-manufacturers", async function () {
    const expiry = (await time.latest()) + ONE_YEAR;
    await expect(
      medTrace.connect(stranger).registerBatch("Fake", "LOT-X", expiry, 20, 80, "")
    ).to.be.revertedWithCustomError(medTrace, "AccessControlUnauthorizedAccount");
  });

  it("moves a batch from manufacturer to pharmacy and dispenses it", async function () {
    const id = await registerSampleBatch();

    await expect(medTrace.connect(maker).transferCustody(id, distributor.address))
      .to.emit(medTrace, "CustodyTransferred").withArgs(id, maker.address, distributor.address);
    await medTrace.connect(distributor).confirmReceipt(id);
    await medTrace.connect(distributor).transferCustody(id, pharmacy.address);
    await medTrace.connect(pharmacy).confirmReceipt(id);
    await medTrace.connect(pharmacy).markDispensed(id);

    const batch = await medTrace.getBatch(id);
    expect(batch.status).to.equal(Status.Dispensed);
    expect(batch.currentHolder).to.equal(pharmacy.address);

    // Registered, CoA doc, 2 transfers, 2 receipts, dispensed = 7 history lines.
    const history = await medTrace.getHistory(id);
    expect(history.length).to.equal(7);
  });

  it("only lets the intended receiver confirm a hand-off", async function () {
    const id = await registerSampleBatch();
    await medTrace.connect(maker).transferCustody(id, distributor.address);
    await expect(medTrace.connect(pharmacy).confirmReceipt(id)).to.be.revertedWith(
      "MedTrace: caller is not the receiver"
    );
  });

  it("records temperature alerts only for out-of-range readings", async function () {
    const id = await registerSampleBatch();
    await expect(medTrace.connect(sensor).recordTemperatureAlert(id, 50, "QmLog")).to.be.revertedWith(
      "MedTrace: reading is within range"
    );
    await expect(medTrace.connect(sensor).recordTemperatureAlert(id, 120, "QmLog"))
      .to.emit(medTrace, "TempAlert").withArgs(id, 120, "QmLog");
    expect((await medTrace.getBatch(id)).temperatureBreached).to.equal(true);
  });

  it("lets a regulator certify and recall, and freezes recalled batches", async function () {
    const id = await registerSampleBatch();
    await medTrace.connect(regulator).certifyBatch(id, "QmCert");
    let [, safe] = await medTrace.verifyBatch(id);
    expect(safe).to.equal(true);

    await medTrace.connect(regulator).recallBatch(id, "Contamination found");
    [, safe] = await medTrace.verifyBatch(id);
    expect(safe).to.equal(false);
    await expect(medTrace.connect(maker).transferCustody(id, distributor.address)).to.be.revertedWith(
      "MedTrace: batch is recalled"
    );
  });

  it("reports unknown batch IDs as not existing (possible counterfeit)", async function () {
    const [exists, safe] = await medTrace.verifyBatch(999);
    expect(exists).to.equal(false);
    expect(safe).to.equal(false);
  });
});
