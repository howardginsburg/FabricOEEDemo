#!/usr/bin/env bash
# =============================================================================
# 5-setup-activator-alerts.sh — Scripted Fabric Activator (Reflex) deploy
#
# Creates/updates the "Floor Ops Alerts" Activator in the OEE demo workspace and
# wires a real-time outage rule:
#
#   Eventstream (manufacturing-telemetry)
#     -> object "Device" keyed by device_id
#        -> rule: machine_status BECOMES "Fault"  (one alert per Running->Fault)
#           -> action: email the ops recipient with device/line/station context
#
# The rule definition lives in scripts/activator/ReflexEntities.template.json.
# This script resolves the live workspace + eventstream ids, resumes the
# eventstream (its Eventhouse destinations can be left Paused, which silently
# blocks ingestion), creates the Reflex item if needed, substitutes the template
# placeholders, and pushes it via the item updateDefinition API. Idempotent.
#
# Prerequisites:
#   - Azure CLI (az) 2.x, logged in (run 'az login' first)
#   - jq, base64
#   - The core OEE foundation from scripts/1-setup-fabric.sh (Eventstream exists)
#
# Usage:
#   bash scripts/5-setup-activator-alerts.sh --workspace-name <NAME>
#   bash scripts/5-setup-activator-alerts.sh --workspace-name <NAME> \
#        --alert-email ops@contoso.com
#   bash scripts/5-setup-activator-alerts.sh --workspace-name <NAME> --use-device-code
# =============================================================================
set -euo pipefail

FABRIC_API="https://api.fabric.microsoft.com/v1"
FABRIC_RESOURCE="https://api.fabric.microsoft.com"
WORKSPACE_NAME=""
ALERT_EMAIL=""
EVENTSTREAM_NAME="manufacturing-telemetry"
ACTIVATOR_NAME="Floor Ops Alerts"
USE_DEVICE_CODE=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/activator/ReflexEntities.template.json"

# ── Colours ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  GREEN='\033[92m'; YELLOW='\033[93m'; RED='\033[91m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; RESET=''
fi
ok()   { printf "   ${GREEN}\xE2\x9C\x93${RESET} %s\n" "$*"; }
warn() { printf "   ${YELLOW}!${RESET} %s\n" "$*"; }
die()  { printf "   ${RED}\xE2\x9C\x97 ERROR:${RESET} %s\n" "$*" >&2; exit 1; }
step() { printf "\n\xE2\x94\x80\xE2\x94\x80 %s\n" "$*"; }

# ── Args ──────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --workspace-name)   WORKSPACE_NAME="$2"; shift 2 ;;
    --alert-email)      ALERT_EMAIL="$2"; shift 2 ;;
    --eventstream-name) EVENTSTREAM_NAME="$2"; shift 2 ;;
    --activator-name)   ACTIVATOR_NAME="$2"; shift 2 ;;
    --use-device-code)  USE_DEVICE_CODE=true; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ -z "$WORKSPACE_NAME" ]] && die "Usage: $0 --workspace-name <NAME> [--alert-email <ADDR>]"
[[ -f "$TEMPLATE" ]] || die "Rule template not found: $TEMPLATE"

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in az jq base64; do
  command -v "$cmd" &>/dev/null || die "'$cmd' is required but not installed."
done

