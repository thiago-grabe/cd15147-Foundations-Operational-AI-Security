#!/usr/bin/env bash
# =============================================================================
# 97_verify_evidence.sh - submission completeness gate
#
# Mechanically checks that every artifact referenced by the deliverables exists,
# is non-empty, and contains no unreplaced placeholders. Also runs a secret scan.
#
# Run this BEFORE 99_teardown.sh - after teardown nothing is recoverable.
# =============================================================================
. "$(dirname "$0")/lib.sh"
load_env 2>/dev/null || true

PASS=0; FAIL=0
chk () {  # path  label
  if [ -s "$1" ]; then ok "$2"; PASS=$((PASS+1))
  else printf '  \033[31m✖\033[0m %s  (missing or empty: %s)\n' "$2" "$1"; FAIL=$((FAIL+1)); fi
}
chkdir () {  # dir  expected-count  label
  local n; n=$(find "$1" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -ge "$2" ]; then ok "$3 ($n files)"; PASS=$((PASS+1))
  else printf '  \033[31m✖\033[0m %s  (found %s, expected >= %s)\n' "$3" "$n" "$2"; FAIL=$((FAIL+1)); fi
}

printf '\033[1m═══ Submission completeness check ═══\033[0m\n'

step "Deliverable documents"
for f in 00-UI-PREREQUISITES 01-agent-validation 02-ml-bom 03-stride-ml-threat-model \
         04-iam-hardening-summary 05-safety-controls 06-monitoring-and-ir-playbook \
         07-launch-readiness-report 08-rubric-audit; do
  chk "docs/$f.md" "docs/$f.md"
done

step "Completed templates (.docx)"
chk "deliverables/ML-BOM - Northstar Assist.docx" "ML-BOM"
chk "deliverables/STRIDE-ML Threat Model - Northstar Assist.docx" "STRIDE-ML"

step "Template placeholder audit"
if uv run python scripts/fill_templates.py >/tmp/tpl.log 2>&1; then
  ok "no unreplaced [Required]/[Optional]/[Describe] placeholders"; PASS=$((PASS+1))
else
  printf '  \033[31m✖\033[0m unreplaced placeholders remain\n'; sed 's/^/      /' /tmp/tpl.log; FAIL=$((FAIL+1))
fi

step "Task 1 - deployment evidence"
chk evidence/logs/kb-ingestion.json          "ingestion job result"
chk evidence/logs/rag-validation.json        "RAG end-to-end validation"
chk evidence/logs/s3vectors-index.json       "vector index metadata"
chk evidence/logs/s3-corpus-inventory.json   "S3 corpus inventory"
chk evidence/logs/resource-facts.txt         "resource fact sheet"

step "Task 4 - IAM before/after"
chkdir iam/before 4 "iam/before"
chkdir iam/after  4 "iam/after"
chk evidence/logs/iam-wildcard-audit.txt       "wildcard audit (before)"
chk evidence/logs/iam-wildcard-audit-after.txt "wildcard audit (after)"

step "Task 5 - guardrail"
chk guardrails/northstar-guardrail.json  "guardrail source config"
chk evidence/logs/guardrail-config.json  "deployed guardrail (versioned)"
chk evidence/logs/canary-verdict.txt     "indirect-injection canary verdict"

step "Task 6 - monitoring"
chk monitoring/metric-filters/filters.json      "metric filters"
chk monitoring/alarms/alarms.json               "alarms"
chk evidence/logs/invocation-logging-config.json "invocation logging config"
chk evidence/logs/sample-invocation-event.json   "sample log event (pattern derivation)"

step "Task 7 - test evidence"
chk evidence/results-before.json "results-before.json"
chk evidence/results-after.json  "results-after.json"
chkdir evidence/transcripts/before 13 "before transcripts"
chkdir evidence/transcripts/after  13 "after transcripts"

step "Test-result integrity"
uv run python - <<'PY'
import json, pathlib, sys
ok = True
for phase in ("before", "after"):
    p = pathlib.Path(f"evidence/results-{phase}.json")
    r = json.loads(p.read_text())
    ids = sorted(x["id"] for x in r)
    exp = [f"T-{i:02d}" for i in range(1, 14)]
    if ids != exp:
        print(f"  ✖ {phase}: expected 13 tests, got {len(ids)} ({set(exp)-set(ids)} missing)")
        ok = False
    else:
        passed = sum(1 for x in r if x["passed"])
        leaked = [x["id"] for x in r if x["leaked"]]
        print(f"  ✅ {phase}: 13/13 present · {passed} passed · leaking: {leaked or 'none'}")
a = {x["id"]: x for x in json.loads(pathlib.Path("evidence/results-after.json").read_text())}
if any(x["leaked"] for x in a.values()):
    print("  ✖ AFTER phase still leaking - launch recommendation must be BLOCK"); ok = False
else:
    print("  ✅ after phase: zero leaks")
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

step "Secret scan"
if git -C .. ls-files -co --exclude-standard 2>/dev/null \
   | xargs grep -lE 'ASIA[A-Z0-9]{16}|AKIA[A-Z0-9]{16}' 2>/dev/null | grep -q .; then
  printf '  \033[31m✖\033[0m credential material found in committable files\n'; FAIL=$((FAIL+1))
else
  ok "no AKIA/ASIA credentials in committable files"; PASS=$((PASS+1))
fi
if git -C .. check-ignore project/.env >/dev/null 2>&1; then
  ok ".env is gitignored"; PASS=$((PASS+1))
else
  printf '  \033[31m✖\033[0m .env is NOT gitignored\n'; FAIL=$((FAIL+1))
fi

step "Starter files unmodified"
if git -C .. diff --quiet -- project/northstar-knowledge-base project/streamlit_app/app.py \
     "project/ML-BOM Template.docx" "project/STRIDE-ML Template.docx" 2>/dev/null; then
  ok "corpus, app.py and both templates untouched"; PASS=$((PASS+1))
else
  warn "starter files show modifications - review 'git diff'"; FAIL=$((FAIL+1))
fi

printf '\n\033[1m═══ Result ═══\033[0m\n  passed %d   failed %d\n\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m\033[1m  SUBMISSION COMPLETE — safe to run 99_teardown.sh\033[0m\n\n'; exit 0
else
  printf '\033[31m\033[1m  %d issue(s) — do NOT tear down yet\033[0m\n\n' "$FAIL"; exit 1
fi
