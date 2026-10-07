const fs = require('fs');
const path = require('path');
const { Worker } = require('worker_threads');
const { connectOrg } = require('./gateway');
const { wp, hkdf, randomPii } = require('./crypto');
const { report } = require('./stats');
const { flowPseudonymization, flowReidentification } = require('./workloads');

const SCENARIOS = {
  small:  { N: 1000,    samples: 100,  threads: 1 },
  large:  { N: 5000,  samples: 20,  threads: 1 },
  stress: { N: 50000, samples: 10,  threads: 1 },   // single-thread throughput
  // Multi-thread throughput runs (independent of N):
  mt4:    { N: 5000,  samples: 20,  threads: 4 },
  mt16:   { N: 5000,  samples: 20,  threads: 16 },
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

/**
 * Prepare a reusable (ref, wp, pii) triple on the warehouse channel and keep
 * a signer to produce per-request approvals + SPI attestations.
 */
async function prepareReidFixture(conns) {
  const pii = randomPii('reid');
  const wpValue = wp(WP_MASTER_KEY, pii);

  const imCc = conns.im.gateway.getNetwork('warehouse-channel').getContract('identity-mapping');
  const wmCc = conns.wpi.gateway.getNetwork('warehouse-channel').getContract('warehouse-mapping');

  // Register identity + WP with the correct API
  const refsJson = await imCc.submit('RegisterIdentityReferenceBatch', {
    transientData: { piis: JSON.stringify([pii]) },
  });
  const ref = JSON.parse(new TextDecoder().decode(refsJson))[0];

  await wmCc.submit('RegisterWPBatch', {
    transientData: {
      pairs: JSON.stringify([{ identityReference: ref, wp: wpValue }]),
    },
  });

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

    // Warm-up (discarded)
    await flowPseudonymization({
      imConn: conns.im, wpiConn: conns.wpi, spiConn: conns.spi,
      N: Math.min(20, cfg.N), studyId: STUDY_ID, datamartId: DATAMART_ID,
      wpMasterKey: WP_MASTER_KEY, spMasterKey: SP_MASTER_KEY,
    });

    // ---- Flow A ----
    // We collect per-chunk samples (flattened across samples) AND aggregate
    // totals (one per logical N-patient ingestion).
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

    // ---- Flow B ----
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
    w.once('message', (m) => m.ok ? resolve(m.results) : reject(new Error(m.error)));
    w.once('error', reject);
  });
}

/**
 * Multi-thread mode: T workers each running S samples concurrently.
 * We measure wall-clock throughput (ops/s) for the whole pool.
 *
 * The workload for each worker is `reid` jobs against a per-worker fixture,
 * so they don't collide on reqId.
 */
async function runMultiThread(name, cfg) {
  console.log(`\n=== scenario=${name} N=${cfg.N} samples=${cfg.samples} (threads=${cfg.threads}) ===`);

  // 1) Prepare one fixture + pre-computed signatures per worker.
  const fixtures = await withConnections(async (conns) => {
    const arr = [];
    for (let t = 0; t < cfg.threads; t++) {
      const f = await prepareReidFixture(conns);
      arr.push(f);
    }
    return arr;
  });

  // 2) Build one spec list per worker.
  const perWorkerJobs = fixtures.map((f, t) => {
    const specs = [];
    for (let s = 0; s < cfg.samples; s++) {
      const reqIdPrefix = `mt-${name}-t${t}-s${s}-${Date.now()}`;
      const { approvals, spiSig } = buildApprovalsAndSig({ reqId: reqIdPrefix, wpValue: f.wpValue });
      specs.push({
        kind: 'reid',
        wpValue: f.wpValue,
        spiSignature: spiSig,
        approvals,
        reqIdPrefix,
        expectedPii: f.pii,
      });
    }
    return specs;
  });

  // 3) Launch workers in parallel and measure wall-clock.
  const t0 = process.hrtime.bigint();
  const results = await Promise.all(perWorkerJobs.map((specs, t) => runWorker({
    specs,
    studyId: STUDY_ID, datamartId: DATAMART_ID,
    wpMasterKey: WP_MASTER_KEY, spMasterKey: SP_MASTER_KEY,
  })));
  const t1 = process.hrtime.bigint();
  const wallMs = Number(t1 - t0) / 1e6;

  // 4) Aggregate per-operation samples across all workers.
  const flat = { B0: [], B1: [], B2: [], B3: [], B4: [] };
  let totalOps = 0;
  for (const w of results) {
    for (const r of w) {
      if (r.kind !== 'reid') continue;
      flat.B0.push(r.samples.B0);
      flat.B1.push(r.samples.B1);
      flat.B2.push(r.samples.B2);
      flat.B3.push(r.samples.B3);
      flat.B4.push(r.samples.B4);
      totalOps++;
    }
  }

  const out = {
    scenario: name, config: cfg, mode: 'multi-thread',
    threads: cfg.threads, wallMs,
    throughputOpsPerSec: +(totalOps / (wallMs / 1000)).toFixed(2),
    flows: {
      reidentification: {
        B0: report('B0', flat.B0),
        B1: report('B1', flat.B1),
        B2: report('B2', flat.B2),
        B3: report('B3', flat.B3),
        B4: report('B4', flat.B4),
      },
    },
    startedAt: nowIso(),
    finishedAt: nowIso(),
  };

  console.log(`  wall=${wallMs.toFixed(1)}ms  ops=${totalOps}  ` +
    `throughput=${out.throughputOpsPerSec} ops/s`);
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

  // ---- Summary ----
  console.log('\n================ SUMMARY ================');
  for (const [name, r] of Object.entries(all)) {
    console.log(`\n# ${name} (${r.mode})`);
    if (r.mode === 'multi-thread') {
      console.log(`  threads=${r.threads} wall=${r.wallMs.toFixed(1)}ms ` +
        `throughput=${r.throughputOpsPerSec} ops/s`);
      for (const [k, rep] of Object.entries(r.flows.reidentification)) {
        console.log(`  ${k}  mean=${rep.mean}  median=${rep.median}  stdev=${rep.stdev}  p95=${rep.p95}`);
      }
      continue;
    }
    // single-thread
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