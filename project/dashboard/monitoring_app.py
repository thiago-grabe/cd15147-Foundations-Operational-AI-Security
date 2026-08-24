#!/usr/bin/env python3
"""
Northstar Assist - Security Monitoring Dashboard

    uv run streamlit run dashboard/monitoring_app.py

Visualises the AI-specific signals defined in docs/06-monitoring-and-ir-playbook.md:
guardrail intervention rate, prompt-attack attempts, ungrounded responses, token
usage, and the before/after control-effectiveness comparison.

Reads CloudWatch metrics and logs live where credentials allow, and falls back to
the committed evidence files so the dashboard still renders after teardown - which
matters, because the AWS resources are deliberately destroyed at the end of the
project and the evidence is what survives.
"""
import datetime as dt
import json
import os
import pathlib

import boto3
import pandas as pd
import streamlit as st
from botocore.exceptions import BotoCoreError, ClientError
from dotenv import load_dotenv

ROOT = pathlib.Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")

REGION = os.environ.get("AWS_REGION", "us-east-1")
LOG_GROUP = os.environ.get("LOG_GROUP", "/aws/bedrock/northstar-assist")
GUARDRAIL_ID = os.environ.get("BEDROCK_GUARDRAIL_ID", "")
NS = "NorthstarAssist"

st.set_page_config(page_title="Northstar Assist · Security Monitoring",
                   page_icon="🛡️", layout="wide")


# --------------------------------------------------------------------------- #
# data access - live where possible, evidence files otherwise
# --------------------------------------------------------------------------- #
@st.cache_resource
def clients():
    try:
        return (boto3.client("cloudwatch", region_name=REGION),
                boto3.client("logs", region_name=REGION))
    except Exception:
        return None, None


@st.cache_data(ttl=120)
def metric_series(metric: str, hours: int):
    cw, _ = clients()
    if cw is None:
        return pd.DataFrame(), "no client"
    end = dt.datetime.now(dt.timezone.utc)
    try:
        r = cw.get_metric_statistics(
            Namespace=NS, MetricName=metric,
            StartTime=end - dt.timedelta(hours=hours), EndTime=end,
            Period=300, Statistics=["Sum"],
        )
    except (ClientError, BotoCoreError) as e:
        return pd.DataFrame(), f"live query failed: {type(e).__name__}"
    pts = sorted(r.get("Datapoints", []), key=lambda d: d["Timestamp"])
    if not pts:
        return pd.DataFrame(), "no datapoints yet"
    return pd.DataFrame({"time": [p["Timestamp"] for p in pts],
                         metric: [p["Sum"] for p in pts]}).set_index("time"), "live"


@st.cache_data(ttl=300)
def alarm_states():
    cw, _ = clients()
    rows = []
    if cw is not None:
        try:
            for a in cw.describe_alarms(AlarmNamePrefix="NorthstarAssist-")["MetricAlarms"]:
                rows.append({"Alarm": a["AlarmName"], "State": a["StateValue"],
                             "Metric": a.get("MetricName", ""), "Threshold": a.get("Threshold"),
                             "Source": "live"})
        except (ClientError, BotoCoreError):
            pass
    if not rows:
        f = ROOT / "monitoring" / "alarms" / "alarms.json"
        if f.exists():
            for a in json.loads(f.read_text()).get("MetricAlarms", []):
                rows.append({"Alarm": a["AlarmName"], "State": a["StateValue"],
                             "Metric": a.get("MetricName", ""), "Threshold": a.get("Threshold"),
                             "Source": "evidence"})
    return pd.DataFrame(rows)


@st.cache_data
def test_results():
    out = {}
    for phase in ("before", "after"):
        f = ROOT / "evidence" / f"results-{phase}.json"
        out[phase] = json.loads(f.read_text()) if f.exists() else []
    return out


# --------------------------------------------------------------------------- #
st.title("🛡️ Northstar Assist — Security Monitoring")
st.caption(f"Account {os.environ.get('AWS_ACCOUNT_ID', '—')} · {REGION} · "
           f"guardrail `{GUARDRAIL_ID or '—'}` · log group `{LOG_GROUP}`")

hours = st.sidebar.slider("Time window (hours)", 1, 72, 24)
st.sidebar.markdown("---")
st.sidebar.markdown(
    "**Signals** (docs/06 §2)\n\n"
    "- **S-1** guardrail interventions\n"
    "- **S-1a** prompt attacks\n"
    "- **S-2** ungrounded responses\n\n"
    "Falls back to committed evidence when AWS is unreachable — the resources are "
    "torn down at project end."
)

res = test_results()
before, after = res["before"], res["after"]

