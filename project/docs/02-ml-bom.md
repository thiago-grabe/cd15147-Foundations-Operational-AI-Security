# 02 — ML-BOM / AI Asset Inventory (Task 2)

**System:** Northstar Assist · **Account:** 638018627275 · **Region:** us-east-1
**Generated:** 2026-08-24 · **Method:** AWS CLI introspection of the live deployment

---

## Rubric mapping

| Requirement | Where |
|---|---|
| Entries for foundation model, embedding model, knowledge source, storage/retrieval services, key IAM roles | §2, §3, §4 |
| Each entry documents type, provider, intended use, known limitations / transparency gaps | §2, §3 (all six template subsections) |
| Includes a system overview explaining how components work together | §1 |

Every identifier below was read from the running system, not transcribed from a plan.

---

## 1. System Overview

Northstar Assist is a retrieval-augmented generation system. A question is embedded, matched against a vector index of internal documentation, and the retrieved passages are supplied to a generation model that composes a grounded answer with citations.

```
question ──► Titan Text Embeddings V2 ──► 1024-dim query vector
                                              │
                                     cosine search over 179 chunks
                                              │
                          S3 Vectors index ◄──┴──► S3 corpus (30 documents)
                                              │
                            retrieved passages + system template
                                              │
                                     Nova Lite ──► grounded answer + citations
```

### 1.1 Two models, two entirely different failure modes

This is the most important thing the inventory records, and the reason the template is instantiated twice.

| | Nova Lite | Titan Text Embeddings V2 |
|---|---|---|
| Class | Generative decoder | **Encoder — produces vectors, not text** |
| Output | Natural language | 1024 float32 values |
| Fails by | **Generating** something it should not | **Retrieving** something it should not |
| Observability | The bad output is visible and reviewable | **Silent** — a wrong neighbour surfaces no artifact to inspect |
| Guardrail coverage | Covered (input and output assessment) | **Not covered** — guardrails never see the embedding step |

A generation failure leaves evidence. A retrieval failure does not: if the encoder places `employee_directory.csv` near an innocuous query, the only symptom is that confidential text quietly enters model context. Every control in Task 5 operates on text — none inspects vector space. This asymmetry is why threat I-1 is architectural rather than a tuning problem.

### 1.2 Component map

| Layer | Component | Identifier |
|---|---|---|
| Generation | Amazon Nova Lite | `amazon.nova-lite-v1:0` |
| Embedding | Amazon Titan Text Embeddings V2 | `amazon.titan-embed-text-v2:0` |
| Orchestration | Bedrock Knowledge Base | `4BRS8V4CUR` |
| Data source | Bedrock S3 data source | `Y7I9CDZ5XD` |
| Vector store | Amazon S3 Vectors | `northstar-kb-index` |
| Document store | Amazon S3 | `northstar-kb-docs-638018627275` |
| Safety | Bedrock Guardrail | `mgyw8ekj4xf9` v1 |
| Observability | CloudWatch Logs | `/aws/bedrock/northstar-assist` |
| Client | Streamlit | `streamlit_app/app.py` |

---

## 2. Model 1 — Amazon Nova Lite (generation)

### 2.1 Model Information

| Field | Value |
|---|---|
| Name | Amazon Nova Lite |
| Version | `amazon.nova-lite-v1:0` |
| ARN | `arn:aws:bedrock:us-east-1::foundation-model/amazon.nova-lite-v1:0` |
| Type | Text generation (multimodal-capable; used text-only here) |
| Author | Amazon Web Services |
| Licence | Proprietary — AWS Service Terms; consumed as a managed service |
| Libraries | None deployed. Accessed via `bedrock-agent-runtime` (boto3 ≥ 1.35) |
| Source | Amazon Bedrock managed endpoint. No weights downloaded or hosted |

**Substitution note.** The project brief specifies Claude 3.7 Sonnet *or* Amazon Nova Lite. Claude 3.7 Sonnet is **not available in this account** — absent from `list-foundation-models`, no inference profile, and no Anthropic model is invocable (`ResourceNotFoundException`). Nova Lite was confirmed working by real invocation. This is itself a supply-chain observation: **model availability is an entitlement, not a property of the region**, and a system designed around one provider may find it unavailable at deployment time.

