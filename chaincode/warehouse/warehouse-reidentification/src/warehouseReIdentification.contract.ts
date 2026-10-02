import { Context, Contract, Returns, Transaction } from 'fabric-contract-api';
import { createVerify } from 'crypto';

const PDC_COLLECTION = 'WarehouseReIdentification';
const WPI_MSP_ID = 'OrgWPIMSP';
const MO_MSP_ID  = 'OrgMOMSP';
const EC_MSP_IDS = ['OrgEC1MSP', 'OrgEC2MSP', 'OrgEC3MSP'];
const K_OF_N_THRESHOLD = 2;
const REID_KEY_PREFIX = 'reid:';
const EC_KEY_PREFIX = 'ec_key:';
const RO_MSP_ID  = 'OrgROMSP';
const SPI_MSP_ID = 'OrgSPIMSP';

interface ReIDEntry { reqId: string; pii: string; registeredAt: string; }
interface ReIDApproval { mspId: string; decision: 'approve' | 'reject'; signature: string; }
interface WarehouseReIDRequest {
  reqId: string;
  wp: string;
  spiSignature: string;
  approvals: ReIDApproval[];
  status: 'pending' | 'completed';
  createdAt: string;
}

function warehouseRequestKey(reqId: string): string {
  return `reid_req:${reqId}`;
}

/** Verifies an ECDSA signature over a UTF-8 message using a PEM public key. */
function verifyEcdsa(publicKeyPem: string, message: string, signatureB64: string): boolean {
  try {
    const v = createVerify('SHA256');
    v.update(message, 'utf8');
    v.end();
    return v.verify(publicKeyPem, Buffer.from(signatureB64, 'base64'));
  } catch { return false; }
}

export class WarehouseReIdentificationContract extends Contract {
  /** Creates the Fabric contract with its registered contract name. */
  constructor() { super('WarehouseReIdentificationContract'); }

  /** Confirms that the warehouse re-identification chaincode is installed and reachable. */
  @Transaction(false) @Returns('string')
  public async testChaincode(ctx: Context): Promise<string> {
    return 'WarehouseReIdentificationContract is working!';
  }

  /** Registers the public key of the SPI. */
  @Transaction()
  public async RegisterSPIPublicKey(ctx: Context, publicKeyPem: string): Promise<void> {
    if (!publicKeyPem) throw new Error('publicKeyPem is required');
    await ctx.stub.putState(`spi_key:${SPI_MSP_ID}`, Buffer.from(publicKeyPem));
    ctx.stub.setEvent('SPIPublicKeyRegistered', Buffer.from(JSON.stringify({ mspId: SPI_MSP_ID })));
  }
  /**
   * Registers or replaces the public key for an authorized EC committee member.
   *
   * @param ctx Fabric transaction context and caller identity
   * @param publicKeyPem EC member public key in PEM format
   * @throws when the caller is not an EC member or the key is missing
   */
  @Transaction()
  public async RegisterCommitteeMember(ctx: Context, publicKeyPem: string): Promise<void> {
    const mspId = ctx.clientIdentity.getMSPID();
    if (!EC_MSP_IDS.includes(mspId)) {
      throw new Error(`Only EC members can register keys (caller=${mspId})`);
    }
    if (!publicKeyPem || publicKeyPem.trim().length === 0) {
      throw new Error('publicKeyPem is required');
    }
    await ctx.stub.putState(this.getCommitteeKey(mspId), Buffer.from(publicKeyPem));
    ctx.stub.setEvent('CommitteeMemberRegistered',
      Buffer.from(JSON.stringify({ mspId })));
  }
  
