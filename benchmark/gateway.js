const grpc = require('@grpc/grpc-js');
const fs = require('fs');
const crypto = require('crypto');
const { connect, signers } = require('@hyperledger/fabric-gateway');
const { identityFor } = require('./identities');

function newGrpcClient({ peerEndpoint, hostAlias, tlsCertPath }) {
  const tlsRootCert = fs.readFileSync(tlsCertPath);
  return new grpc.Client(peerEndpoint, grpc.credentials.createSsl(tlsRootCert), {
    'grpc.ssl_target_name_override': hostAlias,
  });
}

async function connectOrg(orgKey) {
  const id = identityFor(orgKey);
  const client = newGrpcClient(id);

  const cert = fs.readFileSync(id.certPath);
  const key = crypto.createPrivateKey(fs.readFileSync(id.keyPath));

  const gateway = connect({
    client,
    identity: { mspId: id.mspId, credentials: cert },
    signer: signers.newPrivateKeySigner(key),
    evaluateOptions: () => ({ deadline: Date.now() + 30_000 }),
    endorseOptions:  () => ({ deadline: Date.now() + 60_000 }),
    submitOptions:   () => ({ deadline: Date.now() + 60_000 }),
    commitStatusOptions: () => ({ deadline: Date.now() + 120_000 }),
  });

  return {
    orgKey,
    gateway,
    close: () => { gateway.close(); client.close(); },
  };
}

/** Coerces a transient map to Record<string, Uint8Array>. */
function toTransient(td) {
  if (!td) return undefined;
  const out = {};
  for (const [k, v] of Object.entries(td)) {
    // Always hand the SDK a Uint8Array.
    out[k] = v instanceof Uint8Array ? v : Buffer.from(String(v));
  }
  return out;
}

/** Submit a transaction with transient data and hrtime instrumentation. */
async function submit(contract, fn, args, transient) {
  const td = toTransient(transient);
  const t0 = process.hrtime.bigint();
  const result = await contract.submit(fn, {
    arguments: args,
    ...(td ? { transientData: td } : {}),
  });
  const t1 = process.hrtime.bigint();
  return { ms: Number(t1 - t0) / 1e6, text: new TextDecoder().decode(result) };
}

async function evaluate(contract, fn, args) {
  const t0 = process.hrtime.bigint();
  const result = await contract.evaluateTransaction(fn, ...args);
  const t1 = process.hrtime.bigint();
  return { ms: Number(t1 - t0) / 1e6, text: new TextDecoder().decode(result) };
}

module.exports = { connectOrg, submit, evaluate, toTransient };