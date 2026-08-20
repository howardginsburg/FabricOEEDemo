#!/usr/bin/env bash
# =============================================================================
# setup-activator-alerts.sh — Fabric Activator alert setup helper
#
# Activator/Data Activator/Reflex alert creation is portal-driven. This helper
# does not create Activator resources. It verifies Fabric access, resolves the
# existing workspace, Eventstream, and KQL database IDs, then prints the exact
# manual portal steps for the OEE demo alert rules.
#
# Prerequisites:
#   - Azure CLI (az) 2.x with an active login (run 'az login' first)
#   - jq
#   - A Fabric workspace with the core OEE foundation already provisioned
#
# Usage:
#   bash scripts/setup-activator-alerts.sh --workspace-name <NAME>
#   bash scripts/setup-activator-alerts.sh --workspace-name <NAME> --use-device-code
# =============================================================================
set -euo pipefail

FABRIC_API="https://api.fabric.microsoft.com/v1"
FABRIC_RESOURCE="https://api.fabric.microsoft.com"
WORKSPACE_NAME=""
USE_DEVICE_CODE=false

# ── Colours ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  GREEN='\033[92m'; YELLOW='\033[93m'; RED='\033[91m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; RESET=''
fi
ok()     { printf "   ${GREEN}✓${RESET} %s\n" "$*"; }
warn()   { printf "   ${YELLOW}!${RESET} %s\n" "$*"; }
die()    { printf "   ${RED}✗ ERROR:${RESET} %s\n" "$*" >&2; exit 1; }
step()   { printf "\n── %s\n" "$*"; }
manual() { printf "   ${YELLOW}→${RESET} %s\n" "$*"; }

# ── Args ──────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --workspace-name)  WORKSPACE_NAME="$2"; shift 2 ;;
    --use-device-code) USE_DEVICE_CODE=true; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ -z "$WORKSPACE_NAME" ]] && die "Usage: $0 --workspace-name <NAME>"

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in az jq; do
  command -v "$cmd" &>/dev/null || die "'$cmd' is required but not installed."
done

# ── az rest helper ─────────────────────────────────────────────────────────────
fabric_get() {
  local path="$1" response
  if response=$(az rest --method GET \
    --uri "${FABRIC_API}/$path" \
    --resource "$FABRIC_RESOURCE" \
    --output json 2>&1); then
    printf '%s\n' "$response"
  else
    warn "GET $path failed: ${response:0:300}" >&2
    return 1
  fi
}

find_item_id() {
  local path="$1" name="$2" label="$3" list id
  if ! list=$(fabric_get "$path"); then
    warn "Could not list $label items; continuing with portal guidance only." >&2
    printf '\n'
    return 0
  fi

  id=$(echo "$list" | jq -r --arg n "$name" \
    '.value[]? | select(.displayName == $n) | .id' | head -1 || true)
  printf '%s\n' "$id"
}

# ── Authenticate ───────────────────────────────────────────────────────────────
step "Authenticating"
[[ "$USE_DEVICE_CODE" == true ]] && \
  az login --use-device-code --allow-no-subscriptions >/dev/null

az account show --output none 2>/dev/null \
  || die "Not logged in — run 'az login' first."
ok "Authenticated"

# ── Resolve workspace and existing Fabric items ────────────────────────────────
step "Resolving Fabric workspace and existing OEE items"
WORKSPACES=$(fabric_get "workspaces") \
  || die "Failed to list workspaces — check 'az login' and Fabric permissions."
WS_ID=$(echo "$WORKSPACES" | jq -r --arg n "$WORKSPACE_NAME" \
  '.value[]? | select(.displayName == $n) | .id' | head -1 || true)
[[ -z "$WS_ID" ]] && \
  die "Workspace '$WORKSPACE_NAME' not found — check name and permissions."
ok "Workspace: '$WORKSPACE_NAME' ($WS_ID)"

ES_NAME="manufacturing-telemetry"
DB_NAME="ManufacturingEH"

ES_ID=$(find_item_id "workspaces/$WS_ID/eventstreams" "$ES_NAME" "Eventstream")
if [[ -n "$ES_ID" ]]; then
  ok "Eventstream: '$ES_NAME' (id=$ES_ID)"
else
  warn "Eventstream '$ES_NAME' not found. Run scripts/1-setup-fabric.sh first, or create the alert from the portal after the Eventstream exists."