  /**
   * Creates a new warehouse re-identification request.
   *
   * @param ctx Fabric transaction context and caller identity
   * @param reqId re-identification request identifier
   * @returns the request identifier
   * @throws when the caller is not the RO or the request is invalid
   */
  @Transaction() @Returns('string')
  public async CreateWarehouseReIDRequest(ctx: Context, reqId: string): Promise<string> {
    this.assertCallerIs(ctx, RO_MSP_ID);
    if (!reqId) throw new Error('reqId is required');

    const transient = ctx.stub.getTransient();
    const wp           = this.getRequiredTransientValue(transient, 'wp');
    const spiSignature = this.getRequiredTransientValue(transient, 'spiSignature');
    const approvals    = this.parseApprovals(
      this.getRequiredTransientValue(transient, 'approvals')
    );

    const key = warehouseRequestKey(reqId);
    const existing = await ctx.stub.getState(key);
    if (existing && existing.length > 0) return reqId; // idempotente

    const request: WarehouseReIDRequest = {
      reqId, wp, spiSignature, approvals,
      status: 'pending',
      createdAt: new Date(Number(ctx.stub.getTxTimestamp().seconds) * 1000).toISOString(),
    };
    await ctx.stub.putState(key, Buffer.from(JSON.stringify(request)));
    ctx.stub.setEvent('WarehouseReIDRequestCreated', Buffer.from(JSON.stringify({ reqId })));
    return reqId;
  }
  /**
   * Stores re-identified PII in private data after validating K-of-N EC approvals.
   *
   * The caller must be WPI. The PII and JSON-encoded approvals are supplied through
   * transient data so that they are not written to the public ledger.
   *
   * @param ctx Fabric transaction context and caller identity
   * @param reqId re-identification request identifier
   * @returns a message describing whether the value was stored or already existed
   * @throws when transient input is invalid or insufficient approvals are valid
   */
  @Transaction() @Returns('string')
  public async RegisterReIdentifiedPII(ctx: Context, reqId: string): Promise<string> {
    this.assertCallerIs(ctx, WPI_MSP_ID);
    if (!reqId) throw new Error('reqId is required');

    const reqBytes = await ctx.stub.getState(warehouseRequestKey(reqId));
    if (!reqBytes || reqBytes.length === 0) throw new Error(`reqId ${reqId} not found`);
    const request = JSON.parse(reqBytes.toString()) as WarehouseReIDRequest;

    const pii = this.getRequiredTransientValue(ctx.stub.getTransient(), 'pii');

    const approveCount = await this.verifyApprovals(ctx, reqId, request.approvals);
    if (approveCount < K_OF_N_THRESHOLD) {
      throw new Error(`Insufficient valid EC approvals (got ${approveCount}, need ${K_OF_N_THRESHOLD})`);
    }

    const spiKeyBytes = await ctx.stub.getState(`spi_key:${SPI_MSP_ID}`);
    if (!spiKeyBytes || spiKeyBytes.length === 0) {
      throw new Error('SPI public key is not registered on the Warehouse Channel');
    }
    const spiMessage = `spi_resolution:${reqId}:${request.wp}`;
    if (!verifyEcdsa(spiKeyBytes.toString(), spiMessage, request.spiSignature)) {
      throw new Error('Invalid SPI attestation');
    }

    const key = this.getReIdKey(reqId);
    const existing = await this.getPrivateData<ReIDEntry>(ctx, key);
    if (existing) return `reqId ${reqId} already registered, skipping.`;

    const ts = ctx.stub.getTxTimestamp();
    const entry: ReIDEntry = {
      reqId, pii,
      registeredAt: new Date(Number(ts.seconds) * 1000).toISOString(),
    };
    await ctx.stub.putPrivateData(PDC_COLLECTION, key, Buffer.from(JSON.stringify(entry)));

    // request.status = 'completed';
    // await ctx.stub.putState(warehouseRequestKey(reqId), Buffer.from(JSON.stringify(request)));

    ctx.stub.setEvent('WarehouseReIDRegistered',
      Buffer.from(JSON.stringify({ reqId, approveCount })));
    return 'Re-identified PII registered.';
  }

  /**
   * Retrieves re-identified PII from private data for the medical organization.
   *
   * @param ctx Fabric transaction context and caller identity
   * @param reqId re-identification request identifier
   * @returns the PII associated with the request
   * @throws when the caller is not MO or the request does not exist
   */
  @Transaction(false) @Returns('string')
  public async GetReidentifiedPII(ctx: Context, reqId: string): Promise<string> {
    this.assertCallerIs(ctx, MO_MSP_ID);
    const entry = await this.getPrivateData<ReIDEntry>(ctx, this.getReIdKey(reqId));
    if (!entry) throw new Error(`reqId ${reqId} not found`);
    return entry.pii;
  }

