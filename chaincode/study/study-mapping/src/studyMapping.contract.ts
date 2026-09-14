import { Context, Contract, Returns, Transaction } from 'fabric-contract-api';
import { createHmac } from 'crypto';

const STUDY_MAPPING_COLLECTION = 'StudyMapping';

interface StudyMappingReverseValue {
  wp: string;
  datamartId: string;
}

export class StudyMappingContract extends Contract {
  /** Creates the Fabric contract with its registered contract name. */
  constructor() {
    super('StudyMappingContract');
  }

  /** Computes the study pseudonym for a work package using the study key. */
  private computeSp(studyKey: string, wp: string): string {
    return createHmac('sha256', studyKey).update(wp, 'utf8').digest('hex');
  }

  /** Builds the private-data key used for a data mart's WP-to-SP mapping. */
  private datamartKey(datamartId: string): string {
    return `datamart:${datamartId}`;
  }

  /** Builds the private-data key used for the reverse SP-to-WP lookup. */
  private spKey(sp: string): string {
    return `sp:${sp}`;
  }

  /** Reads and parses a data mart's WP-to-SP mapping, if it exists. */
  private async getDatamartMap(
    ctx: Context,
    datamartId: string
  ): Promise<Record<string, string> | null> {
    const bytes = await ctx.stub.getPrivateData(
      STUDY_MAPPING_COLLECTION,
      this.datamartKey(datamartId)
    );
    if (!bytes || bytes.length === 0) return null;
    return JSON.parse(bytes.toString()) as Record<string, string>;
  }

  /** Parses and validates the transient WP list used to register a batch. */
  private parseWpList(raw: Buffer): string[] {
    let value: unknown;
    try {
      value = JSON.parse(raw.toString('utf8'));
    } catch {
      throw new Error('Transient field "wpList" must be a JSON array of WP strings');
    }

    if (
      !Array.isArray(value) ||
      value.length === 0 ||
      !value.every((wp): wp is string => typeof wp === 'string' && wp.length > 0)
    ) {
      throw new Error('"wpList" must be a non-empty array of WP strings');
    }
    if (new Set(value).size !== value.length) {
      throw new Error('"wpList" must not contain duplicate WPs');
    }
    return value;
  }

  /** Registers all work packages for a data mart and creates their reverse indexes. */
  @Transaction()
  public async RegisterSPBatch(ctx: Context, datamartId: string): Promise<string> {
    const transient = ctx.stub.getTransient();
    if (!transient.has('studyKey') || !transient.has('wpList')) {
      throw new Error('Transient fields "studyKey" and "wpList" are required');
    }
    const studyKey = Buffer.from(transient.get('studyKey')!).toString('utf8');
    const wpList = this.parseWpList(Buffer.from(transient.get('wpList')!));

    const oldMap = await this.getDatamartMap(ctx, datamartId);
    if (oldMap) {
      const oldKeys = Object.keys(oldMap);
      const newKeys = new Set(wpList);
      const same =
        oldKeys.length === newKeys.size &&
        oldKeys.every((wp) => newKeys.has(wp));
      if (same) {
        ctx.stub.setEvent('SPBatchAlreadyRegistered',
          Buffer.from(JSON.stringify({ datamartId, count: wpList.length })));
        return "SP batch already registered in Data Mart " + datamartId + ". Skipping creation.";
      }
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

    if (oldMap) {
      for (const [wp, oldSp] of Object.entries(oldMap)) {
        if (datamartMap[wp] !== oldSp) {
          await ctx.stub.deletePrivateData(
            STUDY_MAPPING_COLLECTION,
            this.spKey(oldSp)
          );
        }
      }
    }

    await ctx.stub.putPrivateData(
      STUDY_MAPPING_COLLECTION,
      this.datamartKey(datamartId),
      Buffer.from(JSON.stringify(datamartMap))
    );
    ctx.stub.setEvent('SPBatchRegistered', Buffer.from(JSON.stringify({ datamartId, count: wpList.length })));
    return "SP batch registered successfully in Data Mart " + datamartId + ".";
  }

  /** Returns the complete WP-to-SP mapping registered for a data mart. */
  @Transaction(false)
  @Returns('string')
  public async GetSPListByDatamart(ctx: Context, datamartId: string): Promise<string> {
    const map = await this.getDatamartMap(ctx, datamartId);
    return map ? JSON.stringify(map) : '{}';
  }

  /** Returns the SP associated with a WP in a specific data mart. */
  @Transaction(false)
  @Returns('string')
  public async GetSPForWP(ctx: Context, datamartId: string, wp: string): Promise<string> {
    const map = await this.getDatamartMap(ctx, datamartId);
    return map?.[wp] ?? '';
  }

  /** Returns the WP associated with an SP by using the reverse private-data index. */
  @Transaction(false)
  @Returns('string')
  public async GetWPBySP(ctx: Context, sp: string): Promise<string> {
    const bytes = await ctx.stub.getPrivateData(STUDY_MAPPING_COLLECTION, this.spKey(sp));
    if (!bytes || bytes.length === 0) return '';
    const value = JSON.parse(bytes.toString()) as StudyMappingReverseValue;
    return value.wp;
  }
}