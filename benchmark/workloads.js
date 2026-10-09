const { submit, evaluate } = require('./gateway');
const { wp, hkdf, randomPii } = require('./crypto');

const CHANNEL_WAREHOUSE = 'warehouse-channel';
const CHANNEL_STUDY     = 'study-channel';
const CC_IDENTITY       = 'identity-mapping';
const CC_WAREHOUSE      = 'warehouse-mapping';
const CC_STUDY          = 'study-mapping';

const MAX_CHUNK = 10000; // must match MAX_BATCH_SIZE in the chaincodes

function chunk(arr, size) {
  const out = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

/**
 * Flow A — pseudonymization: PII -> REF -> WP -> SP.
 *
 * Warehouse phase (A1, A3) can run in parallel across chunks; the datamart
 * phase (A4) is always serial because all chunks share the same datamart
 * map and the chaincode's RegisterSPBatch is not safe for concurrent
 * write-after-write on the same key.
 *
 * `parallelWarehouse` controls A1/A3 parallelism only.
 */
async function flowPseudonymization({
  imConn, wpiConn, spiConn,
  N, studyId, datamartId, wpMasterKey, spMasterKey,
  chunkSize = MAX_CHUNK,
  parallelWarehouse = false,
  registerDatamart = true,
}) {
  const imCc = imConn.gateway.getNetwork(CHANNEL_WAREHOUSE).getContract(CC_IDENTITY);
  const wmCc = wpiConn.gateway.getNetwork(CHANNEL_WAREHOUSE).getContract(CC_WAREHOUSE);
  const piis = Array.from({ length: N }, () => randomPii('bench'));
  const piiChunks = chunk(piis, chunkSize);

  const A1 = [];   // per-chunk, in chunk order
  const A3 = [];   // per-chunk, in chunk order
  const A4 = [];   // per-chunk, in chunk order
  const allRefs = [];
  const allWps  = [];

  // -------------------------------------------------------------------------
  // Phase 1 — warehouse (A1: IM batch, A3: WM batch)
  // -------------------------------------------------------------------------
  let wpsPerChunk;   // string[][]   aligned with piiChunks
  let refsPerChunk;  // string[][]   aligned with piiChunks

  if (parallelWarehouse) {
    // A1 — all chunks in parallel
    const a1Results = await Promise.all(
      piiChunks.map(pc =>
        submit(imCc, 'RegisterIdentityReferenceBatch', [], { piis: JSON.stringify(pc) })
      )
    );
    refsPerChunk = a1Results.map(r => JSON.parse(r.text));
    // record A1 latencies in chunk order
    a1Results.forEach(r => A1.push(r.ms));

    // derive WPs per chunk
    wpsPerChunk = piiChunks.map(pc => pc.map(p => wp(wpMasterKey, p)));

    // A3 — all chunks in parallel
    const a3Results = await Promise.all(
      refsPerChunk.map((refs, i) => {
        const pairs = refs.map((ref, j) => ({
          identityReference: ref,
          wp: wpsPerChunk[i][j],
        }));
        return submit(wmCc, 'RegisterWPBatch', [], { pairs: JSON.stringify(pairs) });
      })
    );
    a3Results.forEach(r => A3.push(r.ms));
  } else {
    refsPerChunk = [];
    wpsPerChunk  = [];
    for (const pc of piiChunks) {
      const r1 = await submit(imCc, 'RegisterIdentityReferenceBatch', [], {
        piis: JSON.stringify(pc),
      });
      const refs = JSON.parse(r1.text);
      A1.push(r1.ms);
      refsPerChunk.push(refs);

      const wps = pc.map(p => wp(wpMasterKey, p));
      wpsPerChunk.push(wps);

      const pairs = refs.map((ref, j) => ({ identityReference: ref, wp: wps[j] }));
      const r3 = await submit(wmCc, 'RegisterWPBatch', [], { pairs: JSON.stringify(pairs) });
      A3.push(r3.ms);
    }
  }

  // flatten for the caller
  for (let i = 0; i < piiChunks.length; i++) {
    allRefs.push(...refsPerChunk[i]);
    allWps.push(...wpsPerChunk[i]);
  }

  // -------------------------------------------------------------------------
  // Phase 2 — datamart (A4) serial, one RegisterSPBatch per chunk
  // -------------------------------------------------------------------------
  if (registerDatamart) {
    const datamartSamples = await registerDatamartBatches({
      spiConn, studyId, datamartId, spMasterKey, wpsPerChunk,
    });
    A4.push(...datamartSamples);
  }

  const sum = a => a.reduce((s, x) => s + x, 0);
  return {
    samples: { A1, A3, A4 },
    totals: { A1: sum(A1), A3: sum(A3), A4: sum(A4), chunks: piiChunks.length },
    refs: allRefs,
    wps: allWps,
    wpChunks: wpsPerChunk,
  };
}

async function registerDatamartBatches({
  spiConn, studyId, datamartId, spMasterKey, wpsPerChunk,
}) {
  const smCc = spiConn.gateway.getNetwork(CHANNEL_STUDY).getContract(CC_STUDY);
  const studyKey = hkdf(spMasterKey, studyId, datamartId);
  const samples = [];

  for (const wps of wpsPerChunk) {
    const r4 = await submit(smCc, 'RegisterSPBatch', [datamartId], {
      studyKey,
      wpList: JSON.stringify(wps),
    });
    samples.push(r4.ms);
  }
  return samples;
}

/**
 * Flow B — re-identification. Single logical operation, no chunking.
 */
async function flowReidentification({
  roConn, wpiConn, moConn,
  wpValue, spiSignature, approvals, reqIdPrefix,
}) {
  const roWReid  = roConn.gateway.getNetwork(CHANNEL_WAREHOUSE).getContract('warehouse-reidentification');
  const wpiWReid = wpiConn.gateway.getNetwork(CHANNEL_WAREHOUSE).getContract('warehouse-reidentification');
  const moWReid  = moConn.gateway.getNetwork(CHANNEL_WAREHOUSE).getContract('warehouse-reidentification');
  const wpiWm    = wpiConn.gateway.getNetwork(CHANNEL_WAREHOUSE).getContract(CC_WAREHOUSE);
  const wpiIm    = wpiConn.gateway.getNetwork(CHANNEL_WAREHOUSE).getContract(CC_IDENTITY);

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

module.exports = {
  flowPseudonymization,
  flowReidentification,
  registerDatamartBatches,
  MAX_CHUNK,
};