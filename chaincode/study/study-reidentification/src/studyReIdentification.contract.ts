import { Context, Contract, Returns, Transaction } from 'fabric-contract-api';

const PDC_COLLECTION = 'StudyReIdentification';

const RO_MSP_ID       = 'OrgROMSP';
const SPI_MSP_ID      = 'OrgSPIMSP';
const APPROVER_MSP_ID = 'OrgSCMSP'; // proxy do EC na Fase 4; vira K-of-N na Fase 5

type ReIDStatus = 'pending' | 'approved' | 'rejected';

// -------- channel ledger
interface ReIDRequest {
  reqId: string;
  studyId: string;
  datamartId: string;
  sp: string;
  //roDid: string;
  //researcherDid: string;
  //justificationHash: string;
  //ipfsPointer: string;
  status: ReIDStatus;
  createdAt: string;
  approvedAt?: string;
  approvedBy?: string;
  resolvedAt?: string;
}

// -------- PDC Study_Re-Identification --------
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

  // -------------------------------------------------------------------
  // Ledger regular: request (criação / aprovação / leitura)
  // -------------------------------------------------------------------

  /**
   * CreateReIDRequest
   * RO makes the re identification request. The request is stored in the regular ledger (public). No PDC interaction is needed at this point.
   * The request is public by design, so any member of the Study Channel can read it.
   * The request is created with status = pending.
   * The request is approved or rejected by the Approver (OrgSCMSP).
   * The request is identified by reqId = txId.
   */
  @Transaction()
  @Returns('string')
  public async CreateReIDRequest(
    ctx: Context,
    studyId: string,
    datamartId: string,
    sp: string,
    //roDid: string,
    //researcherDid: string,
    //justificationHash: string,
    //ipfsPointer: string
  ): Promise<string> {
    this.assertCallerIs(ctx, RO_MSP_ID);

    if (!studyId)          throw new Error('studyId is required');
    if (!datamartId)       throw new Error('datamartId is required');
    if (!sp)               throw new Error('sp is required');

    const reqId = ctx.stub.getTxID();
    const key = `reid_request:${reqId}`;
    const existing = await ctx.stub.getState(key);
    if (existing && existing.length > 0) {
      return reqId; 
    }

    const ts = ctx.stub.getTxTimestamp();
    const createdAt = new Date(Number(ts.seconds) * 1000).toISOString();

    const value: ReIDRequest = {
      reqId, studyId, datamartId, sp,
      //roDid, researcherDid, justificationHash, ipfsPointer,
      status: 'pending',
      createdAt,
    };

    await ctx.stub.putState(key, Buffer.from(JSON.stringify(value)));

    ctx.stub.setEvent(
      'ReIDRequestCreated',
      Buffer.from(JSON.stringify({ reqId }))
    );

    return reqId;
  }

  // for now doing only 1 approval and using the SC
  @Transaction()
  public async ApproveReIDRequest(ctx: Context, reqId: string): Promise<void> {
    this.assertCallerIs(ctx, APPROVER_MSP_ID);

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

    const ts = ctx.stub.getTxTimestamp();
    value.status = 'approved';
    value.approvedAt = new Date(Number(ts.seconds) * 1000).toISOString();
    value.approvedBy = ctx.clientIdentity.getMSPID();

    await ctx.stub.putState(key, Buffer.from(JSON.stringify(value)));

    ctx.stub.setEvent(
      'ReIDRequestApproved',
      Buffer.from(JSON.stringify({ reqId }))
    );
  }

  @Transaction()
  public async RejectReIDRequest(
    ctx: Context,
    reqId: string,
    reason: string
  ): Promise<void> {
    this.assertCallerIs(ctx, APPROVER_MSP_ID);

    const key = `reid_request:${reqId}`;
    const bytes = await ctx.stub.getState(key);
    if (!bytes || bytes.length === 0) {
      throw new Error(`reqId ${reqId} not found`);
    }
    const value = JSON.parse(bytes.toString()) as ReIDRequest;

    if (value.status === 'rejected') return;
    if (value.status === 'approved') {
      throw new Error(`reqId ${reqId} already approved`);
    }

    value.status = 'rejected';
    await ctx.stub.putState(key, Buffer.from(JSON.stringify(value)));

    ctx.stub.setEvent(
      'ReIDRequestRejected',
      Buffer.from(JSON.stringify({ reqId, reason }))
    );
  }

  @Transaction(false)
  @Returns('string')
  public async GetReIDRequest(ctx: Context, reqId: string): Promise<string> {
    const key = `reid_request:${reqId}`;
    const bytes = await ctx.stub.getState(key);
    if (!bytes || bytes.length === 0) {
      throw new Error(`reqId ${reqId} not found`);
    }
    return bytes.toString();
  }

  // -------------------------------------------------------------------
  // PDC: resultado (reqId ↔ WP)
  // -------------------------------------------------------------------

  /**
   * RegisterReIDResult
   * SPI escreve o WP na PDC. Exige status = approved.
   * A resolução SP → WP é feita client-side antes, via study-mapping.
   */
  @Transaction()
  public async RegisterReIDResult(ctx: Context, reqId: string): Promise<void> {
    this.assertCallerIs(ctx, SPI_MSP_ID);

    const transient = ctx.stub.getTransient();
    if (!transient.has('wp')) {
      throw new Error('Transient field "wp" is required');
    }
    const wp = Buffer.from(transient.get('wp')!).toString('utf8');
    if (!wp) throw new Error('Transient field "wp" must not be empty');

    // Confere que o pedido existe e está aprovado (ledger regular)
    const reqKey = `reid_request:${reqId}`;
    const reqBytes = await ctx.stub.getState(reqKey);
    if (!reqBytes || reqBytes.length === 0) {
      throw new Error(`reqId ${reqId} not found`);
    }
    const request = JSON.parse(reqBytes.toString()) as ReIDRequest;

    if (request.status !== 'approved') {
      throw new Error(
        `reqId ${reqId} is not approved (status=${request.status})`
      );
    }

    // Escreve na PDC
    const resultKey = `reid_result:${reqId}`;
    const existing = await ctx.stub.getPrivateData(PDC_COLLECTION, resultKey);
    if (existing && existing.length > 0) {
      return; // idempotente
    }

    const result: ReIDResult = { reqId, wp };
    await ctx.stub.putPrivateData(
      PDC_COLLECTION,
      resultKey,
      Buffer.from(JSON.stringify(result))
    );

    // Marca resolvedAt no ledger regular
    const ts = ctx.stub.getTxTimestamp();
    request.resolvedAt = new Date(Number(ts.seconds) * 1000).toISOString();
    await ctx.stub.putState(reqKey, Buffer.from(JSON.stringify(request)));

    ctx.stub.setEvent(
      'ReIDResultRegistered',
      Buffer.from(JSON.stringify({ reqId }))
    );
  }

  /**
   * GetReIDResult — RO lê o WP da PDC.
   */
  @Transaction(false)
  @Returns('string')
  public async GetReIDResult(ctx: Context, reqId: string): Promise<string> {
    const key = `reid_result:${reqId}`;
    const bytes = await ctx.stub.getPrivateData(PDC_COLLECTION, key);
    if (!bytes || bytes.length === 0) {
      throw new Error(`reqId ${reqId} not found in Study_Re-Identification`);
    }
    const result = JSON.parse(bytes.toString()) as ReIDResult;
    return result.wp;
  }

  // -------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------

  private assertCallerIs(ctx: Context, expectedMsp: string): void {
    const mspId = ctx.clientIdentity.getMSPID();
    if (mspId !== expectedMsp) {
      throw new Error(
        `Access denied: only ${expectedMsp} can call this (caller=${mspId})`
      );
    }
  }

  private assertCallerIsAnyOf(ctx: Context, allowed: string[]): void {
    const mspId = ctx.clientIdentity.getMSPID();
    if (!allowed.includes(mspId)) {
      throw new Error(
        `Access denied: caller=${mspId}, allowed=[${allowed.join(',')}]`
      );
    }
  }
}