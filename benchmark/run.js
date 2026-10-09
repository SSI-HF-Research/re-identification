const fs = require('fs');
const path = require('path');
const { Worker } = require('worker_threads');
const { connectOrg, submit } = require('./gateway');
const { wp, hkdf, randomPii } = require('./crypto');
const { report } = require('./stats');
const {
  flowPseudonymization,
  flowReidentification,
  registerDatamartBatches,
} = require('./workloads');

const SCENARIOS = {
  small:  { N: 2000,    samples: 50,  threads: 1 },
  large:  { N: 5000,    samples: 50,  threads: 1 },
  stress: { N: 50000,   samples: 10,  threads: 1 },

  // Multi-thread throughput runs.
  //   N:        patients
  //   samples:  pseudo samples per worker; reid samples = threads * samples
  //   threads:  number of workers
  mt4:    { N: 20000,  samples: 20,  threads: 4  },
  mt8:    { N: 20000,  samples: 20,  threads: 8  },
  mt16:   { N: 20000,  samples: 20,  threads: 16 },
};

const STUDY_ID = 'bench-study';
const DATAMART_ID = 'bench-dm';
const WP_MASTER_KEY = process.env.WP_MASTER_KEY || 'test-wp-master-key';
const SP_MASTER_KEY = process.env.SP_MASTER_KEY || 'test-sp-master-key';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function nowIso() { return new Date().toISOString(); }

async function withConnections(fn) {
  const conns = {
    im:  await connectOrg('OrgIM'),
    wpi: await connectOrg('OrgWPI'),
    spi: await connectOrg('OrgSPI'),
    ro:  await connectOrg('OrgRO'),
    mo:  await connectOrg('OrgMO'),
  };
  try { return await fn(conns); } finally { for (const c of Object.values(conns)) c.close(); }
}

function signWith(orgKey, message) {
  const crypto = require('crypto');
  const fs = require('fs');
  const { identityFor } = require('./identities');
  const id = identityFor(orgKey);
  const keyBytes = fs.readFileSync(id.keyPath);
  const sign = crypto.createSign('SHA256');
  sign.update(message, 'utf8');
  sign.end();
  return sign.sign(keyBytes, 'base64');
}



async function prepareReidFixture(conns) {
  const pii = randomPii('reid');
  const wpValue = wp(WP_MASTER_KEY, pii);

  const imCc = conns.im.gateway.getNetwork('warehouse-channel').getContract('identity-mapping');
  const wmCc = conns.wpi.gateway.getNetwork('warehouse-channel').getContract('warehouse-mapping');

  const r1 = await submit(imCc, 'RegisterIdentityReferenceBatch', [],
    { piis: JSON.stringify([pii]) });
  const ref = JSON.parse(r1.text)[0];

  await submit(wmCc, 'RegisterWPBatch', [],
    { pairs: JSON.stringify([{ identityReference: ref, wp: wpValue }]) });

  return { pii, wpValue, ref };
}

function buildApprovalsAndSig({ reqId, wpValue }) {
  const msgApprove = `reid_approval:${reqId}:approve`;
  const sigEc1 = signWith('OrgEC1', msgApprove);
  const sigEc2 = signWith('OrgEC2', msgApprove);
  const approvals = [
    { mspId: 'OrgEC1MSP', decision: 'approve', signature: sigEc1 },
    { mspId: 'OrgEC2MSP', decision: 'approve', signature: sigEc2 },
  ];
  const spiSig = signWith('OrgSPI', `spi_resolution:${reqId}:${wpValue}`);
  return { approvals, spiSig };
}

// ---------------------------------------------------------------------------
// Single-thread scenario
// ---------------------------------------------------------------------------

