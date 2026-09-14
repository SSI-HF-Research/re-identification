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

/** Builds the world-state key for a re-identification request. */
function requestStateKey(reqId: string): string {
  return `reid_request:${reqId}`;
}

/** Builds the world-state key for one EC member's approval. */
function approvalStateKey(reqId: string, mspId: string): string {
  return `reid_approval:${reqId}:${mspId}`;
}

/** Builds the private-data key for a re-identification result. */
function resultPrivateDataKey(reqId: string): string {
  return `reid_result:${reqId}`;
}

/** Converts Fabric's transaction timestamp to the ISO format stored on ledger. */
function timestampToIso(ctx: Context): string {
  const timestamp = ctx.stub.getTxTimestamp();
  return new Date(Number(timestamp.seconds) * 1000).toISOString();
}

/** Builds the exact message that EC members must sign for an approval decision. */
function canonicalApprovalMessage(reqId: string, decision: Decision): string {
  return `reid_approval:${reqId}:${decision}`;
}

/** Verifies a base64-encoded ECDSA signature against a PEM public key. */
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
  /** Creates the Fabric contract with its registered contract name. */
  constructor() { super('StudyReIdentificationContract'); }

  /** Confirms that the chaincode is installed and callable. */
  @Transaction(false) @Returns('string')
  public async testChaincode(ctx: Context): Promise<string> {
    return 'StudyReIdentificationContract is working!';
  }

  /** Registers or replaces the caller's public key for committee signatures. */
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

  /** Creates a pending re-identification request on behalf of the RO organization. */
  @Transaction() @Returns('string')
  public async CreateReIDRequest(
    ctx: Context, studyId: string, datamartId: string, sp: string
  ): Promise<string> {
    this.assertCallerIs(ctx, RO_MSP_ID);
    if (!studyId || !datamartId || !sp) throw new Error('studyId/datamartId/sp required');

    const reqId = ctx.stub.getTxID();
    const key = requestStateKey(reqId);
    const existing = await ctx.stub.getState(key);
    if (existing && existing.length > 0) return reqId;

    const value: ReIDRequest = {
      reqId, studyId, datamartId, sp,
      status: 'pending',
      createdAt: timestampToIso(ctx),
    };
    await ctx.stub.putState(key, Buffer.from(JSON.stringify(value)));
    ctx.stub.setEvent('ReIDRequestCreated', Buffer.from(JSON.stringify({ reqId })));
    return reqId;
  }

  /** Verifies and records an EC decision, resolving the request when the K-of-N rule is met. */
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

  const reqKey = requestStateKey(reqId);
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

  const approvalKey = approvalStateKey(reqId, mspId);
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
    const b = await ctx.stub.getState(approvalStateKey(reqId, ec));
    if (b && b.length > 0) {
      const a = JSON.parse(b.toString()) as ReIDApproval;
      if (a.decision === 'approve') approveCount++;
      else rejectCount++;
    }
  }
  const totalEC = EC_MSP_IDS.length;

  if (approveCount >= K_OF_N_THRESHOLD) {
    request.status = 'approved';
    request.approvedAt = timestampToIso(ctx);
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

  /** Returns all recorded EC approvals for a re-identification request. */
  @Transaction(false) @Returns('string')
  public async GetReIDApprovals(ctx: Context, reqId: string): Promise<string> {
    const out: ReIDApproval[] = [];
    for (const ec of EC_MSP_IDS) {
      const b = await ctx.stub.getState(approvalStateKey(reqId, ec));
      if (b && b.length > 0) out.push(JSON.parse(b.toString()));
    }
    return JSON.stringify(out);
  }

  /** Returns the public request record identified by its transaction ID. */
  @Transaction(false) @Returns('string')
  public async GetReIDRequest(ctx: Context, reqId: string): Promise<string> {
    const b = await ctx.stub.getState(requestStateKey(reqId));
    if (!b || b.length === 0) throw new Error(`reqId ${reqId} not found`);
    return b.toString();
  }

  /** Stores the resolved work package in private data after EC approval. */
  @Transaction()
  public async RegisterReIDResult(ctx: Context, reqId: string): Promise<void> {
  this.assertCallerIs(ctx, SPI_MSP_ID);

  const transient = ctx.stub.getTransient();
  if (!transient.has('wp')) throw new Error('Transient "wp" required');
  const wp = Buffer.from(transient.get('wp')!).toString('utf8');
  if (!wp) throw new Error('Transient "wp" must not be empty');

  const reqBytes = await ctx.stub.getState(requestStateKey(reqId));
  if (!reqBytes || reqBytes.length === 0) throw new Error(`reqId ${reqId} not found`);
  const request = JSON.parse(reqBytes.toString()) as ReIDRequest;
  if (request.status !== 'approved') {
    throw new Error(`reqId ${reqId} is not approved (status=${request.status})`);
  }

  const resultKey = resultPrivateDataKey(reqId);
  const existing = await ctx.stub.getPrivateData(PDC_COLLECTION, resultKey);
  if (existing && existing.length > 0) return; // idempotente

  const resolvedAt = timestampToIso(ctx);
  await ctx.stub.putPrivateData(
    PDC_COLLECTION,
    resultKey,
    Buffer.from(JSON.stringify({ reqId, wp, resolvedAt } as ReIDResult))
  );

  ctx.stub.setEvent('ReIDResultRegistered', Buffer.from(JSON.stringify({ reqId })));
}

  /** Returns the private work package associated with an approved request. */
  @Transaction(false) @Returns('string')
  public async GetReIDResult(ctx: Context, reqId: string): Promise<string> {
    const b = await ctx.stub.getPrivateData(PDC_COLLECTION, resultPrivateDataKey(reqId));
    if (!b || b.length === 0) throw new Error(`reqId ${reqId} not found`);
    return (JSON.parse(b.toString()) as ReIDResult).wp;
  }

  /** Rejects the transaction unless the caller belongs to the expected organization. */
  private assertCallerIs(ctx: Context, expectedMsp: string): void {
    const mspId = ctx.clientIdentity.getMSPID();
    if (mspId !== expectedMsp) {
      throw new Error(`Access denied: only ${expectedMsp} (caller=${mspId})`);
    }
  }
}