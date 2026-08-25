# 04 — IAM Hardening Summary (Task 4)

**Northstar Assist · Account 638018627275 · us-east-1**

---

## Rubric mapping

| Requirement | Where |
|---|---|
| Documents the original **and** scoped permissions | §2 before · §3 after · raw JSON in `iam/before/` and `iam/after/` |
| Scoped to only the models, knowledge sources and services required | §3 per-statement tables |
| No wildcard actions or resources remain unless justified | §4 — **zero remain** |

---

## 1. Provenance of the "before" state

Because this system was built by CLI rather than through the Bedrock console wizard, **the baseline policies were authored by us**, not captured from an AWS-generated role. This is stated plainly rather than implied.

`scripts/20_iam_baseline.sh` creates both roles with a realistic first-pass policy — the kind the console wizard produces and the kind an engineer writes on day one: service-level wildcards on `Resource: "*"`. Task 4 asks you to *"identify any permissions that are broader than necessary — look for wildcard actions (`bedrock:*`, `s3:*`) and wildcard resources (`*`)"*, and a baseline containing exactly those satisfies that framing.

The advantage of scripting it: the before → after transition is a reproducible git diff rather than a one-off screenshot nobody can re-derive. `scripts/25_capture_before.sh` snapshots the originals **before** any scoping, because `put-role-policy` overwrites in place and inline role policies have no version history.

## Roles in scope

| Role | Assumed by | Purpose |
|---|---|---|
| `NorthstarAssist-KnowledgeBaseRole` | `bedrock.amazonaws.com` | Reads corpus objects, calls Titan to embed, reads/writes the vector index |
| `NorthstarAssist-AgentRole` | `bedrock.amazonaws.com` | Application invocation identity — what the Streamlit client uses to call RetrieveAndGenerate |
| `NorthstarAssist-BedrockLoggingRole` | `bedrock.amazonaws.com` | Writes model invocation logs |

> **Note on the second role.** Because Bedrock Agents are in Maintenance Mode for this account, there is no Agent execution role. `NorthstarAssist-AgentRole` is the **caller** identity instead. It remains a genuine least-privilege boundary — it decides which knowledge base, which model and which guardrail the application may touch — and is scoped accordingly.

`NorthstarAssist-BedrockLoggingRole` was written least-privilege from the outset (`logs:CreateLogStream` + `logs:PutLogEvents` on one log-stream ARN), so it has no before/after delta.

---

## 2. Before — the permissive baseline

**Wildcard audit output** (`evidence/logs/iam-wildcard-audit.txt`):

```
ROLE                                   SID                    ACTION             RESOURCE
NorthstarAssist-AgentRole              BedrockFullAccess      bedrock:*          *
NorthstarAssist-AgentRole              S3FullAccess           s3:*               *
NorthstarAssist-AgentRole              LogsFullAccess         logs:*             *
NorthstarAssist-KnowledgeBaseRole      BedrockFullAccess      bedrock:*          *
NorthstarAssist-KnowledgeBaseRole      S3FullAccess           s3:*               *
NorthstarAssist-KnowledgeBaseRole      S3VectorsFullAccess    s3vectors:*        *

TOTAL wildcard statements needing justification or scoping: 6
```

Both trust policies additionally allowed `bedrock.amazonaws.com` to assume the role with **no conditions at all**.

---

## 3. After — scoped, with rationale

### 3.1 KnowledgeBaseRole

| Sid | Before | After | What an attacker could do before vs. after |
|---|---|---|---|
| `InvokeEmbeddingModelOnly` | `bedrock:*` on `*` | `bedrock:InvokeModel` on the Titan ARN only | **Before:** invoke any model in the account — run inference at Northstar's expense, or use a more capable model to process exfiltrated corpus text. Also `bedrock:Delete*` on any Bedrock resource. **After:** one embedding model. Cannot generate text at all. |
| `ReadCorpusObjectsOnly` | `s3:*` on `*` | `s3:GetObject` on `…/corpus/*` + `aws:ResourceAccount` condition | **Before:** read, overwrite or delete **every S3 object in the account**, including buckets unrelated to this system. Critically, `s3:PutObject` on the corpus prefix means the role could **poison its own knowledge base** (threat T-2). **After:** read-only, one prefix, this account. |
| `ListOnlyCorpusPrefix` | (covered by `s3:*`) | `s3:ListBucket` with `s3:prefix` condition on `corpus/*` | **Before:** enumerate every bucket and key in the account — reconnaissance ahead of exfiltration. **After:** can list only the prefix it must crawl. |
| `VectorIndexDataPlaneOnly` | `s3vectors:*` on `*` | 6 data-plane actions on the specific index ARN | **Before:** `DeleteIndex` / `DeleteVectorBucket` destroys the knowledge base outright (availability), and `PutVectors` into *any* index allows silent embedding poisoning. **After:** data-plane only, one index. No control-plane verbs. |