async function runSingleThread(name, cfg) {
  console.log(`\n=== scenario=${name} N=${cfg.N} samples=${cfg.samples} (threads=1) ===`);

  return withConnections(async (conns) => {
    const out = {
      scenario: name, config: cfg, mode: 'single-thread',
      studyId: STUDY_ID, datamartId: DATAMART_ID,
      startedAt: nowIso(),
      flows: { pseudonymization: { perChunk: {}, aggregate: {} }, reidentification: {} },
    };

    await flowPseudonymization({
      imConn: conns.im, wpiConn: conns.wpi, spiConn: conns.spi,
      N: Math.min(20, cfg.N), studyId: STUDY_ID, datamartId: DATAMART_ID,
      wpMasterKey: WP_MASTER_KEY, spMasterKey: SP_MASTER_KEY,
    });

    const chunkSamples = { A1: [], A3: [], A4: [] };
    const aggSamples   = { A1: [], A3: [], A4: [] };

    for (let s = 0; s < cfg.samples; s++) {
      const r = await flowPseudonymization({
        imConn: conns.im, wpiConn: conns.wpi, spiConn: conns.spi,
        N: cfg.N, studyId: STUDY_ID, datamartId: DATAMART_ID,
        wpMasterKey: WP_MASTER_KEY, spMasterKey: SP_MASTER_KEY,
      });
      chunkSamples.A1.push(...r.samples.A1);
      chunkSamples.A3.push(...r.samples.A3);
      chunkSamples.A4.push(...r.samples.A4);
      aggSamples.A1.push(r.totals.A1);
      aggSamples.A3.push(r.totals.A3);
      aggSamples.A4.push(r.totals.A4);
      process.stdout.write(`  A sample ${s + 1}/${cfg.samples}  ` +
        `aggA1=${r.totals.A1.toFixed(1)}ms aggA3=${r.totals.A3.toFixed(1)}ms ` +
        `aggA4=${r.totals.A4.toFixed(1)}ms chunks=${r.totals.chunks}\r`);
    }
    process.stdout.write('\n');

    out.flows.pseudonymization.N = cfg.N;
    out.flows.pseudonymization.perChunk.A1 = report('A1-perchunk', chunkSamples.A1);
    out.flows.pseudonymization.perChunk.A3 = report('A3-perchunk', chunkSamples.A3);
    out.flows.pseudonymization.perChunk.A4 = report('A4-perchunk', chunkSamples.A4);
    out.flows.pseudonymization.aggregate.A1 = report('A1-agg', aggSamples.A1);
    out.flows.pseudonymization.aggregate.A3 = report('A3-agg', aggSamples.A3);
    out.flows.pseudonymization.aggregate.A4 = report('A4-agg', aggSamples.A4);

    const fixture = await prepareReidFixture(conns);
    const bSamples = { B0: [], B1: [], B2: [], B3: [], B4: [] };

    for (let s = 0; s < cfg.samples; s++) {
      const reqIdPrefix = `bench-reid-${name}-${Date.now()}-${s}`;
      const { approvals, spiSig } = buildApprovalsAndSig({ reqId: reqIdPrefix, wpValue: fixture.wpValue });

      const r = await flowReidentification({
        roConn: conns.ro, wpiConn: conns.wpi, moConn: conns.mo,
        wpValue: fixture.wpValue, spiSignature: spiSig,
        approvals, reqIdPrefix,
      });
      if (r.piiFromMo !== fixture.pii) throw new Error(`sample ${s}: PII mismatch`);

      bSamples.B0.push(r.samples.B0);
      bSamples.B1.push(r.samples.B1);
      bSamples.B2.push(r.samples.B2);
      bSamples.B3.push(r.samples.B3);
      bSamples.B4.push(r.samples.B4);

      process.stdout.write(`  B sample ${s + 1}/${cfg.samples}  ` +
        `B0=${r.samples.B0.toFixed(1)} B1=${r.samples.B1.toFixed(1)} B2=${r.samples.B2.toFixed(1)} ` +
        `B3=${r.samples.B3.toFixed(1)} B4=${r.samples.B4.toFixed(1)}\r`);
    }
    process.stdout.write('\n');

    out.flows.reidentification.B0 = report('B0', bSamples.B0);
    out.flows.reidentification.B1 = report('B1', bSamples.B1);
    out.flows.reidentification.B2 = report('B2', bSamples.B2);
    out.flows.reidentification.B3 = report('B3', bSamples.B3);
    out.flows.reidentification.B4 = report('B4', bSamples.B4);

    out.finishedAt = nowIso();
    return out;
  });
}

// ---------------------------------------------------------------------------
// Multi-thread throughput
// ---------------------------------------------------------------------------

