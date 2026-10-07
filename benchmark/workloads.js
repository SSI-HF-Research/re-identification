const { submit, evaluate } = require('./gateway');
const { wp, hkdf, randomPii } = require('./crypto');

const CHANNEL_WAREHOUSE = 'warehouse-channel';
const CHANNEL_STUDY     = 'study-channel';
const CC_IDENTITY       = 'identity-mapping';
const CC_WAREHOUSE      = 'warehouse-mapping';
const CC_STUDY          = 'study-mapping';

const MAX_CHUNK = 1000; // must match MAX_BATCH_SIZE in the chaincodes

function chunk(arr, size) {
  const out = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

/**
 * Flow A — pseudonymization: PII -> REF -> WP -> SP.
 * One datamart, one study. Batches are automatically split into chunks of
 * MAX_CHUNK to respect the chaincode limit.
 *
 * Returns per-chunk latencies and the aggregate (sum) so callers can report
 * both "per-batch" and "per-N-patients" numbers.
 */
async function flowPseudonymization({
  imConn, wpiConn, spiConn,
  N, studyId, datamartId, wpMasterKey, spMasterKey,
  chunkSize = MAX_CHUNK,
}) {
  const imCc = imConn.gateway.getNetwork(CHANNEL_WAREHOUSE).getContract(CC_IDENTITY);
  const wmCc = wpiConn.gateway.getNetwork(CHANNEL_WAREHOUSE).getContract(CC_WAREHOUSE);
  const smCc = spiConn.gateway.getNetwork(CHANNEL_STUDY).getContract(CC_STUDY);

  const piis = Array.from({ length: N }, () => randomPii('bench'));
  const piiChunks = chunk(piis, chunkSize);

  const A1 = []; // per-chunk IM batch latency
  const A3 = []; // per-chunk WM batch latency
  const A4 = []; // per-chunk SM batch latency
  const refsAll = [];
  const wpsAll  = [];

  for (const piiChunk of piiChunks) {
    // [A1] IdentityMapping batch
    const r1 = await submit(imCc, 'RegisterIdentityReferenceBatch', [], {
      piis: JSON.stringify(piiChunk),
    });
    const refs = JSON.parse(r1.text);
    A1.push(r1.ms);

    // [A2] client-side WP derivation
    const wps = piiChunk.map(p => wp(wpMasterKey, p));
    const pairs = refs.map((r, i) => ({ identityReference: r, wp: wps[i] }));

    // [A3] WarehouseMapping batch
    const r3 = await submit(wmCc, 'RegisterWPBatch', [], {
      pairs: JSON.stringify(pairs),
    });
    A3.push(r3.ms);

    // [A4] StudyMapping batch (same datamart for all chunks)
    const studyKey = hkdf(spMasterKey, studyId, datamartId);
    const r4 = await submit(smCc, 'RegisterSPBatch', [datamartId], {
      studyKey,
      wpList: JSON.stringify(wps),
    });
    A4.push(r4.ms);

    refsAll.push(...refs);
    wpsAll.push(...wps);
  }

  const sum = a => a.reduce((s, x) => s + x, 0);
  return {
    // per-chunk samples (useful for stats)
    samples: { A1, A3, A4 },
    // aggregate (sum over chunks) — one "logical operation" for N patients
    totals: { A1: sum(A1), A3: sum(A3), A4: sum(A4), chunks: piiChunks.length },
    refs: refsAll,
    wps: wpsAll,
  };
}

/**
 * Flow B — re-identification. Same as before; a single logical operation,
 * no chunking needed (the request is per-patient by design).
 */
async function flowReidentification({
  roConn, wpiConn, moConn,
  wpValue, spiSignature, approvals, reqIdPrefix,
}) {
  const roWReid = roConn.gateway.getNetwork(CHANNEL_WAREHOUSE).getContract('warehouse-reidentification');
  const wpiWReid = wpiConn.gateway.getNetwork(CHANNEL_WAREHOUSE).getContract('warehouse-reidentification');
  const moWReid = moConn.gateway.getNetwork(CHANNEL_WAREHOUSE).getContract('warehouse-reidentification');
  const wpiWm   = wpiConn.gateway.getNetwork(CHANNEL_WAREHOUSE).getContract(CC_WAREHOUSE);
  const wpiIm   = wpiConn.gateway.getNetwork(CHANNEL_WAREHOUSE).getContract(CC_IDENTITY);

  // Signatures are created by the caller for this exact request ID.
  const reqId = reqIdPrefix;

  const b0 = await submit(roWReid, 'CreateWarehouseReIDRequest', [reqId], {
    wp: wpValue,
    spiSignature,
    approvals: JSON.stringify(approvals),
  });
  const b1 = await evaluate(wpiWm, 'GetIdentityReferenceByWP', [wpValue]);
  const ref = b1.text;
  const b2 = await evaluate(wpiIm, 'GetPii', [ref]);
  const pii = b2.text;
  const b3 = await submit(wpiWReid, 'RegisterReIdentifiedPII', [reqId], { pii });
  const b4 = await evaluate(moWReid, 'GetReidentifiedPII', [reqId]);

  return {
    samples: { B0: b0.ms, B1: b1.ms, B2: b2.ms, B3: b3.ms, B4: b4.ms },
    reqId, ref, pii, piiFromMo: b4.text,
  };
}

module.exports = { flowPseudonymization, flowReidentification, MAX_CHUNK };