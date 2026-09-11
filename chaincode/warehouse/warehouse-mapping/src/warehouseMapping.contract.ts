// warehouseMapping.contract.ts
import { Context, Contract, Returns, Transaction } from 'fabric-contract-api';

const WAREHOUSE_MAPPING_COLLECTION = 'WarehouseMapping';
const WPI_MSP_ID = 'OrgWPIMSP';

interface WarehouseMappingValue {
  identityReference: string;
  wp: string;
}

interface WarehouseMappingReverseValue {
  identityReference: string;
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
   * WP is generated OFF-CHAIN by WPI: HMAC(WP_MASTER_KEY, PII_i)
   * Saves:
   *   ref:<identityReference> -> { identityReference, wp }
   *   wp:<wp>                 -> { identityReference }
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

    const refKey = `ref:${identityReference}`;
    const wpKey = `wp:${wp}`;

    const existingRef = await ctx.stub.getPrivateData(
      WAREHOUSE_MAPPING_COLLECTION,
      refKey
    );
    if (existingRef && existingRef.length > 0) {
      const existingValue = JSON.parse(existingRef.toString()) as WarehouseMappingValue;
      if (existingValue.wp !== wp) {
        throw new Error(
          `identityReference ${identityReference} already bound to another WP`
        );
      }

      const existingRev = await ctx.stub.getPrivateData(
        WAREHOUSE_MAPPING_COLLECTION,
        wpKey
      );
      if (!existingRev || existingRev.length === 0) {
        const revValue: WarehouseMappingReverseValue = { identityReference };
        await ctx.stub.putPrivateData(
          WAREHOUSE_MAPPING_COLLECTION,
          wpKey,
          Buffer.from(JSON.stringify(revValue))
        );
      }

      return `WP already registered for identityReference ${identityReference}`;
    }

    const existingRev = await ctx.stub.getPrivateData(
      WAREHOUSE_MAPPING_COLLECTION,
      wpKey
    );
    if (existingRev && existingRev.length > 0) {
      const rev = JSON.parse(existingRev.toString()) as WarehouseMappingReverseValue;
      if (rev.identityReference !== identityReference) {
        throw new Error(
          `WP already bound to another identityReference (${rev.identityReference})`
        );
      }
    }

    const value: WarehouseMappingValue = { identityReference, wp };
    await ctx.stub.putPrivateData(
      WAREHOUSE_MAPPING_COLLECTION,
      refKey,
      Buffer.from(JSON.stringify(value))
    );

    const revValue: WarehouseMappingReverseValue = { identityReference };
    await ctx.stub.putPrivateData(
      WAREHOUSE_MAPPING_COLLECTION,
      wpKey,
      Buffer.from(JSON.stringify(revValue))
    );
    
    ctx.stub.setEvent('WPRegistered', Buffer.from(JSON.stringify({ identityReference })));
    return 'wp registered';
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

  /**
   * reverse lookup: WP -> identityReference.
   * used for re-identification
   */
  @Transaction(false)
  @Returns('string')
  public async GetIdentityReferenceByWP(ctx: Context, wp: string): Promise<string> {
    const key = `wp:${wp}`;
    const bytes = await ctx.stub.getPrivateData(WAREHOUSE_MAPPING_COLLECTION, key);
    if (!bytes || bytes.length === 0) return '';
    const value = JSON.parse(bytes.toString()) as WarehouseMappingReverseValue;
    return value.identityReference;
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