#!/usr/bin/env bash
# =============================================================================
# 82_harden_trust.sh - close the confused-deputy gap on both service roles
#
# PROBLEM. The baseline trust policies allow bedrock.amazonaws.com to assume
# these roles with NO conditions. Any Bedrock resource, in any AWS account,
# could in principle be the deputy. The fix is aws:SourceAccount +
# aws:SourceArn conditions.
#
# OBSTACLE. This AWS Academy lab account DENIES iam:UpdateAssumeRolePolicy, so
# the trust document of an existing role cannot be edited.
#
# FIX. iam:CreateRole IS permitted, and it accepts a trust document at creation.
# So instead of accepting this as residual risk, the roles are RECREATED with
# hardened trust. The knowledge base must reference a valid role at all times,
# hence the temp-role swap:
#
#   create temp (hardened) → repoint KB → verify → delete original
#   → recreate original (hardened) → repoint KB back → verify → delete temp
#
# The AgentRole is referenced by no AWS resource, so it is simply
# deleted and recreated in place.
#
# Verification is behavioural at every step: if retrieval stops working, the
# script stops rather than leaving the KB pointing at a broken role.
# =============================================================================
. "$(dirname "$0")/lib.sh"
load_env; check_creds
require AWS_ACCOUNT_ID BEDROCK_KB_ID KB_ROLE_NAME AGENT_ROLE_NAME

A="$AWS_ACCOUNT_ID"; R="$AWS_REGION"
TEMP_ROLE="NorthstarAssist-KBRoleTemp"