function runWorker(job) {
  return new Promise((resolve, reject) => {
    const w = new Worker(path.join(__dirname, 'worker.js'), { workerData: job });
    let settled = false;
    w.once('message', (m) => {
      settled = true;
      if (m.ok) resolve(m.results);
      else reject(new Error(`worker ${job.tag} failed:\n${m.error}`));
      void w.terminate();
    });
    w.once('error', (err) => {
      if (!settled) {
        settled = true;
        reject(err);
      }
    });
    w.once('exit', (code) => {
      if (!settled && code !== 0) {
        settled = true;
        reject(new Error(`worker stopped with exit code ${code}`));
      }
    });
  });
}

/**
 * Multi-thread: each worker runs
 *   - S pseudo samples (N patients each, warehouse phase parallel per worker)
 *
 * Note: reidentification is not performed by workers in this implementation.
 *
 * Wall-clock and throughput are measured for the whole run.
 * Pseudo samples are aggregated, mirroring the single-thread output shape so
 * results/*.json are directly comparable.
 */
async function runMultiThread(name, cfg) {
  const patientsPerWorker = cfg.N / cfg.threads;
  if (!Number.isInteger(patientsPerWorker)) {
    throw new Error(`N (${cfg.N}) must be divisible by threads (${cfg.threads})`);
  }

  console.log(`\n=== scenario=${name} N=${cfg.N} ` +
    `(${patientsPerWorker}/worker) samples=${cfg.samples} (threads=${cfg.threads}) ===`);

  // Workers only execute warehouse phases. A4 is committed serially below
  // after every worker has finished, using the single benchmark datamart.
  const perWorkerJobs = Array.from({ length: cfg.threads }, (_, t) => {
    const specs = [];
    for (let s = 0; s < cfg.samples; s++) {
      specs.push({ kind: 'pseudo', N: patientsPerWorker, tag: `t${t}-s${s}` });
    }
    return {
      specs,
      studyId: STUDY_ID,
      datamartId: DATAMART_ID,
      wpMasterKey: WP_MASTER_KEY, spMasterKey: SP_MASTER_KEY,
      tag: t,
    };
  });

  const t0 = process.hrtime.bigint();
  const results = await Promise.all(perWorkerJobs.map(job => runWorker(job)));

  // ---- aggregate pseudo ----
  const chunkA1 = [], chunkA3 = [], chunkA4 = [];
  const aggA1 = [], aggA3 = [], aggA4 = [];
  let totalPseudoOps = 0;
  const flatB = { B0: [], B1: [], B2: [], B3: [], B4: [] };
  let totalReidOps = 0;

  for (const w of results) {
    for (const r of w) {
      if (r.kind !== 'pseudo') continue;
      chunkA1.push(...r.samples.A1);
      chunkA3.push(...r.samples.A3);
      aggA1.push(r.totals.A1);
      aggA3.push(r.totals.A3);
      totalPseudoOps++;
    }
  }

  // ---- datamart: commit A4 serially after all warehouse work ----
  // A4 and reidentification are both serialized in the parent process.
  await withConnections(async (conns) => {
    for (let wIdx = 0; wIdx < results.length; wIdx++) {
      const workerResults = results[wIdx];
      for (let rIdx = 0; rIdx < workerResults.length; rIdx++) {
        const res = workerResults[rIdx];
        if (res.kind !== 'pseudo') continue;

        const a4Samples = await registerDatamartBatches({
          spiConn: conns.spi,
          studyId: STUDY_ID,
          datamartId: DATAMART_ID,
          spMasterKey: SP_MASTER_KEY,
          wpsPerChunk: res.wpChunks,
        });
        chunkA4.push(...a4Samples);
        aggA4.push(a4Samples.reduce((sum, value) => sum + value, 0));
      }
    }

    // ---- reidentification: run in main thread after A4 ----
    for (let wIdx = 0; wIdx < results.length; wIdx++) {
      const workerResults = results[wIdx];
      for (let rIdx = 0; rIdx < workerResults.length; rIdx++) {
        const res = workerResults[rIdx];
        if (res.kind !== 'pseudo') continue;

        // Prepare a tiny reid fixture (single PII + WP) on the network.
        const fixture = await prepareReidFixture(conns);
        const reqIdPrefix = `bench-mt-reid-t${wIdx}-s${rIdx}-${Date.now()}`;
        const { approvals, spiSig } = buildApprovalsAndSig({ reqId: reqIdPrefix, wpValue: fixture.wpValue });

        const rr = await flowReidentification({
          roConn: conns.ro, wpiConn: conns.wpi, moConn: conns.mo,
          wpValue: fixture.wpValue, spiSignature: spiSig,
          approvals, reqIdPrefix,
        });

        flatB.B0.push(rr.samples.B0);
        flatB.B1.push(rr.samples.B1);
        flatB.B2.push(rr.samples.B2);
        flatB.B3.push(rr.samples.B3);
        flatB.B4.push(rr.samples.B4);
        totalReidOps++;
      }
    }
  });

  const t1 = process.hrtime.bigint();
  const wallMs = Number(t1 - t0) / 1e6;

  const out = {
    scenario: name, config: cfg, mode: 'multi-thread',
    threads: cfg.threads, wallMs,
    throughputPseudoOpsPerSec: totalPseudoOps > 0
      ? +(totalPseudoOps / (wallMs / 1000)).toFixed(2) : 0,
    throughputReidOpsPerSec: totalReidOps > 0
      ? +(totalReidOps / (wallMs / 1000)).toFixed(2) : 0,
    flows: {
      pseudonymization: {
        N: cfg.N,
        perChunk: {
          A1: report('A1-perchunk', chunkA1),
          A3: report('A3-perchunk', chunkA3),
          A4: report('A4-perchunk', chunkA4),
        },
        aggregate: {
          A1: report('A1-agg', aggA1),
          A3: report('A3-agg', aggA3),
          A4: report('A4-agg', aggA4),
        },
      },
      reidentification: totalReidOps > 0 ? {
        B0: report('B0', flatB.B0),
        B1: report('B1', flatB.B1),
        B2: report('B2', flatB.B2),
        B3: report('B3', flatB.B3),
        B4: report('B4', flatB.B4),
      } : {},
    },
    startedAt: nowIso(),
    finishedAt: nowIso(),
  };

  console.log(`  wall=${wallMs.toFixed(1)}ms  ` +
    `pseudoOps=${totalPseudoOps} (${out.throughputPseudoOpsPerSec} ops/s)  ` +
    `reidOps=${totalReidOps} (${out.throughputReidOpsPerSec} ops/s)`);
  return out;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const only = process.argv[2];
  const outDir = path.join(__dirname, 'results');
  fs.mkdirSync(outDir, { recursive: true });

  const scenarios = only ? { [only]: SCENARIOS[only] } : SCENARIOS;
  const all = {};

  for (const [name, cfg] of Object.entries(scenarios)) {
    if (!cfg) { console.error(`unknown scenario ${name}`); process.exit(2); }
    const isMt = name.startsWith('mt');
    all[name] = isMt ? await runMultiThread(name, cfg) : await runSingleThread(name, cfg);
    fs.writeFileSync(path.join(outDir, `results-${name}.json`),
      JSON.stringify(all[name], null, 2));
  }

  console.log('\n================ SUMMARY ================');
  for (const [name, r] of Object.entries(all)) {
    console.log(`\n# ${name} (${r.mode})`);
    if (r.mode === 'multi-thread') {
      console.log(`  threads=${r.threads} wall=${r.wallMs.toFixed(1)}ms ` +
        `pseudo=${r.throughputPseudoOpsPerSec} ops/s  ` +
        `reid=${r.throughputReidOpsPerSec} ops/s`);
      const p = r.flows.pseudonymization;
      if (p && p.aggregate) {
        for (const [k, rep] of Object.entries(p.aggregate)) {
          console.log(`  pseudo-agg ${k}  mean=${rep.mean}  median=${rep.median}  stdev=${rep.stdev}`);
        }
      }
      for (const [k, rep] of Object.entries(r.flows.reidentification)) {
        console.log(`  reid ${k}  mean=${rep.mean}  median=${rep.median}  stdev=${rep.stdev}  p95=${rep.p95}`);
      }
      continue;
    }

    const p = r.flows.pseudonymization;
    if (p && p.aggregate) {
      for (const [k, rep] of Object.entries(p.aggregate)) {
        console.log(`  pseudo-agg ${k}  mean=${rep.mean}  median=${rep.median}  stdev=${rep.stdev}`);
      }
    }
    for (const [k, rep] of Object.entries(r.flows.reidentification)) {
      console.log(`  reid ${k}  mean=${rep.mean}  median=${rep.median}  stdev=${rep.stdev}  p95=${rep.p95}`);
    }
  }
}

main().catch(err => { console.error(err); process.exit(1); });