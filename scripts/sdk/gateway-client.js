#!/usr/bin/env node
// ============================================================================
// gateway-client.js — Single-shot fabric-gateway client used by the
// benchmark suite when USE_SDK=1.
//
// PURPOSE
//   Replaces `peer chaincode invoke/query` for benchmarking. Uses discovery
//   to resolve endorsers, honors CAPTURE_TXID_FILE, and produces a clean
//   number by avoiding the peer CLI's ~1.2 s of Node+gRPC+TLS startup per
//   call.
//
// USAGE
//   node gateway-client.js query  <org> <channel> <cc> <fn> <argsJson>
//   node gateway-client.js invoke <org> <channel> <cc> <fn> <argsJson> <transientJson|NA> [endorsersJson]
//
// ENV VARS
//   CAPTURE_TXID_FILE — when set, writes the transaction id to that path.
//
// NOTE
//   Still pays ~150–250 ms of Node startup per call. This is now the
//   dominant floor; measure it with scenario-f and subtract via analyze.py
//   --baseline.
// ============================================================================
const grpc = require('@grpc/grpc-js');
const { connect, signers } = require('@hyperledger/fabric-gateway');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const ROOT = path.resolve(__dirname, '../..');

const ORG = {
  OrgIM:  { msp: 'OrgIMMSP',  domain: 'im.example.com',  port: 7051  },
  OrgWPI: { msp: 'OrgWPIMSP', domain: 'wpi.example.com', port: 8051  },
  OrgHDW: { msp: 'OrgHDWMSP', domain: 'hdw.example.com', port: 9051  },
  OrgSC:  { msp: 'OrgSCMSP',  domain: 'sc.example.com',  port: 10051 },
  OrgSPI: { msp: 'OrgSPIMSP', domain: 'spi.example.com', port: 11051 },
  OrgRO:  { msp: 'OrgROMSP',  domain: 'ro.example.com',  port: 12051 },
  OrgMO:  { msp: 'OrgMOMSP',  domain: 'mo.example.com',  port: 13051 },
  OrgEC1: { msp: 'OrgEC1MSP', domain: 'ec1.example.com', port: 14051 },
  OrgEC2: { msp: 'OrgEC2MSP', domain: 'ec2.example.com', port: 15051 },
  OrgEC3: { msp: 'OrgEC3MSP', domain: 'ec3.example.com', port: 16051 },
};

function loadAdminIdentity(org) {
  const { domain } = ORG[org];
  const mspDir = path.join(ROOT, 'network/crypto-config/peerOrganizations',
    domain, `users/Admin@${domain}/msp`);
  const certDir = path.join(mspDir, 'signcerts');
  const keyDir = path.join(mspDir, 'keystore');
  const cert = fs.readFileSync(path.join(certDir, fs.readdirSync(certDir)[0]));
  const key = fs.readFileSync(path.join(keyDir, fs.readdirSync(keyDir)[0]));
  return { cert, key };
}

function newGateway(org) {
  const { msp, domain, port } = ORG[org];
  const { cert, key } = loadAdminIdentity(org);
  const tlsCert = fs.readFileSync(path.join(
    ROOT, 'network/crypto-config/peerOrganizations',
    domain, `peers/peer0.${domain}/tls/ca.crt`));

  const client = new grpc.Client(`localhost:${port}`,
    grpc.credentials.createSsl(tlsCert));

  return connect({
    client,
    identity: { mspId: msp, credentials: cert },
    signer: signers.newPrivateKeySigner(crypto.createPrivateKey(key)),
    evaluateOptions:    () => ({ deadline: Date.now() + 15000 }),
    endorseOptions:     () => ({ deadline: Date.now() + 30000 }),
    submitOptions:      () => ({ deadline: Date.now() + 30000 }),
    commitStatusOptions:() => ({ deadline: Date.now() + 60000 }),
  });
}

async function main() {
  const [,, mode, org, channel, cc, fn, argsJson, transientJson, endorsersJson] = process.argv;

  if (!['query', 'invoke'].includes(mode)) {
    throw new Error('usage: gateway-client.js query|invoke <org> <channel> <cc> <fn> <argsJson> [transientJson] [endorsersJson]');
  }
  if (!ORG[org]) throw new Error(`unknown org: ${org}`);

  const args = JSON.parse(argsJson || '[]');
  const gw = newGateway(org);
  const contract = gw.getNetwork(channel).getContract(cc);

  try {
    if (mode === 'query') {
      const result = await contract.evaluateTransaction(fn, ...args);
      process.stdout.write(result.toString());
      return;
    }

    const transient = transientJson && transientJson !== 'NA'
      ? Object.fromEntries(
          Object.entries(JSON.parse(transientJson))
            .map(([k, v]) => [k, Buffer.from(v)]))
      : undefined;

    const endorsers = endorsersJson
      ? JSON.parse(endorsersJson).map((o) => ORG[o]?.msp).filter(Boolean)
      : undefined;

    const proposal = contract.newProposal(fn, {
      arguments: args,
      transientData: transient,
    });

    const transaction = await proposal.endorse(
      endorsers && endorsers.length > 0
        ? { endorsingOrganizations: endorsers }
        : {}
    );

    const txId = transaction.getTransactionId();
    if (process.env.CAPTURE_TXID_FILE) {
      fs.writeFileSync(process.env.CAPTURE_TXID_FILE, txId);
    }

    await transaction.submit();
    const status = await transaction.getStatus();
    if (!status.successful) {
      throw new Error(`commit failed: status.code=${status.code}`);
    }

    process.stdout.write(transaction.getResult().toString());
  } finally {
    gw.close();
  }
}

main().catch((err) => {
  process.stderr.write(`${err.message || err}\n`);
  process.exit(1);
});