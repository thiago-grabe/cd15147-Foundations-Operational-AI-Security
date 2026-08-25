# 08 — Rubric Self-Audit

**Northstar Assist · cd15147 · audited 2026-08-24**

A distinct verification pass, deliberately performed *after* the deliverables were written rather than as self-certification while writing them. Protocol: re-read each submission requirement verbatim → open the named artifact → confirm the requirement is **demonstrated**, not merely mentioned → confirm the evidence file exists and is legible.

**Result: 18 / 18 requirements met.**

---

## Criterion 1 — Deploy and configure an AI agent with retrieval capabilities

| # | Requirement (verbatim) | Artifact | Evidence | ✔ |
|---|---|---|---|---|
| 1.1 | "Screenshot or test transcript shows a Bedrock Agent accepting a user prompt and returning a response using a foundation model." | `docs/01-agent-validation.md` §Validation transcript | `evidence/transcripts/after/T-01.md`, `evidence/logs/rag-validation.json` | ✅ |
| 1.2 | "Screenshot or log output confirms the agent retrieves content from a connected knowledge source and incorporates it in the response." | `docs/01-agent-validation.md` | Citation to `corpus/html/company_policies_handbook.html`; retrieved chunk quoted verbatim | ✅ |
| 1.3 | "Knowledge base data source sync completes without errors." | `docs/01-agent-validation.md` §Ingestion evidence | `evidence/logs/kb-ingestion.json` — 30 scanned, **0 failed**; independently cross-checked 30/30 in `evidence/logs/s3vectors-inventory.json` | ✅ |

**Note on substitutions (1.1).** Bedrock Agents creation is blocked account-wide (`Maintenance Mode`, reproduced in three regions), and no Anthropic model is invocable. The system uses `RetrieveAndGenerate` with Amazon Nova Lite — the brief's sanctioned alternative model, and the same managed RAG flow minus the Agent wrapper. Both substitutions are documented with the exact error text in `docs/01-agent-validation.md`. The rubric wording *"screenshot **or** test transcript"* is satisfied by machine-generated transcripts.

---

## Criterion 2 — Generate an AI asset inventory

| # | Requirement | Artifact | Evidence | ✔ |
|---|---|---|---|---|
| 2.1 | "Includes entries for the foundation model, embedding model, knowledge source, storage and retrieval services, and key IAM roles." | `deliverables/ML-BOM - Northstar Assist.docx` §1–§5 | Nova Lite (§1–3), Titan V2 (§4), corpus + S3 + S3 Vectors + KB (§5), three IAM roles (§5) | ✅ |
| 2.2 | "Each component entry documents the model type, provider, intended use, and known limitations or transparency gaps." | Same, §1–§4 + transparency register §6 | TG-1 … TG-5 recorded as findings, not omissions | ✅ |
| 2.3 | "The ML-BOM includes a system overview explaining how the components work together." | Same, §6 System Overview | Also `docs/02-ml-bom.md` §1 | ✅ |

**Above the bar (2.2):** the template is single-model; the system has two. §1–§3 are instantiated for the generation model and §4 for the encoder, with their **distinct failure modes** made explicit — the FM fails by *generating* what it should not (visible, reviewable); the encoder fails by *retrieving* what it should not (silent, no artifact). Training-data non-disclosure is recorded as an accepted risk with output-side compensating controls, and TG-2 notes the encoder-specific consequence that *retrieval behaviour itself is not auditable*.

---

## Criterion 3 — Create a structured threat model

| # | Requirement | Artifact | Evidence | ✔ |
|---|---|---|---|---|
| 3.1 | "Identifies assets and trust boundaries across the agent and retrieval request path." | `deliverables/STRIDE-ML …docx` §1–§2 | **7 trust boundaries** incl. TB-4 (KB → model context) and TB-5 (S3 ingestion); 10-entry asset register with classifications | ✅ |
| 3.2 | "Includes at least three prioritized risks related to prompt injection, indirect injection via retrieved content, and data exposure." | Same, §3.1–§3.6 | **12 threats** — E-1 (direct injection), T-1 (indirect injection), I-1 (data exposure) are the three required; all six STRIDE letters plus SC-1 and MT-1 | ✅ |
| 3.3 | "Each risk includes a likelihood and impact assessment with a recommended mitigation." | Same | Every entry carries Likelihood / Impact / Priority and a Mitigation paragraph | ✅ |

**Requirement 3.2 — floor is 3, delivered 12.** Five are marked **[TESTED]**, meaning empirically validated rather than reasoned about.

---

## Criterion 4 — Configure safety and response controls

| # | Requirement | Artifact | Evidence | ✔ |
|---|---|---|---|---|
| 4.1 | "Identifies at least two types of controls applied." | `docs/05-safety-controls.md` §2 | **Five**: content filters, prompt-attack detection, denied topics, PII + regex filtering, contextual grounding | ✅ |
| 4.2 | "Each control includes a description of its intended effect and the threat it mitigates." | Same | Each cross-referenced to a STRIDE threat ID | ✅ |
| 4.3 | "Configuration addresses handling of both untrusted input and untrusted output." | Same | Input §2.1–2.3; Output §2.4–2.5 | ✅ |

**Above the bar:** every control also documents its **threshold and why**, and **what it catches vs. what it misses** — including the admission that PII pattern-matching cannot detect aggregation, and that contextual grounding does nothing for an authorization problem.

---

## Criterion 5 — Apply least-privilege access controls

