#!/usr/bin/env node
const crypto = require('crypto');

const [,, cmd, ...args] = process.argv;

function hmac(key, data) {
  return crypto.createHmac('sha256', key).update(data, 'utf8').digest('hex');
}

function hkdf(masterKey, studyId, datamartId) {
  const salt = Buffer.from(studyId, 'utf8');
  const info = Buffer.from(datamartId, 'utf8');
  const key = crypto.hkdfSync('sha256', Buffer.from(masterKey, 'utf8'), salt, info, 32);
  return Buffer.from(key).toString('hex');
}

switch (cmd) {
  case 'wp':
    console.log(hmac(args[0], args[1]));
    break;
  case 'hkdf':
    console.log(hkdf(args[0], args[1], args[2]));
    break;
  case 'sp':
    console.log(hmac(args[0], args[1]));
    break;
  default:
    console.error('use: wp <masterKey> <pii> | hkdf <masterKey> <studyId> <datamartId> | sp <studyKey> <wp>');
    process.exit(1);
}