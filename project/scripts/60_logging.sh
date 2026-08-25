#!/usr/bin/env bash
# =============================================================================
# 60_logging.sh - Bedrock model invocation logging → CloudWatch
#
# ⏰ ORDERING IS NON-NEGOTIABLE. CloudWatch does not backfill. Every prompt sent
# before this switch is on produces ZERO evidence - and 70_test_before.sh's
# unhardened baseline run is unrepeatable once guardrails are attached.
#
# These logs are the raw material for:
#   - Task 6 metric filters and alarms (guardrail interventions, token counts)
#   - Task 7 before/after evidence
#   - the IR playbook's investigation steps
#
# Bedrock needs a service role it can assume to write into the log group.
# =============================================================================
. "$(dirname "$0")/lib.sh"
load_env; check_creds
require AWS_ACCOUNT_ID

LG="${LOG_GROUP:-/aws/bedrock/northstar-assist}"
ROLE="NorthstarAssist-BedrockLoggingRole"

step "CloudWatch log group: $LG"
if aws logs describe-log-groups --log-group-name-prefix "$LG" \
     --query "logGroups[?logGroupName=='$LG'] | length(@)" --output text | grep -q '^1$'; then
  skip "log group $LG"
else
  aws logs create-log-group --log-group-name "$LG"
  ok "created $LG"
fi
aws logs put-retention-policy --log-group-name "$LG" --retention-in-days 30
ok "retention 30 days (lab hygiene - avoids indefinite storage cost)"

# --- delivery role ----------------------------------------------------------
step "Logging service role: $ROLE"
TRUST=$(cat <<JSON
{"Version":"2012-10-17","Statement":[{
  "Effect":"Allow",
  "Principal":{"Service":"bedrock.amazonaws.com"},
  "Action":"sts:AssumeRole",
  "Condition":{
    "StringEquals":{"aws:SourceAccount":"${AWS_ACCOUNT_ID}"},
    "ArnLike":{"aws:SourceArn":"arn:aws:bedrock:${AWS_REGION}:${AWS_ACCOUNT_ID}:*"}
  }}]}
JSON
)
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  skip "role $ROLE"
  # lab accounts may deny iam:UpdateAssumeRolePolicy - non-fatal on re-run
  aws iam update-assume-role-policy --role-name "$ROLE" --policy-document "$TRUST" 2>/dev/null || warn "trust update denied (lab restriction) - existing trust retained"
else
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" \
    --description "Lets Bedrock write model invocation logs to CloudWatch" \
    --tags Key=Project,Value=NorthstarAssist >/dev/null
  ok "created $ROLE"
fi

# Already least-privilege: scoped to this one log group, not logs:* on *.
aws iam put-role-policy --role-name "$ROLE" --policy-name BedrockLoggingPolicy \
  --policy-document "$(cat <<JSON
{"Version":"2012-10-17","Statement":[{
  "Effect":"Allow",
  "Action":["logs:CreateLogStream","logs:PutLogEvents"],
  "Resource":"arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:${LG}:log-stream:aws/bedrock/modelinvocations"
}]}
JSON
)"
ok "policy scoped to $LG only (no logs:* wildcard)"

step "Waiting for IAM propagation (10s)"
sleep 10

# --- enable -----------------------------------------------------------------
step "Enabling model invocation logging"
aws bedrock put-model-invocation-logging-configuration --logging-config "$(cat <<JSON
{
  "cloudWatchConfig": {
    "logGroupName": "${LG}",
    "roleArn": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE}"
  },
  "textDataDeliveryEnabled": true,
  "imageDataDeliveryEnabled": false,
  "embeddingDataDeliveryEnabled": true
}
JSON
)"
ok "enabled (text + embedding data)"

aws bedrock get-model-invocation-logging-configuration --output json \
  > evidence/logs/invocation-logging-config.json
ok "evidence → evidence/logs/invocation-logging-config.json"

env_set LOG_GROUP "$LG"
env_set LOGGING_ROLE_NAME "$ROLE"

warn "Logging is now ON. Everything from here is captured - including the"
warn "deliberately unguarded baseline run in 70_test_before.sh."
step "Next: ./scripts/70_test_before.sh"
