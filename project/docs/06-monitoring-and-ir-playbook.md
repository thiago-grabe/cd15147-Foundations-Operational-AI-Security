# 06 — Monitoring Plan and Incident Response Playbook (Task 6)

**Northstar Assist · Account 638018627275 · us-east-1**

---

## Rubric mapping

| Requirement | Where |
|---|---|
| Specific logs and metrics including ≥1 **AI-specific** signal | §2 — five AI-specific signals |
| ≥1 concrete alert condition with a defined threshold | §3 — three alarms, thresholds with reasoning |
| IR playbook with containment and investigation actions | §5 — seven phases, console paths and CLI |

---

# PART A — MONITORING PLAN

## 1. Log and metric sources

| # | Source | Location | Contains |
|---|---|---|---|
| 1 | **Bedrock model invocation logs** | `/aws/bedrock/northstar-assist` | Full prompt, full response, **guardrail trace**, token counts, `requestId` |
| 2 | Bedrock service metrics | `AWS/Bedrock` | `InvocationCount`, `InputTokenCount`, `OutputTokenCount`, latency, throttles |
| 3 | Derived metrics | `NorthstarAssist` | Three metric filters (§2) |
| 4 | CloudTrail | management + data events | IAM changes, guardrail edits, `PutObject` to the corpus |
| 5 | S3 object versions | corpus bucket | **When** a document changed and **to what** |
| 6 | Application logs | Streamlit host | Session start, auth failures |

Logging was enabled (`scripts/60_logging.sh`) **before any testing**. CloudWatch does not backfill — a prompt sent before that switch produces no evidence at all.

### 1.1 Guardrail trace location

Verified against a real event:

```
$.output.outputBodyJson.trace.guardrail.inputAssessment.<GUARDRAIL_ID>.topicPolicy.topics[].action
$.output.outputBodyJson.trace.guardrail.inputAssessment.<GUARDRAIL_ID>.invocationMetrics
```

> **The guardrail ID is a dynamic key in that path.** CloudWatch JSON patterns (`$.a.b.c`) cannot wildcard a key, so the metric filters below use **term matching** instead. This is deliberate, and it survives a guardrail ID change.

---

## 2. Signals

Standard infrastructure metrics (latency, error rate) are necessary but blind to the actual risks. These five are AI-specific.

| ID | Signal | Detects | Implemented |
|---|---|---|---|
| **S-1** | Guardrail interventions (all types) | Active probing; or over-blocking harming legitimate use | ✅ `GuardrailInterventions` |
| **S-1a** | Prompt-attack interventions | Deliberate injection attempts (E-1) | ✅ `PromptAttackInterventions` |
| **S-2** | Ungrounded responses | Hallucination risk **and silent retrieval failure** | ✅ `UngroundedResponses` |
| **S-3** | Output-token outliers vs. session mean | Bulk-extraction / dump attempts (D-1) | ⬚ recommended |
| **S-4** | Per-session query velocity + topic drift | Enumeration; **multi-turn escalation (MT-1)** | ⬚ recommended |
| **S-5** | Near-duplicate query clustering | Embedding-space probing; systematic rephrasing to evade topics | ⬚ recommended |

### Why S-2 matters more than it looks

A sudden rise in ungrounded answers has two very different causes, and both need a human:
1. **Retrieval is broken** — an over-tight IAM scope, a failed sync, or a deleted index. The assistant keeps answering, just without grounding. Users may not notice, because a fluent wrong answer looks like a right one.
2. **Someone is probing** for topics outside the corpus to induce fabrication.

This signal is the earliest warning of silent RAG failure. Note that during this build, an ingestion job reported `0 failed` while two documents were missing from the index — exactly the kind of silent degradation S-2 is meant to surface in production.

### Implemented metric filters

Patterns were **derived from 37 real log events**, not guessed:

```
PROMPT_ATTACK        3/37 events
"action":"BLOCKED"  12/37 events
GROUNDING            6/37 events
action values seen: BLOCKED (13), NONE (11)
```

| Filter | Pattern | Metric |
|---|---|---|
| `GuardrailInterventions` | `"BLOCKED"` | `NorthstarAssist/GuardrailInterventions` |
| `PromptAttackInterventions` | `"PROMPT_ATTACK"` | `NorthstarAssist/PromptAttackInterventions` |
| `UngroundedResponses` | `"GROUNDING"` | `NorthstarAssist/UngroundedResponses` |

