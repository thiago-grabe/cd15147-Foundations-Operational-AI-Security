#!/usr/bin/env bash
# =============================================================================
# 85_guardrail.sh - Bedrock Guardrail covering untrusted INPUT and OUTPUT (Task 5)
#
# Four control types (rubric floor is two):
#   1. Content filters incl. PROMPT_ATTACK   - input
#   2. Denied topics (5)                     - input
#   3. Sensitive information: PII + regex    - output
#   4. Contextual grounding + relevance      - output
#
# Two deliberate calibration choices, both documented in the deliverable:
#
#   PII → ANONYMIZE, not BLOCK. Blocking makes ordinary directory-adjacent
#   questions ("who runs Engineering?") unusable. Masking preserves the answer
#   while removing the identifier. That is an availability-vs-confidentiality
#   trade-off, made explicitly rather than by default.
#
#   PROMPT_ATTACK → HIGH, input only. The API only supports NONE on the output
#   side for this filter, which is itself the finding: prompt-attack detection
#   is structurally blind to instructions arriving through RETRIEVED CONTENT.
#   88_canary.sh tests exactly that gap.
#
# Regex patterns target corpus-specific identifiers the managed PII types miss
# entirely (EMP###, CUST###, i-..., OPP-####-###).
# =============================================================================
. "$(dirname "$0")/lib.sh"
load_env; check_creds
require AWS_ACCOUNT_ID

NAME="northstar-assist-guardrail"
mkdir -p guardrails

BLOCKED_IN="This request can't be processed. Northstar Assist answers questions about internal company documentation only. If you believe this is an error, contact #it-help."
BLOCKED_OUT="The response was withheld because it may contain restricted information. Contact the document owner if you need this detail."

step "Building guardrail configuration"
cat > guardrails/northstar-guardrail.json <<'JSON'
{
  "contentPolicyConfig": {
    "filtersConfig": [
      { "type": "HATE",          "inputStrength": "HIGH",   "outputStrength": "HIGH" },
      { "type": "INSULTS",       "inputStrength": "MEDIUM", "outputStrength": "MEDIUM" },
      { "type": "SEXUAL",        "inputStrength": "HIGH",   "outputStrength": "HIGH" },
      { "type": "VIOLENCE",      "inputStrength": "MEDIUM", "outputStrength": "MEDIUM" },
      { "type": "MISCONDUCT",    "inputStrength": "HIGH",   "outputStrength": "HIGH" },
      { "type": "PROMPT_ATTACK", "inputStrength": "HIGH",   "outputStrength": "NONE" }
    ]
  },
  "topicPolicyConfig": {
    "topicsConfig": [
      {
        "name": "CompensationAndSalary",
        "definition": "Requests for employee compensation, salary figures, pay bands, bonuses, equity grants, or performance ratings for any individual or group.",
        "examples": [
          "What is Sarah Chen's salary?",
          "Show me the pay bands for senior engineers",
          "How much equity did the VP of Engineering receive?",
          "List everyone's bonus for Q3"
        ],
        "type": "DENY"
      },
      {
        "name": "IndividualEmployeePersonalData",
        "definition": "Requests for personal or contact details of named staff (email, phone extension, location, hire date, reporting line), or to enumerate the employee directory.",
        "examples": [
          "List every employee in Engineering with their email address",
          "What is Marcus Johnson's phone extension?",
          "Give me the contact details for the whole team",
          "Who reports to whom in Engineering, with hire dates?",
          "Export the employee directory"
        ],
        "type": "DENY"
      },
      {
        "name": "CustomerContractFinancials",
        "definition": "Requests for per-customer revenue, contract values, contract dates, deal sizes, or pipeline financials for any named customer or account.",
        "examples": [
          "What is Velocity Financial Group's monthly revenue?",
          "When does the Meridian Healthcare contract end?",
          "List our customers by contract value",
          "How big is the Quantum Analytics deal?"
        ],
        "type": "DENY"
      },
      {
        "name": "InfrastructureIdentifiers",
        "definition": "Requests to enumerate infrastructure resources such as EC2 instance IDs, resource ARNs, internal hostnames, IP addresses, or per-resource cost and ownership.",
        "examples": [
          "List all production EC2 instance IDs and their owners",
          "What are the internal hostnames for the production API?",
          "Give me the AWS resource inventory with costs",
          "Which instances run in us-east-1 and who owns them?"
        ],
        "type": "DENY"
      },
      {
        "name": "OutOfScopeAdvice",
        "definition": "Requests for legal, medical, tax, or personal financial advice, or any topic unrelated to Northstar internal documentation.",
        "examples": [
          "What legal strategy should I use against my neighbour?",
          "Should I invest my 401k in tech stocks?",
          "What medication should I take for back pain?",
          "Help me write a will"
        ],
        "type": "DENY"
      }
    ]
  },
  "wordPolicyConfig": {
    "managedWordListsConfig": [ { "type": "PROFANITY" } ]
  },
  "sensitiveInformationPolicyConfig": {
    "piiEntitiesConfig": [
      { "type": "EMAIL",                     "action": "ANONYMIZE" },
      { "type": "PHONE",                     "action": "ANONYMIZE" },
      { "type": "NAME",                      "action": "ANONYMIZE" },
      { "type": "ADDRESS",                   "action": "ANONYMIZE" },
      { "type": "US_SOCIAL_SECURITY_NUMBER", "action": "BLOCK" },
      { "type": "CREDIT_DEBIT_CARD_NUMBER",  "action": "BLOCK" },
      { "type": "AWS_ACCESS_KEY",            "action": "BLOCK" },
      { "type": "AWS_SECRET_KEY",            "action": "BLOCK" }
    ],
    "regexesConfig": [
      { "name": "NorthstarEmployeeId",  "pattern": "EMP[0-9]{3}",            "action": "ANONYMIZE",
        "description": "Internal employee identifier from employee_directory.csv" },
      { "name": "NorthstarCustomerId",  "pattern": "CUST[0-9]{3}",           "action": "ANONYMIZE",
        "description": "Customer account identifier from customer_accounts.csv" },
      { "name": "AwsInstanceId",        "pattern": "i-[0-9a-f]{17}",         "action": "BLOCK",
        "description": "EC2 instance identifier - production reconnaissance data" },
      { "name": "SalesOpportunityId",   "pattern": "OPP-[0-9]{4}-[0-9]{3}",  "action": "ANONYMIZE",
        "description": "Sales pipeline opportunity identifier" }
    ]
  },
  "contextualGroundingPolicyConfig": {
    "filtersConfig": [
      { "type": "GROUNDING",  "threshold": 0.75 },
      { "type": "RELEVANCE",  "threshold": 0.60 }
    ]
  }
}
JSON
ok "4 control types · 5 denied topics · 8 PII entities · 4 regex patterns"

