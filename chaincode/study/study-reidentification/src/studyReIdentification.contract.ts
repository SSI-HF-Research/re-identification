import { Context, Contract, Returns, Transaction } from 'fabric-contract-api';
import { createHash } from 'crypto';

const PDC_COLLECTION = 'StudyReIdentification';

const RO_MSP_ID = 'OrgROMSP';
const SPI_MSP_ID = 'OrgSPIMSP';
const EC_MSP_ID  = 'OrgECMSP';

const DEFAULT_K = 2;  // K-of-N; N é o número de membros do EC com cert válido

type ReIDStatus = 'pending' | 'approved' | 'rejected';

interface ReIDRequest {
  reqId: string;
  studyId: string;
  datamartId: string;
  sp: string;
  status: ReIDStatus;
  createdAt: string;
  approvals: string[];        // fingerprints de membros do EC que aprovaram
  rejections: string[];       // fingerprints que rejeitaram
  requiredApprovals: number;  // K
  approvedAt?: string;
  resolvedAt?: string;
}

interface ReIDResult {
  reqId: string;
  wp: string;
}

export class StudyReIdentificationContract extends Contract {
  constructor() {
    super('StudyReIdentificationContract');
  }

  @Transaction(false)
  @Returns('string')
  public async testChaincode(ctx: Context): Promise<string> {
    return 'StudyReIdentificationContract is working!';
  }

  // ---------------------------------------------------------------
  // Ledger regular
  // ---------------------------------------------------------------

  @Transaction()
  @Returns('string')
  public async CreateReIDRequest(
    ctx: Context,
    studyId: string,
    datamartId: string,
    sp: string,
  ): Promise<string> {
    this.assertCallerIs(ctx, RO_MSP_ID);

    if (!studyId)    throw new Error('studyId is required');
    if (!datamartId) throw new Error('datamartId is required');
    if (!sp)         throw new Error('sp is required');

    const reqId = ctx.stub.getTxID();
    const key = `reid_request:${reqId}`;
    const existing = await ctx.stub.getState(key);
    if (existing && existing.length > 0) return reqId;

    const ts = ctx.stub.getTxTimestamp();
    const createdAt = new Date(Number(ts.seconds) * 1000).toISOString();

    const value: ReIDRequest = {
      reqId, studyId, datamartId, sp,
      status: 'pending',
      createdAt,
      approvals: [],
      rejections: [],
      requiredApprovals: DEFAULT_K,
    };

    await ctx.stub.putState(key, Buffer.from(JSON.stringify(value)));

    ctx.stub.setEvent(
      'ReIDRequestCreated',
      Buffer.from(JSON.stringify({ reqId, requiredApprovals: DEFAULT_K }))
    );

    return reqId;
  }

  /**
   * ApproveReIDRequest — um membro do EC vota.
   * Idempotente por membro. Quando approvals >= K, status vira 'approved'.
   */
  @Transaction()
  public async ApproveReIDRequest(ctx: Context, reqId: string): Promise<void> {
    this.assertCallerIs(ctx, EC_MSP_ID);

    const memberId = this.getMemberId(ctx);

    const key = `reid_request:${reqId}`;
    const bytes = await ctx.stub.getState(key);
    if (!bytes || bytes.length === 0) {
      throw new Error(`reqId ${reqId} not found`);
    }
    const value = JSON.parse(bytes.toString()) as ReIDRequest;

    if (value.status === 'approved') return;
    if (value.status === 'rejected') {
      throw new Error(`reqId ${reqId} already rejected`);
    }
    if (value.approvals.includes(memberId)) return;   // já aprovou
    if (value.rejections.includes(memberId)) {
      throw new Error(`member ${memberId} already rejected reqId ${reqId}`);
    }

    value.approvals.push(memberId);

    if (value.approvals.length >= value.requiredApprovals) {
      value.status = 'approved';
      const ts = ctx.stub.getTxTimestamp();
      value.approvedAt = new Date(Number(ts.seconds) * 1000).toISOString();
      ctx.stub.setEvent(
        'ReIDRequestApproved',
        Buffer.from(JSON.stringify({
          reqId, approvals: value.approvals.length, required: value.requiredApprovals,
        }))
      );
    } else {
      ctx.stub.setEvent(
        'ReIDApprovalRecorded',
        Buffer.from(JSON.stringify({
          reqId, approvals: value.approvals.length, required: value.requiredApprovals,
        }))
      );
    }

    await ctx.stub.putState(key, Buffer.from(JSON.stringify(value)));
  }