# ── Windows/native az path handling (bash calling Windows az needs @winpath) ──
_AZ_BIN="$(command -v az)"
if [[ "$_AZ_BIN" == /mnt/* ]] || [[ "$_AZ_BIN" == *.exe ]]; then
  _AZ_IS_WINDOWS=true
  _WIN_TEMP="/mnt/c/Users/${USER}/AppData/Local/Temp"
  mkdir -p "$_WIN_TEMP" 2>/dev/null || _WIN_TEMP="/mnt/c/Windows/Temp"
else
  _AZ_IS_WINDOWS=false
  _WIN_TEMP="${TMPDIR:-/tmp}"
fi
_win_tmpfile() { local f; f=$(mktemp "${_WIN_TEMP}/reflex.XXXXXX.json"); printf '%s' "$1" > "$f"; echo "$f"; }
_winpath() { if [[ "$_AZ_IS_WINDOWS" == true ]]; then wslpath -w "$1" 2>/dev/null || echo "$1"; else echo "$1"; fi; }

fabric_get() {
  az rest --method GET --uri "${FABRIC_API}/$1" --resource "$FABRIC_RESOURCE" --output json 2>/dev/null
}
# POST a JSON body; echoes response body (or '{}'); returns az exit code.
fabric_post() {
  local tmp win rc
  tmp=$(_win_tmpfile "$2"); win=$(_winpath "$tmp")
  az rest --method POST --uri "${FABRIC_API}/$1" --resource "$FABRIC_RESOURCE" \
    --headers "Content-Type=application/json" --body "@${win}" --output json 2>/dev/null || echo '{}'
  rc=$?; rm -f "$tmp"; return $rc
}
# POST a JSON body; no output; returns 0 on success (handles 200/201/202).
fabric_post_status() {
  local tmp win
  tmp=$(_win_tmpfile "$2"); win=$(_winpath "$tmp")
  if az rest --method POST --uri "${FABRIC_API}/$1" --resource "$FABRIC_RESOURCE" \
    --headers "Content-Type=application/json" --body "@${win}" --output none 2>/dev/null; then
    rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"; return 1
}

# ── Authenticate ──────────────────────────────────────────────────────────────
step "Authenticating"
[[ "$USE_DEVICE_CODE" == true ]] && az login --use-device-code --allow-no-subscriptions >/dev/null
az account show --output none 2>/dev/null || die "Not logged in — run 'az login' first."
ok "Authenticated"

if [[ -z "$ALERT_EMAIL" ]]; then
  ALERT_EMAIL="$(az account show --query 'user.name' -o tsv 2>/dev/null || true)"
  [[ -z "$ALERT_EMAIL" ]] && die "Could not resolve signed-in user; pass --alert-email <ADDR>."
  ok "Alert recipient (signed-in user): $ALERT_EMAIL"
else
  ok "Alert recipient: $ALERT_EMAIL"
fi

# ── Resolve workspace + eventstream ───────────────────────────────────────────
step "Resolving workspace and eventstream"
WS_ID=$(fabric_get "workspaces" | jq -r --arg n "$WORKSPACE_NAME" \
  '.value[]? | select(.displayName == $n) | .id' | head -1 || true)
[[ -z "$WS_ID" ]] && die "Workspace '$WORKSPACE_NAME' not found — check name and permissions."
ok "Workspace: '$WORKSPACE_NAME' ($WS_ID)"

ES_ID=$(fabric_get "workspaces/$WS_ID/eventstreams" | jq -r --arg n "$EVENTSTREAM_NAME" \
  '.value[]? | select(.displayName == $n) | .id' | head -1 || true)
[[ -z "$ES_ID" ]] && die "Eventstream '$EVENTSTREAM_NAME' not found — run scripts/1-setup-fabric.sh first."
ok "Eventstream: '$EVENTSTREAM_NAME' ($ES_ID)"

# ── Resume the eventstream (Eventhouse destinations can be left Paused) ────────
step "Resuming eventstream (ensures live ingestion into the Eventhouse)"
if fabric_post_status "workspaces/$WS_ID/eventstreams/$ES_ID/resume" '{"startType":"Now"}'; then
  ok "Resume requested (sources + destinations)"
else
  warn "Resume call did not succeed (already running, or needs active capacity) — continuing."
fi

# ── Create the Activator (Reflex) item if it does not exist ────────────────────
step "Ensuring Activator item '$ACTIVATOR_NAME'"
RX_ID=$(fabric_get "workspaces/$WS_ID/reflexes" | jq -r --arg n "$ACTIVATOR_NAME" \
  '.value[]? | select(.displayName == $n) | .id' | head -1 || true)
if [[ -n "$RX_ID" ]]; then
  ok "Activator already exists ($RX_ID)"
else
  CREATE_BODY=$(jq -n --arg n "$ACTIVATOR_NAME" \
    --arg d "Emails ops when a machine goes to Fault (Running->Fault outage) on $EVENTSTREAM_NAME." \
    '{displayName:$n, description:$d}')
  RESP=$(fabric_post "workspaces/$WS_ID/reflexes" "$CREATE_BODY" || true)
  RX_ID=$(echo "$RESP" | jq -r '.id // empty' 2>/dev/null || true)
  # LRO path: item may provision asynchronously — poll the list for it.
  if [[ -z "$RX_ID" ]]; then
    for _ in $(seq 1 20); do
      sleep 6
      RX_ID=$(fabric_get "workspaces/$WS_ID/reflexes" | jq -r --arg n "$ACTIVATOR_NAME" \
        '.value[]? | select(.displayName == $n) | .id' | head -1 || true)
      [[ -n "$RX_ID" ]] && break
    done
  fi
  [[ -z "$RX_ID" ]] && die "Failed to create Activator item '$ACTIVATOR_NAME'."
  ok "Activator created ($RX_ID)"
fi

# ── Build the rule definition from the template ───────────────────────────────
step "Applying the outage rule definition"
DEF=$(sed -e "s/__EVENTSTREAM_ARTIFACT_ID__/${ES_ID}/g" \
          -e "s#__ALERT_EMAIL__#${ALERT_EMAIL}#g" "$TEMPLATE")
if echo "$DEF" | grep -q "__EVENTSTREAM_ARTIFACT_ID__\|__ALERT_EMAIL__"; then
  die "Template substitution left placeholders unresolved."
fi
echo "$DEF" | jq empty 2>/dev/null || die "Substituted definition is not valid JSON."

PAYLOAD=$(printf '%s' "$DEF" | base64 -w0 2>/dev/null || printf '%s' "$DEF" | base64 | tr -d '\n')
UPDATE_BODY=$(jq -n --arg p "$PAYLOAD" \
  '{definition:{parts:[{path:"ReflexEntities.json", payload:$p, payloadType:"InlineBase64"}]}}')

if fabric_post_status "workspaces/$WS_ID/items/$RX_ID/updateDefinition" "$UPDATE_BODY"; then
  ok "Rule definition applied (machine_status BECOMES 'Fault' -> email $ALERT_EMAIL)"
else
  die "updateDefinition failed for Activator '$ACTIVATOR_NAME'."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
W=$(printf '\xE2\x95\x90%.0s' {1..65})
printf "\n${GREEN}%s${RESET}\n" "$W"
printf "${GREEN}  Activator '%s' is deployed and the outage rule is active.${RESET}\n" "$ACTIVATOR_NAME"
printf "${GREEN}%s${RESET}\n" "$W"
printf "   Open: https://app.fabric.microsoft.com/groups/%s/reflexes/%s\n\n" "$WS_ID" "$RX_ID"