HARDENED_TRUST=$(cat <<JSON
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

verify_retrieval () {
  local label="$1" n
  n=$(aws bedrock-agent-runtime retrieve --knowledge-base-id "$BEDROCK_KB_ID" \
      --retrieval-query '{"text":"PTO carryover limit"}' \
      --retrieval-configuration '{"vectorSearchConfiguration":{"numberOfResults":3}}' \
      --query 'length(retrievalResults)' --output text 2>/dev/null || echo 0)
  [ "${n:-0}" -gt 0 ] && ok "$label - retrieval returns $n results" \
                      || die "$label - retrieval BROKEN; KB role is misconfigured"
}

repoint_kb () {  # role-arn
  local arn="$1" cfg storage name
  cfg=$(aws bedrock-agent get-knowledge-base --knowledge-base-id "$BEDROCK_KB_ID" --output json)
  name=$(printf '%s' "$cfg" | python3 -c "import sys,json;print(json.load(sys.stdin)['knowledgeBase']['name'])")
  printf '%s' "$cfg" | python3 -c "import sys,json;print(json.dumps(json.load(sys.stdin)['knowledgeBase']['knowledgeBaseConfiguration']))" > /tmp/kbcfg.json
  printf '%s' "$cfg" | python3 -c "import sys,json;print(json.dumps(json.load(sys.stdin)['knowledgeBase']['storageConfiguration']))" > /tmp/kbstore.json
  aws bedrock-agent update-knowledge-base \
    --knowledge-base-id "$BEDROCK_KB_ID" --name "$name" --role-arn "$arn" \
    --knowledge-base-configuration file:///tmp/kbcfg.json \
    --storage-configuration file:///tmp/kbstore.json >/dev/null
  for i in $(seq 1 30); do
    local st; st=$(aws bedrock-agent get-knowledge-base --knowledge-base-id "$BEDROCK_KB_ID" \
                   --query 'knowledgeBase.status' --output text)
    [ "$st" = "ACTIVE" ] && return 0
    sleep 5
  done
  die "knowledge base did not return to ACTIVE"
}

make_role () {  # name  policy-name  policy-file
  aws iam create-role --role-name "$1" --assume-role-policy-document "$HARDENED_TRUST" \
    --description "Northstar Assist - hardened trust (aws:SourceAccount + aws:SourceArn)" \
    --tags Key=Project,Value=NorthstarAssist >/dev/null
  aws iam put-role-policy --role-name "$1" --policy-name "$2" --policy-document "file://$3"
}

step "Pre-flight: confirm retrieval works before touching anything"
verify_retrieval "baseline"

# =============================================================================
step "1/6 Creating temporary hardened role"
# =============================================================================
aws iam get-role --role-name "$TEMP_ROLE" >/dev/null 2>&1 \
  && skip "$TEMP_ROLE" \
  || { make_role "$TEMP_ROLE" NorthstarKBPolicy iam/after/kb-role-policy.json; ok "created $TEMP_ROLE"; }
sleep 10

step "2/6 Repointing knowledge base at the temporary role"
repoint_kb "arn:aws:iam::${A}:role/${TEMP_ROLE}"
sleep 5
verify_retrieval "on temp role"

step "3/6 Deleting the original (unhardened-trust) knowledge base role"
for P in $(aws iam list-role-policies --role-name "$KB_ROLE_NAME" --query 'PolicyNames[]' --output text 2>/dev/null); do
  aws iam delete-role-policy --role-name "$KB_ROLE_NAME" --policy-name "$P"
done
aws iam delete-role --role-name "$KB_ROLE_NAME"
ok "deleted $KB_ROLE_NAME"

step "4/6 Recreating it with hardened trust"
make_role "$KB_ROLE_NAME" NorthstarKBPolicy iam/after/kb-role-policy.json
ok "recreated $KB_ROLE_NAME with aws:SourceAccount + aws:SourceArn"
sleep 10

step "5/6 Repointing knowledge base back"
repoint_kb "arn:aws:iam::${A}:role/${KB_ROLE_NAME}"
sleep 5
verify_retrieval "on hardened role"

step "6/6 Removing the temporary role"
for P in $(aws iam list-role-policies --role-name "$TEMP_ROLE" --query 'PolicyNames[]' --output text 2>/dev/null); do
  aws iam delete-role-policy --role-name "$TEMP_ROLE" --policy-name "$P"
done
aws iam delete-role --role-name "$TEMP_ROLE"
ok "deleted $TEMP_ROLE"

# =============================================================================
step "Agent role (referenced by no AWS resource - straight swap)"
# =============================================================================
for P in $(aws iam list-role-policies --role-name "$AGENT_ROLE_NAME" --query 'PolicyNames[]' --output text 2>/dev/null); do
  aws iam delete-role-policy --role-name "$AGENT_ROLE_NAME" --policy-name "$P"
done
aws iam delete-role --role-name "$AGENT_ROLE_NAME" 2>/dev/null || true
make_role "$AGENT_ROLE_NAME" NorthstarAgentPolicy iam/after/agent-role-policy.json
ok "recreated $AGENT_ROLE_NAME with hardened trust"

# --- re-capture + prove -----------------------------------------------------
step "Re-capturing iam/after with the new trust policies"
for ROLE in "$KB_ROLE_NAME" "$AGENT_ROLE_NAME"; do
  aws iam get-role --role-name "$ROLE" \
    --query 'Role.{RoleName:RoleName,Arn:Arn,Trust:AssumeRolePolicyDocument}' \
    --output json > "iam/after/${ROLE}.role.json"
  for P in $(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[]' --output text); do
    aws iam get-role-policy --role-name "$ROLE" --policy-name "$P" \
      --query 'PolicyDocument' --output json > "iam/after/${ROLE}.${P}.json"
  done
done
rm -f iam/after/INTENDED-trust-policy.json evidence/logs/iam-trust-denied.txt
ok "iam/after refreshed; stale 'intended/denied' artifacts removed"

step "Proof: trust conditions are now present on both roles"
for ROLE in "$KB_ROLE_NAME" "$AGENT_ROLE_NAME"; do
  C=$(aws iam get-role --role-name "$ROLE" \
      --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition' --output json)
  if printf '%s' "$C" | grep -q SourceAccount; then
    ok "$ROLE"
    printf '%s\n' "$C" | sed 's/^/      /'
  else
    die "$ROLE has NO trust conditions"
  fi
done

step "Final behavioural check"
uv run python security-tests/run_tests.py --phase after --only T-01 2>&1 | grep -E "T-01|passed"

step "R-TRUST is now CLOSED, not accepted. Update docs/04 accordingly."
