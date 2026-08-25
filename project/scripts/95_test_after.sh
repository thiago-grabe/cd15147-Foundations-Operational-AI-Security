#!/usr/bin/env bash
# =============================================================================
# 95_test_after.sh - hardened run (Task 7, "after" half)
# Same 13 prompts, same harness, guardrail attached. The delta against
# evidence/results-before.json IS the control-effectiveness evidence.
# =============================================================================
. "$(dirname "$0")/lib.sh"
load_env; check_creds
require BEDROCK_GUARDRAIL_ID BEDROCK_GUARDRAIL_VERSION
step "Running the 13-prompt suite WITH guardrail ${BEDROCK_GUARDRAIL_ID}:${BEDROCK_GUARDRAIL_VERSION}"
uv run python security-tests/run_tests.py --phase after
