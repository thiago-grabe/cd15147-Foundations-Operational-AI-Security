# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Source-of-truth repo for the Udacity course **cd15147 — Foundations of Operational AI Security**. It is course *authoring* material, not a product. Two unrelated halves live here:

1. `module-1-name/` … `module-8-name/` — **empty scaffolding** for per-module exercises. Only `module-1-name/.../INSTRUCTIONS.md` has the boilerplate template text; modules 2–8 have zero-byte `INSTRUCTIONS.md` files, and every `solution/` holds only a `.gitkeep`. No exercises have been written yet.
2. `project/` — the **course capstone**, which is where all real content currently lives.

Because this is learner-facing content, treat the fictional company ("Northstar Technologies") and all names/emails/accounts in the knowledge base as intentional fabrications. Do not replace them with real brands or people.

## The Capstone: Northstar Assist

An intentionally over-permissive RAG system that learners must threat-model. Understanding this intent matters: the "vulnerabilities" are the curriculum, not bugs to fix.

```
Browser → Streamlit (app.py) → bedrock-agent-runtime.invoke_agent()
                                    → Bedrock Agent → Bedrock Knowledge Base → Claude
```

- `project/streamlit_app/app.py` — the entire application, ~120 lines, single file. Password gate via `APP_PASSWORD` (plaintext compare, `st.session_state.authenticated`), a `@st.cache_resource` boto3 client, a per-browser-session `uuid4` passed as Bedrock `sessionId`, and manual assembly of the streaming response by concatenating `event["chunk"]["bytes"].decode()`.
- `project/northstar-knowledge-base/` — 30 documents, 5 each across `csv/ docx/ html/ pdf/ txt/ xlsx/`. This is the corpus a learner uploads to S3 and indexes into a Bedrock Knowledge Base.
- **The corpus is deliberately seeded with material that should never be uniformly retrievable**: `employee_directory.csv` (names, emails, manager chain, extensions), `customer_accounts.csv` (revenue, contacts, contract dates), `sales_pipeline.csv`, `support_tickets.csv`, and `aws_infrastructure_inventory.csv` (instance IDs, regions, cost, owners). Combined with a single unsegmented KB and no per-user authorization, this is the core information-disclosure finding the exercise is built around.
- `project/STRIDE-ML Template.docx` and `project/ML-BOM Template.docx` — the two deliverable templates (STRIDE extended with ML threats such as data poisoning and adversarial examples; CycloneDX-style ML Bill of Materials). Learner submissions are filled-in copies of these.

**This repo provisions no AWS infrastructure.** There is no IaC, no CDK, no Terraform. The S3 bucket, Knowledge Base, and Bedrock Agent are created by hand in the AWS console; the app only consumes an already-existing `BEDROCK_AGENT_ID`. Don't go looking for the resource definitions — they aren't here.

## Running the App

```bash
cd project/streamlit_app
pip install -r requirements.txt     # streamlit, boto3, python-dotenv
cp .env.example .env                # then fill in BEDROCK_AGENT_ID
streamlit run app.py                # http://localhost:8501
```

There is no test suite, linter config, formatter config, CI, or dependency lockfile anywhere in the repo. Don't invent `pytest`/`ruff` invocations — verification is manual (run the app, ask it a question). Note this repo does **not** use `uv`, unlike most siblings in the parent workspace.

Config is read from env vars at import time in `app.py`. `AGENT_ALIAS_ID` defaults to `TSTALIASID`, which is Bedrock's draft/test alias — fine for labs, wrong for anything published. Leaving `APP_PASSWORD` empty disables auth entirely by design.

## Conventions

**Credentials.** Root `.gitignore` is deliberately aggressive (`.env`, `credentials`, `.aws/`, `*.pem`, `*.key`, `.streamlit/secrets.toml`) because learners fork this repo while holding temporary AWS credentials. `.env.example` is tracked on purpose; `.env` never is. boto3 resolves credentials normally (env → `~/.aws/credentials` → IAM role) — prefer an instance role over keys in any example you write.

**Exercise folder naming** (from `README.md`): rename `module-#-name/` and `exercise-name-starter/` to descriptive names as content is authored, e.g. `ai-agents/fact-checker-agent-starter`. Never number the exercises — modules are reused across programs in different orders. Remove a `solution/.gitkeep` once real solution files land there.

**Office temp files.** The `~$*.docx` / `~$*.xlsx` ignore patterns exist because this repo ships templates and corpus documents in Office formats that are opened constantly during authoring.

## Known Stale References

`README.md` links to an `Exercise Creation Resources/` folder (exercise guidance, WCAG 2.1 AA accessibility standards, real-world-content and third-party-licensing rules). That folder was **deleted** in commit `8a4d4ef`, so every one of those links is dead. It also still carries the "remove these instructions before sharing with learners" banner. Flag this rather than fabricating the missing guidance.
