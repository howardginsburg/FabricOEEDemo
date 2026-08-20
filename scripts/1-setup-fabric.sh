#!/usr/bin/env bash
# =============================================================================
# 1-setup-fabric.sh — End-to-end Fabric OEE demo provisioner
#
# Automates the core Fabric-side setup described in README.md.
# This is the required first script for both ingestion options.
#
# What it creates:
#   Step 1 — Eventhouse (ManufacturingEH)
#   Step 2 — KQL Database with:
#              • 3 Bronze (raw) tables: MachineEvents_Raw, PartEvents_Raw,
#                MaintenanceEvents_Raw — Eventstream landing zone
#              • JSON ingestion mappings for each Bronze table
#              • 3 reference tables: LineMaster, StationMaster, ProductionSchedule
#              • 3 Silver (enriched) tables: MachineEvents, PartEvents,
#                MaintenanceEvents — populated by KQL update policies with
#                numeric proxy columns (is_running / is_fault / is_pass /
#                performance_ratio / shift_id / ...) used by the dashboard,
#                ontology, and Fabric Data Agent
#              • OneLake mirroring enabled on the Silver tables (5-min latency)
#   Step 2a — Lakehouse (ManufacturingLH) for ontology OneLake shortcuts
#   Step 3 — Eventstream (manufacturing-telemetry) with:
#              • Custom endpoint source (oee-simulator)
#              • 3 SQL Query routing operators (filter by event_type)
#              • 3 Eventhouse destinations (one per table)
#   Step 4 — Dashboard JSON generated from dashboard/oee-dashboard.template.json
#   Step 5 — Real-Time Dashboard imported (OEE Manufacturing Dashboard)
#   Step 6 — Simulator configuration guidance (simulator.local.yaml)
#
# The script is idempotent — re-running it skips resources that already exist.
#
# Prerequisites:
#   - Azure CLI (az) 2.x with an active login (run 'az login' first)
#   - base64, sed (standard on Linux/macOS/WSL)
#   - jq (auto-installed via apt if missing)
#   - A Fabric workspace (not "My workspace") with Real-Time Intelligence enabled
#   - Tenant admin has enabled "Service principals can call Fabric public APIs"
#
# Usage:
#   bash 1-setup-fabric.sh --workspace-name <NAME>
#   bash 1-setup-fabric.sh --workspace-name <NAME> --use-device-code
#
# Arguments:
#   --workspace-name <NAME>   (required) Fabric workspace display name
#   --use-device-code         Use device-code auth flow (for headless/SSH sessions)
#   --skip-fabric-iq          Do NOT create the Fabric IQ ontology + Data Agent
#                              (by default both are created automatically)
#
# After completion:
#   1. Verify the Eventstream is running in the Fabric UI (it may need a manual
#      Publish click to activate)
#   2. Attach the ontology to the Data Agent and Publish it (portal-only — the
#      Fabric public REST API has no endpoint for these two actions; see the
#      end-of-run output and README.md)
#   3. Configure and start the simulator (see the final step output)
#   4. Optionally set up Activator alerts (see README.md)
# =============================================================================
set -euo pipefail

FABRIC_API="https://api.fabric.microsoft.com/v1"
FABRIC_RESOURCE="https://api.fabric.microsoft.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_NAME=""
USE_DEVICE_CODE=false
SKIP_FABRIC_IQ=false

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
    --skip-fabric-iq)  SKIP_FABRIC_IQ=true; shift ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ -z "$WORKSPACE_NAME" ]] && die "Usage: $0 --workspace-name <NAME>"

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in az base64; do
  command -v "$cmd" &>/dev/null || die "'$cmd' is required but not installed."
done

if ! command -v jq &>/dev/null; then
  step "Installing jq"
  sudo apt-get update -qq && sudo apt-get install -y -qq jq
  command -v jq &>/dev/null || die "Failed to install 'jq'."
  ok "jq installed"
fi

# Fabric IQ (ontology + Data Agent) needs python3 + PyYAML. If they are missing
# we don't fail the whole run — we just skip that optional step with a warning.
PY=""
if ! $SKIP_FABRIC_IQ; then
  if command -v python3 &>/dev/null; then PY=python3
  elif command -v python &>/dev/null; then PY=python; fi
  if [[ -z "$PY" ]]; then
    warn "python3 not found — skipping Fabric IQ creation (run scripts/0-check-prereqs.sh)."
    SKIP_FABRIC_IQ=true
  elif ! "$PY" -c 'import yaml' &>/dev/null; then
    warn "PyYAML not installed ('$PY -m pip install pyyaml') — skipping Fabric IQ creation."
    SKIP_FABRIC_IQ=true
  fi