> **A note on S-2's implementation.** The original intent was to count literal zero-chunk retrievals via `"retrievedReferences":[]`. CloudWatch rejects `[` in a filter term (`Invalid character(s) in term '['`), so a bracketed JSON fragment cannot be matched. The contextual-grounding assessment measures the same underlying condition — an answer unsupported by retrieved context — and was verified present in the logs. The substitution is recorded rather than silently made.

---

## 3. Alert conditions

All three: `Sum`, 1-hour period, 1 of 1 datapoints, `treatMissingData = notBreaching`, notifying `arn:aws:sns:us-east-1:638018627275:northstar-ai-security-alerts`.

`notBreaching` is deliberate — missing data means "no attacks were logged", not "the alarm should fire".

### Alarm 1 — `NorthstarAssist-PromptAttackSpike` *(primary)*

> **Fire when `PromptAttackInterventions` ≥ 5 within 1 hour.**

**Threshold reasoning.** A legitimate employee might trip prompt-attack detection once or twice by accident — quoting a suspicious email, pasting text containing "ignore previous instructions". Five in an hour is not accident-shaped; it is someone iterating on phrasings. Set low enough to catch a deliberate campaign early, high enough that honest users never page an on-call analyst. Baseline traffic produced 3 interventions across the entire 13-prompt suite, so 5/hour sits comfortably above normal use.

### Alarm 2 — `NorthstarAssist-GuardrailInterventionSpike`

> **Fire when `GuardrailInterventions` ≥ 20 within 1 hour.**

Catches both an attack campaign **and** the opposite failure: an over-tightened guardrail blocking legitimate work. Higher threshold because ordinary users do occasionally ask about colleagues' contact details.

### Alarm 3 — `NorthstarAssist-UngroundedResponseSpike`

> **Fire when `UngroundedResponses` ≥ 10 within 1 hour.**

Early warning for broken retrieval or hallucination probing.

### Recommended additions

| Alarm | Condition |
|---|---|
| Cost / token ceiling | `AWS/Bedrock OutputTokenCount` > 3σ above 7-day mean |
| Corpus write | Any CloudTrail `PutObject` to `corpus/` outside the publishing role — **immediate**, as this is the T-2 poisoning path |
| Guardrail modification | Any `UpdateGuardrail` / `DeleteGuardrail` — **immediate** |

> ⚠️ **Confirm the SNS email subscription.** An unconfirmed subscription notifies nobody while the alarm still shows healthy. Verify:
> ```bash
> aws sns list-subscriptions-by-topic --topic-arn "$SNS_TOPIC_ARN" \
>   --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output table
> ```
> A `SubscriptionArn` of `PendingConfirmation` means alerts go nowhere.

---

## 4. Dashboard and review cadence

| Cadence | Activity |
|---|---|
| Real-time | Three alarms → SNS → on-call |
| Daily | Intervention counts by type; any new denied-topic category trending |
| Weekly | Top intervention-triggering sessions; ungrounded-response rate |
| On change | **Re-run the 13-prompt suite** after any guardrail, corpus or model change — results are model-specific |
| Quarterly | Threat-model review; alarm-threshold tuning |

---

# PART B — INCIDENT RESPONSE PLAYBOOK

## Suspected prompt injection or data-exfiltration attempt

**Audience:** on-call analyst with **no prior AI incident experience**. Follow in order. Every step gives a literal command or console path.

**Setup for all CLI steps:**
```bash
cd /path/to/project && set -a && source .env && set +a
```

---

### Phase 1 — Detect (0–5 min)

Trigger: SNS alert from any alarm in §3, or a user report.

**Confirm it is real, not a metric-filter artifact.**

```bash
aws cloudwatch describe-alarms --alarm-name-prefix NorthstarAssist- \
  --query 'MetricAlarms[].{Alarm:AlarmName,State:StateValue,Updated:StateUpdatedTimestamp}' --output table

aws logs filter-log-events --log-group-name /aws/bedrock/northstar-assist \
  --start-time $(( ($(date +%s) - 3600) * 1000 )) \
  --filter-pattern '"PROMPT_ATTACK"' --max-items 20
```

Console: **CloudWatch → Alarms → NorthstarAssist-PromptAttackSpike → History**

---

### Phase 2 — Triage (5–15 min)

| Severity | Criteria | Response |
|---|---|---|
| **SEV-1** | Confidential data confirmed in a response (emails, instance IDs, customer financials) | Page security lead. Containment **now** |
| **SEV-2** | Repeated attack attempts, all blocked | Contain within 1 hour |
| **SEV-3** | Isolated attempts, blocked | Monitor; review next business day |

**Did anything actually leak?** This is the decisive question — the guardrail blocking a request is a *non-event*.

```bash
# real corpus values in any response in the last hour
aws logs filter-log-events --log-group-name /aws/bedrock/northstar-assist \
  --start-time $(( ($(date +%s) - 3600) * 1000 )) \
  --filter-pattern '"@northstartech.com"' --max-items 20
```

Repeat with `"i-0"` (instance IDs) and `"CUST"` (customer IDs).
**Hits → SEV-1.** No hits → controls held; SEV-2 or SEV-3.

---

### Phase 3 — Contain

Choose the **lowest** rung that addresses the incident. Escalate only if it does not.

| Rung | Action | User impact |
|---|---|---|
| **C1** | Tighten the guardrail — add a denied topic or raise a threshold | None |
| **C2** | Rotate `APP_PASSWORD`; invalidate sessions | Users re-authenticate |
| **C3** | Roll the guardrail back to a known-good version | None |
| **C4** | Detach the knowledge base | Retrieval offline; model still answers |
| **C5** | Disable the endpoint | **Full outage** |
| **C6** | Quarantine a poisoned document (S3 version rollback) | KB re-sync needed |

**C1 — tighten the guardrail** *(most incidents end here)*
```bash
# add a topic / raise a threshold, then publish an immutable version
aws bedrock update-guardrail --guardrail-identifier "$BEDROCK_GUARDRAIL_ID" ...
aws bedrock create-guardrail-version --guardrail-identifier "$BEDROCK_GUARDRAIL_ID" \
  --description "IR-<ticket>: tightened after incident"
# point the application at the new version
```
Console: **Bedrock → Guardrails → northstar-assist-guardrail → Edit → Create version**

**C2 — rotate the shared secret**
```bash
# edit APP_PASSWORD in .env, then restart the Streamlit service
```

**C3 — roll back**
```bash
aws bedrock list-guardrails --query 'guardrails[?name==`northstar-assist-guardrail`]'
# set BEDROCK_GUARDRAIL_VERSION to the last known-good version and redeploy
```

**C4 — detach the knowledge base** *(suspected corpus poisoning)*
Stop the application, or remove the KB from `config/rag-config.json`. Retrieval stops; no corpus content can reach the model.

**C5 — full stop**
```bash
aws iam delete-role-policy --role-name "$AGENT_ROLE_NAME" --policy-name NorthstarAgentPolicy
```
Revokes the application's permission to call Bedrock at all. **Causes a full outage — security-lead approval required.**

**C6 — quarantine a poisoned document**
```bash
aws s3api list-object-versions --bucket "$KB_S3_BUCKET" --prefix corpus/<path>
aws s3api get-object --bucket "$KB_S3_BUCKET" --key corpus/<path> \
  --version-id <PREVIOUS_CLEAN_VERSION> ./restored.file
aws s3 cp ./restored.file "s3://$KB_S3_BUCKET/corpus/<path>"
aws bedrock-agent start-ingestion-job --knowledge-base-id "$BEDROCK_KB_ID" \
  --data-source-id "$BEDROCK_DS_ID"
```
> Bucket versioning (enabled in `10_s3_bucket.sh`) is what makes C6 possible. Without it, the clean version is unrecoverable.

---

### Phase 4 — Investigate

**4.1 Who?** *(Limitation, state it in the ticket: with a shared password there is no per-user identity — threat S-1/R-1. Attribution stops at session.)*
```bash
aws logs filter-log-events --log-group-name /aws/bedrock/northstar-assist \
  --start-time <MS> --filter-pattern '"<requestId>"'
```

**4.2 What was asked, across the whole session?** Multi-turn escalation (MT-1) is invisible turn-by-turn — read the **sequence**.

**4.3 Was a document tampered with?**
```bash
aws s3api list-object-versions --bucket "$KB_S3_BUCKET" --prefix corpus/ \
  --query 'Versions[?IsLatest==`true`].[Key,LastModified,VersionId]' --output table
```
Any `LastModified` newer than the last approved publication is suspect.

**4.4 Who changed it?**
```bash
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=PutObject \
  --start-time <ISO8601> --query 'Events[].{Time:EventTime,User:Username,Res:Resources[0].ResourceName}'
```

**4.5 Were the controls themselves altered?**
```bash
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=UpdateGuardrail
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=PutRolePolicy
```

---

### Phase 5 — Eradicate

1. If a document was poisoned → C6, then re-sync and confirm the injected content is gone from the index.
2. If a phrasing bypassed the guardrail → add it as a denied-topic example, publish a new version.
3. **Add the successful attack to `security-tests/prompts.jsonl` as a permanent regression test.** Every real incident should make the suite stronger.

---

### Phase 6 — Recover

```bash
# 1. controls active
aws bedrock get-guardrail --guardrail-identifier "$BEDROCK_GUARDRAIL_ID" \
  --guardrail-version "$BEDROCK_GUARDRAIL_VERSION" --query 'status'

# 2. corpus intact (must print 30/30)
./scripts/40_knowledge_base.sh

# 3. full regression - must be 13/13
uv run python security-tests/run_tests.py --phase after
```
Restore service only when all three pass.

---

### Phase 7 — Post-incident

Within five business days: timeline; what the attacker obtained (**or confirmed did not obtain**); which control succeeded or failed and why; whether detection was fast enough; permanent regression test added; threshold tuning; whether the incident strengthens the case for per-user retrieval authorization (**RR-1**).

---

## 6. Known monitoring gaps

| Gap | Consequence |
|---|---|
| **No per-user attribution** | Investigation stops at session ID. The single biggest limitation of this playbook. |
| No session-level anomaly detection | MT-1 multi-turn escalation is invisible to per-turn alarms |
| Term-based metric filters | Slightly coarser than JSON-path matching, forced by the dynamic guardrail-ID key |
| Logs contain sensitive data | The log group holds exactly what guardrails block from users (threat I-4); restrict read access |
| Alarms not yet exercised in anger | All three read `INSUFFICIENT_DATA` until first data. Demonstrate with `aws cloudwatch set-alarm-state` |

---

**Artifacts:** `monitoring/metric-filters/filters.json` · `monitoring/alarms/alarms.json` · `evidence/logs/invocation-logging-config.json` · `evidence/logs/sample-invocation-event.json`
**Script:** `60_logging.sh` · `90_monitoring.sh`