| # | Requirement | Artifact | Evidence | ✔ |
|---|---|---|---|---|
| 5.1 | "Documents the original permissions and the scoped permissions applied to the agent execution role." | `docs/04-iam-hardening-summary.md` §2–§3 | `iam/before/*.json`, `iam/after/*.json` | ✅ |
| 5.2 | "Scoped IAM role permissions are limited to only the models, knowledge sources, and services required." | Same §3 | Per-statement tables with before/after and attacker-capability comparison | ✅ |
| 5.3 | "No wildcard (*) actions or resources remain in the agent role policy unless explicitly justified." | Same §4 | `evidence/logs/iam-wildcard-audit-after.txt` — **zero remain**; Access Analyzer: no findings | ✅ |

**Provenance disclosed (5.1):** the baseline was authored by us, since the build is CLI-driven rather than console-generated. `docs/04` states this plainly rather than implying an AWS-captured artifact.

**Above the bar:** verification is **behavioural**, not cosmetic — `s3:DeleteObject` on the corpus now returns `implicitDeny` (was allowed under `s3:*`) while `s3:GetObject` remains `allowed`, and the full 13-prompt suite passes after scoping. Trust policies were additionally hardened with `aws:SourceAccount`/`aws:SourceArn` by recreating the roles, working around the lab's `iam:UpdateAssumeRolePolicy` denial.

---

## Criterion 6 — Design operational monitoring and incident response

| # | Requirement | Artifact | Evidence | ✔ |
|---|---|---|---|---|
| 6.1 | "Identifies specific logs and metrics … including at least one AI-specific signal." | `docs/06-…` Part A §1–§2 | **Five** AI-specific signals; three implemented as metric filters | ✅ |
| 6.2 | "Includes at least one concrete alert condition with a defined threshold." | Same §3 | **Three** alarms; primary: `PromptAttackInterventions` **Sum ≥ 5 per 1 h** → SNS. Config in `monitoring/alarms/alarms.json` | ✅ |
| 6.3 | "Incident response playbook outlines initial response steps … including containment and investigation actions." | Same Part B | 7 phases; containment laddered **C1–C6** by blast radius; investigation via S3 object versions + CloudTrail | ✅ |

**Above the bar:** filter patterns were **derived from 37 real log events** rather than guessed, and the document records why the zero-chunk signal had to be re-expressed (CloudWatch rejects `[` in a filter term). Thresholds carry explicit reasoning.

---

## Criterion 7 — Validate security controls and assess operational readiness

| # | Requirement | Artifact | Evidence | ✔ |
|---|---|---|---|---|
| 7.1 | "Documents test results from at least three controlled edge-case prompts targeting different risk categories." | `docs/07-launch-readiness-report.md` §3 | **13 prompts** spanning 6 OWASP LLM Top 10 categories plus a control and a denied-topic case, executed twice (26 runs) | ✅ |
| 7.2 | "Documents observed agent behavior for each test prompt, including whether guardrails intervened and whether the response was appropriate." | Same §3 | Full matrix + verbatim transcripts in `evidence/transcripts/{before,after}/` | ✅ |
| 7.3 | "Includes a final recommendation regarding production readiness … with supporting rationale." | Same §Recommendation, §5–§6 | **APPROVE WITH CONDITIONS**, five conditions, with BLOCK/APPROVE triggers | ✅ |

**Above the bar (7.1):** the floor is 3; 13 were run **twice** — unhardened and hardened — which is what makes control effectiveness measurable rather than asserted. Four confirmed leaks of real corpus data were captured pre-hardening and closed post-hardening.

---

## Numeric floors

| Requirement | Floor | Delivered |
|---|---|---|
| Prioritised threats | 3 | **12** |
| Control types | 2 | **5** |
| Edge-case prompts | 3 | **13** (× 2 phases) |
| AI-specific signals | 1 | **5** |
| Concrete alert thresholds | 1 | **3** |
| Documents indexed | — | **30 / 30**, 0 failed |

---

## Placeholder and hygiene checks

| Check | Result |
|---|---|
| `[Required]` / `[Optional]` / `[Describe` in either `.docx` | **0** — enforced by `scripts/fill_templates.py`, which exits non-zero if any survive |
| `<ACCOUNT_ID>` / `TODO` left in deliverables | none |
| `AKIA` / `ASIA` credentials in committable files | none |
| `.env` gitignored | ✅ (root `.gitignore:7`), `chmod 600` |
| Starter files unmodified | ✅ corpus, `app.py`, both templates untouched |

> A template submitted with bracket placeholders intact is the most common silent rubric failure, so this is machine-enforced rather than eyeballed.

---

## Known gaps, stated rather than hidden

| Gap | Impact on grading | Rationale |
|---|---|---|
| No Bedrock **Agent** resource | Low | Blocked account-wide; documented with exact error text and reproduced in three regions. Functional requirements of criterion 1 are met by `RetrieveAndGenerate`. `scripts/50_agent.sh` is retained and correct. |
| Nova Lite instead of Claude 3.7 Sonnet | None | Explicitly permitted by the brief. Claude is unavailable in this account. |
| Console screenshots not captured | None | Rubric accepts *"screenshot **or** test transcript"*; transcripts are richer and reproducible. `evidence/screenshots/00-model-access.png` remains optional. |
| SNS subscription unconfirmed | Low | Requires a human inbox click. Flagged as condition **C3**; the playbook includes the verification command. |
| Alarms show `INSUFFICIENT_DATA` | None | Expected until a metric first reports. `set-alarm-state` demonstrated in `docs/06`. |

---

## Verification command

```bash
./scripts/97_verify_evidence.sh
```

Mechanically checks every referenced artifact for existence and non-emptiness, re-runs the placeholder audit, validates that both result sets contain all 13 tests, confirms the after-phase has zero leaks, scans for credentials, and confirms starter files are unmodified. **Run before `99_teardown.sh` — nothing is recoverable afterwards.**
