const { parentPort, workerData } = require('worker_threads');
const { connectOrg } = require('./gateway');
const { flowPseudonymization, flowReidentification } = require('./workloads');
const { wp } = require('./crypto');

async function main() {
  const job = workerData;
  const conns = {
    im:  await connectOrg('OrgIM'),
    wpi: await connectOrg('OrgWPI'),
    spi: await connectOrg('OrgSPI'),
    ro:  await connectOrg('OrgRO'),
    mo:  await connectOrg('OrgMO'),
  };
  try {
    const results = [];
    for (const spec of job.specs) {
      if (spec.kind === 'pseudo') {
        const r = await flowPseudonymization({
          imConn: conns.im, wpiConn: conns.wpi, spiConn: conns.spi,
          N: spec.N, studyId: job.studyId, datamartId: job.datamartId,
          wpMasterKey: job.wpMasterKey, spMasterKey: job.spMasterKey,
        });
        results.push({ kind: 'pseudo', samples: r.samples, totals: r.totals });
      } else if (spec.kind === 'reid') {
        const r = await flowReidentification({
          roConn: conns.ro, wpiConn: conns.wpi, moConn: conns.mo,
          wpValue: spec.wpValue,
          spiSignature: spec.spiSignature,
          approvals: spec.approvals,
          reqIdPrefix: spec.reqIdPrefix,
        });
        results.push({ kind: 'reid', samples: r.samples, ok: r.piiFromMo === spec.expectedPii });
      }
    }
    parentPort.postMessage({ ok: true, results });
  } catch (err) {
    parentPort.postMessage({ ok: false, error: String(err && err.stack || err) });
  } finally {
    for (const c of Object.values(conns)) c.close();
  }
}

main();