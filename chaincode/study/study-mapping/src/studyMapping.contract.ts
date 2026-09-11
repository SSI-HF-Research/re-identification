import { Context, Contract, Returns, Transaction } from 'fabric-contract-api';
import { createHmac } from 'crypto';

const STUDY_MAPPING_COLLECTION = 'StudyMapping';

interface StudyMappingReverseValue {
  wp: string;
  datamartId: string;
}

export class StudyMappingContract extends Contract {
  constructor() {
    super('StudyMappingContract');
  }

  private computeSp(studyKey: string, wp: string): string {
    return createHmac('sha256', studyKey).update(wp, 'utf8').digest('hex');
  }

  private datamartKey(datamartId: string): string {
    return `datamart:${datamartId}`;
  }

  private spKey(sp: string): string {
    return `sp:${sp}`;
  }

  @Transaction()
  public async RegisterSPBatch(ctx: Context, datamartId: string): Promise<void> {
    const transient = ctx.stub.getTransient();
    if (!transient.has('studyKey') || !transient.has('wpList')) {
      throw new Error('Transient fields "studyKey" and "wpList" are required');
    }
    const studyKey = Buffer.from(transient.get('studyKey')!).toString('utf8');
    const wpListRaw = Buffer.from(transient.get('wpList')!).toString('utf8');

    let wpList: string[];
    try {
      wpList = JSON.parse(wpListRaw);
    } catch {
      throw new Error('Transient field "wpList" must be a JSON array of WP strings');
    }
    if (!Array.isArray(wpList) || wpList.length === 0) {
      throw new Error('"wpList" must be a non-empty array');
    }

    const existingDatamart = await ctx.stub.getPrivateData(STUDY_MAPPING_COLLECTION, this.datamartKey(datamartId));
    if (existingDatamart && existingDatamart.length > 0) {
      return;
    }

    const datamartMap: Record<string, string> = {};

    for (const wp of wpList) {
      const sp = this.computeSp(studyKey, wp);
      datamartMap[wp] = sp;

      const reverseValue: StudyMappingReverseValue = { wp, datamartId };
      await ctx.stub.putPrivateData(
        STUDY_MAPPING_COLLECTION,
        this.spKey(sp),
        Buffer.from(JSON.stringify(reverseValue))
      );
    }

    await ctx.stub.putPrivateData(
      STUDY_MAPPING_COLLECTION,
      this.datamartKey(datamartId),
      Buffer.from(JSON.stringify(datamartMap))
    );
    ctx.stub.setEvent('SPBatchRegistered', Buffer.from(JSON.stringify({ datamartId, count: wpList.length })));
  }

  @Transaction(false)
  @Returns('string')
  public async GetSPListByDatamart(ctx: Context, datamartId: string): Promise<string> {
    const bytes = await ctx.stub.getPrivateData(STUDY_MAPPING_COLLECTION, this.datamartKey(datamartId));
    if (!bytes || bytes.length === 0) return '{}';
    return bytes.toString();
  }

  @Transaction(false)
  @Returns('string')
  public async GetSPForWP(ctx: Context, datamartId: string, wp: string): Promise<string> {
    const bytes = await ctx.stub.getPrivateData(STUDY_MAPPING_COLLECTION, this.datamartKey(datamartId));
    if (!bytes || bytes.length === 0) return '';
    const map = JSON.parse(bytes.toString()) as Record<string, string>;
    return map[wp] ?? '';
  }

  @Transaction(false)
  @Returns('string')
  public async GetWPBySP(ctx: Context, sp: string): Promise<string> {
    const bytes = await ctx.stub.getPrivateData(STUDY_MAPPING_COLLECTION, this.spKey(sp));
    if (!bytes || bytes.length === 0) return '';
    const value = JSON.parse(bytes.toString()) as StudyMappingReverseValue;
    return value.wp;
  }
}