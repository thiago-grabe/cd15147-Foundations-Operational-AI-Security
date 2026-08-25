#!/usr/bin/env bash
# =============================================================================
# 40_knowledge_base.sh - Bedrock Knowledge Base + S3 data source + ingestion
#
# Chunking is set EXPLICITLY rather than left to the default, for two reasons:
#   1. It is a required ML-BOM architecture field (Task 2).
#   2. It is a genuine security knob. Chunk size determines how much
#      surrounding text is pulled into model context on every retrieval - a
#      larger chunk over employee_directory.csv drags in neighbouring people's
#      rows even when the question was about one person. 300 tokens / 20%
#      overlap is the conservative default; the trade-off is documented in the
#      threat model under I-1 (excessive retrieval).
#
# The rubric requires "sync completes without errors", so this script FAILS
# LOUDLY on a partial ingest instead of continuing with a half-indexed corpus.
# =============================================================================
. "$(dirname "$0")/lib.sh"
load_env; check_creds
require AWS_ACCOUNT_ID KB_S3_BUCKET KB_ROLE_ARN VECTOR_INDEX_ARN

KB_NAME="northstar-assist-kb"
DS_NAME="northstar-corpus"
EMBED_ARN="arn:aws:bedrock:${AWS_REGION}::foundation-model/${EMBED_MODEL_ID:-amazon.titan-embed-text-v2:0}"

# --- knowledge base ---------------------------------------------------------
step "Knowledge Base: $KB_NAME"
EXISTING=$(aws bedrock-agent list-knowledge-bases \
  --query "knowledgeBaseSummaries[?name=='${KB_NAME}'].knowledgeBaseId | [0]" --output text 2>/dev/null || true)

if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
  KB_ID="$EXISTING"; skip "knowledge base $KB_NAME ($KB_ID)"
else
  KB_ID=$(aws bedrock-agent create-knowledge-base \
    --name "$KB_NAME" \
    --description "RAG store over Northstar Technologies internal documentation" \
    --role-arn "$KB_ROLE_ARN" \
    --knowledge-base-configuration "{
        \"type\": \"VECTOR\",
        \"vectorKnowledgeBaseConfiguration\": { \"embeddingModelArn\": \"$EMBED_ARN\" }
      }" \
    --storage-configuration "{
        \"type\": \"S3_VECTORS\",
        \"s3VectorsConfiguration\": { \"indexArn\": \"$VECTOR_INDEX_ARN\" }
      }" \
    --query 'knowledgeBase.knowledgeBaseId' --output text)
  ok "created knowledge base $KB_ID"
fi
env_set BEDROCK_KB_ID "$KB_ID"

step "Waiting for knowledge base to become ACTIVE"
for i in $(seq 1 30); do
  ST=$(aws bedrock-agent get-knowledge-base --knowledge-base-id "$KB_ID" \
       --query 'knowledgeBase.status' --output text 2>/dev/null || echo PENDING)
  case "$ST" in
    ACTIVE) ok "status ACTIVE"; break ;;
    FAILED) die "knowledge base creation FAILED - check the console for the reason" ;;
    *) printf '  … status %s (%ds)\n' "$ST" "$((i*5))"; sleep 5 ;;
  esac
done

# --- data source ------------------------------------------------------------
step "Data source: $DS_NAME → s3://$KB_S3_BUCKET/corpus/"
DS_EXISTING=$(aws bedrock-agent list-data-sources --knowledge-base-id "$KB_ID" \
  --query "dataSourceSummaries[?name=='${DS_NAME}'].dataSourceId | [0]" --output text 2>/dev/null || true)

if [ -n "$DS_EXISTING" ] && [ "$DS_EXISTING" != "None" ]; then
  DS_ID="$DS_EXISTING"; skip "data source $DS_NAME ($DS_ID)"
else
  DS_ID=$(aws bedrock-agent create-data-source \
    --knowledge-base-id "$KB_ID" \
    --name "$DS_NAME" \
    --description "Northstar starter corpus - 30 documents across 6 formats" \
    --data-source-configuration "{
        \"type\": \"S3\",
        \"s3Configuration\": {
          \"bucketArn\": \"arn:aws:s3:::${KB_S3_BUCKET}\",
          \"inclusionPrefixes\": [\"corpus/\"]
        }
      }" \
    --vector-ingestion-configuration '{
        "chunkingConfiguration": {
          "chunkingStrategy": "FIXED_SIZE",
          "fixedSizeChunkingConfiguration": { "maxTokens": 300, "overlapPercentage": 20 }
        }
      }' \
    --query 'dataSource.dataSourceId' --output text)
  ok "created data source $DS_ID (FIXED_SIZE 300 tokens / 20% overlap)"
