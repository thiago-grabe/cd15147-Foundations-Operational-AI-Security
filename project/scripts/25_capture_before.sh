#!/usr/bin/env bash
# =============================================================================
# 25_capture_before.sh - snapshot the pre-hardening IAM state
#
# ⚠️  IRREVERSIBLE IF SKIPPED. put-role-policy overwrites in place; there is no
# version history on inline role policies. Once 80_iam_harden.sh runs, the
# original document is gone from AWS forever.
#
# Task 4 explicitly requires "documentation of the original and scoped IAM
# permissions". This is the only chance to capture the original.
#
# Also emits a human-readable wildcard audit that seeds the deliverable table.
# =============================================================================
. "$(dirname "$0")/lib.sh"
load_env; check_creds
require AGENT_ROLE_NAME KB_ROLE_NAME

mkdir -p iam/before
step "Capturing pre-hardening IAM state → iam/before/"

for ROLE in "$KB_ROLE_NAME" "$AGENT_ROLE_NAME"; do
  aws iam get-role --role-name "$ROLE" \
    --query 'Role.{RoleName:RoleName,Arn:Arn,Created:CreateDate,Trust:AssumeRolePolicyDocument}' \
    --output json > "iam/before/${ROLE}.role.json"
  ok "$ROLE → role + trust policy"

  aws iam list-attached-role-policies --role-name "$ROLE" \
    --output json > "iam/before/${ROLE}.attached.json"

  for P in $(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[]' --output text); do
    aws iam get-role-policy --role-name "$ROLE" --policy-name "$P" \
      --query 'PolicyDocument' --output json > "iam/before/${ROLE}.${P}.json"
    ok "$ROLE → inline policy $P"
  done
done

# --- wildcard audit ---------------------------------------------------------
# Enumerates exactly what Task 4 asks you to find. Output feeds the
# before/after table in docs/04-iam-hardening-summary.md.
step "Wildcard audit (what Task 4 asks you to identify)"

python3 - <<'PY' | tee evidence/logs/iam-wildcard-audit.txt
import json, pathlib

rows = []
for f in sorted(pathlib.Path("iam/before").glob("*.json")):
    if f.name.endswith((".role.json", ".attached.json")):
        continue
    doc = json.loads(f.read_text())
    role = f.name.split(".")[0]
    for st in doc.get("Statement", []):
        acts = st.get("Action", [])
        acts = [acts] if isinstance(acts, str) else acts
        res = st.get("Resource", [])
        res = [res] if isinstance(res, str) else res
        wild_a = [a for a in acts if a.endswith("*")]
        wild_r = [r for r in res if r == "*"]
        if wild_a or wild_r:
            rows.append((role, st.get("Sid", "-"), ",".join(acts), ",".join(res)))

print(f"{'ROLE':<38} {'SID':<22} {'ACTION':<18} RESOURCE")
print("-" * 92)
for r in rows:
    print(f"{r[0]:<38} {r[1]:<22} {r[2]:<18} {r[3]}")
print()
print(f"TOTAL wildcard statements needing justification or scoping: {len(rows)}")
PY

step "Captured. These files are the 'before' half of the Task 4 deliverable."
step "Next: ./scripts/30_vector_store.sh"
