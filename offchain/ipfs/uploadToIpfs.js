// IPFS helper (owner: Rohan Chandrashekar).
//
// Uploads a document (Certificate of Analysis, temperature log, shipping record)
// to IPFS through a pinning service and returns its CID. Only the CID is stored
// on-chain (registerBatch / attachDocument / certifyBatch), which keeps gas low
// and keeps large or sensitive files off the public ledger.
//
// Planned provider: Pinata (free tier). Needs PINATA_JWT in .env.
//
// DRAFT: function signatures and flow are defined; implementation is a TODO
// for the interim demo.

/**
 * Upload a file from disk to IPFS.
 * @param {string} filePath  Path to the PDF / JSON / CSV file.
 * @returns {Promise<string>} The IPFS CID (e.g. "bafy...").
 */
async function uploadFile(filePath) {
  // TODO (interim demo): read the file, POST it to
  // https://api.pinata.cloud/pinning/pinFileToIPFS with the PINATA_JWT header,
  // and return response.IpfsHash.
  throw new Error(`uploadFile not implemented yet (${filePath})`);
}

/**
 * Upload a JavaScript object (e.g. a sensor log) as JSON.
 * @param {object} data
 * @param {string} name  Label shown in the Pinata dashboard.
 * @returns {Promise<string>} The IPFS CID.
 */
async function uploadJson(data, name) {
  // TODO (interim demo): POST to /pinning/pinJSONToIPFS and return the CID.
  throw new Error(`uploadJson not implemented yet (${name})`);
}

/**
 * Build a public gateway link so users can open a document in the browser.
 * @param {string} cid
 * @returns {string}
 */
function gatewayUrl(cid) {
  return `https://gateway.pinata.cloud/ipfs/${cid}`;
}

module.exports = { uploadFile, uploadJson, gatewayUrl };
