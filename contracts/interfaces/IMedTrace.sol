// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  IMedTrace
 * @author Team BlockRx (CSE 540, Fall B 2026)
 * @notice Public interface of the MedTrace pharmaceutical provenance system.
 *
 * MedTrace tracks a *batch* (one production lot of one medicine) from the
 * manufacturer, through distributors, to the pharmacy that dispenses it.
 * Every hand-off, status change, document and temperature alert is written
 * on-chain so any participant (or a patient) can verify the batch's history.
 *
 * Design rules that every implementation must follow:
 *  - Only addresses with the right role can write (see MedTraceAccess).
 *  - Large files (certificates, sensor logs) live on IPFS; only their
 *    content identifiers (CIDs) are stored on-chain.
 *  - Every state-changing call appends a HistoryEntry AND emits an event,
 *    so the front end can read history directly or by listening to events.
 *
 * Batch life cycle (status state machine):
 *
 *   Created --transferCustody--> InTransit --confirmReceipt--> Received
 *      ^                                                          |
 *      |                         (next hand-off) <----------------+
 *      |                                                          |
 *   Any status except Dispensed --recallBatch--> Recalled         v
 *                                               Received --markDispensed--> Dispensed
 */
interface IMedTrace {
    // ---------------------------------------------------------------------
    // Data types
    // ---------------------------------------------------------------------

    /// @notice Where a batch is in its life cycle.
    enum BatchStatus {
        Created,    // registered by the manufacturer, still at the factory
        InTransit,  // handed off, waiting for the receiver to confirm
        Received,   // receiver confirmed it holds the batch
        Dispensed,  // pharmacy gave the medicine to patients (end of chain)
        Recalled    // regulator pulled the batch from the market (end of chain)
    }

    /// @notice Kind of off-chain document linked to a batch.
    enum DocType {
        CertificateOfAnalysis, // lab quality report from the manufacturer
        TemperatureLog,        // full sensor log for a shipment
        ShippingRecord,        // bill of lading, invoice, etc.
        RegulatorCertificate,  // approval issued by the regulator
        Other
    }

    /// @notice Kind of action recorded in a batch's history.
    enum ActionType {
        Registered,
        CustodyTransferred,
        ReceiptConfirmed,
        Dispensed,
        DocumentAttached,
        TemperatureAlert,
        Certified,
        Recalled
    }

    /// @notice Core on-chain record for one batch.
    struct Batch {
        uint256 id;               // auto-incremented, starts at 1
        string productName;       // e.g. "Amoxicillin 500mg"
        string lotNumber;         // manufacturer's lot number printed on the box
        address manufacturer;     // wallet that registered the batch
        address currentHolder;    // wallet that physically holds it now
        address pendingHolder;    // receiver during a hand-off (0x0 otherwise)
        uint64 manufactureDate;   // unix timestamp (set at registration)
        uint64 expiryDate;        // unix timestamp
        int16 minTempTenthsC;     // allowed storage range, in tenths of a degree C
        int16 maxTempTenthsC;     //   (e.g. 20 = 2.0 C, 80 = 8.0 C for cold chain)
        BatchStatus status;
        bool certified;           // regulator has approved this batch
        bool temperatureBreached; // at least one out-of-range reading was reported
    }

    /// @notice One line of a batch's audit trail.
    struct HistoryEntry {
        ActionType action;
        address actor;       // who performed the action
        BatchStatus status;  // batch status right after the action
        uint64 timestamp;
        string details;      // free text or an IPFS CID, depending on the action
    }

    /// @notice A document stored on IPFS and linked to a batch.
    struct Document {
        DocType docType;
        string cid;          // IPFS content identifier
        address uploadedBy;
        uint64 timestamp;
    }

    // ---------------------------------------------------------------------
    // Events (one per state-changing action; the front end listens to these)
    // ---------------------------------------------------------------------

    event BatchRegistered(uint256 indexed batchId, address indexed manufacturer, string productName, string lotNumber);
    event CustodyTransferred(uint256 indexed batchId, address indexed from, address indexed to);
    event ReceiptConfirmed(uint256 indexed batchId, address indexed receiver);
    event BatchDispensed(uint256 indexed batchId, address indexed pharmacy);
    event DocumentAttached(uint256 indexed batchId, DocType docType, string cid, address indexed uploadedBy);
    event TempAlert(uint256 indexed batchId, int16 readingTenthsC, string logCid);
    event BatchCertified(uint256 indexed batchId, address indexed regulator, string certificateCid);
    event BatchRecalled(uint256 indexed batchId, address indexed regulator, string reason);

