#!/usr/bin/env node
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const [,, action, ...args] = process.argv;
const ROOT = path.resolve(__dirname, '../..');

function adminDir(domain) {
  return path.join(ROOT, 'network/crypto-config/peerOrganizations',
    domain, `users/Admin@${domain}/msp`);
}

function findAdminKey(domain) {
  const dir = path.join(adminDir(domain), 'keystore');
  const files = fs.readdirSync(dir);
  if (files.length === 0) throw new Error(`No key in ${dir}`);
  return path.join(dir, files[0]);
}

function findAdminCert(domain) {
  const dir = path.join(adminDir(domain), 'signcerts');
  const files = fs.readdirSync(dir);
  if (files.length === 0) throw new Error(`No cert in ${dir}`);
  return path.join(dir, files[0]);
}

switch (action) {
  case 'sign': {
    const [domain, message] = args;
    const keyBytes = fs.readFileSync(findAdminKey(domain));
    const sign = crypto.createSign('SHA256');
    sign.update(message, 'utf8');
    sign.end();
    console.log(sign.sign(keyBytes, 'base64'));
    break;
  }
  case 'pubkey': {
    const [domain] = args;
    const certPem = fs.readFileSync(findAdminCert(domain), 'utf8');
    const cert = new crypto.X509Certificate(certPem);
    process.stdout.write(cert.publicKey.export({ type: 'spki', format: 'pem' }));
    break;
  }
  case 'verify': {
    const [domain, message, sigB64] = args;
    const certPem = fs.readFileSync(findAdminCert(domain), 'utf8');
    const cert = new crypto.X509Certificate(certPem);
    const pubKey = cert.publicKey;
    const v = crypto.createVerify('SHA256');
    v.update(message, 'utf8');
    v.end();
    console.log(v.verify(pubKey, Buffer.from(sigB64, 'base64')) ? 'OK' : 'FAIL');
    break;
  }
  default:
    console.error('Usage: ec-sign.js sign|pubkey|verify <domain> [message] [signature]');
    process.exit(1);
}