#!/usr/bin/env bash
# =============================================================================
# 00_preflight.sh - Part 1 gate verifier
#
# Read-only apart from `uv sync`. Safe to re-run at any time.
# Every check runs even if an earlier one fails, so you get the full picture
# in one pass instead of fixing issues one at a time.
#
#   ./scripts/00_preflight.sh
# =============================================================================

cd "$(dirname "$0")/.." || exit 1
PROJECT_DIR="$PWD"

PASS=0; FAIL=0; WARN=0
ok ()   { printf '  \033[32m✅ PASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
no ()   { printf '  \033[31m❌ FAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && printf '           ↳ %s\n' "$2"; FAIL=$((FAIL+1)); }
warn () { printf '  \033[33m⚠️  WARN\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && printf '           ↳ %s\n' "$2"; WARN=$((WARN+1)); }
hdr ()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

printf '\033[1m═══ Northstar Assist · Part 1 preflight ═══\033[0m\n'

# ---------------------------------------------------------------------------
hdr "1. Python toolchain (uv)"
# ---------------------------------------------------------------------------
if command -v uv >/dev/null 2>&1; then
  ok "uv present ($(uv --version))"
  if [ -f pyproject.toml ]; then
    if uv sync --quiet 2>/tmp/uvsync.err; then
      ok "uv sync succeeded (.venv populated)"
      uv run python -c "import boto3, docx, dotenv" 2>/dev/null \
        && ok "boto3 / python-docx / dotenv importable" \
        || no "dependency import failed" "run: uv sync"
    else
      no "uv sync failed" "$(head -2 /tmp/uvsync.err)"
    fi
  else
    no "pyproject.toml missing"
  fi
else
  no "uv not found" "install: curl -LsSf https://astral.sh/uv/install.sh | sh"
fi

# ---------------------------------------------------------------------------
hdr "2. AWS CLI capabilities  (docs/00-UI-PREREQUISITES.md §1.1)"
# ---------------------------------------------------------------------------
if command -v aws >/dev/null 2>&1; then
  CLI_VER=$(aws --version 2>&1 | sed -E 's|aws-cli/([0-9.]+).*|\1|')
  CLI_MAJOR=$(echo "$CLI_VER" | cut -d. -f1); CLI_MINOR=$(echo "$CLI_VER" | cut -d. -f2)
  if [ "$CLI_MAJOR" -ge 2 ] && [ "$CLI_MINOR" -ge 28 ]; then
    ok "aws-cli $CLI_VER (>= 2.28)"
  else
    no "aws-cli $CLI_VER is too old (need >= 2.28 for S3 Vectors)" \
       "see §1.1 - curl the AWSCLIV2.pkg installer, then: hash -r"
  fi

  aws s3vectors help              >/dev/null 2>&1 && ok "s3vectors service available"          || no "s3vectors service MISSING"           "§1.1 CLI upgrade required"
  aws s3vectors create-index help >/dev/null 2>&1 && ok "s3vectors create-index available"     || no "s3vectors create-index MISSING"      "§1.1 CLI upgrade required"
  aws bedrock-agent create-knowledge-base help 2>/dev/null | grep -q S3_VECTORS \
      && ok "S3_VECTORS storage type supported" \
      || no "S3_VECTORS storage type MISSING" "§1.1 upgrade, or use the §1.5 console fallback"
  aws bedrock-agent create-agent help >/dev/null 2>&1 && ok "bedrock-agent create-agent available" || no "bedrock-agent create-agent MISSING"
else
  no "aws CLI not found"
fi

# ---------------------------------------------------------------------------
hdr "3. Credentials  (§1.2)"
# ---------------------------------------------------------------------------
if [ -f .env ]; then
  ok ".env present"
  set -a; . ./.env; set +a

  [ -n "${AWS_ACCESS_KEY_ID:-}" ]     && ok "AWS_ACCESS_KEY_ID set"     || no "AWS_ACCESS_KEY_ID empty"
  [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] && ok "AWS_SECRET_ACCESS_KEY set" || no "AWS_SECRET_ACCESS_KEY empty"
  case "${AWS_ACCESS_KEY_ID:-}" in
    ASIA*) [ -n "${AWS_SESSION_TOKEN:-}" ] \
             && ok "AWS_SESSION_TOKEN set (required for ASIA temporary keys)" \
             || no "AWS_SESSION_TOKEN empty but key is ASIA* (temporary)" "temporary creds need all three values" ;;
    AKIA*) ok "permanent IAM user key (no session token needed)" ;;
  esac

  # TLS-inspection proxies (Zscaler et al.) break Bedrock endpoints without this
  if [ -n "${AWS_CA_BUNDLE:-}" ]; then
    [ -f "$AWS_CA_BUNDLE" ] && ok "AWS_CA_BUNDLE present ($(grep -c 'BEGIN CERTIFICATE' "$AWS_CA_BUNDLE") certs)" \
                            || no "AWS_CA_BUNDLE points at a missing file" "$AWS_CA_BUNDLE"
  fi

  IDENT=$(aws sts get-caller-identity --output json 2>&1)
  if echo "$IDENT" | grep -q '"Account"'; then
    ACCT=$(echo "$IDENT" | python3 -c "import sys,json;print(json.load(sys.stdin)['Account'])" 2>/dev/null)
    ok "STS authenticated - account $ACCT"
    echo "$IDENT" | grep -q 'voclabs' && warn "AWS Academy lab account" "credentials expire in hours; refresh .env when calls start failing"
  else
    ERR=$(echo "$IDENT" | grep -oE 'InvalidClientTokenId|ExpiredToken|SignatureDoesNotMatch|CERTIFICATE_VERIFY_FAILED' | head -1)
    case "$ERR" in
      CERTIFICATE_VERIFY_FAILED) no "TLS verification failed" "corporate proxy - see §1.0, set AWS_CA_BUNDLE" ;;
      InvalidClientTokenId|ExpiredToken) no "STS rejected credentials ($ERR)" "refresh credentials from the lab portal" ;;
      *) no "STS call failed" "$(echo "$IDENT" | head -1)" ;;
    esac
  fi

  REG="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
  [ "$REG" = "us-east-1" ] && ok "region us-east-1" || no "region is '$REG', expected us-east-1"
