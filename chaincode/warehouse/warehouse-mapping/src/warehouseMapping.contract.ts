import { Context, Contract, Returns, Transaction } from 'fabric-contract-api';

const WAREHOUSE_MAPPING_COLLECTION = 'WarehouseMapping';
const WPI_MSP_ID = 'OrgWPIMSP';
const MAX_BATCH_SIZE = 10000;

interface RefToWp { wp: string; }
interface WpToRef { ref: string; }
interface PairInput { identityReference: string; wp: string; }

export class WarehouseMappingContract extends Contract {
  constructor() { super('WarehouseMappingContract'); }

  @Transaction(false) @Returns('string')
  public async testChaincode(ctx: Context): Promise<string> {
    return 'WarehouseMappingContract is working!';
  }

  @Transaction() @Returns('string')
  public async RegisterWPBatch(ctx: Context): Promise<string> {
    this.assertCallerIsWpi(ctx);

    const raw = this.getRequiredTransient(ctx.stub.getTransient(), 'pairs');
    let parsed: unknown;
    try { parsed = JSON.parse(raw); } catch { throw new Error('Transient "pairs" must be JSON'); }
    if (!Array.isArray(parsed) || parsed.length === 0) {
      throw new Error('"pairs" must be a non-empty array');
    }
    if (parsed.length > MAX_BATCH_SIZE) {
      throw new Error(`batch size ${parsed.length} exceeds ${MAX_BATCH_SIZE}`);
    }

    const entries: PairInput[] = [];
    const seenRefs = new Set<string>();
    const seenWps = new Set<string>();
    let imBatchId: string | null = null;

    for (let i = 0; i < parsed.length; i++) {
      const p = parsed[i] as Partial<PairInput>;
      if (!p || typeof p !== 'object' || Array.isArray(p)) {
        throw new Error(`pairs[${i}] must be an object`);
      }
      if (typeof p.identityReference !== 'string' || p.identityReference.length === 0) {
        throw new Error(`pairs[${i}].identityReference must be a non-empty string`);
      }
      if (typeof p.wp !== 'string' || p.wp.length === 0) {
        throw new Error(`pairs[${i}].wp must be a non-empty string`);
      }
      if (seenRefs.has(p.identityReference)) {
        throw new Error(`duplicate identityReference: ${p.identityReference}`);
      }
      if (seenWps.has(p.wp)) {
        throw new Error(`duplicate wp: ${p.wp}`);
      }
      seenRefs.add(p.identityReference);
      seenWps.add(p.wp);

      const refBatch = this.batchIdOf(p.identityReference);
      if (imBatchId === null) imBatchId = refBatch;
      else if (imBatchId !== refBatch) {
        throw new Error(`all pairs must belong to the same IM batch (got "${imBatchId}" and "${refBatch}")`);
      }

      entries.push({ identityReference: p.identityReference, wp: p.wp });
    }
    if (imBatchId === null) throw new Error('no pairs to register');

    for (const e of entries) {
      const existingRef = await this.getRefToWp(ctx, e.identityReference);
      if (existingRef && existingRef.wp !== e.wp) {
        throw new Error(`ref ${e.identityReference} already bound to another wp`);
      }
      const existingWp = await this.getWpToRef(ctx, e.wp);
      if (existingWp && existingWp.ref !== e.identityReference) {
        throw new Error(`wp ${e.wp} already bound to another ref (${existingWp.ref})`);
      }
    }

    for (const e of entries) {
      await ctx.stub.putPrivateData(
        WAREHOUSE_MAPPING_COLLECTION,
        this.refKey(ctx, e.identityReference),
        Buffer.from(JSON.stringify({ wp: e.wp } as RefToWp)),
      );
      await ctx.stub.putPrivateData(
        WAREHOUSE_MAPPING_COLLECTION,
        this.wpKey(ctx, e.wp),
        Buffer.from(JSON.stringify({ ref: e.identityReference } as WpToRef)),
      );
    }

    const mappingTxId = ctx.stub.getTxID();
    ctx.stub.setEvent('WPBatchRegistered',
      Buffer.from(JSON.stringify({ imBatchId, mappingTxId, count: entries.length })));

    return JSON.stringify({ count: entries.length, imBatchId, mappingTxId });
  }

  @Transaction(false) @Returns('string')
  public async GetWP(ctx: Context, identityReference: string): Promise<string> {
    if (!identityReference) throw new Error('identityReference is required');
    const v = await this.getRefToWp(ctx, identityReference);
    return v?.wp ?? '';
  }

  @Transaction(false) @Returns('string')
  public async GetIdentityReferenceByWP(ctx: Context, wp: string): Promise<string> {
    if (!wp) throw new Error('wp is required');
    const v = await this.getWpToRef(ctx, wp);
    if (!v) throw new Error(`wp ${wp} not found`);
    return v.ref;
  }

  // -------------------------------------------------------------------------

  private refKey(ctx: Context, ref: string): string {
    return ctx.stub.createCompositeKey('map_ref', [ref]);
  }

  private wpKey(ctx: Context, wp: string): string {
    return ctx.stub.createCompositeKey('map_wp', [wp]);
  }

  private async getRefToWp(ctx: Context, ref: string): Promise<RefToWp | undefined> {
    const bytes = await ctx.stub.getPrivateData(WAREHOUSE_MAPPING_COLLECTION, this.refKey(ctx, ref));
    if (!bytes || bytes.length === 0) return undefined;
    return JSON.parse(bytes.toString()) as RefToWp;
  }

  private async getWpToRef(ctx: Context, wp: string): Promise<WpToRef | undefined> {
    const bytes = await ctx.stub.getPrivateData(WAREHOUSE_MAPPING_COLLECTION, this.wpKey(ctx, wp));
    if (!bytes || bytes.length === 0) return undefined;
    return JSON.parse(bytes.toString()) as WpToRef;
  }

  private batchIdOf(ref: string): string {
    const sep = ref.lastIndexOf(':');
    if (sep <= 0) throw new Error(`identityReference "${ref}" is not in <batchId>:<index> format`);
    return ref.slice(0, sep);
  }

  private getRequiredTransient(transient: Map<string, Uint8Array>, field: string): string {
    const v = transient.get(field);
    if (!v) throw new Error(`Transient field "${field}" is required`);
    const s = Buffer.from(v).toString('utf8');
    if (!s) throw new Error(`Transient field "${field}" must not be empty`);
    return s;
  }

  private assertCallerIsWpi(ctx: Context): void {
    const mspId = ctx.clientIdentity.getMSPID();
    if (mspId !== WPI_MSP_ID) {
      throw new Error(`Access denied: only ${WPI_MSP_ID} (caller=${mspId})`);
    }
  }
}