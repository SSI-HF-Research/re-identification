# Security Test Suite

## Purpose

Automated validation of every isolation property the PoC claims. Each file
covers one layer, so a failure isolates exactly which guarantee broke.

## Files

| File | What it verifies | Maps to |
|---|---|---|
| `channel-isolation.sh` | Orgs not in a channel cannot query its chaincodes | Fabric channel policy |
| `pdc-isolation.sh` | Orgs in the channel but not in a collection's policy cannot read it | `memberOnlyRead` on each PDC |
| `function-access.sh` | Every `assertCallerIs(...)` check inside every chaincode | RS1.1, RS1.2, RS4.1-4.4 |
| `ec-signatures.sh` | Every failure mode of the committee approval flow | RF5.1, RS5.1, RS4.4 |
| `cross-channel-leakage.sh` | No actor can bridge channels to reach PII without the committee | RS4.5 |

## Usage

```bash
chmod +x scripts/security/*.sh
./scripts/security/run-all.sh