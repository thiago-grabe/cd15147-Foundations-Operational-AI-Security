#!/usr/bin/env bash
# =============================================================================
# 30_vector_store.sh - Amazon S3 Vectors bucket + index
#
# S3 Vectors is pay-per-request. The alternative, OpenSearch Serverless, bills
# a standing hourly minimum (~$10-25/day) whether queried or not and can drain
# a lab budget in two days. This choice is the single biggest cost decision in
# the project.
#
# The index dimension MUST equal the embedding model's output dimension.
# Titan Text Embeddings V2 emits 1024 floats (verified by real invocation in
# 00_preflight.sh check 9). A mismatch here fails at ingestion time with an
# error that does not obviously point back to this file.
#
# Syntax confirmed against `aws s3vectors create-index help` on CLI 2.36.30:
#   --data-type float32   --distance-metric cosine|euclidean   --dimension <=4096
# =============================================================================
. "$(dirname "$0")/lib.sh"
load_env; check_creds
require AWS_ACCOUNT_ID

VBUCKET="${VECTOR_BUCKET:-northstar-vectors-${AWS_ACCOUNT_ID}}"
VINDEX="${VECTOR_INDEX:-northstar-kb-index}"
DIM="${EMBED_DIMENSION:-1024}"

step "S3 Vectors bucket: $VBUCKET"
if aws s3vectors get-vector-bucket --vector-bucket-name "$VBUCKET" >/dev/null 2>&1; then
  skip "vector bucket $VBUCKET"
else
  aws s3vectors create-vector-bucket --vector-bucket-name "$VBUCKET" >/dev/null
  ok "created vector bucket $VBUCKET"
fi

# -----------------------------------------------------------------------------
# nonFilterableMetadataKeys is MANDATORY for Bedrock Knowledge Base integration.
#
# Bedrock stores each chunk's full text in an AMAZON_BEDROCK_TEXT metadata key
# and its source metadata in AMAZON_BEDROCK_METADATA. S3 Vectors caps
# *filterable* metadata at 2048 bytes per vector. Any key not declared
# non-filterable counts against that cap, so a 300-token chunk fails with:
#
#   Invalid record for key '...': Filterable metadata must have at most 2048 bytes
#
# Observed here first-hand: without this, 28 of 30 documents failed to index and
# only two very small ones succeeded. The Bedrock console sets this for you; the
# raw API does not, so it is invisible unless you build via CLI.
# -----------------------------------------------------------------------------
NONFILTERABLE='{"nonFilterableMetadataKeys":["AMAZON_BEDROCK_TEXT","AMAZON_BEDROCK_METADATA"]}'

step "Vector index: $VINDEX (dimension $DIM, cosine, float32)"
if aws s3vectors get-index --vector-bucket-name "$VBUCKET" --index-name "$VINDEX" >/dev/null 2>&1; then
  # An index created without the metadata config is unusable for a KB and
  # cannot be altered in place - it must be recreated.
  HAS_CFG=$(aws s3vectors get-index --vector-bucket-name "$VBUCKET" --index-name "$VINDEX" \
            --query 'index.metadataConfiguration.nonFilterableMetadataKeys' --output text 2>/dev/null || echo "None")
  if [ "$HAS_CFG" = "None" ] || [ -z "$HAS_CFG" ]; then
    warn "index $VINDEX exists WITHOUT nonFilterableMetadataKeys - unusable for a Knowledge Base"
    warn "recreating it (any vectors already written are discarded)"
    aws s3vectors delete-index --vector-bucket-name "$VBUCKET" --index-name "$VINDEX" >/dev/null
    sleep 5
    aws s3vectors create-index \
      --vector-bucket-name "$VBUCKET" --index-name "$VINDEX" \
      --data-type float32 --dimension "$DIM" --distance-metric cosine \
      --metadata-configuration "$NONFILTERABLE" >/dev/null
    ok "recreated index $VINDEX with non-filterable metadata keys"
  else
    skip "index $VINDEX (metadata config present: $HAS_CFG)"
  fi
else
  aws s3vectors create-index \
    --vector-bucket-name "$VBUCKET" \
    --index-name "$VINDEX" \
    --data-type float32 \
    --dimension "$DIM" \
    --distance-metric cosine \
    --metadata-configuration "$NONFILTERABLE" >/dev/null
  ok "created index $VINDEX (AMAZON_BEDROCK_TEXT/METADATA non-filterable)"
fi

# --- resolve the index ARN (needed by create-knowledge-base) ----------------
INDEX_JSON=$(aws s3vectors get-index --vector-bucket-name "$VBUCKET" --index-name "$VINDEX" --output json)
INDEX_ARN=$(printf '%s' "$INDEX_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
idx = d.get('index', d)
for k in ('indexArn', 'arn', 'IndexArn'):
    if idx.get(k):
        print(idx[k]); break
")
[ -n "$INDEX_ARN" ] || die "could not resolve index ARN from get-index output"

VBUCKET_ARN=$(printf '%s' "$INDEX_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin); idx = d.get('index', d)
print(idx.get('vectorBucketArn') or '')
")
[ -n "$VBUCKET_ARN" ] || VBUCKET_ARN="arn:aws:s3vectors:${AWS_REGION}:${AWS_ACCOUNT_ID}:bucket/${VBUCKET}"

# Confirm the index really matches the embedding model, rather than trusting
# the create call succeeded.
ACTUAL_DIM=$(printf '%s' "$INDEX_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin); idx = d.get('index', d)
print(idx.get('dimension', '?'))
")
[ "$ACTUAL_DIM" = "$DIM" ] \
  && ok "index dimension $ACTUAL_DIM matches EMBED_DIMENSION" \
  || die "index dimension $ACTUAL_DIM != EMBED_DIMENSION $DIM - ingestion would fail"

env_set VECTOR_BUCKET     "$VBUCKET"
env_set VECTOR_INDEX      "$VINDEX"
env_set VECTOR_INDEX_ARN  "$INDEX_ARN"
env_set VECTOR_BUCKET_ARN "$VBUCKET_ARN"

printf '%s' "$INDEX_JSON" > evidence/logs/s3vectors-index.json
ok "index metadata → evidence/logs/s3vectors-index.json"

step "Next: ./scripts/40_knowledge_base.sh"
