const crypto = require('crypto');

function wp(wpMasterKey, pii) {
  return crypto.createHmac('sha256', wpMasterKey).update(pii, 'utf8').digest('hex');
}

function hkdf(spMasterKey, studyId, datamartId) {
  const salt = Buffer.from(studyId, 'utf8');
  const info = Buffer.from(datamartId, 'utf8');
  const key = crypto.hkdfSync('sha256', Buffer.from(spMasterKey, 'utf8'), salt, info, 32);
  return Buffer.from(key).toString('hex');
}

function randomPii(prefix = 'pii') {
  return `${prefix}-${crypto.randomBytes(8).toString('hex')}`;
}

module.exports = { wp, hkdf, randomPii };