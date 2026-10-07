import { Context, Contract, Info, Returns, Transaction } from 'fabric-contract-api';

const IDENTITY_MAPPING_COLLECTION = 'IdentityMapping';
const IM_MSP_ID = 'OrgIMMSP';
const MAX_BATCH_SIZE = 1000;

interface IdentityRecord { pii: string; }

@Info({ title: 'IdentityMappingContract', description: 'Identity mapping contract' })
export class IdentityMappingContract extends Contract {
  constructor() { super('IdentityMappingContract'); }

  @Transaction(false) @Returns('string')
  public async testChaincode(ctx: Context): Promise<string> {
    return 'IdentityMappingContract is working!';
  }

  /**
   * Batch ingestion of PIIs.
   *
   * Transient: { piis: string[] } (JSON)
   * Returns:   JSON array of identity references, one per PII, same order.
   *            Each ref is `<txId>:<index>` — stable, unique, and self-describing.
   *
   * Only the PII is persisted per ref; the batch/index metadata is implied
   * by the key layout, so re-identification needs a single lookup.
   */
  @Transaction() @Returns('string')
  public async RegisterIdentityReferenceBatch(ctx: Context): Promise<string> {
    this.assertCallerIsIM(ctx);

    const raw = this.getRequiredTransient(ctx.stub.getTransient(), 'piis');
    let piis: unknown;
    try { piis = JSON.parse(raw); } catch { throw new Error('Transient "piis" must be JSON'); }
    if (!Array.isArray(piis) || piis.length === 0) {
      throw new Error('"piis" must be a non-empty array');
    }
    if (piis.length > MAX_BATCH_SIZE) {
      throw new Error(`batch size ${piis.length} exceeds ${MAX_BATCH_SIZE}`);
    }

    const txId = ctx.stub.getTxID();
    const refs: string[] = [];

    for (let i = 0; i < piis.length; i++) {
      const pii = piis[i];
      if (typeof pii !== 'string' || pii.length === 0) {
        throw new Error(`piis[${i}] must be a non-empty string`);
      }

      const key = ctx.stub.createCompositeKey('ref', [txId, String(i)]);
      const record: IdentityRecord = { pii };
      await ctx.stub.putPrivateData(
        IDENTITY_MAPPING_COLLECTION,
        key,
        Buffer.from(JSON.stringify(record)),
      );
      refs.push(`${txId}:${i}`);
    }

    ctx.stub.setEvent('IdentityBatchRegistered',
      Buffer.from(JSON.stringify({ batchId: txId, count: refs.length })));
    return JSON.stringify(refs);
  }

  /**
   * Re-identification: ref -> PII. Single lookup, no scans.
   */
  @Transaction(false) @Returns('string')
  public async GetPii(ctx: Context, identityReference: string): Promise<string> {
    if (!identityReference) throw new Error('identityReference is required');
    const { batchId, index } = this.splitRef(identityReference);
    const key = ctx.stub.createCompositeKey('ref', [batchId, index]);
    const bytes = await ctx.stub.getPrivateData(IDENTITY_MAPPING_COLLECTION, key);
    if (!bytes || bytes.length === 0) {
      throw new Error(`identityReference ${identityReference} not found`);
    }
    return (JSON.parse(bytes.toString()) as IdentityRecord).pii;
  }

  // -------------------------------------------------------------------------

  private splitRef(ref: string): { batchId: string; index: string } {
    const sep = ref.lastIndexOf(':');
    if (sep <= 0) throw new Error(`invalid identityReference "${ref}"`);
    return { batchId: ref.slice(0, sep), index: ref.slice(sep + 1) };
  }

  private getRequiredTransient(transient: Map<string, Uint8Array>, field: string): string {
    const v = transient.get(field);
    if (!v) throw new Error(`Transient field "${field}" is required`);
    const s = Buffer.from(v).toString('utf8');
    if (!s) throw new Error(`Transient field "${field}" must not be empty`);
    return s;
  }

  private assertCallerIsIM(ctx: Context): void {
    const mspId = ctx.clientIdentity.getMSPID();
    if (mspId !== IM_MSP_ID) {
      throw new Error(`Access denied: only ${IM_MSP_ID} (caller=${mspId})`);
    }
  }
}