else
  no ".env missing" "cp .env.template .env  then fill in credentials"
fi

# ---------------------------------------------------------------------------
hdr "4. Model access  (§1.3)  - real invocations, not just listings"
# ---------------------------------------------------------------------------
# list-foundation-models returns every model in the region regardless of access,
# so it cannot verify a grant. A tiny real call is the only definitive test.
if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then

  EMB=$(aws bedrock-runtime invoke-model --region us-east-1 \
        --model-id "${EMBED_MODEL_ID:-amazon.titan-embed-text-v2:0}" \
        --body '{"inputText":"ping"}' --cli-binary-format raw-in-base64-out \
        /tmp/nsa-embed.json 2>&1)
  if [ -f /tmp/nsa-embed.json ] && python3 -c "import json,sys;d=json.load(open('/tmp/nsa-embed.json'));sys.exit(0 if d.get('embedding') else 1)" 2>/dev/null; then
    DIMS=$(python3 -c "import json;print(len(json.load(open('/tmp/nsa-embed.json'))['embedding']))")
    ok "embedding model invocable - ${EMBED_MODEL_ID:-titan-v2} (${DIMS} dims)"
    [ "$DIMS" = "${EMBED_DIMENSION:-1024}" ] || warn "dimension $DIMS != EMBED_DIMENSION=${EMBED_DIMENSION:-1024}" "vector index must match"
    rm -f /tmp/nsa-embed.json
  else
    no "embedding model NOT invocable" "$(echo "$EMB" | grep -oE 'AccessDenied[A-Za-z]*|ResourceNotFound[A-Za-z]*' | head -1) - grant access in console §1.3"
  fi

  FM=$(aws bedrock-runtime converse --region us-east-1 \
       --model-id "${FM_MODEL_ID:-amazon.nova-lite-v1:0}" \
       --messages '[{"role":"user","content":[{"text":"Reply with the single word: ok"}]}]' \
       --inference-config '{"maxTokens":10}' 2>&1)
  if echo "$FM" | grep -q '"text"'; then
    ok "foundation model invocable - ${FM_MODEL_ID:-amazon.nova-lite-v1:0}"
  else
    no "foundation model NOT invocable - ${FM_MODEL_ID:-}" \
       "$(echo "$FM" | grep -oE 'AccessDenied[A-Za-z]*|ResourceNotFound[A-Za-z]*|Validation[A-Za-z]*' | head -1) - grant access in console §1.3"
  fi
else
  warn "skipped model checks" "credentials not loaded"
fi

# ---------------------------------------------------------------------------
hdr "5. Evidence scaffolding"
# ---------------------------------------------------------------------------
for d in docs scripts evidence/screenshots evidence/logs evidence/transcripts iam/before iam/after; do
  [ -d "$d" ] || mkdir -p "$d"
done
ok "evidence/ + iam/ directories present"
[ -f evidence/screenshots/00-model-access.png ] \
  && ok "model-access screenshot captured" \
  || warn "evidence/screenshots/00-model-access.png not captured yet" "§1.3 - not reproducible after teardown"

git check-ignore .env >/dev/null 2>&1 && ok ".env is gitignored" || no ".env is NOT gitignored" "do not commit"

# ---------------------------------------------------------------------------
printf '\n\033[1m═══ Result ═══\033[0m\n'
printf '  passed %d   failed %d   warnings %d\n\n' "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m\033[1m  GATE PASSED — ready for Part 2\033[0m\n\n'
  exit 0
else
  printf '\033[31m\033[1m  GATE BLOCKED — resolve the %d failure(s) above\033[0m\n' "$FAIL"
  printf '  Reference: docs/00-UI-PREREQUISITES.md\n\n'
  exit 1
fi
