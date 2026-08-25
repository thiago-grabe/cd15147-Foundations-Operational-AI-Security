#!/usr/bin/env bash
# =============================================================================
# 99_teardown.sh - destroy every resource created by this project
#
# ⚠️  RUN ./scripts/97_verify_evidence.sh FIRST. Nothing below is recoverable.
#
# Order matters - dependencies block deletion. The single most-missed charge is
# step 3: the S3 Vectors bucket is NOT always removed with the knowledge base,
# and it keeps billing quietly after everything else is gone.
#
#   ./scripts/99_teardown.sh          # prompts for confirmation
#   ./scripts/99_teardown.sh --yes    # non-interactive
# =============================================================================
. "$(dirname "$0")/lib.sh"
load_env; check_creds

ASSUME_YES=false
[ "${1:-}" = "--yes" ] && ASSUME_YES=true

printf '\033[1;31m'
cat <<'BANNER'
╔══════════════════════════════════════════════════════════════════╗
║  TEARDOWN — this destroys all Northstar Assist AWS resources.    ║
║  Local evidence in evidence/, docs/, iam/ and deliverables/ is   ║
║  NOT touched, but nothing in AWS can be recovered afterwards.    ║
╚══════════════════════════════════════════════════════════════════╝
BANNER
printf '\033[0m\n'

if [ "$ASSUME_YES" != true ]; then
  step "Pre-flight: submission completeness"
  if ./scripts/97_verify_evidence.sh >/tmp/verify.log 2>&1; then
    ok "97_verify_evidence.sh passed - evidence is captured"
  else
    warn "97_verify_evidence.sh FAILED. Tail:"
    tail -12 /tmp/verify.log | sed 's/^/      /'
    printf '\n  \033[31mTearing down now will lose evidence you cannot recreate.\033[0m\n'
  fi
  printf '\nType \033[1mDESTROY\033[0m to continue: '
  read -r reply
  [ "$reply" = "DESTROY" ] || die "aborted"
fi

soft () { "$@" >/dev/null 2>&1 && ok "$*" || skip "$*"; }

# 1 ---------------------------------------------------------------- agent ----
step "1/9 Bedrock Agent and aliases"
if [ -n "${BEDROCK_AGENT_ID:-}" ]; then
  for A in $(aws bedrock-agent list-agent-aliases --agent-id "$BEDROCK_AGENT_ID" \
             --query 'agentAliasSummaries[].agentAliasId' --output text 2>/dev/null); do
    soft aws bedrock-agent delete-agent-alias --agent-id "$BEDROCK_AGENT_ID" --agent-alias-id "$A"
  done
  soft aws bedrock-agent delete-agent --agent-id "$BEDROCK_AGENT_ID" --skip-resource-in-use-check
else
  skip "no agent (Bedrock Agents were in Maintenance Mode for this account)"
fi

# 2 ------------------------------------------------------- knowledge base ----
step "2/9 Knowledge Base and data source"
if [ -n "${BEDROCK_KB_ID:-}" ]; then
  [ -n "${BEDROCK_DS_ID:-}" ] && soft aws bedrock-agent delete-data-source \
    --knowledge-base-id "$BEDROCK_KB_ID" --data-source-id "$BEDROCK_DS_ID"
  sleep 10
  soft aws bedrock-agent delete-knowledge-base --knowledge-base-id "$BEDROCK_KB_ID"
  for i in $(seq 1 20); do
    aws bedrock-agent get-knowledge-base --knowledge-base-id "$BEDROCK_KB_ID" >/dev/null 2>&1 || break
    sleep 5
  done
fi

# 3 -------------------------------------------------------- S3 Vectors ⚠️ ----
step "3/9 S3 Vectors index and bucket  ⚠️  most-missed charge"
if [ -n "${VECTOR_BUCKET:-}" ]; then
  [ -n "${VECTOR_INDEX:-}" ] && soft aws s3vectors delete-index \
    --vector-bucket-name "$VECTOR_BUCKET" --index-name "$VECTOR_INDEX"
  sleep 5
  soft aws s3vectors delete-vector-bucket --vector-bucket-name "$VECTOR_BUCKET"
fi

# 4 ------------------------------------------------------------ guardrail ----
step "4/9 Guardrail (all versions)"
[ -n "${BEDROCK_GUARDRAIL_ID:-}" ] && \
  soft aws bedrock delete-guardrail --guardrail-identifier "$BEDROCK_GUARDRAIL_ID"

