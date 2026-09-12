import { Context, Contract, Returns, Transaction } from 'fabric-contract-api';

const COLLECTION = 'Warehouse_Re-Identification';
const WPI_MSP_ID = 'OrgWPIMSP';
const MO_MSP_ID  = 'OrgMOMSP';

interface ReIDValue {
  reqId: string;
  pii: string;
}

export class WarehouseReIDContract extends Contract {
  constructor() {
    super('WarehouseReIDContract');
  }

  @Transaction(false)
  @Returns('string')
  public async testChaincode(ctx: Context): Promise<string> {
    return 'WarehouseReIDContract is working!';
  }

  /**
   * RegisterWarehouseReID(reqId, approved)
   * transient: pii
   * Não lê Warehouse_Mapping nem Identity_Mapping.
   */
  @Transaction()
  public async RegisterWarehouseReID(
    ctx: Context,
    reqId: string,
    approved: string
  ): Promise<void> {
    this.assertCallerIsWpi(ctx);

    if (approved !== 'true') {
      throw new Error(
        `Re-identification request ${reqId} is not approved (approved=${approved})`
      );
    }
    if (!reqId || reqId.length === 0) {
      throw new Error('reqId is required');
    }

    const transient = ctx.stub.getTransient();
    if (!transient.has('pii')) {
      throw new Error('Transient field "pii" is required');
    }
    const pii = Buffer.from(transient.get('pii')!).toString('utf8');
    if (!pii) {
      throw new Error('Transient field "pii" must not be empty');
    }

    const key = `reid:${reqId}`;
    const existing = await ctx.stub.getPrivateData(COLLECTION, key);
    if (existing && existing.length > 0) {
      return;
    }

    const value: ReIDValue = { reqId, pii };
    await ctx.stub.putPrivateData(
      COLLECTION,
      key,
      Buffer.from(JSON.stringify(value))
    );

    ctx.stub.setEvent(
      'WarehouseReIDRegistered',
      Buffer.from(JSON.stringify({ reqId }))
    );
  }

  /**
   * GetReidentifiedPII(reqId)
   * RS4.3 — só MO lê.
   */
  @Transaction(false)
  @Returns('string')
  public async GetReidentifiedPII(ctx: Context, reqId: string): Promise<string> {
    this.assertCallerIsMo(ctx);

    const key = `reid:${reqId}`;
    const bytes = await ctx.stub.getPrivateData(COLLECTION, key);
    if (!bytes || bytes.length === 0) {
      throw new Error(`reqId ${reqId} not found in Warehouse_Re-Identification`);
    }
    const value = JSON.parse(bytes.toString()) as ReIDValue;
    return value.pii;
  }

  private assertCallerIsWpi(ctx: Context): void {
    const mspId = ctx.clientIdentity.getMSPID();
    if (mspId !== WPI_MSP_ID) {
      throw new Error(
        `Access denied: only ${WPI_MSP_ID} can register warehouse re-identifications (caller=${mspId})`
      );
    }
  }

  private assertCallerIsMo(ctx: Context): void {
    const mspId = ctx.clientIdentity.getMSPID();
    if (mspId !== MO_MSP_ID) {
      throw new Error(
        `Access denied: only ${MO_MSP_ID} can read re-identified PII (caller=${mspId})`
      );
    }
  }
}