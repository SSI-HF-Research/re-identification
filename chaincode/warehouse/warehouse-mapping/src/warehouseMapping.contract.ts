// warehouseMapping.contract.ts
import { Context, Contract, Returns, Transaction } from 'fabric-contract-api';

const WAREHOUSE_MAPPING_COLLECTION = 'Warehouse_Mapping';

const WPI_MSP_ID = 'OrgWPIMSP';

interface WarehouseMappingValue {
  identityReference: string;
  wp: string;
}

export class WarehouseMappingContract extends Contract {
  constructor() {
    super('WarehouseMappingContract');
  }

  @Transaction(false)
  @Returns('string')
  public async testChaincode(ctx: Context): Promise<string> {
    return 'WarehouseMappingContract is working!';
  }

  /**
   * save_WP(identity_reference_i, WP_i)
   * WP is calculated OFF-CHAIN by the WPI (HMAC(WP_MASTER_KEY, PII_i))
   */
  @Transaction()
  @Returns('string')
  public async RegisterWP(
    ctx: Context,
    identityReference: string
  ): Promise<string> {
    this.assertCallerIsWpi(ctx);

    if (!identityReference || identityReference.length === 0) {
      throw new Error('identityReference is required');
    }

    const transient = ctx.stub.getTransient();
    if (!transient.has('wp')) {
      throw new Error('Transient field "wp" is required');
    }
    const wp = Buffer.from(transient.get('wp')!).toString('utf8');
    if (!wp || wp.length === 0) {
      throw new Error('Transient field "wp" must not be empty');
    }

    const key = `ref:${identityReference}`;
    const existing = await ctx.stub.getPrivateData(WAREHOUSE_MAPPING_COLLECTION, key);
    if (existing && existing.length > 0) {
      return `WP already registered for identityReference ${identityReference}`;
    }

    const value: WarehouseMappingValue = { identityReference, wp };
    await ctx.stub.putPrivateData(
      WAREHOUSE_MAPPING_COLLECTION,
      key,
      Buffer.from(JSON.stringify(value))
    );
    console.log(value);
    return "wp registered";
  }

  @Transaction(false)
  @Returns('string')
  public async GetWP(ctx: Context, identityReference: string): Promise<string> {
    const key = `ref:${identityReference}`;
    const bytes = await ctx.stub.getPrivateData(WAREHOUSE_MAPPING_COLLECTION, key);
    if (!bytes || bytes.length === 0) return '';
    const value = JSON.parse(bytes.toString()) as WarehouseMappingValue;

    return value.wp;
  }
  

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  private assertCallerIsWpi(ctx: Context): void {
    const mspId = ctx.clientIdentity.getMSPID();
    if (mspId !== WPI_MSP_ID) {
      throw new Error(
        `Access denied: only ${WPI_MSP_ID} can register WPs (caller=${mspId})`
      );
    }
  }
}