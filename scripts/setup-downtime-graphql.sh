#!/usr/bin/env bash
# =============================================================================
# setup-downtime-graphql.sh — Downtime Logbook (Component B) plumbing helper
#
# The Rayfin app itself is a Fabric app built on the Rayfin SDK and is deployed
# with the Rayfin CLI (`npx rayfin up`, see app/README.md) — NOT azd/Bicep. This
# helper only handles the two Fabric-side pieces around that deploy:
#   1. Prints the RecentDowntime read-surface SQL view (apply it in the
#      ManufacturingLH SQL analytics endpoint) and the manual steps to build the
#      standalone "Fabric API for GraphQL" over it.
#   2. Optionally creates the OneLake shortcut that surfaces the deployed app's
#      DowntimeReason table into ManufacturingLH/Tables/dbo/DowntimeReason so the
#      Power BI OEE model can blend it (pass --app-sqldb-name once the app is deployed).
#
# Idempotent and safe to re-run.
#
# Usage:
#   bash scripts/setup-downtime-graphql.sh --workspace-name <NAME>
#   bash scripts/setup-downtime-graphql.sh --workspace-name <NAME> --app-sqldb-name <APP_SQLDB>
# =============================================================================
set -euo pipefail

FABRIC_API="https://api.fabric.microsoft.com/v1"
FABRIC_RESOURCE="https://api.fabric.microsoft.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
VIEW_SQL="${REPO_ROOT}/app/graphql/RecentDowntime.view.sql"
LH_NAME="ManufacturingLH"
WORKSPACE_NAME=""
APP_SQLDB_NAME=""
USE_DEVICE_CODE=false

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

while [[ $# -gt 0 ]]; do
  case $1 in
    --workspace-name)  WORKSPACE_NAME="$2"; shift 2 ;;
    --app-sqldb-name)  APP_SQLDB_NAME="$2"; shift 2 ;;
    --use-device-code) USE_DEVICE_CODE=true; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ -z "$WORKSPACE_NAME" ]] && die "Usage: $0 --workspace-name <NAME> [--app-sqldb-name <APP_SQLDB>]"
for cmd in az jq; do command -v "$cmd" &>/dev/null || die "'$cmd' is required."; done

_AZ_BIN="$(command -v az)"
if [[ "$_AZ_BIN" == /mnt/* ]] || [[ "$_AZ_BIN" == *.exe ]]; then
  _WIN_TEMP="/mnt/c/Users/${USER}/AppData/Local/Temp"; mkdir -p "$_WIN_TEMP" 2>/dev/null || _WIN_TEMP="/mnt/c/Windows/Temp"
  _AZ_IS_WINDOWS=true
else
  _WIN_TEMP="${TMPDIR:-/tmp}"; _AZ_IS_WINDOWS=false
fi
_win_tmpfile() { local f; f=$(mktemp "${_WIN_TEMP}/pbi.XXXXXX.json"); printf '%s' "$1" > "$f"; echo "$f"; }
_winpath()     { if [[ "$_AZ_IS_WINDOWS" == true ]]; then wslpath -w "$1" 2>/dev/null || echo "$1"; else echo "$1"; fi; }
fabric_get()   { az rest --method GET --uri "${FABRIC_API}/$1" --resource "$FABRIC_RESOURCE" --output json 2>/dev/null; }
fabric_post_none() {
  local tmp win; tmp=$(_win_tmpfile "$2"); win=$(_winpath "$tmp")
  if az rest --method POST --uri "${FABRIC_API}/$1" --resource "$FABRIC_RESOURCE" \
    --headers "Content-Type=application/json" --body "@${win}" --output none 2>/dev/null; then
    rm -f "$tmp"; return 0
  fi
  rm -f "$tmp"; return 1
}

step "Authenticating"
[[ "$USE_DEVICE_CODE" == true ]] && az login --use-device-code --allow-no-subscriptions >/dev/null
az account show --output none 2>/dev/null || die "Not logged in — run 'az login' first."
ok "Authenticated"

step "Resolving workspace + lakehouse"
WS_ID=$(fabric_get "workspaces" | jq -r --arg n "$WORKSPACE_NAME" '.value[]|select(.displayName==$n)|.id' | head -1 || true)
[[ -z "$WS_ID" ]] && die "Workspace '$WORKSPACE_NAME' not found."
LH_ID=$(fabric_get "workspaces/$WS_ID/lakehouses" | jq -r --arg n "$LH_NAME" '.value[]|select(.displayName==$n)|.id' | head -1 || true)
[[ -z "$LH_ID" ]] && die "Lakehouse '$LH_NAME' not found — run scripts/1-setup-fabric.sh first."
ok "Workspace $WS_ID / Lakehouse $LH_ID"

step "1) Read surface — RecentDowntime view + standalone GraphQL API (manual)"
manual "Apply the read-surface view in the $LH_NAME SQL analytics endpoint query editor:"
manual "   $VIEW_SQL"
manual "Then: + New → API for GraphQL (name 'oee-downtime-read') → Add data →"
manual "   $LH_NAME (SQL analytics endpoint) → select dbo.RecentDowntime → expose query."
manual "Grant operator (user/SSO) access, then set RAYFIN_PUBLIC_DOWNTIME_GRAPHQL_URL in"
manual "   app/rayfin/.env and run 'npm run rayfin:env' (emits VITE_RAYFIN_DOWNTIME_GRAPHQL_URL)."

step "2) DowntimeReason shortcut into $LH_NAME (analytics blend)"
if [[ -z "$APP_SQLDB_NAME" ]]; then
  warn "Skipping shortcut — pass --app-sqldb-name <APP_SQLDB> after 'npx rayfin up' deploys the app."
  manual "The app's managed SQL database mirrors to OneLake; re-run with its name to create the shortcut."
else
  APP_DB=$(fabric_get "workspaces/$WS_ID/items" | jq -c --arg n "$APP_SQLDB_NAME" \
    '.value[]|select(.displayName==$n and (.type=="SQLDatabase" or .type=="SQLEndpoint"))' | head -1 || true)
  [[ -z "$APP_DB" ]] && die "App SQL database '$APP_SQLDB_NAME' not found in workspace — check the name/type."
  APP_DB_ID=$(jq -r '.id' <<<"$APP_DB")
  _BODY=$(jq -n --arg ws "$WS_ID" --arg db "$APP_DB_ID" \
    '{path:"Tables/dbo",name:"DowntimeReason",target:{oneLake:{workspaceId:$ws,itemId:$db,path:"Tables/DowntimeReason"}}}')
  if fabric_post_none "workspaces/$WS_ID/items/$LH_ID/shortcuts?shortcutConflictPolicy=CreateOrOverwrite" "$_BODY"; then
    ok "DowntimeReason shortcut created in $LH_NAME/Tables/dbo"
  else
    warn "Shortcut not confirmed — the app DB Delta may still be mirroring; re-run shortly."
  fi
fi

step "Deploy the Rayfin app (run separately — needs Node + the Fabric Apps preview workload)"
manual "cd app && npm install"
manual "npx rayfin login                 # interactive Entra sign-in (if not already)"
manual "npm run rayfin:up                # rayfin up: app + managed SQL DB + Fabric SSO + static hosting"
manual "npm run rayfin:db                # rayfin up db apply: DowntimeReason schema"
manual "npm run rayfin:status            # confirm deployment; then re-run THIS script with"
manual "   --app-sqldb-name <APP_SQLDB> to create the DowntimeReason OneLake shortcut."

step "Done"
manual "See docs/DOWNTIME_LOGBOOK.md for the full flow and the Power BI blend step."