### 2.2 BOM Generation

| Field | Value |
|---|---|
| Generated | 2026-08-24 |
| By | Thiago M. Grabe (AI Security Engineer) |
| Method | AWS CLI introspection of the live deployment (`scripts/*.sh`) |

### 2.3 Training Datasets

| Dataset | Source | Licence | Notes |
|---|---|---|---|
| **Not disclosed** | — | — | **Transparency gap — recorded as a finding.** |

**Finding TG-1.** Amazon does not publish the training-data composition for Nova Lite. Consequences, stated plainly:

- Pretraining-layer **data poisoning cannot be ruled out or detected** by us.
- **Bias characteristics cannot be independently assessed** against Northstar's use.
- Copyright/provenance of training material cannot be verified.
- Memorised-content extraction risk cannot be quantified.

**Status: accepted risk, not mitigated.** No customer-side control addresses the pretraining layer. Compensating controls are entirely output-side — contextual grounding (0.75), PII filtering, denied topics. This is a genuine limit of consuming a closed managed model, and it is recorded rather than glossed.

**Northstar data is not used for training.** No fine-tuning was performed; the corpus is supplied as retrieval context at inference only.

### 2.4 Architecture Details

| Field | Value |
|---|---|
| Architecture | Not disclosed (transformer-family assumed) |
| Architecture family | Amazon Nova |
| Parameters | Not disclosed |
| Context window | Not disclosed for this tier; not a binding constraint at 5 chunks × ~300 tokens |

### 2.5 Model Lineage

| Relationship | Value |
|---|---|
| Parent model | Not disclosed |
| Base model | Not disclosed |
| Fine-tuning by Northstar | **None** |

### 2.6 Input / Output

| Field | Value |
|---|---|
| Input | Text — system prompt template + retrieved passages + user turn |
| Output | Text — natural-language answer, with citation spans attributed by Bedrock |
| Determinism | Non-deterministic. **Security test results are probabilistic and must be re-run after any change** |

### 2.7 Hardware & Software

| Category | Detail |
|---|---|
| Hardware | AWS-managed; not exposed |
| Software | Amazon Bedrock managed runtime |
| Client dependency | `boto3` (see §5) |

### 2.8 Software Required for Execution

| Field | Value |
|---|---|
| Includes executable code | **False** — no model code runs in Northstar's account |
| Additional dependencies | None beyond the AWS SDK |

### 2.9 Intended Use

Answering Northstar employee questions about internal policies, procedures, products and engineering documentation, grounded in retrieved corpus content and cited to source.

### 2.10 Out of Scope

- Legal, medical, tax or personal financial advice (blocked by denied topic)
- Any question not answerable from the Northstar corpus
- Autonomous action — there are no action groups; the system can only answer
- External/customer-facing use; audience is internal employees only
- Authoritative HR or compensation decisions

### 2.11 Misuse or Malicious Use

| Misuse | Control |
|---|---|
| Harvesting employee PII for phishing | Denied topic + PII anonymisation (**leaked in baseline T-04**) |
| Extracting customer financials | Denied topic (T-06) |
| Infrastructure reconnaissance | Denied topic + instance-ID regex BLOCK (**leaked in baseline T-07**) |
| Prompt injection / jailbreak | `PROMPT_ATTACK` HIGH (T-02, T-03) |
| Indirect injection via poisoned documents | Read-only ingestion; untrusted-data clause (T-10) |
| Cost DoS via token amplification | Guardrail + alarms (T-12) |
| Aggregation across turns | Denied topics — **partial; RR-2 remains open** (T-05, T-13) |

---

## 3. Model 2 — Amazon Titan Text Embeddings V2 (encoder)

> Documented separately because it is **not a generation model**. It produces vectors. Its risks, controls and observability differ fundamentally from §2.

### 3.1 Model Information

| Field | Value |
|---|---|
| Name | Amazon Titan Text Embeddings V2 |
| Version | `amazon.titan-embed-text-v2:0` |
| ARN | `arn:aws:bedrock:us-east-1::foundation-model/amazon.titan-embed-text-v2:0` |
| Type | **Text embedding (encoder)** — vector output, no text generation |
| Author | Amazon Web Services |
| Licence | Proprietary — AWS Service Terms |
| Source | Amazon Bedrock managed endpoint |