# 5 ----------------------------------------------------------- S3 bucket ----
step "5/9 Document bucket (versioned - all versions must be purged)"
if [ -n "${KB_S3_BUCKET:-}" ] && aws s3api head-bucket --bucket "$KB_S3_BUCKET" 2>/dev/null; then
  # `s3 rb --force` does not remove non-current versions or delete markers on a
  # versioned bucket, which silently leaves the bucket undeletable.
  aws s3api list-object-versions --bucket "$KB_S3_BUCKET" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json > /tmp/vers.json 2>/dev/null
  if [ -s /tmp/vers.json ] && ! grep -q '"Objects": null' /tmp/vers.json; then
    aws s3api delete-objects --bucket "$KB_S3_BUCKET" --delete file:///tmp/vers.json >/dev/null 2>&1 || true
  fi
  aws s3api list-object-versions --bucket "$KB_S3_BUCKET" \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json > /tmp/marks.json 2>/dev/null
  if [ -s /tmp/marks.json ] && ! grep -q '"Objects": null' /tmp/marks.json; then
    aws s3api delete-objects --bucket "$KB_S3_BUCKET" --delete file:///tmp/marks.json >/dev/null 2>&1 || true
  fi
  soft aws s3 rb "s3://$KB_S3_BUCKET" --force
fi

# 6 ---------------------------------------------------------- CloudWatch ----
step "6/9 CloudWatch alarms, metric filters, log group, SNS"
soft aws cloudwatch delete-alarms --alarm-names \
  NorthstarAssist-PromptAttackSpike NorthstarAssist-GuardrailInterventionSpike \
  NorthstarAssist-UngroundedResponseSpike
if [ -n "${LOG_GROUP:-}" ]; then
  for F in GuardrailInterventions PromptAttackInterventions UngroundedResponses ZeroChunkRetrievals; do
    soft aws logs delete-metric-filter --log-group-name "$LOG_GROUP" --filter-name "$F"
  done
  soft aws logs delete-log-group --log-group-name "$LOG_GROUP"
fi
[ -n "${SNS_TOPIC_ARN:-}" ] && soft aws sns delete-topic --topic-arn "$SNS_TOPIC_ARN"

# 7 ------------------------------------------------- invocation logging ----
step "7/9 Disabling model invocation logging"
soft aws bedrock delete-model-invocation-logging-configuration

# 8 ---------------------------------------------------------- IAM roles ----
step "8/9 IAM roles"
for R in "${KB_ROLE_NAME:-}" "${AGENT_ROLE_NAME:-}" "${LOGGING_ROLE_NAME:-}" "NorthstarAssist-KBRoleTemp"; do
  [ -z "$R" ] && continue
  for P in $(aws iam list-role-policies --role-name "$R" --query 'PolicyNames[]' --output text 2>/dev/null); do
    soft aws iam delete-role-policy --role-name "$R" --policy-name "$P"
  done
  soft aws iam delete-role --role-name "$R"
done

# 9 ------------------------------------------------------------- verify ----
step "9/9 Verifying nothing remains"
REMAIN=0
chk_gone () {  # label  command...
  local label="$1"; shift
  local n; n=$("$@" 2>/dev/null || echo 0)
  if [ "${n:-0}" = "0" ] || [ -z "$n" ] || [ "$n" = "None" ]; then ok "$label: clear"
  else warn "$label: $n remaining"; REMAIN=$((REMAIN+1)); fi
}
chk_gone "knowledge bases" aws bedrock-agent list-knowledge-bases --query 'length(knowledgeBaseSummaries)' --output text
chk_gone "agents"          aws bedrock-agent list-agents --query 'length(agentSummaries)' --output text
chk_gone "guardrails"      aws bedrock list-guardrails --query "length(guardrails[?name=='northstar-assist-guardrail'])" --output text
chk_gone "vector buckets"  aws s3vectors list-vector-buckets --query "length(vectorBuckets[?vectorBucketName=='${VECTOR_BUCKET:-none}'])" --output text
chk_gone "alarms"          aws cloudwatch describe-alarms --alarm-name-prefix NorthstarAssist- --query 'length(MetricAlarms)' --output text
chk_gone "S3 buckets"      aws s3api list-buckets --query "length(Buckets[?Name=='${KB_S3_BUCKET:-none}'])" --output text

LOGSTATE=$(aws bedrock get-model-invocation-logging-configuration --query 'loggingConfig' --output text 2>/dev/null || echo "None")
[ "$LOGSTATE" = "None" ] && ok "model invocation logging: off" || warn "invocation logging still enabled"

printf '\n'
if [ "$REMAIN" -eq 0 ]; then
  printf '\033[32m\033[1m  TEARDOWN COMPLETE — no billable resources remain\033[0m\n'
else
  printf '\033[33m\033[1m  %d resource group(s) still present — check the AWS console\033[0m\n' "$REMAIN"
fi
printf '  Local deliverables, evidence and IAM snapshots are untouched.\n\n'
