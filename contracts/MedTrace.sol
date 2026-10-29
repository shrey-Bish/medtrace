// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMedTrace} from "./interfaces/IMedTrace.sol";
import {MedTraceAccess} from "./access/MedTraceAccess.sol";

/**
 * @title  MedTrace
 * @author Team BlockRx (CSE 540, Fall B 2026)
 * @notice Main MedTrace contract: stores pharmaceutical batches, their custody
 *         chain, linked IPFS documents and temperature alerts.
 *
 * How the pieces fit together (see docs/architecture.png):
 *  - The React web app (frontend/) sends signed transactions from each
 *    stakeholder's MetaMask wallet to the functions below.
 *  - Documents are uploaded to IPFS first (offchain/ipfs/); only the returned
 *    CID is passed to registerBatch / attachDocument / certifyBatch.
 *  - The IoT simulator (offchain/iot-simulator/) watches readings off-chain and
 *    calls recordTemperatureAlert only when a reading is out of range.
 *  - Patients call verifyBatch / getHistory (free view calls, no wallet needed).
 *
 * Storage layout:
 *  - _batches[id]    : the current state of each batch
 *  - _history[id]    : append-only audit trail (never edited or deleted)
 *  - _documents[id]  : IPFS documents linked to the batch
 *
 * DRAFT STATUS (Smart Contract Design Draft, due 11/01/2026):
 *  Interfaces, roles, storage and core rules are in place. Items marked
 *  "TODO" are planned for the interim demo / final phase.
 */