    // ---------------------------------------------------------------------
    // Manufacturer
    // ---------------------------------------------------------------------

    /**
     * @notice Create a new batch record. Caller becomes manufacturer and first holder.
     * @dev    Only MANUFACTURER_ROLE. Expiry must be in the future and
     *         minTemp must be lower than maxTemp.
     * @param  productName   Human-readable product name.
     * @param  lotNumber     Lot number printed on the packaging.
     * @param  expiryDate    Unix timestamp when the batch expires.
     * @param  minTempTenthsC Lowest allowed storage temperature (tenths of C).
     * @param  maxTempTenthsC Highest allowed storage temperature (tenths of C).
     * @param  coaCid        IPFS CID of the Certificate of Analysis (may be empty).
     * @return batchId       ID assigned to the new batch.
     */
    function registerBatch(
        string calldata productName,
        string calldata lotNumber,
        uint64 expiryDate,
        int16 minTempTenthsC,
        int16 maxTempTenthsC,
        string calldata coaCid
    ) external returns (uint256 batchId);

    // ---------------------------------------------------------------------
    // Custody (manufacturer -> distributor -> pharmacy)
    // ---------------------------------------------------------------------

    /**
     * @notice Step 1 of a hand-off: current holder sends the batch to `to`.
     * @dev    Only the current holder. `to` must be a registered Distributor
     *         or Pharmacy. Status becomes InTransit until the receiver confirms.
     */
    function transferCustody(uint256 batchId, address to) external;

    /**
     * @notice Step 2 of a hand-off: receiver confirms it physically has the batch.
     * @dev    Only the pending holder. Two-step hand-off means both sides sign,
     *         so neither party can fake a delivery on its own.
     */
    function confirmReceipt(uint256 batchId) external;

    /**
     * @notice Pharmacy marks the batch as dispensed to patients (final state).
     * @dev    Only a PHARMACY_ROLE holder that currently holds the batch.
     *         Rejected if the batch is recalled or expired.
     */
    function markDispensed(uint256 batchId) external;

    // ---------------------------------------------------------------------
    // Documents and sensors (off-chain data anchored on-chain)
    // ---------------------------------------------------------------------

    /**
     * @notice Link an IPFS document (certificate, shipping record, log) to a batch.
     * @dev    Allowed for the current holder or a regulator.
     */
    function attachDocument(uint256 batchId, DocType docType, string calldata cid) external;

    /**
     * @notice Report an out-of-range temperature reading from the IoT simulator.
     * @dev    Only SENSOR_ROLE (the simulator's wallet). The reading must be
     *         outside the batch's allowed range; normal readings stay off-chain
     *         to save gas. Sets `temperatureBreached` permanently.
     */
    function recordTemperatureAlert(uint256 batchId, int16 readingTenthsC, string calldata logCid) external;

    // ---------------------------------------------------------------------
    // Regulator
    // ---------------------------------------------------------------------

    /// @notice Regulator approves a batch after reviewing its documents.
    function certifyBatch(uint256 batchId, string calldata certificateCid) external;

    /// @notice Regulator recalls a batch; it can no longer be moved or dispensed.
    function recallBatch(uint256 batchId, string calldata reason) external;

    // ---------------------------------------------------------------------
    // Read-only views (anyone, including patients, can call these for free)
    // ---------------------------------------------------------------------

    /// @notice Full on-chain record of one batch.
    function getBatch(uint256 batchId) external view returns (Batch memory);

    /// @notice Complete audit trail of one batch, oldest first.
    function getHistory(uint256 batchId) external view returns (HistoryEntry[] memory);

    /// @notice All IPFS documents linked to one batch.
    function getDocuments(uint256 batchId) external view returns (Document[] memory);

    /**
     * @notice One-call summary used by the patient "verify my medicine" page.
     * @return exists     The batch ID was registered by a real manufacturer.
     * @return safeToUse  exists AND certified AND not recalled AND not expired
     *                    AND no temperature breach.
     * @return status     Current life-cycle status.
     * @return holder     Wallet currently holding the batch.
     */
    function verifyBatch(uint256 batchId)
        external
        view
        returns (bool exists, bool safeToUse, BatchStatus status, address holder);

    /// @notice Number of batches registered so far.
    function totalBatches() external view returns (uint256);
}
