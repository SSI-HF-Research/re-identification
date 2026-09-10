import { Context, Contract, Info, Returns, Transaction } from 'fabric-contract-api';

const IDENTITY_MAPPING_COLLECTION = 'Identity_Mapping';
const IM_MSP_ID = 'OrgIMMSP';

interface IdentityMappingValue {
  identityReference: string;
  pii: string;
}

@Info({ title: 'IdentityMappingContract', description: 'Identity mapping contract' })
export class IdentityMappingContract extends Contract {
  constructor() {
    super('IdentityMappingContract');
  }

  @Transaction(false)
  @Returns('string')
  public async testChaincode(ctx: Context): Promise<string> {
    return 'IdentityMappingContract is working!';
  }

  @Transaction()
  public async RegisterIdentityReference(ctx: Context): Promise<void> {
    const transient = ctx.stub.getTransient();
    if (!transient.has('pii') || !transient.has('identityReference')) {
      throw new Error('Transient fields "pii" and "identityReference" are required');
    }
    const pii = Buffer.from(transient.get('pii')!).toString('utf8');
    const identityReference = Buffer.from(transient.get('identityReference')!).toString('utf8');

    const key = `ref:${identityReference}`;
    const existing = await ctx.stub.getPrivateData(IDENTITY_MAPPING_COLLECTION, key);
    if (existing && existing.length > 0) {
      console.log(`Identity reference already exists. Skipping creation.`);
      return; 
    }

    const value: IdentityMappingValue = { identityReference, pii };
    await ctx.stub.putPrivateData(
      IDENTITY_MAPPING_COLLECTION,
      key,
      Buffer.from(JSON.stringify(value))
    );
  }

  @Transaction(false)
  @Returns('string')
  public async GetPii(ctx: Context, identityReference: string): Promise<string> {
    const key = `ref:${identityReference}`;
    const bytes = await ctx.stub.getPrivateData(IDENTITY_MAPPING_COLLECTION, key);
    if (!bytes || bytes.length === 0) {
      throw new Error(`identityReference ${identityReference} not found in Identity_Mapping`);
    }
    const value = JSON.parse(bytes.toString()) as IdentityMappingValue;
    return value.pii;
  }


  private assertCallerIsIM(ctx: Context): void {
    const mspId = ctx.clientIdentity.getMSPID();
    if (mspId !== IM_MSP_ID) {
      throw new Error(
        `Access denied: only ${IM_MSP_ID} can register WPs (caller=${mspId})`
      );
    }
  }
}