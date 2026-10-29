# MedTrace Web dApp (planned)

**Owner:** Vaibhav Abhiramacheri. **Target:** Interim Demo (11/15/2026)

**Stack:** React (Vite), Ethers.js v6, MetaMask

## Planned pages

| Page | User | Contract calls |
|---|---|---|
| Connect wallet | Everyone | Detects role with `hasRole` and shows the matching dashboard |
| Admin | Network operator | `registerParticipant`, `removeParticipant` |
| Manufacturer | Drug maker | `registerBatch`, `transferCustody`, `attachDocument` |
| Distributor | Wholesaler | `confirmReceipt`, `transferCustody` |
| Pharmacy | Pharmacist | `confirmReceipt`, `markDispensed` |
| Regulator | Health authority | `certifyBatch`, `recallBatch` |
| **Verify my medicine** | Patient (no wallet) | `verifyBatch`, `getHistory`, `getDocuments` (read-only) |

The verify page will accept a batch ID typed in or scanned from a QR code, and show a green "Safe to use" or red "Do not use" result with the full custody timeline.

## Setup (to be added)

```bash
cd frontend
npm create vite@latest . -- --template react
npm install ethers
```

The contract address and ABI (from `artifacts/contracts/MedTrace.sol/MedTrace.json`) will be loaded from `src/contract.json`.