### 3.2 Training Datasets

**Not disclosed.** **Finding TG-2**, with a consequence specific to encoders:

An embedding model's training data determines *what it considers similar*. Undisclosed training data means **the retrieval behaviour itself is not auditable** — there is no way to predict or verify which queries will surface `employee_directory.csv`. Retrieval relevance cannot be formally assured, only tested empirically. This is a materially different concern from generation-side opacity, and it is why the Task 7 suite tests retrieval outcomes rather than reasoning about them.

### 3.3 Architecture Details

| Field | Value |
|---|---|
| Architecture | Not disclosed (transformer encoder) |
| Family | Amazon Titan |
| **Output dimensions** | **1024** (verified by invocation) |
| Data type | `float32` |
| Distance metric in use | Cosine |

The index dimension **must** match the model output. Verified at build time by `scripts/30_vector_store.sh`; a mismatch fails at ingestion with an error that does not point back to its cause.

### 3.4 Input / Output

| Field | Value |
|---|---|
| Input | Text chunk (≈300 tokens) or user query |
| Output | **1024 float32 values** — no natural language |
| Determinism | Deterministic for identical input |

### 3.5 Invertibility — a confidentiality property

Text embeddings are **partially invertible**: approximate source text can be reconstructed from vectors. Additionally, Bedrock stores each chunk's **plaintext** in the `AMAZON_BEDROCK_TEXT` metadata field alongside its vector.

**Therefore read access to the vector index is functionally equivalent to read access to the corpus.** The vector store is a confidentiality asset at the same classification as the source documents, not merely a search structure. Reflected in threat I-3 and in the IAM scoping, which limits index access to six data-plane actions on one index ARN.

### 3.6 Intended Use / Out of Scope / Misuse

| | |
|---|---|
| Intended | Embedding the 30-document corpus and incoming queries for similarity retrieval |
| Out of scope | Classification, clustering or any decision-making use; generation of any kind |
| Misuse | Embedding-inversion attacks against the index; unauthorised bulk export of vectors |

### 3.7 Software Required for Execution

| Field | Value |
|---|---|
| Includes executable code | **False** |
| Additional dependencies | None |

---

## 4. Supporting components

### 4.1 Knowledge source

| Field | Value |
|---|---|
| Corpus | 30 synthetic Northstar documents |
| Formats | csv (5), docx (5), html (5), pdf (5), txt (5), xlsx (5) |
| Location | `s3://northstar-kb-docs-638018627275/corpus/` |
| Chunking | `FIXED_SIZE`, **300 tokens, 20 % overlap** |
| Chunks produced | **179** |
| Ingestion result | 30 scanned, 30 indexed, **0 failed** |

**Chunk size is a security parameter, not just a quality one.** A larger chunk drags more neighbouring text into model context — over a CSV, a query about one employee can retrieve rows for twenty. 300 tokens is the conservative setting; the trade-off is recorded under threat I-1.

**Data classification.** The corpus deliberately contains confidential material — see `03-stride-ml-threat-model.md` §2.

### 4.2 Storage and retrieval services

| Service | Identifier | Configuration |
|---|---|---|
| S3 (documents) | `northstar-kb-docs-638018627275` | Versioning **enabled**, all public access blocked, SSE-S3 |
| S3 Vectors (index) | `northstar-kb-index` in `northstar-vectors-638018627275` | 1024-dim, cosine, float32, SSE-AES256 |
| Bedrock KB | `4BRS8V4CUR` | Vector type, S3_VECTORS storage |
| Bedrock data source | `Y7I9CDZ5XD` | S3, `inclusionPrefixes: ["corpus/"]` |

**S3 Vectors configuration note.** The index declares `nonFilterableMetadataKeys: [AMAZON_BEDROCK_TEXT, AMAZON_BEDROCK_METADATA]`. This is **mandatory** for Bedrock integration: S3 Vectors caps *filterable* metadata at 2048 bytes, and chunk text exceeds it. Without it, ingestion fails per-document — observed here as 28 of 30 documents rejected. The console sets it automatically; the API does not.

