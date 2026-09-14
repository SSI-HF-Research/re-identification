import { Context, Contract, Info, Returns, Transaction } from 'fabric-contract-api';

const IDENTITY_MAPPING_COLLECTION = 'IdentityMapping';
const IM_MSP_ID = 'OrgIMMSP';

interface IdentityMappingValue {
  identityReference: string;
  pii: string;
}

@Info({ title: 'IdentityMappingContract', description: 'Identity mapping contract' })
export class IdentityMappingContract extends Contract {
  /** Creates the contract with the name exposed to Fabric. */
  constructor() {
    super('IdentityMappingContract');
  }

  /** Confirms that the identity-mapping chaincode is installed and reachable. */
  @Transaction(false)
  @Returns('string')
  public async testChaincode(ctx: Context): Promise<string> {
    return 'IdentityMappingContract is working!';
  }

  /** Registers a PII value under an identity reference using transient data. */
  @Transaction()
  @Returns('string')
  public async RegisterIdentityReference(ctx: Context): Promise<string> {
    this.assertCallerIsIM(ctx);

    const transient = ctx.stub.getTransient();
    const pii = this.getRequiredTransientValue(transient, 'pii');
    const identityReference = this.getRequiredTransientValue(
      transient,
      'identityReference'
    );

    const key = this.getIdentityReferenceKey(identityReference);
    const existing = await ctx.stub.getPrivateData(IDENTITY_MAPPING_COLLECTION, key);
    if (existing && existing.length > 0) {
      ctx.stub.setEvent('IdentityAlreadyExists', Buffer.from(JSON.stringify({identityReference})));
      return `Identity reference already exists. Skipping creation.`; 
    }

    const value: IdentityMappingValue = { identityReference, pii };
    await ctx.stub.putPrivateData(
      IDENTITY_MAPPING_COLLECTION,
      key,
      Buffer.from(JSON.stringify(value))
    );
    ctx.stub.setEvent('IdentityRegistered', Buffer.from(JSON.stringify({identityReference})));
    return `Identity reference registered successfully.`;
  }

  /** Retrieves the PII associated with an identity reference. */
  @Transaction(false)
  @Returns('string')
  public async GetPii(ctx: Context, identityReference: string): Promise<string> {
    const value = await this.getIdentityMapping(ctx, identityReference);
    if (!value) {
      throw new Error(`identityReference ${identityReference} not found in Identity_Mapping`);
    }
    return value.pii;
  }

  /** Builds the private-data key used for an identity reference. */
  private getIdentityReferenceKey(identityReference: string): string {
    return `ref:${identityReference}`;
  }

  /** Reads and parses an identity mapping from the private collection. */
  private async getIdentityMapping(
    ctx: Context,
    identityReference: string
  ): Promise<IdentityMappingValue | null> {
    const bytes = await ctx.stub.getPrivateData(
      IDENTITY_MAPPING_COLLECTION,
      this.getIdentityReferenceKey(identityReference)
    );
    if (!bytes || bytes.length === 0) {
      return null;
    }
    return JSON.parse(bytes.toString()) as IdentityMappingValue;
  }

  /** Decodes a required non-empty UTF-8 value from transient transaction data. */
  private getRequiredTransientValue(
    transient: Map<string, Uint8Array>,
    fieldName: string
  ): string {
    const value = transient.get(fieldName);
    if (!value) {
      throw new Error(`Transient field "${fieldName}" is required`);
    }
    const decodedValue = Buffer.from(value).toString('utf8');
    if (!decodedValue) {
      throw new Error(`Transient field "${fieldName}" must not be empty`);
    }
    return decodedValue;
  }

  /** Ensures that only the identity-management organization can register mappings. */
  private assertCallerIsIM(ctx: Context): void {
    const mspId = ctx.clientIdentity.getMSPID();
    if (mspId !== IM_MSP_ID) {
      throw new Error(
        `Access denied: only ${IM_MSP_ID} can register identity references (caller=${mspId})`
      );
    }
  }
}