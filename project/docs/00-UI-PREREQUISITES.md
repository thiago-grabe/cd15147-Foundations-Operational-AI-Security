# 00 — UI Prerequisites (Manual Setup Gate)

**Northstar Assist · Foundations of Operational AI Security (cd15147)**

---

## Current status — verified 2026-08-24

```
./scripts/00_preflight.sh   →   passed 15 · failed 4 · warnings 2
```

| § | Item | Status |
|---|---|---|
| 1.0 | Corporate TLS interception (Zscaler) | ✅ **resolved** — `AWS_CA_BUNDLE` configured |
| 1.1 | **AWS CLI ≥ 2.28 (S3 Vectors)** | ❌ **BLOCKED — needs you (sudo)** |
| 1.2 | Credentials → `.env` | ✅ **done** — account `638018627275` authenticated |
| 1.3 | Bedrock model access | ✅ **done** — but the model changed, see below |
| 1.4 | Gate verification | ⏳ blocked only by §1.1 |

**One action is outstanding: §1.1.** Everything else passes.

Two findings changed the plan's assumptions — both documented in place below:
1. **Claude 3.7 Sonnet is not available in this account.** The foundation model is now **Amazon Nova Lite**, the fallback the project brief explicitly permits.
2. **A corporate TLS proxy blocks the Bedrock endpoints** unless a custom CA bundle is configured. This is not in the course materials.

---

## What this document is

Everything in this project that **cannot be scripted**. Once these pass, every remaining resource — S3, IAM, vector store, Knowledge Base, Agent, Guardrails, logging, alarms, teardown — is created by CLI scripts in `project/scripts/`.

This is a **gate**. Nothing downstream runs until `00_preflight.sh` exits clean.

---

## 1.0 — Corporate TLS interception ✅ resolved

**Not in the course materials — discovered on this machine.**

### Symptom

```
SSL validation failed for https://bedrock.us-east-1.amazonaws.com/foundation-models
[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: unable to get local issuer certificate
```

Confusingly, `sts` and `iam` calls succeeded while `bedrock` failed.

### Cause

```
subject = CN=bedrock.us-east-1.amazonaws.com, O=Zscaler Inc.
issuer  = CN=Zscaler Intermediate Root CA (zscalerthree.net), O=Zscaler Inc.
```

A **Zscaler** TLS-inspection proxy re-signs traffic to `bedrock.*`. The AWS CLI ships its own CA bundle that does not include the corporate root, so verification fails. `sts`/`iam` worked because those domains are on the proxy's inspection-bypass list.

### Fix applied

Trust the corporate root that is *already installed system-wide* — rather than disabling verification, which would be indefensible in a security project and would also mean this build could not detect a real MITM.

```bash
BUNDLE="$HOME/.aws/ca-bundle-with-zscaler.pem"
cat /usr/local/aws-cli/awscli/botocore/cacert.pem > "$BUNDLE"
security find-certificate -a -c "Zscaler" -p /Library/Keychains/System.keychain >> "$BUNDLE"
```

`AWS_CA_BUNDLE` in `.env` now points at that file (131 certificates). Both the AWS CLI and boto3 honour it, so scripts and Python tooling are covered by the one setting.

> ⚠️ **Never** use `--no-verify-ssl` as a workaround. Aside from the irony in an AI-security deliverable, it would suppress genuine certificate errors for the rest of the build.
>
> 📝 This is worth a line in the **STRIDE-ML** deliverable: an enterprise TLS-inspection proxy is itself a trust boundary — it terminates TLS and can read every prompt and response in plaintext, including anything the corpus returns.

---

## 1.1 — Upgrade the AWS CLI ⚠️ **OUTSTANDING — action required**

### Why

Verified on this machine:

```
aws-cli/2.25.14                        (April 2025)
aws s3vectors                          → NOT FOUND
create-knowledge-base storage types    → OPENSEARCH_SERVERLESS, PINECONE, RDS,
                                         REDIS_ENTERPRISE_CLOUD, MONGO_DB_ATLAS,
                                         NEPTUNE_ANALYTICS, OPENSEARCH_MANAGED_CLUSTER
                                         → S3_VECTORS ABSENT
```

Amazon S3 Vectors launched **July 2025**; this CLI predates it. It can neither create the vector store nor create a Knowledge Base pointing at one. Not a configuration issue — the API models aren't in the binary.

> **Why S3 Vectors matters:** pay-per-request, cents for this corpus. The alternative, OpenSearch Serverless, bills a **standing hourly minimum (~$10–25/day)** whether queried or not and can exhaust a lab budget in two days. This is the single biggest cost decision in the project.

### Do this

```bash
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "/tmp/AWSCLIV2.pkg"
sudo installer -pkg /tmp/AWSCLIV2.pkg -target /
hash -r          # clear the shell's cached path to the old binary
aws --version    # expect 2.28.x or newer
```