fi

DB_ID=$(find_item_id "workspaces/$WS_ID/kqlDatabases" "$DB_NAME" "KQL database")
if [[ -n "$DB_ID" ]]; then
  ok "KQL Database: '$DB_NAME' (id=$DB_ID)"
else
  warn "KQL database '$DB_NAME' not found. Low-OEE KQL guidance is still printed below."
fi

# ── Manual setup guidance ──────────────────────────────────────────────────────
step "Portal-only Activator setup"
warn "Activator/Data Activator/Reflex alert provisioning is portal-driven; this script intentionally does not call undocumented REST APIs."
manual "Open Fabric: https://app.fabric.microsoft.com/groups/$WS_ID"
manual "Confirm the workspace is on Fabric capacity and Real-Time Intelligence + Activator are enabled."
printf "\n"

printf "\033[93m  A) CREATE THE ACTIVATOR ITEM / DESTINATION\033[0m\n"
manual "Option 1: Open Eventstream '$ES_NAME' → Publish if needed → Set alert."
manual "Option 2: Create an Activator/Data Activator/Reflex item named 'OEE Activator Alerts'."
manual "If starting from Eventstream, save the rule into 'OEE Activator Alerts' when prompted."
printf "\n"

printf "\033[93m  B) RULE: STATION DOWN TOO LONG\033[0m\n"
manual "Object/group key: device_id"
manual "Display/context fields: line_id, station_position, machine_status"
manual "Window: 10 minutes"
manual "Condition: is_fault == 1 OR is_idle == 1 OR is_maintenance == 1 for the window"
manual "Eventstream raw-field fallback: machine_status is Fault OR Idle OR Maintenance, grouped by device_id, for 10 minutes"
manual "KQL-backed logic:"
manual "  let window = 10m;"
manual "  MachineEvents"
manual "  | where timestamp >= ago(window)"
manual "  | summarize down_samples = countif(is_fault == 1 or is_idle == 1 or is_maintenance == 1),"
manual "              samples = count(),"
manual "              arg_max(timestamp, machine_status, line_id, station_position) by device_id"
manual "  | extend down_ratio = todouble(down_samples) / todouble(samples)"
manual "  | where samples > 0 and down_ratio >= 0.80"
printf "\n"

printf "\033[93m  C) RULE: SUSTAINED LOW OEE ON A LINE\033[0m\n"
manual "Object/group key: line_id"
manual "Window: 10 minutes"
manual "Default demo target: OEE < 0.60"
manual "Full OEE logic (Availability × Performance × Quality):"
manual "  let window = 10m;"
manual "  let target_oee = 0.60;"
manual "  let machine = MachineEventsEnriched()"
manual "      | where timestamp >= ago(window)"
manual "      | summarize availability = avg(todouble(is_running)),"
manual "                  performance = avgif(performance_ratio, is_running == 1) by line_id;"
manual "  let quality = PartEvents"
manual "      | where timestamp >= ago(window) and is_completed == 1"
manual "      | summarize quality = avg(todouble(is_pass)) by line_id;"
manual "  machine"
manual "  | join kind=leftouter quality on line_id"
manual "  | extend performance = coalesce(performance, 1.0),"
manual "           quality = coalesce(quality, 1.0),"
manual "           oee = availability * performance * quality"
manual "  | where oee < target_oee"
manual "If the portal cannot attach the full expression, use the proxy condition:"
manual "  availability < 0.75 OR (fault_rate + idle_rate) > 0.25 over 10 minutes"
manual "Cleaner later option: watch the OEE measure from the Power BI semantic model once that component exists."
printf "\n"

printf "\033[93m  D) ACTIONS AND ACTIVATION\033[0m\n"
manual "Default action: send a Microsoft Teams message to the operations/demo channel."
manual "Fallback action: send email if Teams actions are tenant-policy blocked."
manual "Message should include rule name, line_id, device_id/station, status or OEE value, and the 10-minute window."
manual "Optional: add a plain URL to the Rayfin Downtime Logbook app or the Power BI report."
manual "Save the rule, send a test notification if available, then Activate/Start it."
printf "\n"

W=$(printf '═%.0s' {1..65})
printf "\033[97m%s\033[0m\n" "$W"
printf "\033[97m  Activator helper complete. Nothing was created or modified.\033[0m\n"
printf "\033[97m%s\033[0m\n\n" "$W"
