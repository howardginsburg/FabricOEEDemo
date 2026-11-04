#!/usr/bin/env bash
# =============================================================================
# 3-setup-floor-ops.sh — wire the Floor Ops Console app data into the OEE model.
#
# The "Floor Ops Console" Fabric app (app/) writes FloorEvent rows to its own
# managed Fabric SQL database (Fabric SSO — no external reads, no Entra app
# registration). That table mirrors to OneLake; this script surfaces it into the
# Direct Lake OEE model by creating a OneLake shortcut:
#
#   ManufacturingLH/Tables/dbo/FloorEvent  ->  <app SQL DB>/Tables/dbo/FloorEvents
#
# The Rayfin @entity model name 'FloorEvent' generates a schema-qualified, pluralized
# table dbo.FloorEvents in the managed DB; the lakehouse shortcut is named 'FloorEvent'
# (singular) so it surfaces as dbo.FloorEvent to match the Power BI model binding.
#
# Idempotent and safe to re-run. Run AFTER the app is deployed (npm run rayfin:up)
# and the schema applied (npm run rayfin:db). Optionally seed demo data first with
# scripts/3a-seed-floor-events.py so the mirror has rows to export.
#
# Usage:
#   bash scripts/3-setup-floor-ops.sh --workspace-name "<WORKSPACE>"
#   bash scripts/3-setup-floor-ops.sh --workspace-name "<WORKSPACE>" --app-sqldb-name oee-downtime-logbook
# =============================================================================
set -euo pipefail

FABRIC_API="https://api.fabric.microsoft.com/v1"
FABRIC_RESOURCE="https://api.fabric.microsoft.com"
LH_NAME="ManufacturingLH"
APP_SQLDB_NAME="oee-downtime-logbook"   # the managed SQLDatabase item created by rayfin up
WORKSPACE_NAME=""

if [[ -t 1 ]]; then GREEN='\033[92m'; YELLOW='\033[93m'; RED='\033[91m'; RESET='\033[0m'; else GREEN=''; YELLOW=''; RED=''; RESET=''; fi
ok()   { printf "   ${GREEN}✓${RESET} %s\n" "$*"; }
warn() { printf "   ${YELLOW}!${RESET} %s\n" "$*"; }
die()  { printf "   ${RED}✗ ERROR:${RESET} %s\n" "$*" >&2; exit 1; }
step() { printf "\n── %s\n" "$*"; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --workspace-name) WORKSPACE_NAME="$2"; shift 2 ;;
    --app-sqldb-name) APP_SQLDB_NAME="$2"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ -z "$WORKSPACE_NAME" ]] && die "Usage: $0 --workspace-name <NAME> [--app-sqldb-name <APP_SQLDB>]"
for c in az jq; do command -v "$c" &>/dev/null || die "'$c' is required."; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_AZ_IS_WINDOWS=false; [[ "$(command -v az)" == *.exe || "$(command -v az)" == /mnt/* ]] && _AZ_IS_WINDOWS=true
if [[ "$_AZ_IS_WINDOWS" == true ]]; then _WIN_TEMP="/mnt/c/Windows/Temp"; mkdir -p "$_WIN_TEMP" 2>/dev/null || _WIN_TEMP="${TMPDIR:-/tmp}"; else _WIN_TEMP="${TMPDIR:-/tmp}"; fi
_win_tmpfile() { local f; f=$(mktemp "${_WIN_TEMP}/fo.XXXXXX.json"); printf '%s' "$1" > "$f"; echo "$f"; }
_winpath() { if [[ "$_AZ_IS_WINDOWS" == true ]]; then wslpath -w "$1" 2>/dev/null || echo "$1"; else echo "$1"; fi; }
fabric_get() { az rest --method GET --uri "${FABRIC_API}/$1" --resource "$FABRIC_RESOURCE" --output json 2>/dev/null; }
fabric_post_none() {
  local tmp win; tmp=$(_win_tmpfile "$2"); win=$(_winpath "$tmp")
  if az rest --method POST --uri "${FABRIC_API}/$1" --resource "$FABRIC_RESOURCE" \
    --headers "Content-Type=application/json" --body "@${win}" --output none 2>/dev/null; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"; return 1
}

step "Authenticating"
az account show --output none 2>/dev/null || die "Not logged in — run 'az login' first."
ok "Authenticated"

step "Resolving workspace + lakehouse + app SQL database"
WS_ID=$(fabric_get "workspaces" | jq -r --arg n "$WORKSPACE_NAME" '.value[]|select(.displayName==$n)|.id' | head -1 || true)
[[ -z "$WS_ID" ]] && die "Workspace '$WORKSPACE_NAME' not found."
LH_ID=$(fabric_get "workspaces/$WS_ID/lakehouses" | jq -r --arg n "$LH_NAME" '.value[]|select(.displayName==$n)|.id' | head -1 || true)
[[ -z "$LH_ID" ]] && die "Lakehouse '$LH_NAME' not found — run scripts/1-setup-fabric.sh first."
# Target the managed SQLDatabase (its OneLake mirror holds the Delta), NOT the paired SQLEndpoint.
APP_DB_ID=$(fabric_get "workspaces/$WS_ID/items" | jq -r --arg n "$APP_SQLDB_NAME" \
  '.value[]|select(.displayName==$n and .type=="SQLDatabase")|.id' | head -1 || true)
[[ -z "$APP_DB_ID" ]] && die "App SQL database '$APP_SQLDB_NAME' not found — deploy the app first (npm run rayfin:up)."
ok "Workspace $WS_ID / Lakehouse $LH_ID / App DB $APP_DB_ID"

step "Creating OneLake shortcut ManufacturingLH/Tables/dbo/FloorEvent"
_BODY=$(jq -n --arg ws "$WS_ID" --arg db "$APP_DB_ID" \
  '{path:"Tables/dbo",name:"FloorEvent",target:{oneLake:{workspaceId:$ws,itemId:$db,path:"Tables/dbo/FloorEvents"}}}')
if fabric_post_none "workspaces/$WS_ID/items/$LH_ID/shortcuts?shortcutConflictPolicy=CreateOrOverwrite" "$_BODY"; then
  ok "FloorEvent shortcut created (→ ${APP_SQLDB_NAME}/Tables/dbo/FloorEvents)"
else
  warn "Shortcut not confirmed — the app DB Delta may still be mirroring."
  warn "Seed rows (scripts/3a-seed-floor-events.py) and re-run; the mirror needs data + a few minutes."
fi

step "Refreshing the lakehouse SQL analytics endpoint metadata"
SEP_ID=$(fabric_get "workspaces/$WS_ID/sqlEndpoints" | jq -r --arg n "$LH_NAME" '.value[]|select(.displayName==$n)|.id' | head -1 || true)
if [[ -n "$SEP_ID" ]] && fabric_post_none "workspaces/$WS_ID/sqlEndpoints/$SEP_ID/refreshMetadata?preview=true" '{}'; then
  ok "SQL analytics endpoint metadata refreshed — dbo.FloorEvent visible to Direct Lake"
else
  warn "Could not refresh endpoint metadata; refresh the semantic model manually if FloorEvent is missing."
fi

step "Done"
printf "   Next: refresh the OEEAnalytics semantic model to frame FloorEvent, then open the\n"
printf "   Floor Ops report page. See https://howardginsburg.github.io/FabricOEEDemo/demo/floor-ops/ for the full flow.\n"
