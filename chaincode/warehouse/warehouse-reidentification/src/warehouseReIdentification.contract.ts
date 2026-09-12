import { Context, Contract, Returns, Transaction } from 'fabric-contract-api';

const PDC_COLLECTION = 'WarehouseReIdentification';

const WPI_MSP_ID = 'OrgWPIMSP';
const MO_MSP_ID  = 'OrgMOMSP';

interface ReIDEntry {
  reqId: string;
  pii: string;
  registeredAt: string;
}

export class WarehouseReIdentificationContract extends Contract {
  constructor() {
    super('WarehouseReIdentificationContract');
  }

  @Transaction(false)
  @Returns('string')
  public async testChaincode(ctx: Context): Promise<string> {
    return 'WarehouseReIdentificationContract is working!';
  }

  /**
   * RegisterWarehouseReID
   * WPI stores the resolved PII in Warehouse Re-Identification.
   *
   * WP -> ref -> PII is done by the WPI in the warehouse-mapping and identity-mapping chaincodes, using warehouse-mapping.GetIdentityReferenceByWP and
   * identity-mapping.GetPii, before this call.
   * This function doesnt read other PDCs
   */
  @Transaction()
  @Returns('string')
  public async RegisterReIdentifiedPII(
    ctx: Context,
    reqId: string,
    // would bring also the approval signatures from the committe
  ): Promise<string> {
    this.assertCallerIs(ctx, WPI_MSP_ID);
    if (!reqId) throw new Error('reqId is required');

    const transient = ctx.stub.getTransient();
    if (!transient.has('pii')) {
      throw new Error('Transient field "pii" is required');
    }
    const pii = Buffer.from(transient.get('pii')!).toString('utf8');
    if (!pii) throw new Error('Transient field "pii" must not be empty');

    const key = `reid:${reqId}`;
    const existing = await ctx.stub.getPrivateData(PDC_COLLECTION, key);
    if (existing && existing.length > 0) {
      return `reqId ${reqId} already exists in Warehouse_Re-Identification, skipping registration.`; 
    }

    const ts = ctx.stub.getTxTimestamp();
    const registeredAt = new Date(Number(ts.seconds) * 1000).toISOString();

    const value: ReIDEntry = { reqId, pii, registeredAt };
    await ctx.stub.putPrivateData(
      PDC_COLLECTION,
      key,
      Buffer.from(JSON.stringify(value))
    );

    ctx.stub.setEvent(
      'WarehouseReIDRegistered',
      Buffer.from(JSON.stringify({ reqId }))
    );

    return "Re-identified PII registered successfully in the Warehouse Re-Identification PDC.";
  }

  @Transaction(false)
  @Returns('string')
  public async GetReidentifiedPII(ctx: Context, reqId: string): Promise<string> {
    this.assertCallerIs(ctx, MO_MSP_ID);

    const key = `reid:${reqId}`;
    const bytes = await ctx.stub.getPrivateData(PDC_COLLECTION, key);
    if (!bytes || bytes.length === 0) {
      throw new Error(`reqId ${reqId} not found in Warehouse_Re-Identification`);
    }
    const value = JSON.parse(bytes.toString()) as ReIDEntry;
    return value.pii;
  }

  private assertCallerIs(ctx: Context, expectedMsp: string): void {
    const mspId = ctx.clientIdentity.getMSPID();
    if (mspId !== expectedMsp) {
      throw new Error(
        `Access denied: only ${expectedMsp} can call this (caller=${mspId})`
      );
    }
  }
}