  @Transaction()
  public async RejectReIDRequest(
    ctx: Context,
    reqId: string,
    reason: string
  ): Promise<void> {
    this.assertCallerIs(ctx, EC_MSP_ID);
    const memberId = this.getMemberId(ctx);

    const key = `reid_request:${reqId}`;
    const bytes = await ctx.stub.getState(key);
    if (!bytes || bytes.length === 0) throw new Error(`reqId ${reqId} not found`);
    const value = JSON.parse(bytes.toString()) as ReIDRequest;

    if (value.status === 'rejected') return;
    if (value.status === 'approved') {
      throw new Error(`reqId ${reqId} already approved`);
    }
    if (value.rejections.includes(memberId)) return;
    if (value.approvals.includes(memberId)) {
      throw new Error(`member ${memberId} already approved reqId ${reqId}`);
    }

    value.rejections.push(memberId);
    value.status = 'rejected';  // regra simples: qualquer rejeição derruba

    await ctx.stub.putState(key, Buffer.from(JSON.stringify(value)));

    ctx.stub.setEvent(
      'ReIDRequestRejected',
      Buffer.from(JSON.stringify({
        reqId, reason, rejections: value.rejections.length,
      }))
    );
  }

  @Transaction(false)
  @Returns('string')
  public async GetReIDRequest(ctx: Context, reqId: string): Promise<string> {
    const key = `reid_request:${reqId}`;
    const bytes = await ctx.stub.getState(key);
    if (!bytes || bytes.length === 0) throw new Error(`reqId ${reqId} not found`);
    return bytes.toString();
  }

  // ---------------------------------------------------------------
  // PDC
  // ---------------------------------------------------------------

  @Transaction()
  public async RegisterReIDResult(ctx: Context, reqId: string): Promise<void> {
    this.assertCallerIs(ctx, SPI_MSP_ID);

    const transient = ctx.stub.getTransient();
    if (!transient.has('wp')) throw new Error('Transient field "wp" is required');
    const wp = Buffer.from(transient.get('wp')!).toString('utf8');
    if (!wp) throw new Error('Transient field "wp" must not be empty');

    const reqKey = `reid_request:${reqId}`;
    const reqBytes = await ctx.stub.getState(reqKey);
    if (!reqBytes || reqBytes.length === 0) throw new Error(`reqId ${reqId} not found`);
    const request = JSON.parse(reqBytes.toString()) as ReIDRequest;

    if (request.status !== 'approved') {
      throw new Error(`reqId ${reqId} is not approved (status=${request.status})`);
    }

    const resultKey = `reid_result:${reqId}`;
    const existing = await ctx.stub.getPrivateData(PDC_COLLECTION, resultKey);
    if (existing && existing.length > 0) return;

    const result: ReIDResult = { reqId, wp };
    await ctx.stub.putPrivateData(
      PDC_COLLECTION,
      resultKey,
      Buffer.from(JSON.stringify(result))
    );

    const ts = ctx.stub.getTxTimestamp();
    request.resolvedAt = new Date(Number(ts.seconds) * 1000).toISOString();
    await ctx.stub.putState(reqKey, Buffer.from(JSON.stringify(request)));

    ctx.stub.setEvent('ReIDResultRegistered', Buffer.from(JSON.stringify({ reqId })));
  }

  @Transaction(false)
  @Returns('string')
  public async GetReIDResult(ctx: Context, reqId: string): Promise<string> {
    const key = `reid_result:${reqId}`;
    const bytes = await ctx.stub.getPrivateData(PDC_COLLECTION, key);
    if (!bytes || bytes.length === 0) {
      throw new Error(`reqId ${reqId} not found in StudyReIdentification`);
    }
    const result = JSON.parse(bytes.toString()) as ReIDResult;
    return result.wp;
  }

  // ---------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------

  private assertCallerIs(ctx: Context, expectedMsp: string): void {
    const mspId = ctx.clientIdentity.getMSPID();
    if (mspId !== expectedMsp) {
      throw new Error(
        `Access denied: only ${expectedMsp} can call this (caller=${mspId})`
      );
    }
  }

  /**
   * getMemberId — identificador estável por membro do EC.
   * Usa sha256 do serialized identity (getID()).
   * Cada user distinto dentro do MSP OrgEC produz um memberId diferente.
   */
  private getMemberId(ctx: Context): string {
    const id = ctx.clientIdentity.getID();
    return createHash('sha256').update(id).digest('hex');
  }
}