#!/usr/bin/env node
// Measures latency via fabric-gateway with a persistent connection.
//
// Usage:
//   node gateway-baseline.js [--submit] [--transient <json>] [--endorsing-orgs <msp,...>] <org> <channel> <cc> <method> [args...]
//
// Examples:
//   node gateway-baseline.js OrgWPI warehouse-channel identity-mapping testChaincode
//   node gateway-baseline.js OrgSPI study-channel study-mapping GetSPListByDatamart dm-1
//   node gateway-baseline.js --submit OrgEC1 study-channel study-reidentification \
//        RegisterCommitteeMember "<PEM>"

const fs = require('fs');
const crypto = require('crypto');
const path = require('path');
const { execFileSync } = require('child_process');
const grpc = require('@grpc/grpc-js');
const { connect, signers } = require('@hyperledger/fabric-gateway');

const ROOT = path.resolve(__dirname, '../..');
const ITER = Number(process.env.ITER || 100);
const WARMUP = Number(process.env.WARMUP || 10);

// ---- arg parsing (flags before positional) ----
const rawArgs = process.argv.slice(2);
let SUBMIT = false;
let TRANSIENT = null;
let ENDORSING_ORGS = null;
let FRESH_REGISTER_WP = false;
const positional = [];
for (let i = 0; i < rawArgs.length; i++) {
  const a = rawArgs[i];
  if (a === '--submit') { SUBMIT = true; continue; }
  if (a === '--transient') { TRANSIENT = JSON.parse(rawArgs[++i]); continue; }
  if (a === '--endorsing-orgs') {
    ENDORSING_ORGS = rawArgs[++i].split(',');
    continue;
  }
  if (a === '--fresh-register-wp') { FRESH_REGISTER_WP = true; continue; }
  positional.push(a);
}
const [org, channel, chaincode, method, ...args] = positional;
if (!org || !channel || !chaincode || !method) {
  console.error('Usage: gateway-baseline.js [--submit] [--transient <json>] [--endorsing-orgs <msp,...>] <org> <channel> <cc> <method> [args...]');
  process.exit(1);
}

const ORG_MAP = {
  OrgIM:  { domain: 'im.example.com',  port: 7051,  msp: 'OrgIMMSP'  },
  OrgWPI: { domain: 'wpi.example.com', port: 8051,  msp: 'OrgWPIMSP' },
  OrgHDW: { domain: 'hdw.example.com', port: 9051,  msp: 'OrgHDWMSP' },
  OrgSC:  { domain: 'sc.example.com',  port: 10051, msp: 'OrgSCMSP'  },
  OrgSPI: { domain: 'spi.example.com', port: 11051, msp: 'OrgSPIMSP' },
  OrgRO:  { domain: 'ro.example.com',  port: 12051, msp: 'OrgROMSP'  },
  OrgMO:  { domain: 'mo.example.com',  port: 13051, msp: 'OrgMOMSP'  },
  OrgEC1: { domain: 'ec1.example.com', port: 14051, msp: 'OrgEC1MSP' },
  OrgEC2: { domain: 'ec2.example.com', port: 15051, msp: 'OrgEC2MSP' },
  OrgEC3: { domain: 'ec3.example.com', port: 16051, msp: 'OrgEC3MSP' },
};

function loadMsp(domain) {
  const base = path.join(ROOT, 'network/crypto-config/peerOrganizations', domain,
    `users/Admin@${domain}/msp`);
  const cert = fs.readFileSync(path.join(base, 'signcerts', fs.readdirSync(path.join(base, 'signcerts'))[0]));
  const key  = fs.readFileSync(path.join(base, 'keystore',  fs.readdirSync(path.join(base, 'keystore'))[0]));
  return { cert, key };
}

function loadTlsCa(domain) {
  return fs.readFileSync(path.join(ROOT, 'network/crypto-config/peerOrganizations',
    domain, 'peers', `peer0.${domain}/tls/ca.crt`));
}

