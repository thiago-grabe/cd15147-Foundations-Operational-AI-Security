#!/usr/bin/env bash
# =============================================================================
# 10_s3_bucket.sh - document bucket + corpus upload
#
# Creates the S3 bucket that backs the Knowledge Base and uploads all 30
# starter documents under a corpus/ prefix.
#
# Two deliberate choices, both load-bearing later:
#
#   versioning ON  - lets the IR playbook (Task 6) answer "when did this
#                    document change, and to what?" via list-object-versions.
#                    Turns a documentation exercise into a real forensic
#                    capability, and enables C6 containment (version rollback).
#
#   corpus/ prefix - reserves prefix space for the Phase 8 injection canary,
#                    and makes Task 4's IAM scoping a genuine prefix condition
#                    rather than a whole-bucket grant. Uploading to the bucket
#                    root would forfeit both.
#
# Idempotent: safe to re-run. s3 sync will not duplicate objects.
# =============================================================================
. "$(dirname "$0")/lib.sh"
load_env; check_creds

BUCKET="${KB_S3_BUCKET:-northstar-kb-docs-${AWS_ACCOUNT_ID}}"
CORPUS_SRC="$PROJECT_DIR/northstar-knowledge-base"

step "S3 document bucket: $BUCKET"

[ -d "$CORPUS_SRC" ] || die "corpus not found at $CORPUS_SRC"

# --- create -----------------------------------------------------------------
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  skip "bucket $BUCKET"
else
  # us-east-1 must NOT pass a LocationConstraint; every other region must.
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region us-east-1 >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
  fi
  ok "created bucket $BUCKET"
fi

# --- harden -----------------------------------------------------------------
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
ok "public access fully blocked (all 4 settings)"

aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
ok "versioning enabled (forensic timeline for the IR playbook)"

aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
ok "default encryption SSE-S3 enabled"

# --- upload -----------------------------------------------------------------
step "Uploading corpus → s3://$BUCKET/corpus/"
aws s3 sync "$CORPUS_SRC/" "s3://$BUCKET/corpus/" --only-show-errors
COUNT=$(aws s3 ls "s3://$BUCKET/corpus/" --recursive | grep -c . || true)
ok "$COUNT objects under corpus/"

if [ "$COUNT" -ne 30 ]; then
  warn "expected 30 objects, found $COUNT"
  warn "the rubric depends on all six formats being indexed - investigate before continuing"
else
  ok "all 30 starter documents present across 6 formats"
fi

# Per-format breakdown - proves csv/docx/html/pdf/txt/xlsx all landed, which is
# what Tasks 5 and 7 depend on (the sensitive material is NOT in txt/).
step "Per-format breakdown"
for fmt in csv docx html pdf txt xlsx; do
  n=$(aws s3 ls "s3://$BUCKET/corpus/$fmt/" --recursive 2>/dev/null | grep -c . || true)
  printf '  %-5s %s\n' "$fmt" "$n"
done

env_set KB_S3_BUCKET "$BUCKET"

aws s3api list-objects-v2 --bucket "$BUCKET" --prefix corpus/ \
  --query 'Contents[].{Key:Key,Size:Size}' --output json > evidence/logs/s3-corpus-inventory.json
ok "inventory → evidence/logs/s3-corpus-inventory.json"

step "Done - next: ./scripts/20_iam_baseline.sh"