fi

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# Detect whether 'az' is the Windows binary (az.exe under /mnt/c) or native Linux.
# Windows az can only read @file paths on the Windows filesystem; native Linux az
# uses normal Linux paths. Pick the temp dir and path-conversion accordingly.
_AZ_BIN="$(command -v az)"
if [[ "$_AZ_BIN" == /mnt/* ]] || [[ "$_AZ_BIN" == *.exe ]]; then
  _AZ_IS_WINDOWS=true
  _WIN_TEMP="/mnt/c/Users/${USER}/AppData/Local/Temp"
  mkdir -p "$_WIN_TEMP" 2>/dev/null || _WIN_TEMP="/mnt/c/Windows/Temp"
else
  _AZ_IS_WINDOWS=false
  _WIN_TEMP="${TMPDIR:-/tmp}"
fi

_win_tmpfile() {
  local f
  f=$(mktemp "${_WIN_TEMP}/fabric.XXXXXX.json")
  printf '%s' "$1" > "$f"
  echo "$f"
}

_winpath() {
  if [[ "$_AZ_IS_WINDOWS" == true ]]; then
    wslpath -w "$1" 2>/dev/null || echo "$1"
  else
    echo "$1"
  fi
}

# ── az rest helpers ───────────────────────────────────────────────────────────
fabric_get() {
  local _stderr_file
  _stderr_file=$(mktemp)
  if az rest --method GET \
    --uri "${FABRIC_API}/$1" \
    --resource "$FABRIC_RESOURCE" \
    --output json 2>"$_stderr_file"; then
    rm -f "$_stderr_file"
  else
    local _rc=$?
    warn "GET $1 failed (exit $_rc): $(cat "$_stderr_file")"
    rm -f "$_stderr_file"
    return $_rc
  fi
}

fabric_post() {
  local tmp win
  tmp=$(_win_tmpfile "$2")
  win=$(_winpath "$tmp")
  az rest --method POST \
    --uri "${FABRIC_API}/$1" \
    --resource "$FABRIC_RESOURCE" \
    --headers "Content-Type=application/json" \
    --body "@${win}" \
    --output json 2>/dev/null || echo '{}'
  rm -f "$tmp"
}

fabric_post_status() {
  local tmp win
  tmp=$(_win_tmpfile "$2")
  win=$(_winpath "$tmp")
  if az rest --method POST \
    --uri "${FABRIC_API}/$1" \
    --resource "$FABRIC_RESOURCE" \
    --headers "Content-Type=application/json" \
    --body "@${win}" \
    --output none 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

fabric_post_lro() {
  local tmp win max elapsed
  tmp=$(_win_tmpfile "$2")
  win=$(_winpath "$tmp")
  max="${3:-120}"

  local response
  response=$(az rest --method POST \
    --uri "${FABRIC_API}/$1" \
    --resource "$FABRIC_RESOURCE" \
    --headers "Content-Type=application/json" \
    --body "@${win}" \
    --output json 2>/dev/null || echo '')
  rm -f "$tmp"

  if [[ -n "$response" ]]; then
    echo "$response"
    return 0
  fi

  return 0
}

wait_for_item() {
  local list_path="$1" name="$2" max="${3:-300}" elapsed=0
  local result item
  while (( elapsed < max )); do
    result=$(fabric_get "$list_path" || echo '{"value":[]}')
    item=$(echo "$result" | jq -c --arg n "$name" \
      '.value[] | select(.displayName == $n)' 2>/dev/null | head -1 || true)
    if [[ -n "$item" ]]; then
      echo "$item"
      return 0
    fi
    sleep 10; elapsed=$((elapsed + 10))
  done
  die "Timed out waiting for '$name'"
}

# ── Kusto data-plane helper ───────────────────────────────────────────────────
kusto_run() {
  local cluster="$1" db="$2" cmd="$3" desc="$4" soft="${5:-false}"
  local body_tmp win err

  body_tmp=$(_win_tmpfile "$(jq -n --arg csl "$cmd" --arg db "$db" '{"csl":$csl,"db":$db}')")
  win=$(_winpath "$body_tmp")

  if err=$(az rest --method POST \
    --uri "${cluster}/v1/rest/mgmt" \
    --resource "$cluster" \
    --headers "Content-Type=application/json" \
    --body "@${win}" \
    --output none 2>&1); then
    rm -f "$body_tmp"
    ok "$desc"
    return 0
  fi

  rm -f "$body_tmp"
  if [[ "$soft" == "true" ]]; then
    warn "$desc (skipped)"
    return 1
  fi
  die "KQL error [$desc]: ${err:0:300}"
}

# ── Step 0: Authenticate ──────────────────────────────────────────────────────
step "Authenticating"
[[ "$USE_DEVICE_CODE" == true ]] && \
  az login --use-device-code --allow-no-subscriptions >/dev/null

az account show --output none 2>/dev/null \
  || die "Not logged in — run 'az login' first."
ok "Authenticated"

# ── Find workspace ────────────────────────────────────────────────────────────
WORKSPACES=$(fabric_get "workspaces") \
  || die "Failed to list workspaces — check 'az login' and Fabric permissions."
WS_ID=$(echo "$WORKSPACES" | jq -r --arg n "$WORKSPACE_NAME" \
  '.value[] | select(.displayName == $n) | .id' | head -1 || true)
[[ -z "$WS_ID" ]] && \
  die "Workspace '$WORKSPACE_NAME' not found — check name and permissions."
ok "Workspace: '$WORKSPACE_NAME' ($WS_ID)"

# ── Step 1: Eventhouse ────────────────────────────────────────────────────────
step "Step 1 — Creating Eventhouse (ManufacturingEH)"
EH_LIST=$(fabric_get "workspaces/$WS_ID/eventhouses") \
  || die "Failed to list eventhouses — is the Fabric capacity active?"
EH_ID=$(echo "$EH_LIST" | jq -r \
  '.value[] | select(.displayName == "ManufacturingEH") | .id' | head -1 || true)
CLUSTER_URI=$(echo "$EH_LIST" | jq -r \
  '.value[] | select(.displayName == "ManufacturingEH") | .properties.queryServiceUri' | head -1 || true)

if [[ -n "$EH_ID" ]]; then
  ok "Eventhouse already exists  →  $CLUSTER_URI"
else
  fabric_post "workspaces/$WS_ID/eventhouses" '{"displayName":"ManufacturingEH"}' >/dev/null
  EH_JSON=$(wait_for_item "workspaces/$WS_ID/eventhouses" "ManufacturingEH")
  EH_ID=$(echo "$EH_JSON" | jq -r '.id')

  CLUSTER_URI=""
  for i in {1..30}; do
    EH_DETAIL=$(fabric_get "workspaces/$WS_ID/eventhouses/$EH_ID")
    CLUSTER_URI=$(echo "$EH_DETAIL" | jq -r '.properties.queryServiceUri // empty')
    [[ -n "$CLUSTER_URI" ]] && break
    sleep 10
  done
  [[ -z "$CLUSTER_URI" ]] && die "Eventhouse created but cluster URI not yet available"
  ok "Eventhouse created  →  $CLUSTER_URI"
fi

# ── Step 2: KQL Database ──────────────────────────────────────────────────────
step "Step 2 — Creating KQL Database"
DB_NAME="ManufacturingEH"
DB_LIST=$(fabric_get "workspaces/$WS_ID/kqlDatabases") \
  || die "Failed to list KQL databases"
DB_ID=$(echo "$DB_LIST" | jq -r --arg n "$DB_NAME" \
  '.value[] | select(.displayName == $n) | .id' | head -1 || true)

if [[ -n "$DB_ID" ]]; then
  ok "KQL Database already exists (id=$DB_ID)"
else
  DB_PROPS_B64=$(b64 '{"databaseType":"ReadWrite","parentEventhouseItemId":"'"$EH_ID"'"}')
  DB_PAYLOAD=$(jq -n \
    --arg name "$DB_NAME" \
    --arg props "$DB_PROPS_B64" \
    '{displayName:$name,definition:{parts:[{path:"DatabaseProperties.json",payload:$props,payloadType:"InlineBase64"}]}}')
  fabric_post "workspaces/$WS_ID/kqlDatabases" "$DB_PAYLOAD" >/dev/null
  DB_JSON=$(wait_for_item "workspaces/$WS_ID/kqlDatabases" "$DB_NAME")
  DB_ID=$(echo "$DB_JSON" | jq -r '.id')
  ok "KQL Database created (id=$DB_ID)"
  sleep 20
fi

# ── Step 2a: Lakehouse for ontology shortcuts ────────────────────────────────
step "Step 2a — Creating Lakehouse (ManufacturingLH)"
LH_NAME="ManufacturingLH"
LH_LIST=$(fabric_get "workspaces/$WS_ID/lakehouses") \
  || die "Failed to list lakehouses"
LH_ID=$(echo "$LH_LIST" | jq -r --arg n "$LH_NAME" \
  '.value[] | select(.displayName == $n) | .id' | head -1 || true)

if [[ -n "$LH_ID" ]]; then
  ok "Lakehouse already exists (id=$LH_ID)"
else
  LH_PAYLOAD=$(jq -n --arg name "$LH_NAME" '{displayName:$name}')
  fabric_post "workspaces/$WS_ID/lakehouses" "$LH_PAYLOAD" >/dev/null
  LH_JSON=$(wait_for_item "workspaces/$WS_ID/lakehouses" "$LH_NAME")
  LH_ID=$(echo "$LH_JSON" | jq -r '.id')
  ok "Lakehouse created (id=$LH_ID)"
fi

# ── Step 2b: Apply KQL schema ─────────────────────────────────────────────────
step "Step 2b — Applying KQL schema (Bronze _Raw + Silver enriched + ref data)"

# --- Bronze: raw event tables (Eventstream destinations) ---

kusto_run "$CLUSTER_URI" "$DB_NAME" \
  '.create-merge table MachineEvents_Raw (event_type:string, device_id:string, machine_type:string, machine_status:string, idle_reason:string, line_id:string, station_position:int, actual_cycle_time:real, input_buffer_count:int, output_buffer_count:int, buffer_capacity:int, total_parts_processed:long, rejected_parts:long, current_part_id:string, timestamp:datetime)' \
  "MachineEvents_Raw (Bronze) table"

read -r -d '' _ME_MAP <<'KQLEOF' || true
.create-or-alter table MachineEvents_Raw ingestion json mapping 'MachineEventsRawMapping'
'['
'  {"column":"event_type",           "path":"$.event_type",           "datatype":"string"},'
'  {"column":"device_id",            "path":"$.device_id",            "datatype":"string"},'
'  {"column":"machine_type",         "path":"$.machine_type",         "datatype":"string"},'
'  {"column":"machine_status",       "path":"$.machine_status",       "datatype":"string"},'
'  {"column":"idle_reason",          "path":"$.idle_reason",          "datatype":"string"},'
'  {"column":"line_id",              "path":"$.line_id",              "datatype":"string"},'
'  {"column":"station_position",     "path":"$.station_position",     "datatype":"int"},'
'  {"column":"actual_cycle_time",    "path":"$.actual_cycle_time",    "datatype":"real"},'
'  {"column":"input_buffer_count",   "path":"$.input_buffer_count",   "datatype":"int"},'
'  {"column":"output_buffer_count",  "path":"$.output_buffer_count",  "datatype":"int"},'
'  {"column":"buffer_capacity",      "path":"$.buffer_capacity",      "datatype":"int"},'
'  {"column":"total_parts_processed","path":"$.total_parts_processed","datatype":"long"},'
'  {"column":"rejected_parts",       "path":"$.rejected_parts",       "datatype":"long"},'
'  {"column":"current_part_id",      "path":"$.current_part_id",      "datatype":"string"},'
'  {"column":"timestamp",            "path":"$.timestamp",            "datatype":"datetime"}'
']'
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_ME_MAP" "MachineEvents_Raw mapping"

kusto_run "$CLUSTER_URI" "$DB_NAME" \
  '.create-merge table PartEvents_Raw (event_type:string, part_id:string, line_id:string, station_position:int, machine_type:string, action:string, cycle_time:real, quality_pass:bool, timestamp:datetime)' \
  "PartEvents_Raw (Bronze) table"

read -r -d '' _PE_MAP <<'KQLEOF' || true
.create-or-alter table PartEvents_Raw ingestion json mapping 'PartEventsRawMapping'
'['
'  {"column":"event_type",       "path":"$.event_type",       "datatype":"string"},'
'  {"column":"part_id",          "path":"$.part_id",          "datatype":"string"},'
'  {"column":"line_id",          "path":"$.line_id",          "datatype":"string"},'
'  {"column":"station_position", "path":"$.station_position", "datatype":"int"},'
'  {"column":"machine_type",     "path":"$.machine_type",     "datatype":"string"},'
'  {"column":"action",           "path":"$.action",           "datatype":"string"},'
'  {"column":"cycle_time",       "path":"$.cycle_time",       "datatype":"real"},'
'  {"column":"quality_pass",     "path":"$.quality_pass",     "datatype":"bool"},'
'  {"column":"timestamp",        "path":"$.timestamp",        "datatype":"datetime"}'
']'
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_PE_MAP" "PartEvents_Raw mapping"

kusto_run "$CLUSTER_URI" "$DB_NAME" \
  '.create-merge table MaintenanceEvents_Raw (event_type:string, work_order_id:string, device_id:string, machine_type:string, line_id:string, station_position:int, issue_type:string, action:string, technician_id:string, timestamp:datetime)' \
  "MaintenanceEvents_Raw (Bronze) table"

read -r -d '' _MAI_MAP <<'KQLEOF' || true
.create-or-alter table MaintenanceEvents_Raw ingestion json mapping 'MaintenanceEventsRawMapping'
'['
'  {"column":"event_type",       "path":"$.event_type",       "datatype":"string"},'
'  {"column":"work_order_id",    "path":"$.work_order_id",    "datatype":"string"},'
'  {"column":"device_id",        "path":"$.device_id",        "datatype":"string"},'
'  {"column":"machine_type",     "path":"$.machine_type",     "datatype":"string"},'
'  {"column":"line_id",          "path":"$.line_id",          "datatype":"string"},'
'  {"column":"station_position", "path":"$.station_position", "datatype":"int"},'
'  {"column":"issue_type",       "path":"$.issue_type",       "datatype":"string"},'
'  {"column":"action",           "path":"$.action",           "datatype":"string"},'
'  {"column":"technician_id",    "path":"$.technician_id",    "datatype":"string"},'
'  {"column":"timestamp",        "path":"$.timestamp",        "datatype":"datetime"}'
']'
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_MAI_MAP" "MaintenanceEvents_Raw mapping"

# --- Reference data: LineMaster ---
read -r -d '' _LINE_MASTER <<'KQLEOF' || true
.set-or-replace LineMaster <|
    datatable(line_id:string, line_name:string, purpose:string, station_count:int)
    [
        "Line-A", "Precision Machining",   "Raw bar stock → machined shaft",              5,
        "Line-B", "Sheet Metal Forming",    "Sheet metal → stamped housing",               4,
        "Line-C", "Welding & Assembly",     "Components → welded subassembly",             6,
        "Line-D", "Surface Treatment",      "Raw part → painted and coated finished part", 7,
        "Line-E", "Electronics Assembly",   "Bare PCB → tested electronics module",        8,
    ]
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_LINE_MASTER" "LineMaster reference data"

# --- Reference data: StationMaster ---
read -r -d '' _STATION_MASTER <<'KQLEOF' || true
.set-or-replace StationMaster with (extend_schema=true) <|
    datatable(
        line_id:string, station_position:int, machine_type:string,
        ideal_cycle_time:real, manufacturer:string, install_year:int,
        buffer_capacity:int, device_id:string
    )
    [
        "Line-A", 1, "CNC-Lathe",            40.0, "Haas",          2018, 5, "line-a-station-1",
        "Line-A", 2, "CNC-Mill",             45.0, "Haas",          2019, 5, "line-a-station-2",
        "Line-A", 3, "Surface-Grinder",      35.0, "Okamoto",       2020, 5, "line-a-station-3",
        "Line-A", 4, "Deburring-Station",    15.0, "Rösler",        2021, 5, "line-a-station-4",
        "Line-A", 5, "CMM-Inspection",       60.0, "Zeiss",         2022, 5, "line-a-station-5",
        "Line-B", 1, "Blanking-Press",        8.0, "Schuler",       2015, 5, "line-b-station-1",
        "Line-B", 2, "Hydraulic-Press",      12.0, "Schuler",       2016, 5, "line-b-station-2",
        "Line-B", 3, "Trimming-Station",     10.0, "Trumpf",        2017, 5, "line-b-station-3",
        "Line-B", 4, "Quality-Inspection",   20.0, "Keyence",       2020, 5, "line-b-station-4",
        "Line-C", 1, "Component-Loader",     10.0, "FANUC",         2019, 5, "line-c-station-1",
        "Line-C", 2, "Welding-Robot",        25.0, "ABB",           2019, 5, "line-c-station-2",
        "Line-C", 3, "Weld-Inspection",      30.0, "Yaskawa",       2020, 5, "line-c-station-3",
        "Line-C", 4, "Fastening-Station",    15.0, "Atlas Copco",   2021, 5, "line-c-station-4",
        "Line-C", 5, "Assembly-Robot",       20.0, "FANUC",         2021, 5, "line-c-station-5",
        "Line-C", 6, "Leak-Test",            25.0, "ATEQ",          2022, 5, "line-c-station-6",
        "Line-D", 1, "Surface-Prep",         20.0, "Wheelabrator",  2017, 5, "line-d-station-1",
        "Line-D", 2, "Chemical-Wash",        30.0, "Dürr",          2017, 5, "line-d-station-2",
        "Line-D", 3, "Primer-Application",   25.0, "Graco",         2018, 5, "line-d-station-3",
        "Line-D", 4, "Paint-Booth",          40.0, "Dürr",          2018, 5, "line-d-station-4",
        "Line-D", 5, "Curing-Oven",          90.0, "Ipsen",         2016, 5, "line-d-station-5",
        "Line-D", 6, "Coating-Inspection",   15.0, "Keyence",       2021, 5, "line-d-station-6",
        "Line-D", 7, "Final-Packaging",      10.0, "Bosch-Rexroth", 2020, 5, "line-d-station-7",
        "Line-E", 1, "PCB-Loader",            5.0, "JUKI",          2021, 5, "line-e-station-1",
        "Line-E", 2, "SMT-Placement",        15.0, "JUKI",          2021, 5, "line-e-station-2",
        "Line-E", 3, "Reflow-Oven",          45.0, "Heller",        2020, 5, "line-e-station-3",
        "Line-E", 4, "AOI-Inspection",       10.0, "Koh Young",     2022, 5, "line-e-station-4",
        "Line-E", 5, "Through-Hole-Insert",  20.0, "Universal",     2019, 5, "line-e-station-5",
        "Line-E", 6, "Wave-Solder",          35.0, "ERSA",          2019, 5, "line-e-station-6",
        "Line-E", 7, "Functional-Test",      30.0, "National Instruments", 2020, 5, "line-e-station-7",
        "Line-E", 8, "Conformal-Coat",       25.0, "Nordson",       2022, 5, "line-e-station-8",
    ]
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_STATION_MASTER" "StationMaster reference data"

# --- Reference data: ProductionSchedule ---
read -r -d '' _PROD_SCHED <<'KQLEOF' || true
.set-or-replace ProductionSchedule <|
    datatable(line_id: string, shift: string, planned_parts: long)
    [
        "Line-A", "Day",    120,
        "Line-A", "Night",  100,
        "Line-B", "Day",    500,
        "Line-B", "Night",  450,
        "Line-C", "Day",    200,
        "Line-C", "Night",  180,
        "Line-D", "Day",    150,
        "Line-D", "Night",  130,
        "Line-E", "Day",    180,
        "Line-E", "Night",  150,
    ]
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_PROD_SCHED" "ProductionSchedule reference data"

# --- Reference data: ShiftMaster (Shift dimension) ---
# Mirrors the Day/Night window used by EnrichMachineEvents (Day = hours 6–18).
read -r -d '' _SHIFT_MASTER <<'KQLEOF' || true
.set-or-replace ShiftMaster <|
    datatable(shift:string, start_hour:int, end_hour:int)
    [
        "Day",    6, 18,
        "Night", 18,  6,
    ]
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_SHIFT_MASTER" "ShiftMaster reference data"

# --- Reference data: MachineTypeMaster (MachineType dimension) ---
# One row per distinct StationMaster.machine_type, with a category rollup that
# compresses the 30 machine types into 6 process families for cross-line rollups.
read -r -d '' _MACHINE_TYPE_MASTER <<'KQLEOF' || true
.set-or-replace MachineTypeMaster <|
    datatable(machine_type:string, category:string)
    [
        "CNC-Lathe",            "Machining",
        "CNC-Mill",             "Machining",
        "Surface-Grinder",      "Machining",
        "Deburring-Station",    "Machining",
        "Blanking-Press",       "Forming",
        "Hydraulic-Press",      "Forming",
        "Trimming-Station",     "Forming",
        "Component-Loader",     "Joining",
        "Welding-Robot",        "Joining",
        "Fastening-Station",    "Joining",
        "Assembly-Robot",       "Joining",
        "Surface-Prep",         "Surface",
        "Chemical-Wash",        "Surface",
        "Primer-Application",   "Surface",
        "Paint-Booth",          "Surface",
        "Curing-Oven",          "Surface",
        "Final-Packaging",      "Surface",
        "PCB-Loader",           "Electronics",
        "SMT-Placement",        "Electronics",
        "Reflow-Oven",          "Electronics",
        "Through-Hole-Insert",  "Electronics",
        "Wave-Solder",          "Electronics",
        "Conformal-Coat",       "Electronics",
        "CMM-Inspection",       "Inspection",
        "Quality-Inspection",   "Inspection",
        "Weld-Inspection",      "Inspection",
        "Coating-Inspection",   "Inspection",
        "AOI-Inspection",       "Inspection",
        "Functional-Test",      "Inspection",
        "Leak-Test",            "Inspection",
    ]
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_MACHINE_TYPE_MASTER" "MachineTypeMaster reference data"

# --- Reference data: IssueTypeMaster (IssueType dimension) ---
# Every issue_type emitted by the simulator's MaintenanceEvents, grouped into 6
# engineering fault categories so the agent can roll ~77 fault codes up by theme.
read -r -d '' _ISSUE_TYPE_MASTER <<'KQLEOF' || true
.set-or-replace IssueTypeMaster <|
    datatable(issue_type:string, category:string)
    [
        "Bearing-Wear",          "Mechanical-Wear",
        "Tool-Break",            "Mechanical-Wear",
        "Spindle-Vibration",     "Mechanical-Wear",
        "Tool-Wear",             "Mechanical-Wear",
        "Wheel-Wear",            "Mechanical-Wear",
        "Brush-Wear",            "Mechanical-Wear",
        "Die-Wear",              "Mechanical-Wear",
        "Blade-Dull",            "Mechanical-Wear",
        "Tip-Wear",              "Mechanical-Wear",
        "Torque-Drift",          "Mechanical-Wear",
        "Bit-Break",             "Mechanical-Wear",
        "Gripper-Fail",          "Mechanical-Wear",
        "Seal-Wear",             "Mechanical-Wear",
        "Abrasive-Wear",         "Mechanical-Wear",
        "Door-Seal-Worn",        "Mechanical-Wear",
        "Clinch-Fail",           "Mechanical-Wear",
        "Fixture-Fault",         "Mechanical-Wear",
        "Probe-Wear",            "Mechanical-Wear",
        "Chuck-Jam",             "Jam-Feed",
        "Jam",                   "Jam-Feed",
        "Feed-Jam",              "Jam-Feed",
        "Hopper-Empty",          "Jam-Feed",
        "Wire-Feed-Jam",         "Jam-Feed",
        "Film-Jam",              "Jam-Feed",
        "Feeder-Jam",            "Jam-Feed",
        "Dust-Overload",         "Jam-Feed",
        "Conveyor-Jam",          "Jam-Feed",
        "Film-Feed-Error",       "Jam-Feed",
        "Magazine-Empty",        "Jam-Feed",
        "Conveyor-Slip",         "Jam-Feed",
        "Lead-Bend",             "Jam-Feed",
        "Insertion-Miss",        "Jam-Feed",
        "Coolant-Leak",          "Fluid-Pressure",
        "Coolant-Clog",          "Fluid-Pressure",
        "Air-Supply",            "Fluid-Pressure",
        "Pressure-Loss",         "Fluid-Pressure",
        "Seal-Failure",          "Fluid-Pressure",
        "Valve-Fault",           "Fluid-Pressure",
        "Gas-Flow-Low",          "Fluid-Pressure",
        "Valve-Stuck",           "Fluid-Pressure",
        "Solution-Low",          "Fluid-Pressure",
        "Pump-Fail",             "Fluid-Pressure",
        "Nozzle-Clog",           "Fluid-Pressure",
        "Pressure-Drop",         "Fluid-Pressure",
        "Viscosity-Off",         "Fluid-Pressure",
        "Air-Filter-Saturated",  "Fluid-Pressure",
        "Paint-Viscosity-Drift", "Fluid-Pressure",
        "Flux-Low",              "Fluid-Pressure",
        "Motor-Overheat",        "Thermal",
        "Temp-Drift",            "Thermal",
        "Thermocouple-Drift",    "Thermal",
        "Element-Burnout",       "Thermal",
        "Seal-Bar-Temp",         "Thermal",
        "Element-Fail",          "Thermal",
        "Solder-Temp-Drift",     "Thermal",
        "Alignment-Drift",       "Sensor-Vision-Calibration",
        "Probe-Calibration",     "Sensor-Vision-Calibration",
        "Sensor-Fail",           "Sensor-Vision-Calibration",
        "Alignment-Fault",       "Sensor-Vision-Calibration",
        "Alignment-Shift",       "Sensor-Vision-Calibration",
        "Camera-Fault",          "Sensor-Vision-Calibration",
        "Sensor-Drift",          "Sensor-Vision-Calibration",
        "Light-Failure",         "Sensor-Vision-Calibration",
        "Sensor-Block",          "Sensor-Vision-Calibration",
        "Calibration",           "Sensor-Vision-Calibration",
        "Joint-Calibration",     "Sensor-Vision-Calibration",
        "Encoder-Fault",         "Sensor-Vision-Calibration",
        "Pressure-Sensor",       "Sensor-Vision-Calibration",
        "Light-Fail",            "Sensor-Vision-Calibration",
        "Vision-Fail",           "Sensor-Vision-Calibration",
        "Calibration-Drift",     "Sensor-Vision-Calibration",
        "Guard-Trip",            "Electrical-Other",
        "X-Ray-Tube-Fault",      "Electrical-Other",
        "Motor-Fault",           "Electrical-Other",
        "Conveyor-Speed-Fault",  "Electrical-Other",
        "Power-Supply-Fail",     "Electrical-Other",
        "UV-Lamp-Fail",          "Electrical-Other",
    ]
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_ISSUE_TYPE_MASTER" "IssueTypeMaster reference data"

# --- Reference data: TechnicianMaster (Technician dimension) ---
# The 8 maintenance technician IDs the simulator assigns to MaintenanceEvents.
read -r -d '' _TECHNICIAN_MASTER <<'KQLEOF' || true
.set-or-replace TechnicianMaster <|
    datatable(technician_id:string, name:string)
    [
        "T001", "Alex Reyes",
        "T002", "Priya Nair",
        "T003", "Marco Bianchi",
        "T004", "Sofia Lindgren",
        "T005", "Chen Wei",
        "T006", "Jordan Blake",
        "T007", "Amara Okafor",
        "T008", "Diego Santos",
    ]
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_TECHNICIAN_MASTER" "TechnicianMaster reference data"

# --- Reference data: SopMaster (SOP dimension) ---
# One row per station-scoped knowledge doc under knowledge/source/Line-X_NN_*.md.
# file_name is the PDF blob indexed by Azure AI Search (scripts/5-setup-aisearch.sh),
# giving the agent a stable key to retrieve full SOP text after a graph lookup.
read -r -d '' _SOP_MASTER <<'KQLEOF' || true
.set-or-replace SopMaster <|
    datatable(sop_id:string, line_id:string, station_position:int, machine_type:string, doc_type:string, title:string, file_name:string)
    [
        "Line-A_01_CNC-Lathe_SOP",            "Line-A", 1, "CNC-Lathe",           "SOP",             "CNC-Lathe SOP",                  "Line-A_01_CNC-Lathe_SOP.pdf",
        "Line-A_02_CNC-Mill_SOP",             "Line-A", 2, "CNC-Mill",            "SOP",             "CNC-Mill SOP",                   "Line-A_02_CNC-Mill_SOP.pdf",
        "Line-A_03_Surface-Grinder_SOP",      "Line-A", 3, "Surface-Grinder",     "SOP",             "Surface-Grinder SOP",            "Line-A_03_Surface-Grinder_SOP.pdf",
        "Line-A_04_Deburring-Station_SOP",    "Line-A", 4, "Deburring-Station",   "SOP",             "Deburring-Station SOP",          "Line-A_04_Deburring-Station_SOP.pdf",
        "Line-A_05_CMM-Inspection_Calibration","Line-A",5, "CMM-Inspection",      "Calibration",     "CMM-Inspection Calibration",     "Line-A_05_CMM-Inspection_Calibration.pdf",
        "Line-B_01_Blanking-Press_SOP",       "Line-B", 1, "Blanking-Press",      "SOP",             "Blanking-Press SOP",             "Line-B_01_Blanking-Press_SOP.pdf",
        "Line-B_02_Hydraulic-Press_Maintenance_SOP","Line-B",2,"Hydraulic-Press", "Maintenance SOP", "Hydraulic-Press Maintenance SOP","Line-B_02_Hydraulic-Press_Maintenance_SOP.pdf",
        "Line-B_03_Trimming-Station_SOP",     "Line-B", 3, "Trimming-Station",    "SOP",             "Trimming-Station SOP",           "Line-B_03_Trimming-Station_SOP.pdf",
        "Line-B_04_Quality-Inspection_SOP",   "Line-B", 4, "Quality-Inspection",  "SOP",             "Quality-Inspection SOP",         "Line-B_04_Quality-Inspection_SOP.pdf",
        "Line-C_01_Component-Loader_SOP",     "Line-C", 1, "Component-Loader",    "SOP",             "Component-Loader SOP",           "Line-C_01_Component-Loader_SOP.pdf",
        "Line-C_02_Welding-Robot_SOP",        "Line-C", 2, "Welding-Robot",       "SOP",             "Welding-Robot SOP",              "Line-C_02_Welding-Robot_SOP.pdf",
        "Line-C_03_Weld-Inspection_NDT",      "Line-C", 3, "Weld-Inspection",     "NDT",             "Weld-Inspection NDT",            "Line-C_03_Weld-Inspection_NDT.pdf",
        "Line-C_04_Fastening-Station_SOP",    "Line-C", 4, "Fastening-Station",   "SOP",             "Fastening-Station SOP",          "Line-C_04_Fastening-Station_SOP.pdf",
        "Line-C_05_Assembly-Robot_SOP",       "Line-C", 5, "Assembly-Robot",      "SOP",             "Assembly-Robot SOP",             "Line-C_05_Assembly-Robot_SOP.pdf",
        "Line-C_06_Leak-Test_SOP",            "Line-C", 6, "Leak-Test",           "SOP",             "Leak-Test SOP",                  "Line-C_06_Leak-Test_SOP.pdf",
        "Line-D_01_Surface-Prep_SOP",         "Line-D", 1, "Surface-Prep",        "SOP",             "Surface-Prep SOP",               "Line-D_01_Surface-Prep_SOP.pdf",
        "Line-D_02_Chemical-Wash_SOP",        "Line-D", 2, "Chemical-Wash",       "SOP",             "Chemical-Wash SOP",              "Line-D_02_Chemical-Wash_SOP.pdf",
        "Line-D_03_Primer-Application_SOP",   "Line-D", 3, "Primer-Application",  "SOP",             "Primer-Application SOP",         "Line-D_03_Primer-Application_SOP.pdf",
        "Line-D_04_Paint-Booth_SOP",          "Line-D", 4, "Paint-Booth",         "SOP",             "Paint-Booth SOP",                "Line-D_04_Paint-Booth_SOP.pdf",
        "Line-D_05_Curing-Oven_SOP",          "Line-D", 5, "Curing-Oven",         "SOP",             "Curing-Oven SOP",                "Line-D_05_Curing-Oven_SOP.pdf",
        "Line-D_06_Coating-Inspection_SOP",   "Line-D", 6, "Coating-Inspection",  "SOP",             "Coating-Inspection SOP",         "Line-D_06_Coating-Inspection_SOP.pdf",
        "Line-D_07_Final-Packaging_SOP",      "Line-D", 7, "Final-Packaging",     "SOP",             "Final-Packaging SOP",            "Line-D_07_Final-Packaging_SOP.pdf",
        "Line-E_01_PCB-Loader_SOP",           "Line-E", 1, "PCB-Loader",          "SOP",             "PCB-Loader SOP",                 "Line-E_01_PCB-Loader_SOP.pdf",
        "Line-E_02_SMT-Placement_SOP",        "Line-E", 2, "SMT-Placement",       "SOP",             "SMT-Placement SOP",              "Line-E_02_SMT-Placement_SOP.pdf",
        "Line-E_03_Reflow-Oven_SOP",          "Line-E", 3, "Reflow-Oven",         "SOP",             "Reflow-Oven SOP",                "Line-E_03_Reflow-Oven_SOP.pdf",
        "Line-E_04_AOI-Inspection_SOP",       "Line-E", 4, "AOI-Inspection",      "SOP",             "AOI-Inspection SOP",             "Line-E_04_AOI-Inspection_SOP.pdf",
        "Line-E_05_Through-Hole-Insert_SOP",  "Line-E", 5, "Through-Hole-Insert", "SOP",             "Through-Hole-Insert SOP",        "Line-E_05_Through-Hole-Insert_SOP.pdf",
        "Line-E_06_Wave-Solder_Troubleshooting","Line-E",6,"Wave-Solder",         "Troubleshooting", "Wave-Solder Troubleshooting",    "Line-E_06_Wave-Solder_Troubleshooting.pdf",
        "Line-E_07_Functional-Test_SOP",      "Line-E", 7, "Functional-Test",     "SOP",             "Functional-Test SOP",            "Line-E_07_Functional-Test_SOP.pdf",
        "Line-E_08_Conformal-Coat_SOP",       "Line-E", 8, "Conformal-Coat",      "SOP",             "Conformal-Coat SOP",             "Line-E_08_Conformal-Coat_SOP.pdf",
    ]
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_SOP_MASTER" "SopMaster reference data"

# --- Reference data: PolicyMaster (Policy dimension) ---
# Plant-wide knowledge docs under knowledge/source/ that are not station-scoped.
# file_name is the PDF blob indexed by Azure AI Search for full-text retrieval.
read -r -d '' _POLICY_MASTER <<'KQLEOF' || true
.set-or-replace PolicyMaster <|
    datatable(policy_id:string, scope:string, doc_type:string, title:string, file_name:string)
    [
        "Maintenance_Workflow_Overview",    "Global", "Workflow",  "Maintenance Workflow Overview",     "Maintenance_Workflow_Overview.pdf",
        "OEE_Targets_and_Escalation",       "Global", "Policy",    "OEE Targets and Escalation",        "OEE_Targets_and_Escalation.pdf",
        "Production_Lines_Reference",       "Global", "Reference", "Production Lines Reference",         "Production_Lines_Reference.pdf",
        "Quality_Reject_Disposition_Policy","Global", "Policy",    "Quality Reject Disposition Policy", "Quality_Reject_Disposition_Policy.pdf",
        "Safety_Lockout_Tagout_Procedure",  "Global", "Procedure", "Safety Lockout/Tagout Procedure",   "Safety_Lockout_Tagout_Procedure.pdf",
        "Shift_Handover_Checklist",         "Global", "Checklist", "Shift Handover Checklist",          "Shift_Handover_Checklist.pdf",
    ]
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_POLICY_MASTER" "PolicyMaster reference data"

# --- Drop legacy OEE_5min materialized view (replaced by Silver enrichment) ---
kusto_run "$CLUSTER_URI" "$DB_NAME" \
  '.drop materialized-view OEE_5min ifexists' \
  "drop legacy OEE_5min materialized view (if present)" "true" \
  || ok "OEE_5min materialized view absent"

# --- Silver: enriched event tables ---
# Bronze _Raw tables are auto-enriched into these via KQL update policies
# (defined below). The Silver tables add numeric proxy columns the Fabric
# Data Agent can aggregate via TimeSeriesSelector (Sum/Avg/Min/Max/Count of a
# single column), letting the agent compose OEE as:
#   Availability = Avg(is_running)
#   Performance  = Avg(performance_ratio) over running rows
#   Quality      = Avg(is_pass) over completed PartEvents
# Dashboard panels query these same Silver names — no panel changes required.

kusto_run "$CLUSTER_URI" "$DB_NAME" \
  '.create-merge table MachineEvents (event_type:string, device_id:string, machine_type:string, machine_status:string, idle_reason:string, line_id:string, station_position:int, actual_cycle_time:real, input_buffer_count:int, output_buffer_count:int, buffer_capacity:int, total_parts_processed:long, rejected_parts:long, current_part_id:string, timestamp:datetime, is_running:long, is_fault:long, is_maintenance:long, is_idle:long, shift_id:string, root_cause_device_id:string)' \
  "MachineEvents (Silver) table"

kusto_run "$CLUSTER_URI" "$DB_NAME" \
  '.create-merge table PartEvents (event_type:string, part_id:string, line_id:string, station_position:int, machine_type:string, action:string, cycle_time:real, quality_pass:bool, timestamp:datetime, is_pass:long, is_completed:long, is_rejected:long, shift_id:string)' \
  "PartEvents (Silver) table"

kusto_run "$CLUSTER_URI" "$DB_NAME" \
  '.create-merge table MaintenanceEvents (event_type:string, work_order_id:string, device_id:string, machine_type:string, line_id:string, station_position:int, issue_type:string, action:string, technician_id:string, timestamp:datetime, shift_id:string)' \
  "MaintenanceEvents (Silver) table"

# --- Enrichment functions (Bronze _Raw → Silver shape) ---

# NOTE: Fabric Eventhouse update policies reject queries that use `lookup`/`join`
# against other tables. So enrichment that depends on StationMaster
# (ideal_cycle_time, performance_ratio) is deferred to query time via the
# MachineEventsEnriched() view function below. To avoid an ambiguous join
# (KQL would keep the left-side null column and rename the right), these
# fields are NOT stored on the Silver MachineEvents table.
read -r -d '' _ENRICH_ME <<'KQLEOF' || true
.create-or-alter function EnrichMachineEvents() {
    MachineEvents_Raw
    | extend
        is_running     = iff(machine_status == "Running", 1, 0),
        is_fault       = iff(machine_status == "Fault", 1, 0),
        is_maintenance = iff(machine_status == "Maintenance", 1, 0),
        is_idle        = iff(machine_status == "Idle", 1, 0),
        shift_id       = iff(hourofday(timestamp) >= 6 and hourofday(timestamp) < 18, "Day", "Night"),
        root_cause_device_id = case(
            idle_reason == "Starved" and station_position > 1,
                strcat(tolower(line_id), "-station-", tostring(station_position - 1)),
            idle_reason == "Blocked",
                strcat(tolower(line_id), "-station-", tostring(station_position + 1)),
            "")
    | project event_type, device_id, machine_type, machine_status, idle_reason,
              line_id, station_position, actual_cycle_time, input_buffer_count,
              output_buffer_count, buffer_capacity, total_parts_processed,
              rejected_parts, current_part_id, timestamp,
              is_running, is_fault, is_maintenance, is_idle,
              shift_id, root_cause_device_id
}
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_ENRICH_ME" "EnrichMachineEvents function"

# Query-time view: backfills ideal_cycle_time and performance_ratio from
# StationMaster reference data. Use this in dashboards / Data Agent prompts
# whenever performance_ratio or ideal_cycle_time is needed.
read -r -d '' _ME_VIEW <<'KQLEOF' || true
.create-or-alter function MachineEventsEnriched() {
    MachineEvents
    | lookup kind=leftouter StationMaster on line_id, station_position
    | extend performance_ratio = iff(machine_status == "Running" and actual_cycle_time > 0,
                                     min_of(1.0, ideal_cycle_time / actual_cycle_time),
                                     real(null))
}
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_ME_VIEW" "MachineEventsEnriched view function"

read -r -d '' _ENRICH_PE <<'KQLEOF' || true
.create-or-alter function EnrichPartEvents() {
    PartEvents_Raw
    | extend
        is_pass      = iff(quality_pass, 1, 0),
        is_completed = iff(action == "completed", 1, 0),
        is_rejected  = iff(action == "rejected", 1, 0),
        shift_id     = iff(hourofday(timestamp) >= 6 and hourofday(timestamp) < 18, "Day", "Night")
    | project event_type, part_id, line_id, station_position, machine_type,
              action, cycle_time, quality_pass, timestamp,
              is_pass, is_completed, is_rejected, shift_id
}
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_ENRICH_PE" "EnrichPartEvents function"

read -r -d '' _ENRICH_MAI <<'KQLEOF' || true
.create-or-alter function EnrichMaintenanceEvents() {
    MaintenanceEvents_Raw
    | extend
        shift_id = iff(hourofday(timestamp) >= 6 and hourofday(timestamp) < 18, "Day", "Night")
    | project event_type, work_order_id, device_id, machine_type, line_id,
              station_position, issue_type, action, technician_id, timestamp, shift_id
}
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_ENRICH_MAI" "EnrichMaintenanceEvents function"

# --- Update policies (auto-flow Bronze _Raw → Silver enriched on ingest) ---

read -r -d '' _ME_UPD <<'KQLEOF' || true
.alter table MachineEvents policy update @'[{"IsEnabled":true,"Source":"MachineEvents_Raw","Query":"EnrichMachineEvents()","IsTransactional":true,"PropagateIngestionProperties":true}]'
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_ME_UPD" "MachineEvents update policy"

read -r -d '' _PE_UPD <<'KQLEOF' || true
.alter table PartEvents policy update @'[{"IsEnabled":true,"Source":"PartEvents_Raw","Query":"EnrichPartEvents()","IsTransactional":true,"PropagateIngestionProperties":true}]'
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_PE_UPD" "PartEvents update policy"

read -r -d '' _MAI_UPD <<'KQLEOF' || true
.alter table MaintenanceEvents policy update @'[{"IsEnabled":true,"Source":"MaintenanceEvents_Raw","Query":"EnrichMaintenanceEvents()","IsTransactional":true,"PropagateIngestionProperties":true}]'
KQLEOF
kusto_run "$CLUSTER_URI" "$DB_NAME" "$_MAI_UPD" "MaintenanceEvents update policy"

# --- OneLake availability on Silver (so the ontology binds to Delta) ---
# Bronze tables stay in-engine only — no need to mirror raw landing data.

kusto_run "$CLUSTER_URI" "$DB_NAME" \
  '.alter-merge table MachineEvents policy mirroring dataformat=parquet with (IsEnabled=true, TargetLatencyInMinutes=5)' \
  "MachineEvents OneLake mirroring (5-min latency)"

kusto_run "$CLUSTER_URI" "$DB_NAME" \
  '.alter-merge table PartEvents policy mirroring dataformat=parquet with (IsEnabled=true, TargetLatencyInMinutes=5)' \
  "PartEvents OneLake mirroring (5-min latency)"

kusto_run "$CLUSTER_URI" "$DB_NAME" \
  '.alter-merge table MaintenanceEvents policy mirroring dataformat=parquet with (IsEnabled=true, TargetLatencyInMinutes=5)' \
  "MaintenanceEvents OneLake mirroring (5-min latency)"

# --- OneLake availability on the reference/master dimensions -------------------
# The ontology binds every dimension entity to a LakehouseTable in ManufacturingLH
# (schema dbo). For that binding to resolve, each master table must (1) be mirrored
# to OneLake as Delta here, AND (2) be exposed in ManufacturingLH as a shortcut at
# Tables/dbo/<Table> whose OneLake target is this KQL database (itemId=$DB_ID,
# path Tables/<Table>). Without BOTH, the entity publishes but has no data source
# (Fabric does not validate bindings at publish time), so the graph node stays
# empty. Mirroring is enabled here; the matching shortcuts are created in the
# lakehouse-provisioning step below.
#
# CRITICAL: these master tables are populated by .set-or-replace ABOVE, i.e.
# BEFORE mirroring is enabled. A mirroring policy defaults to Backfill=false,
# which exports only data ingested AFTER the policy is set — so static tables
# would mirror an EMPTY delta and the lakehouse/ontology would show no rows.
# Backfill=true forces a one-time export of all existing rows. (The streaming
# event tables above don't need it: new telemetry arrives continuously after
# the policy is set.)
REF_TABLES=(
  LineMaster StationMaster ProductionSchedule
  ShiftMaster MachineTypeMaster IssueTypeMaster
  TechnicianMaster SopMaster PolicyMaster
)
for _t in "${REF_TABLES[@]}"; do
  kusto_run "$CLUSTER_URI" "$DB_NAME" \
    ".alter-merge table ${_t} policy mirroring dataformat=parquet with (IsEnabled=true, Backfill=true, TargetLatencyInMinutes=5)" \
    "${_t} OneLake mirroring (with backfill)" true
done

# --- Lakehouse shortcuts for every OneLake-available table --------------------
# ManufacturingLH/Tables/dbo/<Table> → OneLake target (KQL DB $DB_ID, Tables/<Table>).
# Idempotent: shortcutConflictPolicy=CreateOrOverwrite refreshes existing shortcuts.
# Newly mirrored Delta tables can take a few seconds to appear in OneLake, so retry
# each shortcut briefly and warn if it still is not available.
[[ -z "${LH_ID:-}" ]] && die "Lakehouse '$LH_NAME' is required for ontology shortcuts."
SHORTCUT_TABLES=(
  MachineEvents PartEvents MaintenanceEvents
  LineMaster StationMaster ProductionSchedule
  ShiftMaster MachineTypeMaster IssueTypeMaster
  TechnicianMaster SopMaster PolicyMaster
)
for _t in "${SHORTCUT_TABLES[@]}"; do
  _body=$(jq -n --arg name "$_t" --arg ws "$WS_ID" --arg db "$DB_ID" \
    '{path:"Tables/dbo",name:$name,target:{oneLake:{workspaceId:$ws,itemId:$db,path:("Tables/"+$name)}}}')
  _shortcut_created=false
  for _try in 1 2 3 4 5; do
    if fabric_post_status "workspaces/$WS_ID/items/$LH_ID/shortcuts?shortcutConflictPolicy=CreateOrOverwrite" \
      "$_body"; then
      ok "Shortcut Tables/dbo/${_t}"
      _shortcut_created=true
      break
    fi
    sleep 15
  done
  [[ "$_shortcut_created" == true ]] || \
    warn "Shortcut Tables/dbo/${_t} not created yet — enable OneLake availability and re-run before publishing the ontology."
done

# ── Step 3: Eventstream ───────────────────────────────────────────────────────
step "Step 3 — Creating Eventstream (manufacturing-telemetry)"
ES_NAME="manufacturing-telemetry"
ES_LIST=$(fabric_get "workspaces/$WS_ID/eventstreams") \
  || die "Failed to list eventstreams"
ES_ID=$(echo "$ES_LIST" | jq -r --arg n "$ES_NAME" \
  '.value[] | select(.displayName == $n) | .id' | head -1 || true)

if [[ -n "$ES_ID" ]]; then
  ok "Eventstream already exists (id=$ES_ID)"
else
  STREAM="manufacturing-telemetry-stream"

  # Stream column schema — superset of all fields the simulator emits
  STREAM_COLS=$(jq -n '[
    {"name":"event_type",           "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"device_id",            "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"machine_type",         "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"machine_status",       "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"idle_reason",          "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"line_id",              "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"station_position",     "type":"BigInt",        "fields":null,"items":null},
    {"name":"actual_cycle_time",    "type":"Float",         "fields":null,"items":null},
    {"name":"input_buffer_count",   "type":"BigInt",        "fields":null,"items":null},
    {"name":"output_buffer_count",  "type":"BigInt",        "fields":null,"items":null},
    {"name":"buffer_capacity",      "type":"BigInt",        "fields":null,"items":null},
    {"name":"total_parts_processed","type":"BigInt",        "fields":null,"items":null},
    {"name":"rejected_parts",       "type":"BigInt",        "fields":null,"items":null},
    {"name":"current_part_id",      "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"part_id",              "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"action",               "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"cycle_time",           "type":"Float",         "fields":null,"items":null},
    {"name":"quality_pass",         "type":"Bit",           "fields":null,"items":null},
    {"name":"work_order_id",        "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"issue_type",           "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"technician_id",        "type":"Nvarchar(max)", "fields":null,"items":null},
    {"name":"timestamp",            "type":"DateTime",      "fields":null,"items":null}
  ]')

  read -r -d '' MACH_SQL <<SQLEOF || true
SELECT
    event_type,
    device_id,
    machine_type,
    machine_status,
    idle_reason,
    line_id,
    CAST(station_position AS BIGINT)    AS station_position,
    actual_cycle_time,
    CAST(input_buffer_count AS BIGINT)  AS input_buffer_count,
    CAST(output_buffer_count AS BIGINT) AS output_buffer_count,
    CAST(buffer_capacity AS BIGINT)     AS buffer_capacity,
    CAST(total_parts_processed AS BIGINT) AS total_parts_processed,
    CAST(rejected_parts AS BIGINT)      AS rejected_parts,
    current_part_id,
    [timestamp]
INTO [MachineEvents_Raw]
FROM [${STREAM}]
WHERE event_type = 'machine_telemetry'
SQLEOF

  read -r -d '' PART_SQL <<SQLEOF || true
SELECT
    event_type,
    part_id,
    line_id,
    CAST(station_position AS BIGINT) AS station_position,
    machine_type,
    action,
    cycle_time,
    quality_pass,
    [timestamp]
INTO [PartEvents_Raw]
FROM [${STREAM}]
WHERE event_type = 'part_event'
SQLEOF

  read -r -d '' MAINT_SQL <<SQLEOF || true
SELECT
    event_type,
    work_order_id,
    device_id,
    machine_type,
    line_id,
    CAST(station_position AS BIGINT) AS station_position,
    issue_type,
    action,
    technician_id,
    [timestamp]
INTO [MaintenanceEvents_Raw]
FROM [${STREAM}]
WHERE event_type = 'maintenance_event'
SQLEOF

  TOPOLOGY=$(jq -n \
    --arg stream    "$STREAM" \
    --arg ws_id     "$WS_ID" \
    --arg db_id     "$DB_ID" \
    --arg db_name   "$DB_NAME" \
    --argjson cols  "$STREAM_COLS" \
    --arg mach_sql  "$MACH_SQL" \
    --arg part_sql  "$PART_SQL" \
    --arg maint_sql "$MAINT_SQL" \
    '{
      sources: [{name:"oee-simulator",type:"CustomEndpoint",properties:{}}],
      streams: [{
        name: $stream, type: "DefaultStream", properties: {},
        inputNodes: [{name:"oee-simulator"}]
      }],
      operators: [
        {
          name: "MachineTelemetryFilter", type: "SQL",
          inputNodes: [{name:$stream}],
          properties: {query:$mach_sql, advancedSettings:null},
          inputSchemas: [{name:$stream, schema:{columns:$cols}}]
        },
        {
          name: "PartEventFilter", type: "SQL",
          inputNodes: [{name:$stream}],
          properties: {query:$part_sql, advancedSettings:null},
          inputSchemas: [{name:$stream, schema:{columns:$cols}}]
        },
        {
          name: "MaintenanceEventFilter", type: "SQL",
          inputNodes: [{name:$stream}],
          properties: {query:$maint_sql, advancedSettings:null},
          inputSchemas: [{name:$stream, schema:{columns:$cols}}]
        }
      ],
      destinations: [
        {
          name: "MachineEvents_Raw", type: "Eventhouse",
          properties: {
            dataIngestionMode: "ProcessedIngestion",
            workspaceId: $ws_id, itemId: $db_id, databaseName: $db_name,
            tableName: "MachineEvents_Raw",
            inputSerialization: {type:"Json",properties:{encoding:"UTF8"}}
          },
          inputNodes: [{name:"MachineTelemetryFilter"}],
          inputSchemas: [{name:"MachineTelemetryFilter",schema:{columns:[]}}]
        },
        {
          name: "PartEvents_Raw", type: "Eventhouse",
          properties: {
            dataIngestionMode: "ProcessedIngestion",
            workspaceId: $ws_id, itemId: $db_id, databaseName: $db_name,
            tableName: "PartEvents_Raw",
            inputSerialization: {type:"Json",properties:{encoding:"UTF8"}}
          },
          inputNodes: [{name:"PartEventFilter"}],
          inputSchemas: [{name:"PartEventFilter",schema:{columns:[]}}]
        },
        {
          name: "MaintenanceEvents_Raw", type: "Eventhouse",
          properties: {
            dataIngestionMode: "ProcessedIngestion",
            workspaceId: $ws_id, itemId: $db_id, databaseName: $db_name,
            tableName: "MaintenanceEvents_Raw",
            inputSerialization: {type:"Json",properties:{encoding:"UTF8"}}
          },
          inputNodes: [{name:"MaintenanceEventFilter"}],
          inputSchemas: [{name:"MaintenanceEventFilter",schema:{columns:[]}}]
        }
      ],
      compatibilityLevel: "1.1"
    }')

  TOPO_B64=$(b64 "$TOPOLOGY")

  PLATFORM_JSON=$(jq -n \
    --arg name "$ES_NAME" \
    '{
      "$schema": "https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json",
      "metadata": {
        "type": "Eventstream",
        "displayName": $name
      },
      "config": {
        "version": "2.0",
        "logicalId": "00000000-0000-0000-0000-000000000000"
      }
    }')
  PLATFORM_B64=$(b64 "$PLATFORM_JSON")

  ES_PAYLOAD=$(jq -n \
    --arg name "$ES_NAME" \
    --arg topo "$TOPO_B64" \
    --arg plat "$PLATFORM_B64" \
    '{displayName:$name,type:"Eventstream",definition:{parts:[
      {path:"eventstream.json",payload:$topo,payloadType:"InlineBase64"},
      {path:".platform",payload:$plat,payloadType:"InlineBase64"}
    ]}}')

  fabric_post "workspaces/$WS_ID/items" "$ES_PAYLOAD" >/dev/null
  ES_JSON=$(wait_for_item "workspaces/$WS_ID/eventstreams" "$ES_NAME")
  ES_ID=$(echo "$ES_JSON" | jq -r '.id')
  ok "Eventstream created (id=$ES_ID)"

  # Activate
  step "Step 3b — Publishing Eventstream"
  sleep 15

  ES_DEF=$(az rest --method POST \
    --uri "${FABRIC_API}/workspaces/$WS_ID/eventstreams/$ES_ID/getDefinition" \
    --resource "$FABRIC_RESOURCE" \
    --output json 2>/dev/null || true)

  if [[ -n "$ES_DEF" && "$ES_DEF" != "{}" ]]; then
    UPDATE_BODY=$(echo "$ES_DEF" | jq -c '{definition: .definition}')
    _utmp=$(_win_tmpfile "$UPDATE_BODY")
    _uwin=$(_winpath "$_utmp")
    az rest --method POST \
      --uri "${FABRIC_API}/workspaces/$WS_ID/eventstreams/$ES_ID/updateDefinition" \
      --resource "$FABRIC_RESOURCE" \
      --headers "Content-Type=application/json" \
      --body "@${_uwin}" \
      --output none 2>/dev/null || true
    rm -f "$_utmp"
    ok "Eventstream published via updateDefinition"
  else
    warn "Could not retrieve Eventstream definition — open it in Fabric and click Publish"
  fi

  warn "IMPORTANT: The Eventstream sometimes does not start automatically."
  warn "Open the Eventstream in the Fabric UI and verify it shows 'Running'."
  warn "If it is stopped, click 'Publish' to activate it."
fi

# ── Step 4: Generate dashboard ────────────────────────────────────────────────
step "Step 4 — Generating oee-dashboard.json"
REPO_ROOT="${SCRIPT_DIR}/.."
DASH_OUT="${REPO_ROOT}/dashboard/oee-dashboard.json"
DASH_TEMPLATE="${REPO_ROOT}/dashboard/oee-dashboard.template.json"

if [[ -f "$DASH_TEMPLATE" ]]; then
  sed -e "s|__CLUSTER_URI__|${CLUSTER_URI}|g" \
      -e "s|__DATABASE_ID__|${DB_ID}|g" \
      -e "s|__WORKSPACE_ID__|${WS_ID}|g" \
      "$DASH_TEMPLATE" > "$DASH_OUT"
  ok "Dashboard JSON generated"
else
  warn "oee-dashboard.template.json not found — skipping dashboard generation."
fi

# ── Step 5: Import dashboard ──────────────────────────────────────────────────
step "Step 5 — Importing Real-Time Dashboard"
DASH_NAME="OEE Manufacturing Dashboard"

if [[ ! -f "$DASH_OUT" ]]; then
  warn "oee-dashboard.json not found — skipping import."
else
  ITEM_LIST=$(fabric_get "workspaces/$WS_ID/items" || echo '{"value":[]}')
  EXISTING_DASH=$(echo "$ITEM_LIST" | jq -r --arg n "$DASH_NAME" \
    '.value[] | select(.displayName == $n and .type == "KQLDashboard") | .id' 2>/dev/null | head -1 || true)

  if [[ -n "$EXISTING_DASH" ]]; then
    warn "Dashboard already exists — skipping import."
  else
    DASH_B64=$(base64 -w0 "$DASH_OUT")
    DASH_PAYLOAD=$(jq -n \
      --arg name    "$DASH_NAME" \
      --arg payload "$DASH_B64" \
      '{displayName:$name,type:"KQLDashboard",definition:{parts:[{path:"RealTimeDashboard.json",payload:$payload,payloadType:"InlineBase64"}]}}')

    DASH_RESULT=$(fabric_post "workspaces/$WS_ID/items" "$DASH_PAYLOAD")
    DASH_ID=$(echo "$DASH_RESULT" | jq -r '.id // .itemId // empty' 2>/dev/null | head -1 || true)
    if [[ -n "$DASH_ID" ]]; then
      ok "Dashboard imported (id=$DASH_ID)"
    else
      ok "Dashboard import submitted — verify in Fabric UI."
    fi
  fi
fi

# ── Step 6: Fabric IQ — ontology + Data Agent ─────────────────────────────────
# Creates the Fabric IQ ontology and the "OEE Data Agent" (draft) via the public
# Fabric REST API. Attaching the ontology datasource and clicking Publish remain
# manual portal steps (the public API has no endpoint for either) — they are
# printed in the final summary below.
FABRIC_IQ_DONE=false
if $SKIP_FABRIC_IQ; then
  step "Step 6 — Fabric IQ (skipped)"
  warn "Skipping ontology + Data Agent creation (--skip-fabric-iq or missing python/PyYAML)."
else
  step "Step 6 — Creating Fabric IQ ontology"
  if "$PY" "$SCRIPT_DIR/6-publish-ontology.py" --workspace-name "$WORKSPACE_NAME"; then
    ok "Ontology created"
    step "Step 6 — Creating Data Agent (draft)"
    if "$PY" "$SCRIPT_DIR/7-setup-data-agent.py" \
         --workspace-name "$WORKSPACE_NAME" \
         --data-agent-name "OEE Data Agent"; then
      ok "Data Agent draft created"
      FABRIC_IQ_DONE=true
    else
      warn "Data Agent creation failed — see output above. You can re-run:"
      manual "   $PY scripts/7-setup-data-agent.py --workspace-name \"$WORKSPACE_NAME\""
    fi
  else
    warn "Ontology creation failed — see output above. You can re-run:"
    manual "   $PY scripts/6-publish-ontology.py --workspace-name \"$WORKSPACE_NAME\""
  fi
fi

# ── Step 7: Simulator instructions ────────────────────────────────────────────
step "Step 7 — Simulator configuration"

WPF_SIM_DIR="$(cd "$SCRIPT_DIR/../simulator/FabricOEESimulator.Wpf" && pwd)"
LOCAL_FILE="$WPF_SIM_DIR/simulator.local.yaml"
CONN_STR=""

if [[ -t 0 ]]; then
  manual "Open manufacturing-telemetry Eventstream in Fabric"
  manual "Click the 'oee-simulator' source node → Keys tab"
  manual "Copy 'Connection string–primary key'"
  read -rp "   Paste the connection string here to create simulator.local.yaml (or press Enter to skip): " CONN_STR
fi

if [[ -n "$CONN_STR" ]]; then
  cat > "$LOCAL_FILE" <<EOF
simulator:
  broker:
    connection: "$CONN_STR"
EOF
  ok "Created simulator/FabricOEESimulator.Wpf/simulator.local.yaml"
else
  manual "For direct Fabric ingestion, create simulator/FabricOEESimulator.Wpf/simulator.local.yaml"
  manual "with the simulator:broker:connection Eventstream connection string."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
W=$(printf '═%.0s' {1..65})
printf "\n\033[97m%s\033[0m\n"   "$W"
printf "\033[97m  Provisioning complete.  Summary:\033[0m\n"
printf "\033[97m%s\033[0m\n"     "$W"
printf "  Workspace ID       : %s\n" "$WS_ID"
printf "  Cluster URI        : %s\n" "$CLUSTER_URI"
printf "  KQL Database ID    : %s\n" "$DB_ID"
printf "  Eventstream ID     : %s\n" "$ES_ID"
printf "\n"
printf "\033[91m  ⚠  VERIFY EVENTSTREAM IS RUNNING:\033[0m\n"
manual "   Open the Eventstream in the Fabric UI and confirm it shows 'Running'."
manual "   If it is stopped or in draft state, click 'Publish' to activate it."
manual "   The Eventstream sometimes does not start automatically after provisioning."
printf "\n"
printf "\033[93m  REMAINING MANUAL STEPS:\033[0m\n\n"
if $FABRIC_IQ_DONE; then
  printf "\033[93m  A) ATTACH ONTOLOGY + PUBLISH THE DATA AGENT  (portal-only)\033[0m\n"
  manual "   The ontology and the 'OEE Data Agent' (draft) were created for you,"
  manual "   but the Fabric public REST API has NO endpoint to attach an ontology"
  manual "   datasource or to Publish — these two steps must be done in the portal:"
  manual "   1. Open the 'OEE Data Agent' in the Fabric workspace."
  manual "   2. Add data source → Ontology → select 'OEEManufacturingOntology'."
  manual "   3. (KQL source 'ManufacturingEH' + instructions are already configured.)"
  manual "   4. Click 'Publish' to make the agent queryable."
  printf "\n"
  manual "B) OPTIONAL ACTIVATOR ALERTS"
else
  printf "\033[93m  A) OPTIONAL FABRIC IQ (ontology + Data Agent)\033[0m\n"
  manual "   Not created this run. To add it later:"
  manual "     python3 scripts/6-publish-ontology.py  --workspace-name \"$WORKSPACE_NAME\""
  manual "     python3 scripts/7-setup-data-agent.py --workspace-name \"$WORKSPACE_NAME\" \\"
  manual "             --data-agent-name \"OEE Data Agent\""
  manual "   Then in the portal: attach the ontology datasource + click Publish"
  manual "   (the public REST API has no endpoint for those two actions)."
  printf "\n"
  manual "B) OPTIONAL ACTIVATOR ALERTS"
fi
manual "   Eventstream canvas: + Add destination → Activator → name 'MachineAlerts'"
manual "   Add fault rule: machine_status = 'Fault', group by device_id"
manual "   Add low-OEE KQL rule against MachineEvents (composed on the fly):"
manual "     MachineEvents | where timestamp > ago(5m)"
manual "     | summarize avail = avg(toreal(is_running)),"
manual "                 perf  = avgif(performance_ratio, is_running == 1) by line_id"
manual "     | where avail * perf < 0.60"
printf "\n"
manual "C) START THE SIMULATOR"
manual "   cd simulator/FabricOEESimulator.Wpf && dotnet run"
printf "\033[97m%s\033[0m\n\n" "$W"
