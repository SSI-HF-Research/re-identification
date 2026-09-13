import { Context, Contract, Returns, Transaction } from 'fabric-contract-api';
import { createVerify } from 'crypto';

const PDC_COLLECTION = 'StudyReIdentification';
const RO_MSP_ID  = 'OrgROMSP';
const SPI_MSP_ID = 'OrgSPIMSP';
const EC_MSP_IDS = ['OrgEC1MSP', 'OrgEC2MSP', 'OrgEC3MSP'];
const K_OF_N_THRESHOLD = 2;

type ReIDStatus = 'pending' | 'approved' | 'rejected';
type Decision   = 'approve' | 'reject';

interface ReIDRequest {
  reqId: string;
  studyId: string;
  datamartId: string;
  sp: string;
  status: ReIDStatus;
  createdAt: string;
  approvedAt?: string;
  approvedBy?: string;
  resolvedAt?: string;
}

interface ReIDResult {
  reqId: string;
  wp: string;
  resolvedAt: string;
}
interface ReIDApproval { mspId: string; decision: Decision; signature: string; }

function canonicalApprovalMessage(reqId: string, decision: Decision): string {
  return `reid_approval:${reqId}:${decision}`;
}

function verifyEcdsa(publicKeyPem: string, message: string, signatureB64: string): boolean {
  try {
    const v = createVerify('SHA256');
    v.update(message, 'utf8');
    v.end();
    return v.verify(publicKeyPem, Buffer.from(signatureB64, 'base64'));
  } catch {
    return false;
  }
}

export class StudyReIdentificationContract extends Contract {
  constructor() { super('StudyReIdentificationContract'); }

  @Transaction(false) @Returns('string')
  public async testChaincode(ctx: Context): Promise<string> {
    return 'StudyReIdentificationContract is working!';
  }

  // -------- committee key registry --------

  @Transaction()
  public async RegisterCommitteeMember(ctx: Context, publicKeyPem: string): Promise<void> {
    const mspId = ctx.clientIdentity.getMSPID();
    if (!EC_MSP_IDS.includes(mspId)) {
      throw new Error(`Only EC members can register keys (caller=${mspId})`);
    }
    if (!publicKeyPem) throw new Error('publicKeyPem is required');
    await ctx.stub.putState(`ec_key:${mspId}`, Buffer.from(publicKeyPem));
    ctx.stub.setEvent('CommitteeMemberRegistered',
      Buffer.from(JSON.stringify({ mspId })));
  }

  // -------- request creation (RO) --------

  @Transaction() @Returns('string')
  public async CreateReIDRequest(
    ctx: Context, studyId: string, datamartId: string, sp: string
  ): Promise<string> {
    this.assertCallerIs(ctx, RO_MSP_ID);
    if (!studyId || !datamartId || !sp) throw new Error('studyId/datamartId/sp required');

    const reqId = ctx.stub.getTxID();
    const key = `reid_request:${reqId}`;
    const existing = await ctx.stub.getState(key);
    if (existing && existing.length > 0) return reqId;

    const ts = ctx.stub.getTxTimestamp();
    const value: ReIDRequest = {
      reqId, studyId, datamartId, sp,
      status: 'pending',
      createdAt: new Date(Number(ts.seconds) * 1000).toISOString(),
    };
    await ctx.stub.putState(key, Buffer.from(JSON.stringify(value)));
    ctx.stub.setEvent('ReIDRequestCreated', Buffer.from(JSON.stringify({ reqId })));
    return reqId;
  }

  // -------- K-of-N signing (EC members) --------

