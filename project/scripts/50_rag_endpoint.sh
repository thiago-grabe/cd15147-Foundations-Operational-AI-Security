#!/usr/bin/env bash
# =============================================================================
# 50_rag_endpoint.sh - configure and validate the RAG query path
#
# ── WHY THIS EXISTS INSTEAD OF 50_agent.sh ───────────────────────────────────
# Bedrock Agents creation is blocked in this account:
#
#   AccessDeniedException: Bedrock Agents is in Maintenance Mode. New agent
#   creation is not available for accounts without prior service usage.
#
# Verified in us-east-1, us-west-2 and us-east-2 - an AWS-side account
# restriction, not a permissions or region issue. 50_agent.sh is retained and
# is correct; run it instead if Agents access is ever granted.
#
# The substitute is bedrock-agent-runtime RetrieveAndGenerate, the same managed
# RAG flow minus the Agent resource wrapper. It preserves everything this
# project needs:
#   - retrieval + generation with citations   (Task 1)
#   - a custom system prompt template         (Task 5 defence-in-depth)
#   - guardrailConfiguration                  (Task 5 controls)
#   - sessionId for multi-turn conversations  (Task 7 test T-13)
# What is lost - action groups and agent orchestration - this project never used.
#
# There is no resource to create here; the "endpoint" is a configuration. This
# script records it, validates it end to end, and stores it for the test
# harness and the Streamlit client.
# =============================================================================
. "$(dirname "$0")/lib.sh"
load_env; check_creds
require AWS_ACCOUNT_ID BEDROCK_KB_ID

FM="${FM_MODEL_ID:-amazon.nova-lite-v1:0}"
MODEL_ARN="arn:aws:bedrock:${AWS_REGION}::foundation-model/${FM}"
PROMPT_FILE="$PROJECT_DIR/config/system-prompt.txt"

step "RAG endpoint configuration"
[ -f "$PROMPT_FILE" ] || die "missing $PROMPT_FILE"
grep -q 'search_results' "$PROMPT_FILE" \
  || die "prompt template must contain the \$search_results\$ placeholder"
ok "system prompt template present ($(wc -l < "$PROMPT_FILE" | tr -d ' ') lines)"

env_set BEDROCK_MODEL_ARN "$MODEL_ARN"
env_set RAG_MODE "RETRIEVE_AND_GENERATE"

# Build the reusable config the test harness and app both consume, so the
# security posture lives in one version-controlled place.
python3 - "$BEDROCK_KB_ID" "$MODEL_ARN" "$PROMPT_FILE" <<'PY'
import json, sys, pathlib
kb, model_arn, prompt_file = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = {
    "type": "KNOWLEDGE_BASE",
    "knowledgeBaseConfiguration": {
        "knowledgeBaseId": kb,
        "modelArn": model_arn,
        "retrievalConfiguration": {
            "vectorSearchConfiguration": {"numberOfResults": 5}
        },
        "generationConfiguration": {
            "promptTemplate": {
                "textPromptTemplate": pathlib.Path(prompt_file).read_text()
            }
        },
    },
}
pathlib.Path("config").mkdir(exist_ok=True)
pathlib.Path("config/rag-config.json").write_text(json.dumps(cfg, indent=2))
print("  wrote config/rag-config.json")
PY
ok "config/rag-config.json (guardrail is injected at call time by 85_guardrail.sh)"

# --- end-to-end validation --------------------------------------------------
step "Validating the RAG path end to end"
RESP=$(aws bedrock-agent-runtime retrieve-and-generate \
  --input '{"text":"How many PTO days does an employee with 7 years of tenure receive, and what is the carryover limit?"}' \
  --retrieve-and-generate-configuration file://config/rag-config.json \
  --output json)

printf '%s' "$RESP" > evidence/logs/rag-validation.json

# NB: read from the file, not stdin - a heredoc-fed `python3 -` cannot also
# receive a pipe, since both claim stdin.
python3 - <<'PY'
import json
r = json.load(open("evidence/logs/rag-validation.json"))
print("\n  ANSWER:")
for line in r["output"]["text"].strip().splitlines():
    print("   ", line)
srcs = {
    ref["location"]["s3Location"]["uri"].split("/corpus/")[-1]
    for c in r.get("citations", [])
    for ref in c.get("retrievedReferences", [])
}
print("\n  CITED SOURCES:")
for s in sorted(srcs):
    print("   ", s)
txt = r["output"]["text"]
assert "25" in txt, "expected '25 days' - retrieval may not be grounding correctly"
assert srcs, "no citations returned - retrieval did not fire"
print("\n  ✅ grounded answer with citations")
PY

ok "evidence → evidence/logs/rag-validation.json"
step "Next: ./scripts/55_capture_task1.sh"