# --- control effectiveness -------------------------------------------------- #
st.header("Control effectiveness")
if before and after:
    b_leak = [r["id"] for r in before if r["leaked"]]
    a_leak = [r["id"] for r in after if r["leaked"]]
    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Tests passing (before)", f"{sum(1 for r in before if r['passed'])}/{len(before)}")
    c2.metric("Tests passing (after)", f"{sum(1 for r in after if r['passed'])}/{len(after)}",
              delta=sum(1 for r in after if r["passed"]) - sum(1 for r in before if r["passed"]))
    c3.metric("Leaking real data (before)", len(b_leak), delta=None)
    c4.metric("Leaking real data (after)", len(a_leak), delta=len(a_leak) - len(b_leak),
              delta_color="inverse")

    if b_leak and not a_leak:
        st.success(f"All {len(b_leak)} confirmed data leaks closed: {', '.join(b_leak)}")
    elif a_leak:
        st.error(f"STILL LEAKING after hardening: {', '.join(a_leak)} — "
                 f"launch recommendation must be BLOCK.")

    bm = {r["id"]: r for r in before}
    rows = []
    for r in sorted(after, key=lambda x: x["id"]):
        b = bm.get(r["id"], {})
        rows.append({
            "ID": r["id"], "OWASP": r["owasp"], "Category": r["category"],
            "Before": "LEAKED " + ", ".join(b.get("leaked", [])[:2]) if b.get("leaked")
                      else ("pass" if b.get("passed") else "no refusal"),
            "After": "blocked" if r["guardrail_intervened"] else ("pass" if r["passed"] else "FAIL"),
            "Closed": "✅" if b.get("leaked") and not r["leaked"] else "",
        })
    st.dataframe(pd.DataFrame(rows), use_container_width=True, hide_index=True)
else:
    st.info("Run `uv run python security-tests/run_tests.py --phase before|after` to populate.")

# --- live signals ----------------------------------------------------------- #
st.header("AI-specific signals")
cols = st.columns(3)
for col, (metric, label) in zip(cols, [
    ("GuardrailInterventions", "S-1 · Guardrail interventions"),
    ("PromptAttackInterventions", "S-1a · Prompt attacks"),
    ("UngroundedResponses", "S-2 · Ungrounded responses"),
]):
    with col:
        st.subheader(label)
        df, status = metric_series(metric, hours)
        if not df.empty:
            st.metric(f"Total ({hours}h)", int(df[metric].sum()))
            st.bar_chart(df, height=180)
        else:
            st.metric(f"Total ({hours}h)", 0)
            st.caption(f"_{status}_")

if GUARDRAIL_ID:
    st.caption(
        "**Reading these:** a rising S-1a is probing. A rising S-1 with flat S-1a may instead "
        "mean the guardrail is over-blocking legitimate work. A rising S-2 often means retrieval "
        "is broken — an over-tight IAM scope or a failed sync — while the assistant keeps "
        "answering, just without grounding."
    )

# --- alarms ----------------------------------------------------------------- #
st.header("Alarms")
al = alarm_states()
if not al.empty:
    def color(v):
        return {"ALARM": "background-color:#7f1d1d;color:white",
                "OK": "background-color:#14532d;color:white"}.get(v, "")
    st.dataframe(al.style.map(color, subset=["State"]),
                 use_container_width=True, hide_index=True)
    if (al["State"] == "INSUFFICIENT_DATA").all():
        st.info("All alarms read INSUFFICIENT_DATA until each metric first reports — expected "
                "on a freshly built system, not a fault.")
else:
    st.warning("No alarms found. Run `./scripts/90_monitoring.sh`.")

# --- residual risks --------------------------------------------------------- #
st.header("Residual risks at launch")
st.dataframe(pd.DataFrame([
    {"ID": "RR-1", "Severity": "HIGH",
     "Risk": "Excessive retrieval — one flat index, no per-user authorization"},
    {"ID": "RR-2", "Severity": "MEDIUM", "Risk": "Aggregation disclosure across a session"},
    {"ID": "RR-3", "Severity": "MEDIUM", "Risk": "Multi-turn evasion (single-turn classification)"},
    {"ID": "RR-4", "Severity": "MEDIUM", "Risk": "Indirect injection (prompt-attack is input-only)"},
    {"ID": "RR-5", "Severity": "MEDIUM", "Risk": "No per-user attribution (shared password)"},
    {"ID": "RR-6", "Severity": "MEDIUM", "Risk": "Findings are model-specific to Nova Lite"},
]), use_container_width=True, hide_index=True)

st.warning(
    "**Launch recommendation: APPROVE WITH CONDITIONS** — test environment only. "
    "Guardrails filter an over-broad retrieval surface rather than narrowing it; all 30 documents "
    "remain retrievable by any authenticated user. Production rollout is blocked on per-user "
    "retrieval authorization (condition C1). See `docs/07-launch-readiness-report.md`."
)
