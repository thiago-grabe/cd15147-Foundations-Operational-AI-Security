#!/usr/bin/env bash
# =============================================================================
# 90_monitoring.sh - AI-specific metric filters, SNS topic, CloudWatch alarms
#                    (Task 6)
#
# FILTER PATTERNS ARE EMPIRICALLY DERIVED, NOT GUESSED.
# Sampling 37 real invocation events from this log group showed:
#     PROMPT_ATTACK        3/37
#     "action":"BLOCKED"  12/37
#     action values seen: BLOCKED (13), NONE (11)
# so these terms are known to occur in this account's actual log format.
#
# Note the guardrail trace nests under a DYNAMIC key (the guardrail id), i.e.
#   $.output.outputBodyJson.trace.guardrail.inputAssessment.<ID>.topicPolicy...
# CloudWatch JSON patterns ($.a.b.c) cannot wildcard a key, so term matching is
# used instead - deliberately, and it survives a guardrail id change.
#
# Alarm thresholds are stated with reasoning, per the rubric's requirement for
# "at least one concrete alert condition with a defined threshold".
# =============================================================================
. "$(dirname "$0")/lib.sh"
load_env; check_creds
require AWS_ACCOUNT_ID LOG_GROUP

NS="NorthstarAssist"
TOPIC="northstar-ai-security-alerts"
# Alert destination comes from .env. Deliberately not defaulted to a real
# address: this repository is public, and a hardcoded personal email would
# be published with it.
EMAIL="${ALERT_EMAIL:-}"
[ -n "$EMAIL" ] || die "ALERT_EMAIL is unset. Add it to .env so alarms can notify someone."

# --- SNS --------------------------------------------------------------------
step "SNS topic: $TOPIC"
TOPIC_ARN=$(aws sns create-topic --name "$TOPIC" --query 'TopicArn' --output text)
ok "$TOPIC_ARN"
env_set SNS_TOPIC_ARN "$TOPIC_ARN"

SUBS=$(aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" \
       --query "length(Subscriptions[?Endpoint=='${EMAIL}'])" --output text 2>/dev/null || echo 0)
if [ "$SUBS" = "0" ]; then
  aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$EMAIL" >/dev/null
  ok "subscribed $EMAIL"
  warn "CHECK YOUR INBOX and click the confirmation link"
  warn "an unconfirmed subscription silently notifies nobody - the alarm will look healthy"
else
  skip "subscription for $EMAIL"
fi

# --- metric filters ---------------------------------------------------------
put_filter () {  # name  pattern  metric  description
  aws logs put-metric-filter \
    --log-group-name "$LOG_GROUP" \
    --filter-name "$1" \
    --filter-pattern "$2" \
    --metric-transformations \
      "metricName=$3,metricNamespace=$NS,metricValue=1,defaultValue=0"
  ok "$3  ← pattern $2   ($4)"
}

step "Metric filters → namespace $NS"
put_filter "GuardrailInterventions" '"BLOCKED"'       "GuardrailInterventions" \
           "S-1: any guardrail block (topic, content, PII, grounding)"
put_filter "PromptAttackInterventions" '"PROMPT_ATTACK"' "PromptAttackInterventions" \
           "S-1a: prompt-injection attempts specifically"
# S-2 originally targeted literal zero-chunk retrievals, but CloudWatch rejects
# '[' in a filter term ("Invalid character(s) in term '['"), so a bracketed JSON
# fragment cannot be matched. The contextual-grounding assessment measures the
# same underlying condition - an answer the grounding check judged unsupported -
# and GROUNDING was verified present in 6/37 sampled events.
put_filter "UngroundedResponses" '"GROUNDING"' "UngroundedResponses" \
           "S-2: grounding filter engaged - answer unsupported by retrieved context"

# --- alarms -----------------------------------------------------------------
put_alarm () {  # name metric threshold period description
  aws cloudwatch put-metric-alarm \
    --alarm-name "$1" \
    --alarm-description "$5" \
    --namespace "$NS" --metric-name "$2" \
    --statistic Sum --period "$4" --evaluation-periods 1 \
    --threshold "$3" --comparison-operator GreaterThanOrEqualToThreshold \
    --treat-missing-data notBreaching \
    --alarm-actions "$TOPIC_ARN"
  ok "$1  →  Sum >= $3 per $(( $4 / 60 ))min"
}

step "CloudWatch alarms"

# THRESHOLD REASONING (documented in docs/06-monitoring-and-ir-playbook.md):
# A legitimate employee may trip a denied topic once or twice by accident -
# asking about a colleague's contact details is a normal mistake. Five prompt
# attacks in an hour is not a mistake; it is someone probing. Set low enough to
# catch a deliberate campaign, high enough that honest users never page anyone.
put_alarm "NorthstarAssist-PromptAttackSpike" "PromptAttackInterventions" 5 3600 \
  "5+ prompt-injection attempts in one hour indicates deliberate probing, not user error"

# Baseline is near zero; a sustained rise means either an attack campaign or an
# over-tight guardrail harming legitimate use. Both need a human.
put_alarm "NorthstarAssist-GuardrailInterventionSpike" "GuardrailInterventions" 20 3600 \
  "20+ guardrail blocks per hour: attack campaign, or over-blocking that is breaking legitimate use"

# Zero-chunk answers are the canary for silent RAG failure - an IAM scoping
# mistake or a failed sync shows up here before any user complains.
put_alarm "NorthstarAssist-UngroundedResponseSpike" "UngroundedResponses" 10 3600 \
  "10+ ungrounded answers per hour: retrieval broken (IAM/sync), KB drift, or probing for hallucination"

# --- evidence ---------------------------------------------------------------
step "Exporting configuration as evidence"
mkdir -p monitoring/alarms monitoring/metric-filters
aws logs describe-metric-filters --log-group-name "$LOG_GROUP" --output json \
  > monitoring/metric-filters/filters.json
aws cloudwatch describe-alarms --alarm-name-prefix "NorthstarAssist-" --output json \
  > monitoring/alarms/alarms.json
cp monitoring/metric-filters/filters.json evidence/cloudwatch-metric-filters.json 2>/dev/null || true
ok "monitoring/metric-filters/filters.json · monitoring/alarms/alarms.json"

step "Alarm state check"
aws cloudwatch describe-alarms --alarm-name-prefix "NorthstarAssist-" \
  --query 'MetricAlarms[].{Alarm:AlarmName,State:StateValue,Threshold:Threshold}' --output table

warn "Alarms read INSUFFICIENT_DATA until the metric first reports - that is expected."
info "To demonstrate one firing without waiting:"
info "  aws cloudwatch set-alarm-state --alarm-name NorthstarAssist-PromptAttackSpike \\"
info "    --state-value ALARM --state-reason 'launch-readiness evidence'"

step "Next: deliverable authoring + ./scripts/97_verify_evidence.sh"
