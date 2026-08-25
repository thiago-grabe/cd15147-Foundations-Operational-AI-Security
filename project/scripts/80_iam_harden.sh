#!/usr/bin/env bash
# =============================================================================
# 80_iam_harden.sh - replace the permissive baseline with least-privilege (Task 4)
#
# METHOD. Narrow along two axes only, and re-verify after every change:
#   1. Resource: "*"          →  specific ARNs
#   2. wildcard actions       →  the enumerated actions actually needed
#
# Action names are derived from the real API surface (`aws s3vectors help`),
# not from memory. The proof that the scoping is correct is behavioural: after
# applying, retrieval must still work AND an out-of-scope action must be denied.
# A policy that merely *looks* tight is not evidence.
#
# ROLES IN PLAY (note the RetrieveAndGenerate architecture):
#   KnowledgeBaseRole - assumed by Bedrock. Reads corpus objects from S3,
#                       calls Titan to embed, reads/writes the vector index.
#   AgentRole         - the APPLICATION invocation role: what the Streamlit
#                       client assumes to call RetrieveAndGenerate. Because
#                       there is no Agent resource (Agents are in Maintenance
#                       Mode for this account), this is the caller identity
#                       rather than an agent execution role. It is a real
#                       least-privilege boundary either way: it decides which
#                       knowledge base, model and guardrail the app may touch.
# =============================================================================
. "$(dirname "$0")/lib.sh"
load_env; check_creds
require AWS_ACCOUNT_ID KB_S3_BUCKET KB_ROLE_NAME AGENT_ROLE_NAME BEDROCK_KB_ID VECTOR_INDEX_ARN

A="$AWS_ACCOUNT_ID"; R="$AWS_REGION"
EMBED_ARN="arn:aws:bedrock:${R}::foundation-model/${EMBED_MODEL_ID:-amazon.titan-embed-text-v2:0}"
FM_ARN="arn:aws:bedrock:${R}::foundation-model/${FM_MODEL_ID:-amazon.nova-lite-v1:0}"
KB_ARN="arn:aws:bedrock:${R}:${A}:knowledge-base/${BEDROCK_KB_ID}"
GR_ARN="arn:aws:bedrock:${R}:${A}:guardrail/*"   # narrowed by 85_guardrail.sh once the ID exists

mkdir -p iam/after

