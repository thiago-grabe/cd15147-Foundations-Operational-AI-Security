#!/usr/bin/env bash
# =============================================================================
# lib.sh - shared helpers for the Northstar Assist build scripts
#
# Sourced by every 1x-9x script. Provides:
#   - strict mode + project-root cwd
#   - .env loading and write-back (so scripts hand IDs to each other)
#   - consistent logging
#   - idempotency helpers
#
# Secrets are never echoed. env_set() masks credential-shaped values.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

ENV_FILE="$PROJECT_DIR/.env"

# --- logging ----------------------------------------------------------------
_c()   { printf '\033[%sm%s\033[0m' "$1" "$2"; }
step() { printf '\n%s %s\n' "$(_c '1;36' '▶')" "$(_c 1 "$*")"; }
ok()   { printf '  %s %s\n' "$(_c 32 '✅')" "$*"; }
info() { printf '  %s %s\n' "$(_c 34 'ℹ')"  "$*"; }
warn() { printf '  %s %s\n' "$(_c 33 '⚠')"  "$*"; }
die()  { printf '  %s %s\n' "$(_c 31 '✖')"  "$*" >&2; exit 1; }
skip() { printf '  %s %s\n' "$(_c 90 '·')"  "$* (already exists, skipping)"; }

# --- env --------------------------------------------------------------------
load_env() {
  [ -f "$ENV_FILE" ] || die ".env not found - see docs/00-UI-PREREQUISITES.md §1.2"
  set -a; . "$ENV_FILE"; set +a
  : "${AWS_REGION:=us-east-1}"
  export AWS_REGION AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$AWS_REGION}"
}

# env_set KEY VALUE - persist a discovered ID back into .env, in place.
# Later scripts read it with no manual copy-paste.
env_set() {
  local key="$1" val="$2"
  python3 - "$ENV_FILE" "$key" "$val" <<'PY'
import pathlib, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path); lines = p.read_text().splitlines()
out, seen = [], False
for ln in lines:
    k = ln.split("=", 1)[0].strip() if "=" in ln and not ln.lstrip().startswith("#") else None
    if k == key:
        out.append(f"{key}={val}"); seen = True
    else:
        out.append(ln)
if not seen:
    out.append(f"{key}={val}")
p.write_text("\n".join(out) + "\n")
PY
  export "$key=$val"
  case "$key" in
    *SECRET*|*TOKEN*|*PASSWORD*|*ACCESS_KEY_ID*) info "$key = ${val:0:6}…(masked)" ;;
    *) info "$key = $val" ;;
  esac
}

require() {
  for v in "$@"; do
    [ -n "${!v:-}" ] || die "\$$v is empty - run the earlier scripts first"
  done
}

# --- credential freshness ---------------------------------------------------
# Lab creds expire in 1-12h. Fail with a useful message rather than a raw
# AWS error 40 lines into a build.
check_creds() {
  local out
  if ! out=$(aws sts get-caller-identity --output json 2>&1); then
    case "$out" in
      *InvalidClientTokenId*|*ExpiredToken*)
        die "AWS credentials expired. Refresh all three values in .env from the lab portal, then re-run." ;;
      *CERTIFICATE_VERIFY_FAILED*)
        die "TLS verification failed - check AWS_CA_BUNDLE in .env (see docs/00-UI-PREREQUISITES.md §1.0)" ;;
      *) die "STS call failed: $(printf '%s' "$out" | head -1)" ;;
    esac
  fi
  local acct; acct=$(printf '%s' "$out" | python3 -c "import sys,json;print(json.load(sys.stdin)['Account'])")
  [ "${AWS_ACCOUNT_ID:-}" = "$acct" ] || env_set AWS_ACCOUNT_ID "$acct"
}

# --- misc -------------------------------------------------------------------
jqp() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval('d'+sys.argv[1]))" "$1" 2>/dev/null || true; }

# Poll until a command's output matches, or time out.
#   wait_for <seconds> <label> <cmd...>
wait_for() {
  local timeout="$1" label="$2"; shift 2
  local waited=0 interval=10
  while [ "$waited" -lt "$timeout" ]; do
    if "$@" >/dev/null 2>&1; then ok "$label"; return 0; fi
    sleep "$interval"; waited=$((waited + interval))
    printf '  … waiting for %s (%ds)\n' "$label" "$waited"
  done
  die "timed out after ${timeout}s waiting for $label"
}
