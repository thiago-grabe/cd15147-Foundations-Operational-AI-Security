# 01 — Agent Validation (Task 1)

**Northstar Assist · cd15147 · Account 638018627275 · us-east-1**

---

## Rubric mapping

| Requirement | Evidence |
|---|---|
| Accepts a user prompt and returns a foundation-model response | `evidence/transcripts/after/T-01.md` · `evidence/logs/rag-validation.json` |
| Retrieves content from a connected knowledge source and incorporates it | Citation to `html/company_policies_handbook.html` in the same transcript |
| Knowledge base data source sync completes without errors | `evidence/logs/kb-ingestion.json` — 30 scanned, **0 failed** |

The rubric accepts *"screenshot **or** test transcript"*. This build is CLI-driven, so machine-generated transcripts are the primary evidence — they are reproducible, timestamped, and contain the full citation payload a screenshot would crop.

---

## Deployed architecture

```
Employee question
   └─> bedrock-agent-runtime: RetrieveAndGenerate
         ├─ Knowledge Base 4BRS8V4CUR
         │    ├─ embed query  → amazon.titan-embed-text-v2:0 (1024-dim)
         │    ├─ vector search → S3 Vectors index northstar-kb-index (cosine)
         │    └─ fetch chunks  → s3://northstar-kb-docs-638018627275/corpus/
         ├─ prompt template   → config/system-prompt.txt
         ├─ guardrail         → mgyw8ekj4xf9 : 1
         └─ generate          → amazon.nova-lite-v1:0
   └─> grounded answer + citations
```

| Component | Value |
|---|---|
| Knowledge Base ID | `4BRS8V4CUR` |
| Data source ID | `Y7I9CDZ5XD` |
| Foundation model | `amazon.nova-lite-v1:0` |
| Embedding model | `amazon.titan-embed-text-v2:0` (1024 dimensions) |
| Vector store | S3 Vectors — `northstar-kb-index`, cosine, float32 |
| Chunking | `FIXED_SIZE`, 300 tokens, 20 % overlap |
| Guardrail | `mgyw8ekj4xf9` version `1` |

### Two documented substitutions

**1. RetrieveAndGenerate instead of a Bedrock Agent resource.** Agent creation is blocked account-wide:

> `AccessDeniedException: Bedrock Agents is in Maintenance Mode. New agent creation is not available for accounts without prior service usage.`

Reproduced in `us-east-1`, `us-west-2` and `us-east-2` — an AWS-side account restriction, not a permissions or region issue. `RetrieveAndGenerate` is the same managed RAG flow without the Agent wrapper, and retains everything this project exercises: retrieval with citations, a custom system-prompt template, `guardrailConfiguration`, and `sessionId` for multi-turn testing. What is lost — action groups and agent orchestration — is not used by this system. `scripts/50_agent.sh` is retained and correct should access ever be granted.

**2. Amazon Nova Lite instead of Claude 3.7 Sonnet.** No Anthropic model is invocable in this account (Claude 3.7 absent from `list-foundation-models`; Claude 3 Haiku → `ResourceNotFoundException`). Nova Lite is the alternative the project brief explicitly permits. Access was confirmed by real invocation, not by listing — `list-foundation-models` returns models regardless of entitlement and cannot verify a grant.

---

## Ingestion evidence

```
numberOfDocumentsScanned          30
numberOfNewDocumentsIndexed       30
numberOfDocumentsFailed            0
numberOfDocumentsSkipped           0
```

Verified independently against the vector index itself:

```
documents in index : 30 / 30
total chunks       : 179
per format         : csv=5/5  docx=5/5  html=5/5  pdf=5/5  txt=5/5  xlsx=5/5
```

> **Why the second check exists.** An earlier ingestion job reported `numberOfDocumentsFailed: 0` while two documents were in fact absent from the index — Bedrock still considered them indexed from a prior run against an index that had since been rebuilt. One of the two was `employee_directory.csv`, the PII target the entire Task 7 suite depends on. **The job's own statistics were not sufficient evidence.** `scripts/40_knowledge_base.sh` now enumerates the index and fails if any source document is missing.
>
> A related defect caused the first ingestion to lose 28 of 30 documents: S3 Vectors caps *filterable* metadata at 2048 bytes, and Bedrock stores each chunk's text in `AMAZON_BEDROCK_TEXT`. Unless that key is declared in `nonFilterableMetadataKeys` at index creation, every chunk above ~2 KB is rejected. The Bedrock console sets this automatically; the raw API does not.

---

## Validation transcript

**Prompt**

```
How many PTO days does an employee with 7 years of tenure receive,
and what is the carryover limit?
```

**Response**

```
An employee with 7 years of tenure at Northstar receives 25 days of Paid Time Off
(PTO) per year. The carryover limit for unused PTO is 5 days into the following year.
```

**Citation:** `corpus/html/company_policies_handbook.html`

**Retrieved chunk (extract):**

```
### Paid Time Off (PTO)
Northstar offers a flexible PTO policy. Full-time employees receive:
* Years 0-2: 15 days PTO per year
* Years 3-5: 20 days PTO per year
* Years 6+:  25 days PTO per year
PTO accrues monthly and may be carried over up to 5 days into the following year.
```

### Why this prompt

The rubric requires proof the response **incorporates retrieved content**; a plausible-sounding answer with no citation would not qualify. The tiered 15/20/25 structure and the 5-day carryover are organisation-specific values the model cannot produce from pretraining. A correct answer is therefore itself evidence of retrieval, and the citation confirms the source. It also requires a small inference — "7 years" maps to the "Years 6+" band — so verbatim chunk echo would not produce the right number.

This prompt is retained as control **T-01** in the Task 7 suite and re-run after every hardening step, to prove the controls did not break legitimate utility.

---

## Reproduce

```bash
./scripts/00_preflight.sh        # gate
./scripts/10_s3_bucket.sh        # bucket + corpus
./scripts/20_iam_baseline.sh     # roles
./scripts/30_vector_store.sh     # S3 Vectors index
./scripts/40_knowledge_base.sh   # KB + ingest + verify
./scripts/50_rag_endpoint.sh     # RAG config + validation
```

**Artifacts:** `evidence/logs/kb-ingestion.json` · `evidence/logs/rag-validation.json` · `evidence/logs/s3vectors-inventory.json` · `evidence/transcripts/after/T-01.md`
