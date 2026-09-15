#!/usr/bin/env node
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// Parse the CLI: node ec-sign.js <action> [args...]
const [,, action, ...args] = process.argv;

// Resolve the repo root so we can find generated Fabric crypto material.
const ROOT = path.resolve(__dirname, '../..');

// Build the MSP directory for the given organization/domain.
function adminDir(domain) {
  return path.join(ROOT, 'network/crypto-config/peerOrganizations',
    domain, `users/Admin@${domain}/msp`);
}

// Read the admin private key from the MSP keystore.
function findAdminKey(domain) {
  const dir = path.join(adminDir(domain), 'keystore');
  const files = fs.readdirSync(dir);
  if (files.length === 0) throw new Error(`No key in ${dir}`);
  return path.join(dir, files[0]);
}

// Read the admin certificate from the MSP signcerts folder.
function findAdminCert(domain) {
  const dir = path.join(adminDir(domain), 'signcerts');
  const files = fs.readdirSync(dir);
  if (files.length === 0) throw new Error(`No cert in ${dir}`);
  return path.join(dir, files[0]);
}

switch (action) {
  case 'sign': {
    // Sign the provided UTF-8 message with the admin private key.
    const [domain, message] = args;
    const keyBytes = fs.readFileSync(findAdminKey(domain));
    const sign = crypto.createSign('SHA256');
    sign.update(message, 'utf8');
    sign.end();
    // Output the signature in base64 so it can be copied or passed to verify.
    console.log(sign.sign(keyBytes, 'base64'));
    break;
  }
  case 'pubkey': {
    // Extract the public key from the admin certificate in PEM format.
    const [domain] = args;
    const certPem = fs.readFileSync(findAdminCert(domain), 'utf8');
    const cert = new crypto.X509Certificate(certPem);
    process.stdout.write(cert.publicKey.export({ type: 'spki', format: 'pem' }));
    break;
  }
  case 'verify': {
    // Verify a signature against the certificate embedded public key.
    const [domain, message, sigB64] = args;
    const certPem = fs.readFileSync(findAdminCert(domain), 'utf8');
    const cert = new crypto.X509Certificate(certPem);
    const pubKey = cert.publicKey;
    const v = crypto.createVerify('SHA256');
    v.update(message, 'utf8');
    v.end();
    // Check whether the signature matches the message and print OK/FAIL.
    console.log(v.verify(pubKey, Buffer.from(sigB64, 'base64')) ? 'OK' : 'FAIL');
    break;
  }
  default:
    console.error('Usage: ec-sign.js sign|pubkey|verify <domain> [message] [signature]');
    process.exit(1);
}