**Cost posture.** S3 Vectors is pay-per-request. OpenSearch Serverless, the alternative, bills a standing hourly minimum (~$10–25/day) regardless of use.

### 4.3 Safety component

| Field | Value |
|---|---|
| Guardrail | `mgyw8ekj4xf9`, version **1** (immutable) |
| Controls | 6 content filters · 5 denied topics · 8 PII entities · 4 custom regex · contextual grounding |
| Coverage gap | Assesses **text only** — never inspects the embedding or retrieval step |

### 4.4 Key IAM roles

| Role | Assumed by | Scoped permissions |
|---|---|---|
| `NorthstarAssist-KnowledgeBaseRole` | `bedrock.amazonaws.com` | `InvokeModel` on Titan only; `GetObject` on `corpus/*`; `ListBucket` prefix-conditioned; 6 S3 Vectors data-plane actions on one index |
| `NorthstarAssist-AgentRole` | `bedrock.amazonaws.com` | `Retrieve`/`RetrieveAndGenerate` on KB `4BRS8V4CUR`; `InvokeModel` on Nova Lite; `ApplyGuardrail` on `mgyw8ekj4xf9` |
| `NorthstarAssist-BedrockLoggingRole` | `bedrock.amazonaws.com` | `CreateLogStream` + `PutLogEvents` on one log-stream ARN |

All three carry `aws:SourceAccount` + `aws:SourceArn` trust conditions. **Zero wildcard actions or resources remain.** Detail in `04-iam-hardening-summary.md`.

### 4.5 Observability

| Field | Value |
|---|---|
| Log group | `/aws/bedrock/northstar-assist` (30-day retention) |
| Data logged | Text + embedding invocations, including guardrail trace |
| Metric namespace | `NorthstarAssist` — 3 filters |
| Alarms | 3, notifying `arn:aws:sns:us-east-1:638018627275:northstar-ai-security-alerts` |

---

## 5. Client-side software dependencies

From `pyproject.toml` (Python ≥ 3.13):

| Package | Purpose |
|---|---|
| `boto3` ≥ 1.35 | Bedrock, S3, IAM, CloudWatch |
| `streamlit` ≥ 1.40 | Reference client and monitoring dashboard |
| `python-dotenv` ≥ 1.0 | Configuration loading |
| `python-docx` ≥ 1.1 | Deliverable generation |
| `openpyxl` ≥ 3.1 | Reading corpus `.xlsx` |
| `pandas` ≥ 2.2 | Test-result aggregation |

**Supply-chain note.** No model weights, inference servers or ML frameworks are deployed in Northstar's account — every model is a managed endpoint. This removes a large class of supply-chain risk (malicious weights, vulnerable serving stacks) and replaces it with provider dependence and the transparency gaps in §2.3 / §3.2.

---

## 6. Transparency gap register

| ID | Gap | Component | Consequence | Status |
|---|---|---|---|---|
| TG-1 | Training data not disclosed | Nova Lite | Pretraining poisoning/bias unverifiable | **Accepted**, output-side compensating controls |
| TG-2 | Training data not disclosed | Titan V2 | **Retrieval behaviour not auditable**; relevance assured only empirically | **Accepted**, tested rather than reasoned |
| TG-3 | Architecture/parameters not disclosed | Both | No independent capability assessment | Accepted |
| TG-4 | Model lineage not disclosed | Both | Provenance chain unverifiable | Accepted |
| TG-5 | Non-deterministic output | Nova Lite | Security results are probabilistic | **Mitigated by process** — re-run the suite on every change |

---

## 7. Attestation

| Role | Name | Date |
|---|---|---|
| Author | Thiago M. Grabe | 2026-08-24 |
| Reviewer | *(pending)* | |

**References:** CycloneDX ML-BOM Specification · SPDX AI/ML Profile · NIST AI Risk Management Framework
**Evidence:** `evidence/logs/resource-facts.txt` · `evidence/logs/kb-ingestion.json` · `evidence/logs/s3vectors-index.json` · `evidence/logs/guardrail-config.json`
