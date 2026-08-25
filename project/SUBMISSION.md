# Northstar Assist — Submission Index

**Foundations of Operational AI Security (cd15147)** · Thiago M. Grabe · 2026-08-24
Account `638018627275` · `us-east-1`

---

## Deliverables

| # | Task | Deliverable | Supporting source |
|---|---|---|---|
| 1 | Working agent | `docs/01-agent-validation.md` | `evidence/transcripts/after/T-01.md` |
| 2 | ML-BOM | **`deliverables/ML-BOM - Northstar Assist.docx`** | `docs/02-ml-bom.md` |
| 3 | STRIDE-ML threat model | **`deliverables/STRIDE-ML Threat Model - Northstar Assist.docx`** | `docs/03-stride-ml-threat-model.md` |
| 4 | IAM hardening summary | `docs/04-iam-hardening-summary.md` | `iam/before/`, `iam/after/` |
| 5 | Safety controls | `docs/05-safety-controls.md` | `guardrails/northstar-guardrail.json` |
| 6 | Monitoring + IR playbook | `docs/06-monitoring-and-ir-playbook.md` | `monitoring/` |
| 7 | Launch-readiness report | `docs/07-launch-readiness-report.md` | `evidence/results-{before,after}.json` |
| — | Rubric self-audit | `docs/08-rubric-audit.md` | **18/18 requirements met** |
| — | Manual setup gate | `docs/00-UI-PREREQUISITES.md` | |

---

## Headline result

| | Before hardening | After hardening |
|---|---|---|
| Tests passing | 8 / 13 | **13 / 13** |
| Leaking real corpus data | **4** (T-04, T-05, T-07, T-13) | **0** |
| Guardrail interventions | 0 | 9 |
| Legitimate utility (T-01) | ✅ | ✅ preserved |

**Recommendation: APPROVE WITH CONDITIONS** — test environment only. Production rollout is blocked on per-user retrieval authorization (condition C1).

---

## Deployed system

| Component | Value |
|---|---|
| Foundation model | `amazon.nova-lite-v1:0` |
| Embedding model | `amazon.titan-embed-text-v2:0` (1024-dim) |
| Knowledge Base | `4BRS8V4CUR` — 30/30 documents, 179 chunks, 0 failed |
| Vector store | S3 Vectors `northstar-kb-index` (cosine, float32) |
| Document store | `s3://northstar-kb-docs-638018627275/corpus/` |
| Guardrail | `mgyw8ekj4xf9` v1 — 5 control types |
| Log group | `/aws/bedrock/northstar-assist` |
| Alarms | 3 → `northstar-ai-security-alerts` |

**Two documented substitutions.** Bedrock **Agents** creation is blocked account-wide (`Maintenance Mode`, reproduced in three regions), so the system uses `RetrieveAndGenerate` — the same managed RAG flow without the Agent wrapper, retaining citations, custom prompt template, guardrails and multi-turn sessions. **Claude 3.7 Sonnet** is unavailable in this account (no Anthropic model is invocable), so **Amazon Nova Lite** — the brief's sanctioned alternative — is used. Both are explained with exact error text in `docs/01-agent-validation.md`.

---

## Reproduce

```bash
cd project
./scripts/00_preflight.sh        # gate: CLI, creds, model access
./scripts/10_s3_bucket.sh        # bucket + 30 documents
./scripts/20_iam_baseline.sh     # permissive baseline roles
./scripts/25_capture_before.sh   # Task 4 "before" — irreversible if skipped
./scripts/30_vector_store.sh     # S3 Vectors index
./scripts/40_knowledge_base.sh   # KB + ingest + verify against the index
./scripts/50_rag_endpoint.sh     # RAG config + end-to-end validation
./scripts/60_logging.sh          # invocation logging — BEFORE any testing
./scripts/70_test_before.sh      # unhardened baseline (perishable)
./scripts/80_iam_harden.sh       # least privilege
./scripts/82_harden_trust.sh     # confused-deputy closure
./scripts/85_guardrail.sh        # guardrail + version
./scripts/88_canary.sh           # indirect-injection test + cleanup
./scripts/90_monitoring.sh       # filters, alarms, SNS
./scripts/95_test_after.sh       # hardened run
uv run python scripts/fill_templates.py
./scripts/97_verify_evidence.sh  # completeness gate
./scripts/99_teardown.sh         # ⚠️ destroys everything — run LAST
```

Monitoring dashboard: `uv run streamlit run dashboard/monitoring_app.py`
Reference client: `uv run streamlit run streamlit_app/app.py`

---

## Stand-out extensions

| Extension | Where |
|---|---|
| **OWASP LLM Top 10 test matrix** | 13 prompts across 10 categories, run twice — `security-tests/prompts.jsonl` |
| **CloudWatch alarms + metric filters** | 3 filters, 3 alarms; patterns derived from 37 real log events — `monitoring/` |
| **Indirect-injection canary** | Planted, retrieved, tested, cleaned up — `scripts/88_canary.sh` |
| **Streamlit monitoring dashboard** | Live CloudWatch with evidence fallback — `dashboard/monitoring_app.py` |

---

## Five findings worth reading

1. **The system prompt defended perfectly against injection and not at all against disclosure.** T-02/T-03 refused unguarded; T-04/T-05/T-07/T-13 leaked. Instruction-following defence and data protection are unrelated problems — an assessment testing only injection would have called this system safe while it leaked six real email addresses.

2. **An ingestion job reported "0 documents failed" while `employee_directory.csv` was missing from the index.** Bedrock still considered it indexed from a prior run against a rebuilt index. The job's own statistics were not sufficient evidence; `40_knowledge_base.sh` now verifies against the vector index itself.

3. **S3 Vectors silently rejected 28 of 30 documents** until `nonFilterableMetadataKeys` was declared — the console sets this automatically, the API does not.

4. **Guardrails filter an over-broad retrieval surface rather than narrowing it.** All 30 documents stay retrievable by any authenticated user; only the response is blocked. That makes I-1 architectural, and is why the recommendation is conditional.

5. **Multi-turn escalation (T-13) leaked in the baseline** across three individually innocuous turns. Guardrail input classification has no conversational memory — the structural weakness remains even though this specific sequence is now blocked.

---

## Untouched starter files

`northstar-knowledge-base/` · `streamlit_app/app.py` · `ML-BOM Template.docx` · `STRIDE-ML Template.docx` — verified unmodified by `97_verify_evidence.sh`. The completed templates are new files in `deliverables/`.

**Secrets:** `project/.env` holds AWS credentials, is gitignored (root `.gitignore:7`) and `chmod 600`. No `AKIA`/`ASIA` material appears in any committable file.