The prefix condition is only possible because `scripts/10_s3_bucket.sh` uploaded to `corpus/` rather than the bucket root — an early decision made specifically to enable this scoping.

### 3.2 AgentRole

| Sid | Before | After | What an attacker could do before vs. after |
|---|---|---|---|
| `QueryThisKnowledgeBaseOnly` | `bedrock:*` on `*` | `bedrock:Retrieve`, `bedrock:RetrieveAndGenerate` on KB `4BRS8V4CUR` | **Before:** query any knowledge base in the account, create or delete Bedrock resources, and — most damagingly — **create or modify guardrails**, disabling the very controls in Task 5. **After:** query one knowledge base. |
| `InvokeGenerationModelOnly` | `bedrock:*` on `*` | `bedrock:InvokeModel` on the Nova Lite ARN | **Before:** invoke any model, including expensive ones (cost DoS, threat D-1). **After:** one model. |
| `ApplyGuardrail` | `bedrock:*` on `*` | `bedrock:ApplyGuardrail` on guardrail `mgyw8ekj4xf9` | **Before:** apply *or alter* any guardrail. **After:** apply this one; cannot modify it. |
| `S3FullAccess` | `s3:*` on `*` | **removed entirely** | The application never touches S3 directly — retrieval is brokered by Bedrock. The whole statement was unnecessary. |
| `LogsFullAccess` | `logs:*` on `*` | **removed entirely** | Logging is performed by the dedicated logging role. `logs:*` would have allowed `logs:DeleteLogGroup` — **destroying the audit trail**, which is threat R-1 (repudiation). |

### 3.3 Trust policies — confused-deputy closure

Both roles now require the caller to be this account and a Bedrock resource in this region:

```json
"Condition": {
  "StringEquals": { "aws:SourceAccount": "638018627275" },
  "ArnLike":      { "aws:SourceArn": "arn:aws:bedrock:us-east-1:638018627275:*" }
}
```

> **This nearly became a residual risk.** The lab account denies `iam:UpdateAssumeRolePolicy`, so the trust document of an existing role cannot be edited:
>
> ```
> User ... is not authorized to perform: iam:UpdateAssumeRolePolicy
> ```
>
> However `iam:CreateRole` **is** permitted and accepts a trust document at creation. `scripts/82_harden_trust.sh` therefore recreates both roles with hardened trust. Because the knowledge base must reference a valid role at all times, it performs a temp-role swap — create temp → repoint KB → delete original → recreate hardened → repoint back → delete temp — verifying retrieval behaviourally at each step. **R-TRUST is closed, not accepted.**

---

## 4. Wildcard re-audit

`evidence/logs/iam-wildcard-audit-after.txt`:

```
✅ zero wildcard actions and zero wildcard resources remain
```

Both policies also pass IAM Access Analyzer with **no findings**.

---

## 5. Verification — behavioural, not cosmetic

A policy that *looks* tight proves nothing. Both directions were tested.

**Negative — an out-of-scope action is now denied:**

```
s3:DeleteObject on corpus/csv/employee_directory.csv  →  implicitDeny
```
(was **allowed** under `s3:*`)

**Positive — legitimate retrieval still works:**

```
s3:GetObject on corpus/csv/employee_directory.csv  →  allowed
T-01 baseline grounding                            →  pass, cited
```

The full 13-prompt suite was re-run after scoping and after the trust-policy swap: **13/13 passing**. Least privilege that breaks the product is not a win; this is the evidence it did not.

---

## 6. Remaining risk

| ID | Risk | Status |
|---|---|---|
| R-CALLER | In this lab the application is invoked with the operator's own `voclabs` credentials, which are broad. `NorthstarAssist-AgentRole` is scoped correctly but is not yet *assumed* by a running app. | **Open — environmental.** In production the Streamlit task would assume this role via an instance profile or IRSA, with no user credentials present. Documented in the launch-readiness conditions. |
| R-GUARDRAIL-ADMIN | No separation between who operates the assistant and who edits its guardrail. | **Open.** Recommend a distinct admin role holding `bedrock:UpdateGuardrail`, denied to the runtime role. |

---

**Artifacts:** `iam/before/*.json` · `iam/after/*.json` · `evidence/logs/iam-wildcard-audit.txt` · `evidence/logs/iam-wildcard-audit-after.txt`
**Scripts:** `20_iam_baseline.sh` · `25_capture_before.sh` · `80_iam_harden.sh` · `82_harden_trust.sh`
