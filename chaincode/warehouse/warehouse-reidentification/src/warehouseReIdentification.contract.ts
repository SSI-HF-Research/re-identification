import { Context, Contract, Returns, Transaction } from 'fabric-contract-api';
import { createVerify } from 'crypto';

const PDC_COLLECTION = 'WarehouseReIdentification';
const WPI_MSP_ID = 'OrgWPIMSP';
const MO_MSP_ID  = 'OrgMOMSP';
const EC_MSP_IDS = ['OrgEC1MSP', 'OrgEC2MSP', 'OrgEC3MSP'];
const K_OF_N_THRESHOLD = 2;

interface ReIDEntry { reqId: string; pii: string; registeredAt: string; }
interface ReIDApproval { mspId: string; decision: 'approve' | 'reject'; signature: string; }

function verifyEcdsa(publicKeyPem: string, message: string, signatureB64: string): boolean {
  try {
    const v = createVerify('SHA256');
    v.update(message, 'utf8');
    v.end();
    return v.verify(publicKeyPem, Buffer.from(signatureB64, 'base64'));
  } catch { return false; }
}

export class WarehouseReIdentificationContract extends Contract {
  constructor() { super('WarehouseReIdentificationContract'); }

  @Transaction(false) @Returns('string')
  public async testChaincode(ctx: Context): Promise<string> {
    return 'WarehouseReIdentificationContract is working!';
  }

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

  /**
   * RegisterReIdentifiedPII
   * Transient: { pii, approvals (JSON) }
   * Verifies K-of-N EC signatures before writing PII to the PDC.
   */
  @Transaction() @Returns('string')
  public async RegisterReIdentifiedPII(ctx: Context, reqId: string): Promise<string> {
    this.assertCallerIs(ctx, WPI_MSP_ID);
    if (!reqId) throw new Error('reqId is required');

    const transient = ctx.stub.getTransient();
    if (!transient.has('pii'))       throw new Error('Transient "pii" required');
    if (!transient.has('approvals')) throw new Error('Transient "approvals" required');

    const pii = Buffer.from(transient.get('pii')!).toString('utf8');
    const approvalsRaw = Buffer.from(transient.get('approvals')!).toString('utf8');

    let approvals: ReIDApproval[];
    try { approvals = JSON.parse(approvalsRaw); }
    catch { throw new Error('Transient "approvals" must be JSON'); }
    if (!Array.isArray(approvals)) throw new Error('"approvals" must be an array');

    const approveCount = await this.verifyApprovals(ctx, reqId, approvals);
    if (approveCount < K_OF_N_THRESHOLD) {
      throw new Error(`Insufficient valid approvals (got ${approveCount}, need ${K_OF_N_THRESHOLD})`);
    }

    const key = `reid:${reqId}`;
    const existing = await ctx.stub.getPrivateData(PDC_COLLECTION, key);
    if (existing && existing.length > 0) {
      return `reqId ${reqId} already registered, skipping.`;
    }

    const ts = ctx.stub.getTxTimestamp();
    const entry: ReIDEntry = {
      reqId, pii,
      registeredAt: new Date(Number(ts.seconds) * 1000).toISOString(),
    };
    await ctx.stub.putPrivateData(PDC_COLLECTION, key,
      Buffer.from(JSON.stringify(entry)));

    ctx.stub.setEvent('WarehouseReIDRegistered',
      Buffer.from(JSON.stringify({ reqId, approveCount })));
    return 'Re-identified PII registered.';
  }

  @Transaction(false) @Returns('string')
  public async GetReidentifiedPII(ctx: Context, reqId: string): Promise<string> {
    this.assertCallerIs(ctx, MO_MSP_ID);
    const b = await ctx.stub.getPrivateData(PDC_COLLECTION, `reid:${reqId}`);
    if (!b || b.length === 0) throw new Error(`reqId ${reqId} not found`);
    return (JSON.parse(b.toString()) as ReIDEntry).pii;
  }

  private async verifyApprovals(
    ctx: Context, reqId: string, approvals: ReIDApproval[]
  ): Promise<number> {
    let approveCount = 0;
    const seen = new Set<string>();
    for (const a of approvals) {
      if (!EC_MSP_IDS.includes(a.mspId)) {
        throw new Error(`Unknown EC member: ${a.mspId}`);
      }
      if (seen.has(a.mspId)) {
        throw new Error(`Duplicate approval from ${a.mspId}`);
      }
      seen.add(a.mspId);

      const pubBytes = await ctx.stub.getState(`ec_key:${a.mspId}`);
      if (!pubBytes || pubBytes.length === 0) {
        throw new Error(`No public key registered for ${a.mspId}`);
      }
      const message = `reid_approval:${reqId}:${a.decision}`;
      if (!verifyEcdsa(pubBytes.toString(), message, a.signature)) {
        throw new Error(`Invalid signature from ${a.mspId}`);
      }
      if (a.decision === 'approve') approveCount++;
    }
    return approveCount;
  }

  private assertCallerIs(ctx: Context, expectedMsp: string): void {
    const mspId = ctx.clientIdentity.getMSPID();
    if (mspId !== expectedMsp) {
      throw new Error(`Access denied: only ${expectedMsp} (caller=${mspId})`);
    }
  }
}