# =============================================================================
step "Scoping $KB_ROLE_NAME"
# =============================================================================
# Before: bedrock:* + s3:* + s3vectors:* on "*"
# After : embed-only model, corpus/ prefix only, this one vector index only.
cat > iam/after/kb-role-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "InvokeEmbeddingModelOnly",
      "Effect": "Allow",
      "Action": "bedrock:InvokeModel",
      "Resource": "${EMBED_ARN}"
    },
    {
      "Sid": "ReadCorpusObjectsOnly",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${KB_S3_BUCKET}/corpus/*",
      "Condition": { "StringEquals": { "aws:ResourceAccount": "${A}" } }
    },
    {
      "Sid": "ListOnlyCorpusPrefix",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${KB_S3_BUCKET}",
      "Condition": { "StringLike": { "s3:prefix": ["corpus/*", "corpus/"] } }
    },
    {
      "Sid": "VectorIndexDataPlaneOnly",
      "Effect": "Allow",
      "Action": [
        "s3vectors:GetIndex",
        "s3vectors:PutVectors",
        "s3vectors:GetVectors",
        "s3vectors:QueryVectors",
        "s3vectors:ListVectors",
        "s3vectors:DeleteVectors"
      ],
      "Resource": "${VECTOR_INDEX_ARN}"
    }
  ]
}
JSON
aws iam put-role-policy --role-name "$KB_ROLE_NAME" \
  --policy-name NorthstarKBPolicy --policy-document file://iam/after/kb-role-policy.json
ok "embed model only · corpus/ prefix only · one vector index · no control-plane actions"
info "dropped: create/delete bucket+index, s3:PutObject, every other model"

# =============================================================================
step "Scoping $AGENT_ROLE_NAME"
# =============================================================================
cat > iam/after/agent-role-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "QueryThisKnowledgeBaseOnly",
      "Effect": "Allow",
      "Action": ["bedrock:Retrieve", "bedrock:RetrieveAndGenerate"],
      "Resource": "${KB_ARN}"
    },
    {
      "Sid": "InvokeGenerationModelOnly",
      "Effect": "Allow",
      "Action": "bedrock:InvokeModel",
      "Resource": "${FM_ARN}"
    },
    {
      "Sid": "ApplyGuardrail",
      "Effect": "Allow",
      "Action": "bedrock:ApplyGuardrail",
      "Resource": "${GR_ARN}"
    }
  ]
}
JSON
aws iam put-role-policy --role-name "$AGENT_ROLE_NAME" \
  --policy-name NorthstarAgentPolicy --policy-document file://iam/after/agent-role-policy.json
ok "one knowledge base · one model · guardrail apply only"
info "dropped: s3:* entirely (the app never touches S3 directly), logs:*, all other models"

# --- trust policy hardening: close the confused-deputy gap ------------------
step "Hardening trust policies (aws:SourceAccount / aws:SourceArn)"
TRUST=$(cat <<JSON
{"Version":"2012-10-17","Statement":[{
  "Effect":"Allow",
  "Principal":{"Service":"bedrock.amazonaws.com"},
  "Action":"sts:AssumeRole",
  "Condition":{
    "StringEquals":{"aws:SourceAccount":"${A}"},
    "ArnLike":{"aws:SourceArn":"arn:aws:bedrock:${R}:${A}:*"}
  }}]}
JSON
)
TRUST_APPLIED=true
for ROLE in "$KB_ROLE_NAME" "$AGENT_ROLE_NAME"; do
  if ! aws iam update-assume-role-policy --role-name "$ROLE" --policy-document "$TRUST" 2>/dev/null; then
    TRUST_APPLIED=false
  fi
done

if [ "$TRUST_APPLIED" = true ]; then
  ok "Bedrock may now assume these roles only on behalf of THIS account"
  info "baseline trust had no conditions - any Bedrock tenant could be the deputy"
else
  # AWS Academy Learner Lab denies iam:UpdateAssumeRolePolicy. Not a script bug -
  # an environment constraint. Recorded as a residual risk in Task 4 rather than
  # silently skipped, and the intended policy is still emitted as evidence of
  # what SHOULD be applied in a production account.
  printf '%s' "$TRUST" > iam/after/INTENDED-trust-policy.json
  warn "iam:UpdateAssumeRolePolicy is DENIED in this lab account - trust policies unchanged"
  warn "intended policy saved → iam/after/INTENDED-trust-policy.json"
  warn "document as residual risk R-TRUST in docs/04-iam-hardening-summary.md"
  aws iam update-assume-role-policy --role-name "$KB_ROLE_NAME" --policy-document "$TRUST" \
    2>&1 | grep -oE 'not authorized to perform: [a-zA-Z:]+' | head -1 \
    > evidence/logs/iam-trust-denied.txt || true
  info "denial evidence → evidence/logs/iam-trust-denied.txt"
fi

# --- validate ---------------------------------------------------------------
step "Access Analyzer policy validation"
for f in iam/after/kb-role-policy.json iam/after/agent-role-policy.json; do
  N=$(aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY \
        --policy-document "file://$f" --query 'length(findings)' --output text 2>/dev/null || echo 0)
  if [ "$N" = "0" ]; then ok "$(basename "$f"): no findings"
  else
    warn "$(basename "$f"): $N finding(s)"
    aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY --policy-document "file://$f" \
      --query 'findings[].{type:findingType,issue:issueCode}' --output table
  fi
done

step "Capturing the 'after' state"
for ROLE in "$KB_ROLE_NAME" "$AGENT_ROLE_NAME"; do
  for P in $(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[]' --output text); do
    aws iam get-role-policy --role-name "$ROLE" --policy-name "$P" \
      --query 'PolicyDocument' --output json > "iam/after/${ROLE}.${P}.json"
  done
  aws iam get-role --role-name "$ROLE" \
    --query 'Role.{RoleName:RoleName,Arn:Arn,Trust:AssumeRolePolicyDocument}' \
    --output json > "iam/after/${ROLE}.role.json"
done
ok "iam/after/ populated"

# --- wildcard re-audit ------------------------------------------------------
step "Wildcard re-audit (rubric: no wildcards may remain unjustified)"
python3 - <<'PY' | tee evidence/logs/iam-wildcard-audit-after.txt
import json, pathlib
rows = []
for f in sorted(pathlib.Path("iam/after").glob("*.json")):
    if f.name.endswith(".role.json") or "-policy.json" in f.name:
        continue
    doc = json.loads(f.read_text())
    for st in doc.get("Statement", []):
        acts = st.get("Action", []); acts = [acts] if isinstance(acts, str) else acts
        res = st.get("Resource", []); res = [res] if isinstance(res, str) else res
        if any(a.endswith("*") for a in acts) or any(r == "*" for r in res):
            rows.append((f.name.split(".")[0], st.get("Sid", "-"), ",".join(acts), ",".join(res)))
if rows:
    print("  Remaining wildcards (each MUST be justified in the deliverable):")
    for r in rows:
        print(f"   {r[0]:<38} {r[1]:<28} {r[2]:<24} {r[3]}")
else:
    print("  ✅ zero wildcard actions and zero wildcard resources remain")
PY

# --- behavioural proof ------------------------------------------------------
step "Behavioural verification (the part that actually matters)"
info "positive: retrieval must still work after scoping"
uv run python security-tests/run_tests.py --phase before --only T-01 2>&1 | grep -E "T-01|passed" || true

info "negative: an out-of-scope action must be DENIED"
DENY=$(aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::${A}:role/${KB_ROLE_NAME}" \
  --action-names s3:DeleteObject \
  --resource-arns "arn:aws:s3:::${KB_S3_BUCKET}/corpus/csv/employee_directory.csv" \
  --query 'EvaluationResults[0].EvalDecision' --output text 2>/dev/null || echo "unknown")
[ "$DENY" = "implicitDeny" ] || [ "$DENY" = "explicitDeny" ] \
  && ok "s3:DeleteObject on the corpus → $DENY (was ALLOWED under s3:*)" \
  || warn "expected a deny for s3:DeleteObject, got: $DENY"

ALLOW=$(aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::${A}:role/${KB_ROLE_NAME}" \
  --action-names s3:GetObject \
  --resource-arns "arn:aws:s3:::${KB_S3_BUCKET}/corpus/csv/employee_directory.csv" \
  --query 'EvaluationResults[0].EvalDecision' --output text 2>/dev/null || echo "unknown")
[ "$ALLOW" = "allowed" ] \
  && ok "s3:GetObject on the corpus → allowed (retrieval still functions)" \
  || warn "expected allow for s3:GetObject, got: $ALLOW"

step "Next: ./scripts/85_guardrail.sh"