async function main() {
  const { domain, port, msp } = ORG_MAP[org];
  const tlsCert = loadTlsCa(domain);
  const { cert, key } = loadMsp(domain);

  const client = new grpc.Client(`localhost:${port}`,
    grpc.credentials.createSsl(tlsCert), {
      'grpc.ssl_target_name_override': `peer0.${domain}`,
      'grpc.default_authority': `peer0.${domain}`,
    });

  const gateway = connect({
    client,
    identity: { mspId: msp, credentials: cert },
    signer: signers.newPrivateKeySigner(crypto.createPrivateKey(key)),
    evaluateOptions: () => ({ deadline: Date.now() + 30000 }),
    endorseOptions:  () => ({ deadline: Date.now() + 30000 }),
    submitOptions:   () => ({ deadline: Date.now() + 30000 }),
    commitStatusOptions: () => ({ deadline: Date.now() + 30000 }),
  });

  const contract = gateway.getNetwork(channel).getContract(chaincode);

  let callArgs = args;
  let callTransient = TRANSIENT;

  function prepareFreshRegisterWP(iteration) {
    const pii = `gw-write-pii-${iteration}-${crypto.randomBytes(4).toString('hex')}`;
    const ref = `gw-write-ref-${iteration}-${crypto.randomBytes(4).toString('hex')}`;
    const wp = execFileSync(process.execPath, [
      path.join(ROOT, 'scripts/test/crypto-helper.js'), 'wp',
      process.env.WP_MASTER_KEY, pii,
    ], { encoding: 'utf8' }).trim();

    execFileSync(path.join(ROOT, 'scripts/invokeCC.sh'), [
      'warehouse-channel', 'identity-mapping',
      '{"function":"RegisterIdentityReference","Args":[]}',
      JSON.stringify({ pii, identityReference: ref }),
      'OrgIM', 'OrgIM', 'OrgWPI',
    ], { stdio: 'ignore' });

    callArgs = [ref];
    callTransient = { wp };
  }

  async function call() {
    if (SUBMIT) {
      if (callTransient) {
        await contract.submit(method, {
          arguments: callArgs,
          transientData: callTransient,
          endorsingOrganizations: ENDORSING_ORGS || undefined,
        });
      } else {
        await contract.submit(method, {
          arguments: callArgs,
          endorsingOrganizations: ENDORSING_ORGS || undefined,
        });
      }
    } else {
      await contract.evaluateTransaction(method, ...callArgs);
    }
  }

  if (FRESH_REGISTER_WP && (!SUBMIT || method !== 'RegisterWP')) {
    throw new Error('--fresh-register-wp requires --submit and method RegisterWP');
  }

  for (let i = 0; i < WARMUP; i++) {
    if (FRESH_REGISTER_WP) prepareFreshRegisterWP(`warmup-${i}`);
    await call();
  }

  const times = [];
  for (let i = 0; i < ITER; i++) {
    if (FRESH_REGISTER_WP) prepareFreshRegisterWP(i);
    const t0 = process.hrtime.bigint();
    await call();
    times.push(Number(process.hrtime.bigint() - t0) / 1e6);
  }

  times.sort((a, b) => a - b);
  const pick = (p) => times[Math.min(ITER - 1, Math.floor(ITER * p))];
  const mean = times.reduce((a, b) => a + b, 0) / ITER;

  console.log(JSON.stringify({
    org, channel, chaincode, method,
    type: SUBMIT ? 'write' : 'read',
    transient: callTransient ? true : false,
    iter: ITER, warmup: WARMUP,
    p50_ms: +pick(0.50).toFixed(2),
    p95_ms: +pick(0.95).toFixed(2),
    mean_ms: +mean.toFixed(2),
  }));

  gateway.close();
  client.close();
}

main().catch((e) => { console.error(e); process.exit(1); });