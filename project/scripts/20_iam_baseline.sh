#!/usr/bin/env bash
# =============================================================================
# 20_iam_baseline.sh - create the two service roles with PERMISSIVE policies
#
# ⚠️  THESE POLICIES ARE DELIBERATELY OVER-PERMISSIVE. THAT IS THE POINT.
#
# Task 4 asks you to "review the IAM role used by the Bedrock Agent, identify
# any permissions broader than necessary - look for wildcard actions
# (bedrock:*, s3:*) and wildcard resources (*)" and then scope them down.
#
# PROVENANCE (stated here and repeated in docs/04-iam-hardening-summary.md):
# Because we build these roles via CLI rather than letting the Bedrock console
# generate them, WE author the baseline. This is a realistic first-pass policy
# of the kind both the console wizard and a day-one engineer produce - it is
# NOT a captured AWS artifact, and the deliverable says so plainly.
#
# The upside of scripting it: the before→after diff is reproducible and
# reviewable in git, instead of a one-shot screenshot nobody can re-derive.
#
# 80_iam_harden.sh replaces both policies with least-privilege versions.
# =============================================================================
. "$(dirname "$0")/lib.sh"
load_env; check_creds
require AWS_ACCOUNT_ID KB_S3_BUCKET

AGENT_ROLE="${AGENT_ROLE_NAME:-NorthstarAssist-AgentRole}"
KB_ROLE="${KB_ROLE_NAME:-NorthstarAssist-KnowledgeBaseRole}"

# Bedrock assumes both roles. The baseline trust policy has NO source
# conditions - 80_iam_harden.sh adds aws:SourceAccount / aws:SourceArn to close
# the confused-deputy gap, which is a documented hardening step in its own right.
TRUST='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "bedrock.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}'

ensure_role () {
  local name="$1" desc="$2"
  if aws iam get-role --role-name "$name" >/dev/null 2>&1; then
    skip "role $name"
  else
    aws iam create-role --role-name "$name" \
      --assume-role-policy-document "$TRUST" \
      --description "$desc" \
      --tags Key=Project,Value=NorthstarAssist Key=Course,Value=cd15147 >/dev/null
    ok "created role $name"
  fi
}

step "Creating service roles (permissive baseline)"
ensure_role "$KB_ROLE"    "Northstar Assist - Bedrock Knowledge Base service role"
ensure_role "$AGENT_ROLE" "Northstar Assist - Bedrock Agent execution role"

# --- BASELINE POLICY: Knowledge Base role -----------------------------------
# Wildcards throughout. An attacker holding this role could read or delete ANY
# S3 bucket in the account and invoke ANY Bedrock model, not just Titan.
step "Attaching permissive baseline policy → $KB_ROLE"
aws iam put-role-policy --role-name "$KB_ROLE" \
  --policy-name NorthstarKBPolicy \
  --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "BedrockFullAccess",    "Effect": "Allow", "Action": "bedrock:*",   "Resource": "*" },
    { "Sid": "S3FullAccess",         "Effect": "Allow", "Action": "s3:*",        "Resource": "*" },
    { "Sid": "S3VectorsFullAccess",  "Effect": "Allow", "Action": "s3vectors:*", "Resource": "*" }
  ]
}'
ok "bedrock:* + s3:* + s3vectors:* on Resource:*"

# --- BASELINE POLICY: Agent role --------------------------------------------
step "Attaching permissive baseline policy → $AGENT_ROLE"
aws iam put-role-policy --role-name "$AGENT_ROLE" \
  --policy-name NorthstarAgentPolicy \
  --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "BedrockFullAccess", "Effect": "Allow", "Action": "bedrock:*", "Resource": "*" },
    { "Sid": "S3FullAccess",      "Effect": "Allow", "Action": "s3:*",      "Resource": "*" },
    { "Sid": "LogsFullAccess",    "Effect": "Allow", "Action": "logs:*",    "Resource": "*" }
  ]
}'
ok "bedrock:* + s3:* + logs:* on Resource:*"

env_set AGENT_ROLE_NAME "$AGENT_ROLE"
env_set KB_ROLE_NAME    "$KB_ROLE"
env_set AGENT_ROLE_ARN  "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${AGENT_ROLE}"
env_set KB_ROLE_ARN     "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${KB_ROLE}"

# IAM is eventually consistent; Bedrock rejects a role it cannot yet assume.
step "Waiting for IAM propagation (10s)"
sleep 10
ok "done"

warn "These policies are intentionally insecure. 80_iam_harden.sh scopes them."
step "Next: ./scripts/25_capture_before.sh  (captures the 'before' for Task 4)"