contract MedTrace is IMedTrace, MedTraceAccess {
    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    uint256 private _batchCount; // also the ID of the most recent batch

    mapping(uint256 => Batch) private _batches;
    mapping(uint256 => HistoryEntry[]) private _history;
    mapping(uint256 => Document[]) private _documents;

    // TODO (final phase): optional lookup by lot number so a patient can scan
    // the lot printed on the box instead of the numeric batch ID.

    // ---------------------------------------------------------------------
    // Modifiers (shared checks used by several functions)
    // ---------------------------------------------------------------------

    /// @dev Reverts if the batch ID was never registered.
    modifier batchExists(uint256 batchId) {
        require(batchId > 0 && batchId <= _batchCount, "MedTrace: batch not found");
        _;
    }

    /// @dev Reverts unless the caller physically holds the batch right now.
    modifier onlyHolder(uint256 batchId) {
        require(_batches[batchId].currentHolder == msg.sender, "MedTrace: caller is not the holder");
        _;
    }

    /// @dev Recalled and dispensed batches are frozen: no more moves allowed.
    modifier notFinal(uint256 batchId) {
        BatchStatus s = _batches[batchId].status;
        require(s != BatchStatus.Recalled, "MedTrace: batch is recalled");
        require(s != BatchStatus.Dispensed, "MedTrace: batch already dispensed");
        _;
    }

    /// @param admin Wallet that will onboard participants (usually the deployer).
    constructor(address admin) MedTraceAccess(admin) {}

    // ---------------------------------------------------------------------
    // Manufacturer
    // ---------------------------------------------------------------------

    /// @inheritdoc IMedTrace
    function registerBatch(
        string calldata productName,
        string calldata lotNumber,
        uint64 expiryDate,
        int16 minTempTenthsC,
        int16 maxTempTenthsC,
        string calldata coaCid
    ) external onlyRole(MANUFACTURER_ROLE) returns (uint256 batchId) {
        require(bytes(productName).length > 0, "MedTrace: empty product name");
        require(bytes(lotNumber).length > 0, "MedTrace: empty lot number");
        require(expiryDate > block.timestamp, "MedTrace: already expired");
        require(minTempTenthsC < maxTempTenthsC, "MedTrace: bad temperature range");

        batchId = ++_batchCount;

        // Write the batch record. The manufacturer is the first holder.
        Batch storage b = _batches[batchId];
        b.id = batchId;
        b.productName = productName;
        b.lotNumber = lotNumber;
        b.manufacturer = msg.sender;
        b.currentHolder = msg.sender;
        b.manufactureDate = uint64(block.timestamp);
        b.expiryDate = expiryDate;
        b.minTempTenthsC = minTempTenthsC;
        b.maxTempTenthsC = maxTempTenthsC;
        b.status = BatchStatus.Created;

        _record(batchId, ActionType.Registered, productName);
        emit BatchRegistered(batchId, msg.sender, productName, lotNumber);

        // The Certificate of Analysis is optional at registration time.
        if (bytes(coaCid).length > 0) {
            _addDocument(batchId, DocType.CertificateOfAnalysis, coaCid);
        }
    }

    // ---------------------------------------------------------------------
    // Custody
    // ---------------------------------------------------------------------

    /// @inheritdoc IMedTrace
    function transferCustody(uint256 batchId, address to)
        external
        batchExists(batchId)
        onlyHolder(batchId)
        notFinal(batchId)
    {
        Batch storage b = _batches[batchId];
        // A batch can only leave once the previous hand-off is finished.
        require(
            b.status == BatchStatus.Created || b.status == BatchStatus.Received,
            "MedTrace: hand-off already in progress"
        );
        require(to != msg.sender, "MedTrace: cannot transfer to self");
        require(_canReceiveBatch(to), "MedTrace: receiver not a distributor or pharmacy");

        b.pendingHolder = to;
        b.status = BatchStatus.InTransit;

        _record(batchId, ActionType.CustodyTransferred, "");
        emit CustodyTransferred(batchId, msg.sender, to);
    }

    /// @inheritdoc IMedTrace
    function confirmReceipt(uint256 batchId) external batchExists(batchId) notFinal(batchId) {
        Batch storage b = _batches[batchId];
        require(b.status == BatchStatus.InTransit, "MedTrace: batch not in transit");
        require(b.pendingHolder == msg.sender, "MedTrace: caller is not the receiver");

        b.currentHolder = msg.sender;
        b.pendingHolder = address(0);
        b.status = BatchStatus.Received;

        _record(batchId, ActionType.ReceiptConfirmed, "");
        emit ReceiptConfirmed(batchId, msg.sender);
    }

    /// @inheritdoc IMedTrace
    function markDispensed(uint256 batchId)
        external
        onlyRole(PHARMACY_ROLE)
        batchExists(batchId)
        onlyHolder(batchId)
        notFinal(batchId)
    {
        Batch storage b = _batches[batchId];
        require(b.status == BatchStatus.Received, "MedTrace: batch not received yet");
        require(block.timestamp < b.expiryDate, "MedTrace: batch expired");
        // TODO (interim demo): decide whether a temperature breach should block
        // dispensing outright, or only warn the pharmacist in the UI.

        b.status = BatchStatus.Dispensed;

        _record(batchId, ActionType.Dispensed, "");
        emit BatchDispensed(batchId, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Documents and sensors
    // ---------------------------------------------------------------------

    /// @inheritdoc IMedTrace
    function attachDocument(uint256 batchId, DocType docType, string calldata cid)
        external
        batchExists(batchId)
    {
        require(
            _batches[batchId].currentHolder == msg.sender || hasRole(REGULATOR_ROLE, msg.sender),
            "MedTrace: only holder or regulator"
        );
        require(bytes(cid).length > 0, "MedTrace: empty CID");
        _addDocument(batchId, docType, cid);
    }

    /// @inheritdoc IMedTrace
    function recordTemperatureAlert(uint256 batchId, int16 readingTenthsC, string calldata logCid)
        external
        onlyRole(SENSOR_ROLE)
        batchExists(batchId)
        notFinal(batchId)
    {
        Batch storage b = _batches[batchId];
        // Only out-of-range readings are worth paying gas for.
        require(
            readingTenthsC < b.minTempTenthsC || readingTenthsC > b.maxTempTenthsC,
            "MedTrace: reading is within range"
        );

        b.temperatureBreached = true;

        _record(batchId, ActionType.TemperatureAlert, logCid);
        emit TempAlert(batchId, readingTenthsC, logCid);

        // Keep the full sensor log with the batch's other documents.
        if (bytes(logCid).length > 0) {
            _addDocument(batchId, DocType.TemperatureLog, logCid);
        }
    }

    // ---------------------------------------------------------------------
    // Regulator
    // ---------------------------------------------------------------------

    /// @inheritdoc IMedTrace
    function certifyBatch(uint256 batchId, string calldata certificateCid)
        external
        onlyRole(REGULATOR_ROLE)
        batchExists(batchId)
        notFinal(batchId)
    {
        Batch storage b = _batches[batchId];
        require(!b.certified, "MedTrace: already certified");

        b.certified = true;

        _record(batchId, ActionType.Certified, certificateCid);
        emit BatchCertified(batchId, msg.sender, certificateCid);

        if (bytes(certificateCid).length > 0) {
            _addDocument(batchId, DocType.RegulatorCertificate, certificateCid);
        }
    }

    /// @inheritdoc IMedTrace
    function recallBatch(uint256 batchId, string calldata reason)
        external
        onlyRole(REGULATOR_ROLE)
        batchExists(batchId)
        notFinal(batchId)
    {
        require(bytes(reason).length > 0, "MedTrace: reason required");

        Batch storage b = _batches[batchId];
        b.status = BatchStatus.Recalled;
        b.pendingHolder = address(0); // cancel any hand-off in progress

        _record(batchId, ActionType.Recalled, reason);
        emit BatchRecalled(batchId, msg.sender, reason);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IMedTrace
    function getBatch(uint256 batchId) external view batchExists(batchId) returns (Batch memory) {
        return _batches[batchId];
    }

    /// @inheritdoc IMedTrace
    /// @dev TODO (final phase): add a paginated version if histories get long.
    function getHistory(uint256 batchId) external view batchExists(batchId) returns (HistoryEntry[] memory) {
        return _history[batchId];
    }

    /// @inheritdoc IMedTrace
    function getDocuments(uint256 batchId) external view batchExists(batchId) returns (Document[] memory) {
        return _documents[batchId];
    }

    /// @inheritdoc IMedTrace
    function verifyBatch(uint256 batchId)
        external
        view
        returns (bool exists, bool safeToUse, BatchStatus status, address holder)
    {
        // Unknown IDs return exists = false instead of reverting, so the
        // patient page can show "not found" (likely counterfeit) cleanly.
        if (batchId == 0 || batchId > _batchCount) {
            return (false, false, BatchStatus.Created, address(0));
        }

        Batch storage b = _batches[batchId];
        exists = true;
        status = b.status;
        holder = b.currentHolder;
        safeToUse = b.certified
            && b.status != BatchStatus.Recalled
            && !b.temperatureBreached
            && block.timestamp < b.expiryDate;
    }

    /// @inheritdoc IMedTrace
    function totalBatches() external view returns (uint256) {
        return _batchCount;
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    /// @dev Append one line to the batch's audit trail using the current status.
    function _record(uint256 batchId, ActionType action, string memory details) private {
        _history[batchId].push(
            HistoryEntry({
                action: action,
                actor: msg.sender,
                status: _batches[batchId].status,
                timestamp: uint64(block.timestamp),
                details: details
            })
        );
    }

    /// @dev Store an IPFS document reference, log it, and emit DocumentAttached.
    function _addDocument(uint256 batchId, DocType docType, string memory cid) private {
        _documents[batchId].push(
            Document({docType: docType, cid: cid, uploadedBy: msg.sender, timestamp: uint64(block.timestamp)})
        );
        _record(batchId, ActionType.DocumentAttached, cid);
        emit DocumentAttached(batchId, docType, cid, msg.sender);
    }
}