Requires `sudo`, which is why it can't be scripted from here.

If `aws --version` still reports 2.25.14, a second copy is earlier in `PATH`:
```bash
which -a aws
```

### Verify

```bash
./scripts/00_preflight.sh
```

The four §2 failures should turn green.

### If `S3_VECTORS` still doesn't appear after upgrading

1. **Recheck** `which -a aws` resolves to the new binary.
2. **Console fallback** — create the KB manually (§1.5); everything downstream still scripts. Put the IDs in `.env` and tell me.
3. **Do not silently switch to OpenSearch Serverless** — see the cost warning. If S3 Vectors is genuinely unavailable in this account, tell me first.

---

## 1.2 — Credentials → `project/.env` ✅ done

Authenticated as:

```
Account 638018627275
Arn     arn:aws:sts::638018627275:assumed-role/voclabs/user1449613=...
```

`voclabs` = **AWS Academy Learner Lab**. Confirmed by direct test: this account **can create IAM roles** (checked with a throwaway role, since deleted), so the Task 4 hardening scripts will work as planned.

### ⚠️ Credentials expire — expect this

Lab sessions last 1–12 hours. When a script that worked ten minutes ago fails with `InvalidClientTokenId` or `ExpiredToken`:

**Refresh the credentials in `.env` — do not debug the script.** This will happen at least once during the build. Re-copy all three values from the lab portal; the session token changes every time.

The starter `streamlit_app/.env.example` omits `AWS_SESSION_TOKEN` entirely, which is why the initial connection failed. `project/.env.template` includes it.

### Security

- `project/.env` is **gitignored** (repo root `.gitignore:7`, verified) and `chmod 600`.
- `project/.env.template` is tracked and must never hold real values.
- Scripts load `.env` into the process environment; secret values are never echoed.
- Before any commit, artifacts are scanned for `AKIA`/`ASIA`/`aws_secret`, and the account ID is replaced with `<ACCOUNT_ID>` in committed documents.

*Static keys in a dotfile are weaker than SSO or role assumption. For a time-boxed lab with a hard teardown this is pragmatic, and it's recorded in the threat model as an accepted risk of the development environment — not the deployed system.*

---

## 1.3 — Bedrock model access ✅ done — **model substitution required**

### Finding: Claude 3.7 Sonnet is unavailable in this account

```
list-foundation-models  --by-provider anthropic   → no claude-3-7-sonnet entry
list-inference-profiles --query claude-3-7-sonnet → []
converse anthropic.claude-3-haiku…                → ResourceNotFoundException
converse anthropic.claude-sonnet-4-5…             → ValidationException
```

No Anthropic model is invocable in this Learner Lab. The project brief anticipates this and permits **Amazon Nova Lite** as the alternative.

### Confirmed working — by real invocation, not listing

| Role | Model ID | Evidence |
|---|---|---|
| Foundation model | **`amazon.nova-lite-v1:0`** | `converse` returned text ✅ |
| Embeddings | **`amazon.titan-embed-text-v2:0`** | `invoke-model` returned a **1024-dim** vector ✅ |

> **Why invoke instead of list:** `list-foundation-models` returns every model in the region regardless of whether access is granted, so it cannot verify a grant. A tiny real call (a few tokens, effectively free) returns `AccessDeniedException` when access is missing. It is the only definitive test — and it's what `00_preflight.sh` check 4 does.

Recorded in `.env`:
```bash
FM_MODEL_ID=amazon.nova-lite-v1:0
EMBED_MODEL_ID=amazon.titan-embed-text-v2:0
EMBED_DIMENSION=1024      # vector index dimension MUST match this
```

### Downstream consequences

| Area | Effect |
|---|---|
| **Task 2 — ML-BOM** | Model entry documents Nova Lite (Amazon, not Anthropic): different provider, licence, and transparency posture. The substitution and its reason get recorded — a real supply-chain observation, not an inconvenience. |
| **Task 4 — IAM** | Model ARN becomes `arn:aws:bedrock:us-east-1::foundation-model/amazon.nova-lite-v1:0`. **Simpler than planned:** Nova Lite is on-demand, so the cross-region inference-profile trap (needing the profile ARN *plus* per-region model ARNs) does not apply. To confirm during Phase 6, since Bedrock Agents sometimes require an inference profile. |
| **Task 5 — Guardrails** | Unchanged; guardrails are model-agnostic. |
| **Task 7 — Testing** | Nova Lite is a smaller model than Claude 3.7 and may behave differently under injection. That is a *finding to report*, not a problem to hide — the launch-readiness report notes that results are model-specific and would need re-validation before any model swap. |

### If you'd rather use a different model