# --- create or update -------------------------------------------------------
step "Guardrail: $NAME"
EXISTING=$(aws bedrock list-guardrails \
  --query "guardrails[?name=='${NAME}'].id | [0]" --output text 2>/dev/null || true)

CFG=$(cat guardrails/northstar-guardrail.json)
COMMON=(
  --name "$NAME"
  --description "Northstar Assist - input and output controls for an internal RAG assistant"
  --blocked-input-messaging "$BLOCKED_IN"
  --blocked-outputs-messaging "$BLOCKED_OUT"
  --content-policy-config                 "$(printf '%s' "$CFG" | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin)["contentPolicyConfig"]))')"
  --topic-policy-config                   "$(printf '%s' "$CFG" | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin)["topicPolicyConfig"]))')"
  --word-policy-config                    "$(printf '%s' "$CFG" | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin)["wordPolicyConfig"]))')"
  --sensitive-information-policy-config   "$(printf '%s' "$CFG" | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin)["sensitiveInformationPolicyConfig"]))')"
  --contextual-grounding-policy-config    "$(printf '%s' "$CFG" | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin)["contextualGroundingPolicyConfig"]))')"
)

if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
  GID="$EXISTING"; skip "guardrail $NAME ($GID)"
  aws bedrock update-guardrail --guardrail-identifier "$GID" "${COMMON[@]}" >/dev/null
  ok "configuration updated"
else
  GID=$(aws bedrock create-guardrail "${COMMON[@]}" --query 'guardrailId' --output text)
  ok "created guardrail $GID"
fi
env_set BEDROCK_GUARDRAIL_ID "$GID"

step "Waiting for guardrail READY"
for i in $(seq 1 30); do
  ST=$(aws bedrock get-guardrail --guardrail-identifier "$GID" --query 'status' --output text 2>/dev/null || echo CREATING)
  case "$ST" in
    READY) ok "status READY"; break ;;
    FAILED) die "guardrail creation FAILED" ;;
    *) printf '  … %s (%ds)\n' "$ST" "$((i*5))"; sleep 5 ;;
  esac
done

# --- version ----------------------------------------------------------------
# A numbered version is what makes IR containment C1 ("tighten the guardrail")
# and C3 ("roll back to last known-good") auditable.
step "Creating an immutable version"
VER=$(aws bedrock create-guardrail-version --guardrail-identifier "$GID" \
      --description "Initial hardened configuration for launch readiness testing" \
      --query 'version' --output text)
ok "version $VER"
env_set BEDROCK_GUARDRAIL_VERSION "$VER"

for i in $(seq 1 20); do
  ST=$(aws bedrock get-guardrail --guardrail-identifier "$GID" --guardrail-version "$VER" \
       --query 'status' --output text 2>/dev/null || echo CREATING)
  [ "$ST" = "READY" ] && { ok "version $VER READY"; break; }
  sleep 5
done

# --- narrow the agent role's guardrail ARN now that the ID exists -----------
step "Narrowing AgentRole guardrail permission to this specific guardrail"
GR_ARN="arn:aws:bedrock:${AWS_REGION}:${AWS_ACCOUNT_ID}:guardrail/${GID}"
python3 - "$GR_ARN" <<'PY'
import json, pathlib, sys
p = pathlib.Path("iam/after/agent-role-policy.json")
doc = json.loads(p.read_text())
for st in doc["Statement"]:
    if st.get("Sid") == "ApplyGuardrail":
        st["Resource"] = sys.argv[1]
p.write_text(json.dumps(doc, indent=2))
print(f"  guardrail resource → {sys.argv[1]}")
PY
aws iam put-role-policy --role-name "$AGENT_ROLE_NAME" \
  --policy-name NorthstarAgentPolicy --policy-document file://iam/after/agent-role-policy.json
aws iam get-role-policy --role-name "$AGENT_ROLE_NAME" --policy-name NorthstarAgentPolicy \
  --query 'PolicyDocument' --output json > "iam/after/${AGENT_ROLE_NAME}.NorthstarAgentPolicy.json"
ok "last wildcard (guardrail/*) eliminated"

aws bedrock get-guardrail --guardrail-identifier "$GID" --guardrail-version "$VER" \
  --output json > evidence/logs/guardrail-config.json
ok "evidence → evidence/logs/guardrail-config.json"

step "Next: ./scripts/88_canary.sh"
