```bash
#!/bin/bash
# ============================================================================
# 00-config.sh — Security test configuration.
#
# PURPOSE
#   Declares the ground truth of channel membership and PDC membership so
#   that the test scripts can check both positive and negative cases.
#
# METRICS SERVED
#   All security tests. This file is data, not logic.
# ============================================================================

CHANNEL_WAREHOUSE="${CHANNEL_WAREHOUSE:-warehouse-channel}"
CHANNEL_STUDY="${CHANNEL_STUDY:-study-channel}"
CC_IDENTITY="${CC_IDENTITY:-identity-mapping}"
CC_WAREHOUSE="${CC_WAREHOUSE:-warehouse-mapping}"
CC_STUDY="${CC_STUDY:-study-mapping}"
CC_SREID="${CC_SREID:-study-reidentification}"
CC_WREID="${CC_WREID:-warehouse-reidentification}"

WP_MASTER_KEY="${WP_MASTER_KEY:-test-wp-master-key}"
SP_MASTER_KEY="${SP_MASTER_KEY:-test-sp-master-key}"
STUDY_ID="${STUDY_ID:-study-poc}"

# --- Channel membership (from configtx.yaml) --------------------------------
WAREHOUSE_CHANNEL_ORGS=(OrgIM OrgWPI OrgHDW OrgMO OrgRO OrgEC1 OrgEC2 OrgEC3)
STUDY_CHANNEL_ORGS=(OrgSC OrgSPI OrgMO OrgRO OrgEC1 OrgEC2 OrgEC3)

# --- PDC membership (from each collections_config.json) ---------------------
IDENTITY_MAPPING_MEMBERS=(OrgIM OrgWPI)
WAREHOUSE_MAPPING_MEMBERS=(OrgWPI OrgHDW)
WAREHOUSE_REID_MEMBERS=(OrgWPI OrgMO)
STUDY_MAPPING_MEMBERS=(OrgSC OrgSPI)
STUDY_REID_MEMBERS=(OrgSPI OrgRO)

# --- EC committee (K-of-N) --------------------------------------------------
EC_MEMBERS=(OrgEC1 OrgEC2 OrgEC3)
EC_DOMAINS=(ec1.example.com ec2.example.com ec3.example.com)

# --- Output paths -----------------------------------------------------------
SEC_DIR="${SEC_DIR:-$ROOT/security-results}"
mkdir -p "$SEC_DIR"