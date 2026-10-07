const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const CRYPTO = path.join(ROOT, 'network', 'crypto-config');

// Mapeamento org -> { mspId, domain, peerEndpoint, peerHostAlias }
const ORGS = {
  OrgIM:  { mspId: 'OrgIMMSP',  domain: 'im.example.com',  peerEndpoint: 'localhost:7051',  hostAlias: 'peer0.im.example.com'  },
  OrgWPI: { mspId: 'OrgWPIMSP', domain: 'wpi.example.com', peerEndpoint: 'localhost:8051',  hostAlias: 'peer0.wpi.example.com' },
  OrgHDW: { mspId: 'OrgHDWMSP', domain: 'hdw.example.com', peerEndpoint: 'localhost:9051',  hostAlias: 'peer0.hdw.example.com' },
  OrgSC:  { mspId: 'OrgSCMSP',  domain: 'sc.example.com',  peerEndpoint: 'localhost:10051', hostAlias: 'peer0.sc.example.com'  },
  OrgSPI: { mspId: 'OrgSPIMSP', domain: 'spi.example.com', peerEndpoint: 'localhost:11051', hostAlias: 'peer0.spi.example.com' },
  OrgRO:  { mspId: 'OrgROMSP',  domain: 'ro.example.com',  peerEndpoint: 'localhost:12051', hostAlias: 'peer0.ro.example.com'  },
  OrgMO:  { mspId: 'OrgMOMSP',  domain: 'mo.example.com',  peerEndpoint: 'localhost:13051', hostAlias: 'peer0.mo.example.com'  },
  OrgEC1: { mspId: 'OrgEC1MSP', domain: 'ec1.example.com', peerEndpoint: 'localhost:14051', hostAlias: 'peer0.ec1.example.com' },
  OrgEC2: { mspId: 'OrgEC2MSP', domain: 'ec2.example.com', peerEndpoint: 'localhost:15051', hostAlias: 'peer0.ec2.example.com' },
  OrgEC3: { mspId: 'OrgEC3MSP', domain: 'ec3.example.com', peerEndpoint: 'localhost:16051', hostAlias: 'peer0.ec3.example.com' },
};

function userMspDir(domain, user = 'Admin') {
  return path.join(CRYPTO, 'peerOrganizations', domain, `users/${user}@${domain}/msp`);
}

function readFileFirst(dir) {
  const files = fs.readdirSync(dir).filter(f => !f.startsWith('.'));
  if (files.length === 0) throw new Error(`empty dir: ${dir}`);
  return path.join(dir, files[0]);
}

function identityFor(orgKey) {
  const o = ORGS[orgKey];
  if (!o) throw new Error(`unknown org ${orgKey}`);
  const msp = userMspDir(o.domain);
  return {
    ...o,
    certPath: readFileFirst(path.join(msp, 'signcerts')),
    keyPath:  readFileFirst(path.join(msp, 'keystore')),
    tlsCertPath: path.join(CRYPTO, 'peerOrganizations', o.domain,
      `peers/peer0.${o.domain}/tls/ca.crt`),
  };
}

module.exports = { ORGS, identityFor };