`amazon.nova-pro-v1:0` and `amazon.nova-micro-v1:0` are also present (micro confirmed invocable). Nova Lite is the right default: it's the brief's named alternative and balances capability against lab cost. Tell me if you want to change it.

### 📸 Screenshot still worth taking

Console → Bedrock → **Model access**, showing the granted models:

```
project/evidence/screenshots/00-model-access.png
```

Access is already proven functionally, but the screenshot is cheap and **not reproducible after teardown**.

---

## 1.4 — Verify the gate

```bash
cd /Users/73983/ws/grabe/cd15147-Foundations-Operational-AI-Security/project
./scripts/00_preflight.sh
```

Read-only apart from `uv sync`; safe to re-run. Every check runs even when an earlier one fails, so you get the full picture in one pass.

| # | Check | Currently |
|---|---|---|
| 1 | `uv` present, `uv sync`, imports | ✅ |
| 2 | AWS CLI ≥ 2.28 | ❌ §1.1 |
| 3 | `s3vectors` + `create-index` | ❌ §1.1 |
| 4 | `S3_VECTORS` in KB storage enum | ❌ §1.1 |
| 5 | `.env` loads; all credential values set | ✅ |
| 6 | `AWS_CA_BUNDLE` valid (131 certs) | ✅ |
| 7 | STS authenticates | ✅ |
| 8 | Region `us-east-1` | ✅ |
| 9 | **Embedding model really invocable** | ✅ 1024 dims |
| 10 | **Foundation model really invocable** | ✅ Nova Lite |
| 11 | Evidence dirs, `.env` gitignored | ✅ |

**Target:**
```
GATE PASSED — ready for Part 2
```

---

## 1.5 — Fallback only: create the Knowledge Base in the console

**Skip unless check 4 still fails after upgrading.**

**Bedrock → Knowledge Bases → Create → Knowledge Base with vector store**

**Step 1 — Details**
- Name `northstar-assist-kb`
- IAM permissions → **Create and use a new service role** → ⚠️ **write down the role name** (`AmazonBedrockExecutionRoleForKnowledgeBase_xxxxx`); Task 4 needs it
- Data source type → **Amazon S3** → Next

**Step 2 — Data source**
- Name `northstar-corpus`
- S3 URI → **Browse S3** → select the **`corpus/` folder**, not the bucket root
- Chunking → **Default** (≈300 tokens, 20% overlap). Record whatever you choose: chunk size is an ML-BOM field and a real security knob — larger chunks pull more neighbouring records into model context, so one employee row can drag in twenty others → Next

**Step 3 — Embeddings + vector store**
- Embeddings model → **Titan Text Embeddings V2**, dimension **1024** (must match `EMBED_DIMENSION`)
- Vector database → **Quick create a new vector store** → **Amazon S3 Vectors**
- ❌ Not OpenSearch Serverless → Next

**Step 4 — Review and create.** Wait for **Available**.

**Then sync:** KB → **Data source** → select → **Sync** → wait for **COMPLETED** → open the job row and confirm **0 documents failed**. The rubric requires "sync completes without errors."

Record in `.env`:
```bash
BEDROCK_KB_ID=...
BEDROCK_DS_ID=...
KB_ROLE_NAME=AmazonBedrockExecutionRoleForKnowledgeBase_xxxxx
```

*Requires the S3 bucket first — run `./scripts/10_s3_bucket.sh`.*

---

## ⏸ Stop here

Run §1.1, then `./scripts/00_preflight.sh`. When it prints **`GATE PASSED`**, tell me and I'll start Part 2:

```
10_s3_bucket.sh  →  20_iam_baseline.sh  →  25_capture_before.sh  →  30_vector_store.sh
40_knowledge_base.sh  →  50_agent.sh  →  60_logging.sh  →  70_test_before.sh
80_iam_harden.sh  →  85_guardrail.sh  →  88_canary.sh  →  90_monitoring.sh
95_test_after.sh  →  97_verify_evidence.sh  →  99_teardown.sh
```

Tell me too if you used the §1.5 console fallback, or want a model other than Nova Lite.

---

## Remaining UI touchpoints after this gate

The complete list of manual steps in the entire project:

| When | Step | Why |
|---|---|---|
| Part 1 | Bedrock model access | no public API exists |
| Part 1 | AWS CLI upgrade | requires `sudo` |
| Phase 9 | Click the **SNS subscription confirmation email** | AWS requires human confirmation; an unconfirmed subscription silently notifies nobody |
| Conditional | KB creation (§1.5) | only if the CLI lacks `S3_VECTORS` |
| Optional | Console screenshots | the rubric accepts *"screenshot **or** test transcript"*, and the CLI test driver produces transcripts — so these are nice-to-have |

Everything else is scripted.
