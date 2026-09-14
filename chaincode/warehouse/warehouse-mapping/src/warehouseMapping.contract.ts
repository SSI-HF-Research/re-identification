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
  /** Creates the Fabric contract with its registered contract name. */
  constructor() {
    super('WarehouseMappingContract');
  }

  /**
   * Performs a basic chaincode health check.
   *
   * @returns a message confirming that this contract is available
   */
  @Transaction(false)
  @Returns('string')
  public async testChaincode(ctx: Context): Promise<string> {
    return 'WarehouseMappingContract is working!';
  }

  /**
   * Registers a warehouse pseudonym (WP) for an identity reference.
   *
   * The WP must be supplied through the transaction transient data under the
   * `wp` field. The method stores both the identity-reference-to-WP mapping
   * and the reverse WP-to-identity-reference mapping in private data.
   * Registration is idempotent when the same pair is submitted again, but it
   * rejects attempts to reuse either value for a different pair.
   *
   * @param ctx Fabric transaction context and caller identity
   * @param identityReference identity reference to associate with the WP
   * @returns a message describing whether the mapping was created or already existed
   * @throws when the caller is not WPI, input is missing, or either value is already bound
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

    const refKey = this.getReferenceKey(identityReference);
    const wpKey = this.getWpKey(wp);

    const existingValue = await this.getPrivateData<WarehouseMappingValue>(ctx, refKey);
    if (existingValue) {
      if (existingValue.wp !== wp) {
        throw new Error(
          `identityReference ${identityReference} already bound to another WP`
        );
      }

      const existingRev = await this.getPrivateData<WarehouseMappingReverseValue>(ctx, wpKey);
      if (!existingRev) {
        const revValue: WarehouseMappingReverseValue = { identityReference };
        await ctx.stub.putPrivateData(
          WAREHOUSE_MAPPING_COLLECTION,
          wpKey,
          Buffer.from(JSON.stringify(revValue))
        );
      }

      return `WP already registered for identityReference ${identityReference}`;
    }

    const existingRev = await this.getPrivateData<WarehouseMappingReverseValue>(ctx, wpKey);
    if (existingRev) {
      const rev = existingRev;
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
    const value = await this.getPrivateData<WarehouseMappingValue>(
      ctx,
      this.getReferenceKey(identityReference)
    );
    return value?.wp ?? '';
  }

  /**
   * Resolves a warehouse pseudonym back to its identity reference.
   *
   * This is a read-only transaction used by the re-identification flow.
   *
   * @param ctx Fabric transaction context
   * @param wp warehouse pseudonym to resolve
   * @returns the associated identity reference, or an empty string when absent
   */
  @Transaction(false)
  @Returns('string')
  public async GetIdentityReferenceByWP(ctx: Context, wp: string): Promise<string> {
    const value = await this.getPrivateData<WarehouseMappingReverseValue>(
      ctx,
      this.getWpKey(wp)
    );
    return value?.identityReference ?? '';
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /** Builds the private-data key for an identity-reference lookup. */
  private getReferenceKey(identityReference: string): string {
    return `ref:${identityReference}`;
  }

  /** Builds the private-data key for a warehouse-pseudonym lookup. */
  private getWpKey(wp: string): string {
    return `wp:${wp}`;
  }

  /** Reads and deserializes a JSON value from the mapping collection. */
  private async getPrivateData<T>(ctx: Context, key: string): Promise<T | undefined> {
    const bytes = await ctx.stub.getPrivateData(WAREHOUSE_MAPPING_COLLECTION, key);
    if (!bytes || bytes.length === 0) return undefined;
    return JSON.parse(bytes.toString()) as T;
  }

  /** Ensures that only the WPI organization can create warehouse mappings. */
  private assertCallerIsWpi(ctx: Context): void {
    const mspId = ctx.clientIdentity.getMSPID();
    if (mspId !== WPI_MSP_ID) {
      throw new Error(
        `Access denied: only ${WPI_MSP_ID} can register WPs (caller=${mspId})`
      );
    }
  }
}