  @Transaction()
public async SignReIDRequest(
  ctx: Context, reqId: string, decision: string, signatureB64: string
): Promise<string> {
  const mspId = ctx.clientIdentity.getMSPID();
  if (!EC_MSP_IDS.includes(mspId)) {
    throw new Error(`Only EC members can sign (caller=${mspId})`);
  }
  if (decision !== 'approve' && decision !== 'reject') {
    throw new Error(`decision must be "approve" or "reject" (got "${decision}")`);
  }
  if (!signatureB64) throw new Error('signatureB64 is required');

  const reqKey = `reid_request:${reqId}`;
  const bytes = await ctx.stub.getState(reqKey);
  if (!bytes || bytes.length === 0) throw new Error(`reqId ${reqId} not found`);
  const request = JSON.parse(bytes.toString()) as ReIDRequest;
  if (request.status !== 'pending') {
    throw new Error(`reqId ${reqId} is not pending (status=${request.status})`);
  }

  const pubBytes = await ctx.stub.getState(`ec_key:${mspId}`);
  if (!pubBytes || pubBytes.length === 0) {
    throw new Error(`EC member ${mspId} has no registered public key`);
  }
  const publicKeyPem = pubBytes.toString();

  const message = canonicalApprovalMessage(reqId, decision as Decision);
  if (!verifyEcdsa(publicKeyPem, message, signatureB64)) {
    throw new Error(`Signature verification failed for ${mspId}`);
  }

  const approvalKey = `reid_approval:${reqId}:${mspId}`;
  const existing = await ctx.stub.getState(approvalKey);
  if (existing && existing.length > 0) {
    const prev = JSON.parse(existing.toString()) as ReIDApproval;
    if (prev.decision !== decision) {
      throw new Error(`EC member ${mspId} already signed with decision=${prev.decision}`);
    }
    return 'Request already signed by ' + mspId; // idempotent
  }

  const approval: ReIDApproval = { mspId, decision: decision as Decision, signature: signatureB64 };
  await ctx.stub.putState(approvalKey, Buffer.from(JSON.stringify(approval)));

  ctx.stub.setEvent('ReIDApprovalSigned',
    Buffer.from(JSON.stringify({ reqId, mspId, decision })));

  let approveCount = (decision === 'approve') ? 1 : 0;
  let rejectCount  = (decision === 'reject')  ? 1 : 0;

  for (const ec of EC_MSP_IDS) {
    if (ec === mspId) continue;  
    const b = await ctx.stub.getState(`reid_approval:${reqId}:${ec}`);
    if (b && b.length > 0) {
      const a = JSON.parse(b.toString()) as ReIDApproval;
      if (a.decision === 'approve') approveCount++;
      else rejectCount++;
    }
  }
  const totalEC = EC_MSP_IDS.length;

  if (approveCount >= K_OF_N_THRESHOLD) {
    const ts = ctx.stub.getTxTimestamp();
    request.status = 'approved';
    request.approvedAt = new Date(Number(ts.seconds) * 1000).toISOString();
    request.approvedBy = `K_OF_N(${approveCount}/${totalEC})`;
    await ctx.stub.putState(reqKey, Buffer.from(JSON.stringify(request)));
    ctx.stub.setEvent('ReIDRequestApproved',
      Buffer.from(JSON.stringify({ reqId, approveCount, totalEC })));
  } else if ((totalEC - rejectCount) < K_OF_N_THRESHOLD) {
    request.status = 'rejected';
    await ctx.stub.putState(reqKey, Buffer.from(JSON.stringify(request)));
    ctx.stub.setEvent('ReIDRequestRejected',
      Buffer.from(JSON.stringify({ reqId, rejectCount })));
  }
  return 'Request signed successfully by ' + mspId;
}

  @Transaction(false) @Returns('string')
  public async GetReIDApprovals(ctx: Context, reqId: string): Promise<string> {
    const out: ReIDApproval[] = [];
    for (const ec of EC_MSP_IDS) {
      const b = await ctx.stub.getState(`reid_approval:${reqId}:${ec}`);
      if (b && b.length > 0) out.push(JSON.parse(b.toString()));
    }
    return JSON.stringify(out);
  }

  @Transaction(false) @Returns('string')
  public async GetReIDRequest(ctx: Context, reqId: string): Promise<string> {
    const b = await ctx.stub.getState(`reid_request:${reqId}`);
    if (!b || b.length === 0) throw new Error(`reqId ${reqId} not found`);
    return b.toString();
  }

  // -------- PDC result (SPI) --------

  @Transaction()
public async RegisterReIDResult(ctx: Context, reqId: string): Promise<void> {
  this.assertCallerIs(ctx, SPI_MSP_ID);

  const transient = ctx.stub.getTransient();
  if (!transient.has('wp')) throw new Error('Transient "wp" required');
  const wp = Buffer.from(transient.get('wp')!).toString('utf8');
  if (!wp) throw new Error('Transient "wp" must not be empty');

  const reqBytes = await ctx.stub.getState(`reid_request:${reqId}`);
  if (!reqBytes || reqBytes.length === 0) throw new Error(`reqId ${reqId} not found`);
  const request = JSON.parse(reqBytes.toString()) as ReIDRequest;
  if (request.status !== 'approved') {
    throw new Error(`reqId ${reqId} is not approved (status=${request.status})`);
  }

  const resultKey = `reid_result:${reqId}`;
  const existing = await ctx.stub.getPrivateData(PDC_COLLECTION, resultKey);
  if (existing && existing.length > 0) return; // idempotente

  const ts = ctx.stub.getTxTimestamp();
  const resolvedAt = new Date(Number(ts.seconds) * 1000).toISOString();
  await ctx.stub.putPrivateData(
    PDC_COLLECTION,
    resultKey,
    Buffer.from(JSON.stringify({ reqId, wp, resolvedAt } as ReIDResult))
  );

  ctx.stub.setEvent('ReIDResultRegistered', Buffer.from(JSON.stringify({ reqId })));
}

  @Transaction(false) @Returns('string')
  public async GetReIDResult(ctx: Context, reqId: string): Promise<string> {
    const b = await ctx.stub.getPrivateData(PDC_COLLECTION, `reid_result:${reqId}`);
    if (!b || b.length === 0) throw new Error(`reqId ${reqId} not found`);
    return (JSON.parse(b.toString()) as ReIDResult).wp;
  }

  private assertCallerIs(ctx: Context, expectedMsp: string): void {
    const mspId = ctx.clientIdentity.getMSPID();
    if (mspId !== expectedMsp) {
      throw new Error(`Access denied: only ${expectedMsp} (caller=${mspId})`);
    }
  }
}