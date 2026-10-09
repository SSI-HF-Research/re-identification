const { parentPort, workerData } = require('worker_threads');
const { connectOrg } = require('./gateway');
const { flowPseudonymization, flowReidentification } = require('./workloads');

function formatError(err) {
  const parts = [String((err && err.stack) || err)];
  if (err && err.details) parts.push(`details=${JSON.stringify(err.details)}`);
  if (err && err.cause) parts.push(`cause=${String(err.cause.stack || err.cause)}`);
  return parts.join('\n');
}

async function main() {
  const job = workerData;
  const conns = {};
  try {
    // Multi-thread jobs currently execute pseudonymization only. Keep the
    // worker connection footprint small; reidentification runs in the parent.
    conns.im = await connectOrg('OrgIM');
    conns.wpi = await connectOrg('OrgWPI');
    conns.spi = await connectOrg('OrgSPI');

    const results = [];
    for (const spec of job.specs) {
      if (spec.kind === 'pseudo') {
        // Several workers submit concurrently. Keep each transaction below
        // the peer's practical endorsement timeout while preserving the
        // requested patient count for the sample.
        const chunkSize = job.workerChunkSize || 2500;
        const r = await flowPseudonymization({
          imConn: conns.im, wpiConn: conns.wpi, spiConn: conns.spi,
          N: spec.N, studyId: job.studyId, datamartId: job.datamartId,
          wpMasterKey: job.wpMasterKey, spMasterKey: job.spMasterKey,
          chunkSize,
          // Workers provide the warehouse-level parallelism. Keep A1 -> A3
          // ordered inside each worker so a worker never floods the peers with
          // overlapping phases.
          parallelWarehouse: false,
          registerDatamart: false,
        });
        results.push({
          kind: 'pseudo',
          samples: r.samples,               // { A1, A3, A4 } per-chunk
          totals:  r.totals,                // { A1, A3, A4, chunks } aggregated
          refs: r.refs, wps: r.wps, wpChunks: r.wpChunks,
        });
      } else if (spec.kind === 'reid') {
        conns.ro ??= await connectOrg('OrgRO');
        conns.mo ??= await connectOrg('OrgMO');
        const r = await flowReidentification({
          roConn: conns.ro, wpiConn: conns.wpi, moConn: conns.mo,
          wpValue: spec.wpValue,
          spiSignature: spec.spiSignature,
          approvals: spec.approvals,
          reqIdPrefix: spec.reqIdPrefix,
        });
        results.push({
          kind: 'reid',
          samples: r.samples,
          ok: r.piiFromMo === spec.expectedPii,
        });
      } else {
        throw new Error(`unknown spec kind: ${spec.kind}`);
      }
    }
    parentPort.postMessage({ ok: true, results });
  } catch (err) {
    parentPort.postMessage({ ok: false, error: formatError(err) });
  } finally {
    for (const c of Object.values(conns)) c.close();
  }
}

main();