fi
env_set BEDROCK_DS_ID "$DS_ID"

# --- ingestion --------------------------------------------------------------
step "Starting ingestion job"
JOB_ID=$(aws bedrock-agent start-ingestion-job \
  --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" \
  --query 'ingestionJob.ingestionJobId' --output text)
ok "job $JOB_ID"

step "Polling until COMPLETE (embedding 30 documents takes a few minutes)"
for i in $(seq 1 60); do
  JOB=$(aws bedrock-agent get-ingestion-job \
        --knowledge-base-id "$KB_ID" --data-source-id "$DS_ID" --ingestion-job-id "$JOB_ID" --output json)
  ST=$(printf '%s' "$JOB" | python3 -c "import sys,json;print(json.load(sys.stdin)['ingestionJob']['status'])")
  case "$ST" in
    COMPLETE) printf '%s' "$JOB" > evidence/logs/kb-ingestion.json; ok "status COMPLETE"; break ;;
    FAILED)
      printf '%s' "$JOB" > evidence/logs/kb-ingestion-FAILED.json
      printf '%s' "$JOB" | python3 -c "import sys,json;[print('   ',r) for r in json.load(sys.stdin)['ingestionJob'].get('failureReasons',[])]"
      die "ingestion FAILED - see evidence/logs/kb-ingestion-FAILED.json" ;;
    *) printf '  … status %s (%ds)\n' "$ST" "$((i*10))"; sleep 10 ;;
  esac
done

# --- assert a clean sync (rubric requirement) -------------------------------
step "Ingestion statistics"
python3 - <<'PY'
import json, sys
job = json.load(open("evidence/logs/kb-ingestion.json"))["ingestionJob"]
s = job.get("statistics", {})
for k, v in s.items():
    print(f"  {k:<42} {v}")
failed = s.get("numberOfDocumentsFailed", 0)
indexed = s.get("numberOfNewDocumentsIndexed", 0) + s.get("numberOfModifiedDocumentsIndexed", 0)
print()
if failed:
    print(f"  ✖ {failed} document(s) FAILED to index.")
    print("    The rubric requires 'sync completes without errors'. Resolve before continuing.")
    sys.exit(1)
print(f"  ✅ 0 documents failed · {indexed} indexed")
PY

ok "evidence → evidence/logs/kb-ingestion.json"

# --- ground truth: what is ACTUALLY in the vector index ---------------------
# The job statistics are NOT sufficient. Observed here: a job reported
# "0 failed" while two documents were absent from the index, because Bedrock
# still considered them indexed from an earlier run against an index that had
# since been deleted. One of the two was employee_directory.csv - the PII
# target the entire security test suite depends on.
#
# So verify against the index itself, not against the job's self-report.
step "Verifying index contents against the source corpus (ground truth)"
aws s3vectors list-vectors --vector-bucket-name "$VECTOR_BUCKET" --index-name "$VECTOR_INDEX" \
  --return-metadata --output json > evidence/logs/s3vectors-inventory.json 2>/dev/null

python3 - <<'PY'
import json, os, sys, collections

present = collections.Counter()
data = json.load(open("evidence/logs/s3vectors-inventory.json"))
for v in data.get("vectors", []):
    raw = (v.get("metadata") or {}).get("AMAZON_BEDROCK_METADATA")
    if not raw:
        continue
    try:
        meta = json.loads(raw)
    except Exception:
        continue
    loc = (meta.get("source") or {}).get("sourceLocation") or {}
    uri = loc.get("uri") if isinstance(loc, dict) else str(loc)
    if uri:
        present[uri.split("/corpus/")[-1]] += 1

expected = set()
for root, _, files in os.walk("northstar-knowledge-base"):
    for f in files:
        expected.add(os.path.relpath(os.path.join(root, f), "northstar-knowledge-base"))

missing = sorted(expected - set(present))
print(f"  documents in index : {len(present)} / {len(expected)}")
print(f"  total chunks       : {sum(present.values())}")

by_fmt = collections.Counter(s.split("/")[0] for s in present)
print("  per format         : " + "  ".join(f"{f}={by_fmt.get(f,0)}/5"
                                            for f in ("csv","docx","html","pdf","txt","xlsx")))
if missing:
    print("\n  ✖ MISSING FROM INDEX:")
    for m in missing:
        print(f"      {m}")
    print("\n  Fix: delete and recreate the data source (resets ingestion tracking),")
    print("  then re-run this script. Re-uploading identical bytes will NOT work -")
    print("  Bedrock change detection is content-hash based.")
    sys.exit(1)
print("\n  ✅ every source document is represented in the vector index")
PY

step "Next: ./scripts/50_agent.sh"