  /**
   * Validates each committee signature and counts approvals for a request.
   *
   * @param ctx Fabric transaction context used to read registered public keys
   * @param reqId re-identification request identifier being approved
   * @param approvals committee decisions and their signatures
   * @returns the number of valid approvals
   * @throws when an approval is unknown, duplicated, unsigned, or invalid
   */
  private async verifyApprovals(
    ctx: Context, reqId: string, approvals: ReIDApproval[]
  ): Promise<number> {
    let approveCount = 0;
    const seen = new Set<string>();
    for (const a of approvals) {
      if (!EC_MSP_IDS.includes(a.mspId)) {
        throw new Error(`Unknown EC member: ${a.mspId}`);
      }
      if (seen.has(a.mspId)) {
        throw new Error(`Duplicate approval from ${a.mspId}`);
      }
      seen.add(a.mspId);

      const publicKeyPem = await this.getCommitteePublicKey(ctx, a.mspId);
      if (!publicKeyPem) {
        throw new Error(`No public key registered for ${a.mspId}`);
      }
      if (a.decision !== 'approve' && a.decision !== 'reject') {
        throw new Error(`Invalid decision from ${a.mspId}`);
      }
      const message = `reid_approval:${reqId}:${a.decision}`;
      if (!verifyEcdsa(publicKeyPem, message, a.signature)) {
        throw new Error(`Invalid signature from ${a.mspId}`);
      }
      if (a.decision === 'approve') approveCount++;
    }
    return approveCount;
  }

  /** Builds the private-data key for a re-identification request. */
  private getReIdKey(reqId: string): string {
    return `${REID_KEY_PREFIX}${reqId}`;
  }

  /** Builds the world-state key for an EC committee public key. */
  private getCommitteeKey(mspId: string): string {
    return `${EC_KEY_PREFIX}${mspId}`;
  }

  /** Reads and deserializes a JSON value from the re-identification collection. */
  private async getPrivateData<T>(ctx: Context, key: string): Promise<T | undefined> {
    const bytes = await ctx.stub.getPrivateData(PDC_COLLECTION, key);
    if (!bytes || bytes.length === 0) return undefined;
    return JSON.parse(bytes.toString()) as T;
  }

  /** Reads the registered public key for an EC committee member. */
  private async getCommitteePublicKey(ctx: Context, mspId: string): Promise<string | undefined> {
    const bytes = await ctx.stub.getState(this.getCommitteeKey(mspId));
    if (!bytes || bytes.length === 0) return undefined;
    return bytes.toString();
  }

  /** Decodes a required non-empty UTF-8 value from transient transaction data. */
  private getRequiredTransientValue(
    transient: Map<string, Uint8Array>,
    fieldName: string
  ): string {
    const value = transient.get(fieldName);
    if (!value) throw new Error(`Transient "${fieldName}" is required`);
    const decodedValue = Buffer.from(value).toString('utf8');
    if (!decodedValue) throw new Error(`Transient "${fieldName}" must not be empty`);
    return decodedValue;
  }

  /** Parses and validates the JSON approval list supplied through transient data. */
  private parseApprovals(rawApprovals: string): ReIDApproval[] {
    let parsed: unknown;
    try {
      parsed = JSON.parse(rawApprovals);
    } catch {
      throw new Error('Transient "approvals" must be JSON');
    }
    if (!Array.isArray(parsed)) throw new Error('"approvals" must be an array');

    return parsed.map((approval) => {
      if (!approval || typeof approval !== 'object' || Array.isArray(approval)) {
        throw new Error('Each approval must be an object');
      }
      const value = approval as Partial<ReIDApproval>;
      if (typeof value.mspId !== 'string' || value.mspId.length === 0) {
        throw new Error('Each approval must include an mspId');
      }
      if (value.decision !== 'approve' && value.decision !== 'reject') {
        throw new Error(`Invalid decision from ${value.mspId}`);
      }
      if (typeof value.signature !== 'string' || value.signature.length === 0) {
        throw new Error(`Approval from ${value.mspId} must include a signature`);
      }
      return {
        mspId: value.mspId,
        decision: value.decision,
        signature: value.signature,
      };
    });
  }

  /** Ensures that the transaction caller belongs to the expected organization. */
  private assertCallerIs(ctx: Context, expectedMsp: string): void {
    const mspId = ctx.clientIdentity.getMSPID();
    if (mspId !== expectedMsp) {
      throw new Error(`Access denied: only ${expectedMsp} (caller=${mspId})`);
    }
  }
}