const { connectOrg } = require('./gateway');
const { flowPseudonymization } = require('./workloads');

(async () => {
  const conns = {
    im:  await connectOrg('OrgIM'),
    wpi: await connectOrg('OrgWPI'),
    spi: await connectOrg('OrgSPI'),
  };
  try {
    const r = await flowPseudonymization({
      imConn: conns.im, wpiConn: conns.wpi, spiConn: conns.spi,
      N: 3, studyId: 'smoke', datamartId: 'smoke-dm',
      wpMasterKey: 'test-wp-master-key', spMasterKey: 'test-sp-master-key',
    });
    console.log('OK', r.totals.A3, r.refs.length, 'refs');
  } finally {
    for (const c of Object.values(conns)) c.close();
  }
})().catch(e => { console.error(e); process.exit(1); });