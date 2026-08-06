#!/usr/bin/env python3
"""Create and configure the OEE Manufacturing Data Agent.

Provisions a Fabric Data Agent in the target workspace (if missing), then
applies the OEE-specific configuration: aiInstructions, the ManufacturingEH
KQL Database data source, and (when already attached) the
OEEManufacturingOntology element selection.

Idempotent — re-running updates the existing Data Agent in place. Mirrors
the structure of scripts/6-publish-ontology.py (workspace resolved by name,
LRO polling on item create / updateDefinition, az-CLI auth).

The ontology data source has to be attached once via the Fabric portal —
the public REST schema doesn't enumerate it as a known data-source type, so
this script only mutates its element selection when it is already present.

Usage
-----
    python scripts/7-setup-data-agent.py --workspace-name <NAME>
    python scripts/7-setup-data-agent.py --workspace-name <NAME> --recreate
    python scripts/7-setup-data-agent.py --workspace-name <NAME> --step instructions
"""

import argparse
import base64
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

FABRIC_API = "https://api.fabric.microsoft.com/v1"
FABRIC_RESOURCE = "https://api.fabric.microsoft.com"
DEFAULT_DATA_AGENT_NAME = "OEE Data Agent"
DEFAULT_KQL_DB_NAME = "ManufacturingEH"
DEFAULT_ONTOLOGY_NAME = "OEEManufacturingOntology"


# ─── Auth + HTTP ──────────────────────────────────────────────────────────────


def _az_token(resource: str) -> str:
    r = subprocess.run(
        f'az account get-access-token --resource "{resource}" -o json',
        capture_output=True, text=True, shell=True,
    )
    if r.returncode != 0:
        sys.exit(f"az get-access-token failed: {r.stderr}\nRun 'az login' first.")
    return json.loads(r.stdout)["accessToken"]


_token_cache: dict[str, str] = {}


def _token(resource: str = FABRIC_RESOURCE) -> str:
    if resource not in _token_cache:
        _token_cache[resource] = _az_token(resource)
    return _token_cache[resource]


def _request(method: str, url: str, body: dict | None = None) -> tuple[int, dict, dict]:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {_token()}")
    req.add_header("Accept", "application/json")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read().decode() if resp.length != 0 else ""
            payload = json.loads(raw) if raw else {}
            return resp.status, dict(resp.headers), payload
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace") if e.fp else ""
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            payload = {"_raw": raw}
        return e.code, dict(e.headers), payload


def fabric_get(path: str) -> dict:
    status, _, body = _request("GET", f"{FABRIC_API}/{path}")
    if status >= 400:
        sys.exit(f"GET {path} → {status}: {body}")
    return body


def fabric_delete(path: str) -> int:
    status, _, _ = _request("DELETE", f"{FABRIC_API}/{path}")
    return status


def wait_lro(headers: dict, timeout: int = 600) -> dict:
    op = headers.get("Location") or headers.get("operation-location") or headers.get("Operation-Location")
    if not op:
        return {}
    elapsed = 0
    while elapsed < timeout:
        status, _, body = _request("GET", op)
        if status >= 400:
            sys.exit(f"LRO poll failed: {status} {body}")
        state = (body.get("status") or "").lower()
        if state in ("succeeded", "completed"):
            # Some LROs expose the result at /result; ignore failures here
            # since the terminal body is already enough for the callers below.
            return body
        if state in ("failed", "canceled"):
            sys.exit(f"LRO failed: {body}")
        time.sleep(3)
        elapsed += 3
    sys.exit(f"LRO timed out after {timeout}s")


def b64(obj) -> str:
    return base64.b64encode(json.dumps(obj, indent=2).encode("utf-8")).decode("ascii")


def decode(p) -> dict:
    return json.loads(base64.b64decode(p["payload"]).decode("utf-8"))


# ─── Resolvers ────────────────────────────────────────────────────────────────


def _looks_like_guid(s: str) -> bool:
    try:
        uuid.UUID(s)
        return True
    except (ValueError, AttributeError):
        return False


def resolve_workspace(name_or_id: str) -> str:
    if _looks_like_guid(name_or_id):
        return name_or_id
    body = fabric_get("workspaces")
    for w in body.get("value", []):
        if w.get("displayName") == name_or_id:
            return w["id"]
    sys.exit(f"Workspace {name_or_id!r} not found.")


def resolve_kql_db(ws_id: str, name: str) -> str:
    body = fabric_get(f"workspaces/{ws_id}/kqlDatabases")
    for it in body.get("value", []):
        if it.get("displayName") == name:
            return it["id"]
    sys.exit(f"KQL Database {name!r} not found in workspace.")


def find_item(ws_id: str, item_type: str, name: str) -> str | None:
    body = fabric_get(f"workspaces/{ws_id}/items?type={item_type}")
    for it in body.get("value", []):
        if it.get("displayName") == name:
            return it["id"]
    return None


# ─── Data Agent create + definition ───────────────────────────────────────────


def create_data_agent(ws_id: str, name: str) -> str:
    """Create an empty Data Agent and return its id."""
    create_body = {"displayName": name, "type": "DataAgent"}
    elapsed = 0
    while True:
        status, headers, body = _request("POST", f"{FABRIC_API}/workspaces/{ws_id}/items", create_body)
        if status in (200, 201):
            return body["id"]
        if status == 202:
            wait_lro(headers)
            aid = find_item(ws_id, "DataAgent", name)
            if not aid:
                sys.exit(f"Create LRO completed but item {name!r} not found.")
            return aid
        if status == 409 and "NotAvailableYet" in json.dumps(body) and elapsed < 600:
            print(f"  waiting for display name to free up… ({elapsed}s)")
            time.sleep(30)
            elapsed += 30
            continue
        sys.exit(f"Create Data Agent failed: {status} {body}")


def get_definition(ws_id: str, aid: str) -> dict:
    status, headers, _ = _request(
        "POST", f"{FABRIC_API}/workspaces/{ws_id}/dataAgents/{aid}/getDefinition"
    )
    if status not in (200, 202):
        sys.exit(f"getDefinition failed: {status}")
    op = headers.get("Location")
    if not op:
        sys.exit("getDefinition did not return an LRO Location header.")
    elapsed = 0
    while elapsed < 120:
        s, _, b = _request("GET", op)
        if s >= 400:
            sys.exit(f"getDefinition poll failed: {s} {b}")
        state = (b.get("status") or "").lower()
        if state in ("succeeded", "completed"):
            break
        if state in ("failed", "canceled"):
            sys.exit(f"getDefinition LRO failed: {b}")
        time.sleep(2)
        elapsed += 2
    s, _, res = _request("GET", op + "/result")
    if s >= 400:
        sys.exit(f"getDefinition result failed: {s} {res}")
    return res["definition"]


def update_definition(ws_id: str, aid: str, definition: dict) -> None:
    status, headers, body = _request(
        "POST",
        f"{FABRIC_API}/workspaces/{ws_id}/dataAgents/{aid}/updateDefinition",
        {"definition": definition},
    )
    if status not in (200, 202):
        sys.exit(f"updateDefinition failed: {status} {body}")
    if status == 202:
        op = headers.get("Location")
        if not op:
            return
        elapsed = 0
        while elapsed < 300:
            s, _, b = _request("GET", op)
            if s >= 400:
                sys.exit(f"updateDefinition poll failed: {s} {b}")
            state = (b.get("status") or "").lower()
            print(f"  status={state}")
            if state in ("succeeded", "completed"):
                return
            if state in ("failed", "canceled"):
                sys.exit(f"updateDefinition LRO failed: {b}")
            time.sleep(3)
            elapsed += 3
        sys.exit("updateDefinition timed out")


# ─── Configuration payloads ───────────────────────────────────────────────────


AI_INSTRUCTIONS = """You are a manufacturing operations analyst for a 5-line factory OEE system. You answer questions from corp execs, plant managers, line managers, maintenance techs, and quality workers using two complementary data sources.

## ROUTING (decide FIRST, before anything else)

The ontology contains 6 entities: 3 operational dimensions with live telemetry (ProductionLine, Station, ProductionSchedule) and 3 static reference dimensions (Shift, MachineType, SOP). It does NOT contain MachineEvent, PartEvent, or MaintenanceEvent as entities - those are KQL tables. IssueType, Technician, and Policy are NOT ontology entities either (they would be edgeless nodes) - they live only in the KQL source as IssueTypeMaster, TechnicianMaster, and PolicyMaster.

Route to OEEManufacturingOntology when the question asks for current/recent state that can be answered as a simple Avg/Sum/Count/Max of one numeric proxy column grouped by ProductionLine, Station, or ProductionSchedule. This includes natural prompts like:
- "Which Line-B stations are currently in Fault or Maintenance?" -> Station TimeSeries Avg(is_fault), Avg(is_maintenance), grouped by (line_id, station_position), recent window.
- "What are current input and output buffers on Line-D?" -> Station TimeSeries Max(input_buffer_count), Max(output_buffer_count), grouped by Station.
- "How many parts has each line completed this shift?" -> ProductionSchedule or ProductionLine Sum(is_completed), grouped by line/shift.

Route to ManufacturingEH (KQL Database) when the question needs ANY of:
- "machine event", "part event", "maintenance event", "event", "events"
- "latest", "most recent", "last", "newest", "newest record", "max timestamp", "min timestamp", "first", "earliest"
- a specific part_id, work_order_id, machine_id, technician_id, ticket_id, or shift
- downtime, MTTR, MTBF, reject reason, idle reason, machine_status text
- "trend", "over time", "by hour", "by minute", "histogram", "distribution"
- OEE Performance (needs MachineEventsEnriched())
- a join across two event types, or a join between events and master data
- arg_max, countif, bin(), or explicit time-window logic that is not the default recent window for an ontology TimeSeries aggregate

Do not route to ManufacturingEH just because the question says "current", "right now", "Fault", "Maintenance", or uses the default recent window for station/line/shift state. Those simple current-state aggregates are ontology questions unless the user also asks for raw events, work orders, trends, joins, or OEE Performance.

Mixed questions should not require the user to name a source. For example, "Which Line-B stations are currently in Fault or Maintenance, and do any of them have open work orders?" MUST be decomposed into two source calls:
1. OEEManufacturingOntology for current Station state: filter `Station.line_id == "Line-B"`, use a recent time window, aggregate `Avg(is_fault)` and `Avg(is_maintenance)` by `(line_id, station_position)`.
2. ManufacturingEH for MaintenanceEvents only: find open work orders whose latest `action` is not `Resolved`.

Do NOT collapse that mixed prompt into one KQL query over MachineEvents. MachineEvents can technically answer current station state, but the ontology is the intended source for simple current-state station aggregates.

## The two sources

1. OEEManufacturingOntology (ontology source) - 6 entities (3 operational + 3 reference dimensions):
   - ProductionLine (id: line_id) - 5 lines. TimeSeries bindings to MachineEvents (cols ts_machine, is_running, is_fault, is_idle, is_maintenance, actual_cycle_time) and PartEvents (cols ts_part, is_pass, is_completed, is_rejected, cycle_time).
   - Station (composite id: line_id + station_position) - 30 stations. Same two TS bindings, plus input_buffer_count + output_buffer_count on machine.
   - ProductionSchedule (composite id: line_id + shift) - planned_parts per shift. TS binding to PartEvents.
   - Reference dimensions (lakehouse-only static lookups, no live telemetry): Shift (shift, start_hour, end_hour), MachineType (machine_type, category - 6 process families), SOP (sop_id, station scope, title, file_name).
   - Relationships (5): Station_BelongsTo_ProductionLine, ProductionSchedule_For_ProductionLine, ProductionSchedule_For_Shift, Station_Is_Of_MachineType, SOP_AppliesTo_Station. IssueType, Technician, and Policy are deliberately NOT ontology entities - they have no graph edge (their keys live only in event data), so join IssueTypeMaster / TechnicianMaster / PolicyMaster in the KQL source via NL2KQL instead.

2. ManufacturingEH (KQL Database source):
    - MachineEvents: per-machine state samples. Numeric proxies is_running, is_fault, is_idle, is_maintenance. Has actual_cycle_time. Joined to StationMaster on (line_id, station_position).
    - MachineEventsEnriched(): view function over MachineEvents joined to StationMaster. Use whenever Performance, ideal_cycle_time, or performance_ratio is needed.
    - PartEvents: per-part lifecycle. Numeric proxies is_pass, is_completed, is_rejected. Has cycle_time.
    - MaintenanceEvents: per-ticket lifecycle. Use for MTTR/MTBF.
    - StationMaster (dim): line_id, station_position, machine_type, ideal_cycle_time, manufacturer, install_year, buffer_capacity.
    - LineMaster (dim): line_id, line_name, purpose, station_count.
    - ProductionSchedule (dim): line_id, shift, planned_parts.
    - ShiftMaster (dim): shift, start_hour, end_hour. Day = hours 6–18, Night = 18–6.
    - MachineTypeMaster (dim): machine_type, category. Rolls the 30 machine types into 6 process families: Machining, Forming, Joining, Surface, Electronics, Inspection. Join on machine_type (present on MachineEvents, PartEvents, MaintenanceEvents, StationMaster).
    - IssueTypeMaster (dim): issue_type, category. Rolls ~77 fault codes into 6 fault families: Mechanical-Wear, Jam-Feed, Fluid-Pressure, Thermal, Sensor-Vision-Calibration, Electrical-Other. Join MaintenanceEvents.issue_type. Use the category for theme/family rollups instead of the raw code.
    - TechnicianMaster (dim): technician_id, name. T001–T008. Join MaintenanceEvents.technician_id to report a person's name instead of an ID.
    - SopMaster (dim): sop_id, line_id, station_position, machine_type, doc_type, title, file_name. One row per station-scoped SOP/calibration doc; file_name is the PDF indexed by Azure AI Search for full-text retrieval.
    - PolicyMaster (dim): policy_id, scope, doc_type, title, file_name. Plant-wide policy/procedure/checklist docs (e.g. OEE_Targets_and_Escalation, Safety_Lockout_Tagout_Procedure).
    - All three event tables (MachineEvents, PartEvents, MaintenanceEvents) carry a shift_id string column ("Day"/"Night"); filter shift_id directly instead of deriving the shift from timestamp.
    - NO precomputed OEE table is available. To compute Performance, query MachineEventsEnriched():
    ```
    MachineEventsEnriched()
    | where is_running == 1
    | summarize Performance = avg(performance_ratio) by line_id
    ```

## Hard rules

- IDENTIFIER GLOSSARY (the user usually types the ID, not the descriptive name):
  - line_id: "Line-A", "Line-B", "Line-C", "Line-D", "Line-E". When the user says "Line-C" they mean line_id == "Line-C". line_name is the descriptive label like "Welding/Assembly" - do NOT filter on line_name unless the user explicitly uses that descriptive phrase.
  - station_position: integer 1..N within a line. When the user says "station 6" or "Leak-Test", filter on station_position (or machine_type for the named form). Do NOT filter on display names against station_position.
  - machine_type: short string like "Leak-Test", "Curing-Oven", "CNC-Lathe". Roll up to a process family via MachineTypeMaster.category.
  - issue_type: short fault code like "Bearing-Wear", "Coolant-Leak". Roll up to a fault family via IssueTypeMaster.category.
  - technician_id: "T001".."T008". Join TechnicianMaster to show the technician name.
  - shift: "Day" or "Night" ONLY (Day = hours 6–18). Event tables expose this as the shift_id column — filter shift_id == "Day"/"Night" directly. ShiftMaster holds the hour windows. There is no "Evening" shift.
- For descriptive info about a line, station, or shift (name, purpose, station count, ideal cycle time, planned parts, manufacturer, etc.), query the dimension table DIRECTLY with a simple filter on the ID. Do NOT derive these from event tables.
  ```
  LineMaster | where line_id == "Line-C"
  StationMaster | where line_id == "Line-C" and station_position == 6
  ProductionSchedule | where line_id == "Line-A" and shift == "Day"
  ```
- For the ontology source, the same rule applies: filter ProductionLine on `line_id`, Station on `(line_id, station_position)`, ProductionSchedule on `(line_id, shift)`.
- Never aggregate string columns. machine_status, idle_reason, action, event_type are strings - use is_running, is_fault, is_idle, is_maintenance, is_pass, is_completed, is_rejected. KQL DB may countif on strings.
- OEE = Availability * Performance * Quality, composed at query time. Availability=avg(is_running) on MachineEvents. Performance=avg(performance_ratio) on MachineEventsEnriched() where is_running==1. Quality=avg(is_pass) on PartEvents where is_completed==1. Performance MUST come from the KQL DB source via MachineEventsEnriched().
- No precomputed OEE table or view exists. There is NO `OEE_5min` view, no `OEE` table, and no materialized view of any kind - they were removed by design. NEVER cite, name, or claim a source called "OEE_5min", "OEE view", "OEE table", or any precomputed/materialized OEE artifact. When you report OEE, the source IS the live tables you actually queried (MachineEvents / MachineEventsEnriched() / PartEvents, or the ontology TimeSeries proxies). Cite only the table or view you really used; do not invent a friendlier-sounding source name.
- Ontology TS groups on the entity id; KQL DB can group on any column.
- For latest work-order state, keep action as a string column. Use `summarize arg_max(timestamp, *) by work_order_id`, then filter the returned `action` column. Do NOT write `last_action=arg_max(timestamp, action, ...)` and then filter `last_action`; that aliases the datetime timestamp, not the action string. Maintenance action values are Created, Acknowledged, InProgress, and Resolved. Open work orders have latest action != "Resolved".

## Safe KQL patterns

Open work orders for a line. Use this only for the work-order portion of a mixed prompt after the ontology has identified current station state. It returns a summary row even when no work orders are open, so an empty result is not treated as a query failure:
```
let open_work_orders =
    MaintenanceEvents
    | where line_id == "Line-B" and timestamp > ago(24h)
    | summarize arg_max(timestamp, *) by work_order_id
    | where action != "Resolved"
    | project line_id, station_position, work_order_id, issue_type, work_order_action = action, technician_id, work_order_timestamp = timestamp;
open_work_orders
| union (
    open_work_orders
    | summarize open_work_order_count = count()
    | where open_work_order_count == 0
    | project line_id = "Line-B", station_position = int(null), work_order_id = "", issue_type = "", work_order_action = "None", technician_id = "", work_order_timestamp = datetime(null)
)
| order by station_position asc
```

Fault counts rolled up to the 6 engineering fault families (last 24h):
```
MaintenanceEvents
| where timestamp > ago(24h) and action == "Created"
| lookup kind=leftouter IssueTypeMaster on issue_type
| extend category = coalesce(category, "Uncategorized")
| summarize fault_count = count() by category
| order by fault_count desc
```

Technician workload with names (open + resolved, last 24h):
```
MaintenanceEvents
| where timestamp > ago(24h)
| summarize create_time = minif(timestamp, action == "Created"), resolve_time = minif(timestamp, action == "Resolved"), technician_id = any(technician_id) by work_order_id
| where isnotempty(technician_id)
| lookup kind=leftouter TechnicianMaster on technician_id
| extend technician = coalesce(name, technician_id)
| summarize total = count(), open = countif(isnull(resolve_time)) by technician
| order by total desc
```

## Domain

- Line-A Precision Machining: 5 stations, bottleneck CMM-Inspection (60s ideal).
- Line-B Sheet Metal: 4 stations, weak link Hydraulic-Press.
- Line-C Welding/Assembly: 6 stations.
- Line-D Surface Treatment: 7 stations, bottleneck Curing-Oven (90s ideal).
- Line-E Electronics: 8 stations.

States: Running, Idle, Fault, Blocked, Starved. Faults cascade upstream as Blocked, downstream as Starved. Maintenance: Created -> Acknowledged -> InProgress -> Resolved. Technicians T001-T008 (names in TechnicianMaster). When the user asks about fault themes or equipment families rather than individual codes, roll up via IssueTypeMaster.category and MachineTypeMaster.category. For full SOP / policy document text, map stations through SopMaster and plant-wide docs through PolicyMaster to the file_name indexed by Azure AI Search.

## Response guidelines

1. Always break OEE into A/P/Q so the user sees the loss component.
2. Consider cascade effects on adjacent stations.
3. Normalize cycle time differences across lines.
4. Use MaintenanceEvents (KQL DB) for MTTR/MTBF.
5. Default to most recent data when no time range is given.
6. Do not overstate empty results. If no stations match Fault/Maintenance and no open work orders are found, say exactly that for the queried line/window. Do not infer the line is "fully operational" unless running/idle/throughput data was also checked.
"""


NEW_ONTOLOGY_ELEMENTS = [
    {
        "id": "ProductionLine",
        "is_selected": True,
        "display_name": "ProductionLine",
        "type": "ontology.entity",
        "description": "line_id,line_name,purpose,station_count,ts_machine,is_running,is_fault,is_idle,is_maintenance,actual_cycle_time,ts_part,is_pass,is_completed,is_rejected,cycle_time",
        "children": [],
    },
    {
        "id": "Station",
        "is_selected": True,
        "display_name": "Station",
        "type": "ontology.entity",
        "description": "line_id,station_position,machine_type,ideal_cycle_time,manufacturer,install_year,buffer_capacity,ts_machine,is_running,is_fault,is_idle,is_maintenance,actual_cycle_time,input_buffer_count,output_buffer_count,ts_part,is_pass,is_completed,is_rejected,cycle_time",
        "children": [],
    },
    {
        "id": "ProductionSchedule",
        "is_selected": True,
        "display_name": "ProductionSchedule",
        "type": "ontology.entity",
        "description": "line_id,shift,planned_parts,timestamp,is_pass,is_completed,is_rejected",
        "children": [],
    },
    {
        "id": "Shift",
        "is_selected": True,
        "display_name": "Shift",
        "type": "ontology.entity",
        "description": "shift,start_hour,end_hour",
        "children": [],
    },
    {
        "id": "MachineType",
        "is_selected": True,
        "display_name": "MachineType",
        "type": "ontology.entity",
        "description": "machine_type,category",
        "children": [],
    },
    {
        "id": "SOP",
        "is_selected": True,
        "display_name": "SOP",
        "type": "ontology.entity",
        "description": "sop_id,line_id,station_position,machine_type,doc_type,title,file_name",
        "children": [],
    },
]


KUSTO_DS_TEMPLATE = {
    "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/dataAgent/definition/dataSource/1.0.0/schema.json",
    "artifactId": "",   # filled in at runtime from resolve_kql_db
    "workspaceId": "",  # filled in at runtime from resolve_workspace
    "dataSourceInstructions": (
        "Live OEE event store. Use NL2KQL for: single-record lookups (specific "
        "part_id, specific work_order_id), joins across tables, countif on string "
        "columns (machine_status, idle_reason, action), arg_max for "
        "latest-state-per-key, bin() time series, and OEE Performance "
        "(MachineEventsEnriched() view function gives performance_ratio + "
        "ideal_cycle_time). Silver tables already have numeric proxy columns. "
        "Do not use this KQL source for simple current station/line/shift "
        "state that the ontology can answer with numeric proxy aggregates; "
        "for mixed prompts, use KQL only for the event-detail or work-order "
        "portion after ontology current-state lookup. "
        "For open work orders, use summarize arg_max(timestamp, *) by "
        "work_order_id, then filter action != 'Resolved'; never alias "
        "arg_max as last_action because that names the datetime. "
        "Join dimension tables for rollups and friendly labels: "
        "MaintenanceEvents.issue_type -> IssueTypeMaster.category (6 fault "
        "families), .technician_id -> TechnicianMaster.name; machine_type -> "
        "MachineTypeMaster.category (6 process families); shift_id ('Day'/'Night') "
        "is already a column on every event table. SopMaster and PolicyMaster "
        "map a station or plant-wide policy to the knowledge-doc file_name. "
        "Compose OEE on the fly: Availability=avg(is_running), "
        "Performance=avg(performance_ratio) where is_running==1, "
        "Quality=avg(is_pass) where is_completed==1."
    ),
    "displayName": "ManufacturingEH",
    "type": "kusto",
    "userDescription": None,
    "metadata": {},
    "elements": [
        {"id": "MachineEvents", "is_selected": True, "display_name": "MachineEvents", "type": "kusto.table"},
        {"id": "PartEvents", "is_selected": True, "display_name": "PartEvents", "type": "kusto.table"},
        {"id": "MaintenanceEvents", "is_selected": True, "display_name": "MaintenanceEvents", "type": "kusto.table"},
        {"id": "StationMaster", "is_selected": True, "display_name": "StationMaster", "type": "kusto.table"},
        {"id": "LineMaster", "is_selected": True, "display_name": "LineMaster", "type": "kusto.table"},
        {"id": "ProductionSchedule", "is_selected": True, "display_name": "ProductionSchedule", "type": "kusto.table"},
        {"id": "ShiftMaster", "is_selected": True, "display_name": "ShiftMaster", "type": "kusto.table"},
        {"id": "MachineTypeMaster", "is_selected": True, "display_name": "MachineTypeMaster", "type": "kusto.table"},
        {"id": "IssueTypeMaster", "is_selected": True, "display_name": "IssueTypeMaster", "type": "kusto.table"},
        {"id": "TechnicianMaster", "is_selected": True, "display_name": "TechnicianMaster", "type": "kusto.table"},
        {"id": "SopMaster", "is_selected": True, "display_name": "SopMaster", "type": "kusto.table"},
        {"id": "PolicyMaster", "is_selected": True, "display_name": "PolicyMaster", "type": "kusto.table"},
    ],
}


# ─── CLI ──────────────────────────────────────────────────────────────────────


def _ontology_part_path(ontology_name: str) -> str:
    return f"Files/Config/draft/ontology-{ontology_name}/datasource.json"


def _kusto_part_path(kql_db_name: str) -> str:
    return f"Files/Config/draft/kusto-{kql_db_name}/datasource.json"


def build_kusto_ds(ws_id: str, kql_db_id: str, kql_db_name: str) -> dict:
    ds = json.loads(json.dumps(KUSTO_DS_TEMPLATE))
    ds["artifactId"] = kql_db_id
    ds["workspaceId"] = ws_id
    ds["displayName"] = kql_db_name
    return ds


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--workspace-name", required=True,
                    help="Fabric workspace display name or GUID")
    ap.add_argument("--data-agent-name", default=DEFAULT_DATA_AGENT_NAME,
                    help=f"Data Agent display name (default: {DEFAULT_DATA_AGENT_NAME})")
    ap.add_argument("--kql-db-name", default=DEFAULT_KQL_DB_NAME,
                    help=f"KQL Database display name to attach (default: {DEFAULT_KQL_DB_NAME})")
    ap.add_argument("--ontology-name", default=DEFAULT_ONTOLOGY_NAME,
                    help=f"Ontology display name whose element selection to refresh (default: {DEFAULT_ONTOLOGY_NAME})")
    ap.add_argument("--recreate", action="store_true",
                    help="Delete the existing Data Agent and recreate from scratch")
    ap.add_argument("--step", choices=["elements", "instructions", "kusto", "all"],
                    default="all",
                    help="Limit which part of the definition to mutate (default: all)")
    args = ap.parse_args()

    ws_id = resolve_workspace(args.workspace_name)
    print(f"✓ Workspace:      {args.workspace_name} ({ws_id})")

    kql_db_id = resolve_kql_db(ws_id, args.kql_db_name)
    print(f"✓ KQL Database:   {args.kql_db_name} ({kql_db_id})")

    aid = find_item(ws_id, "DataAgent", args.data_agent_name)
    if aid and args.recreate:
        print(f"… Deleting existing Data Agent {aid}")
        rc = fabric_delete(f"workspaces/{ws_id}/items/{aid}")
        if rc >= 400:
            sys.exit(f"DELETE failed: HTTP {rc}")
        aid = None

    if not aid:
        print(f"… Creating Data Agent {args.data_agent_name!r}")
        aid = create_data_agent(ws_id, args.data_agent_name)
        print(f"✓ Data Agent created ({aid})")
        # Allow a moment for the draft layout to materialise before fetching.
        time.sleep(5)
    else:
        print(f"✓ Data Agent:     {args.data_agent_name} ({aid})")

    print("… GET current definition")
    d = get_definition(ws_id, aid)
    parts_by_path = {p["path"]: p for p in d["parts"]}
    print(f"  {len(d['parts'])} parts: {sorted(parts_by_path.keys())}")

    if args.step in ("elements", "all"):
        ont_path = _ontology_part_path(args.ontology_name)
        if ont_path in parts_by_path:
            print(f"… Replace ontology elements ({args.ontology_name})")
            p = parts_by_path[ont_path]
            j = decode(p)
            j["elements"] = NEW_ONTOLOGY_ELEMENTS
            p["payload"] = b64(j)
        else:
            print(f"! Ontology source {args.ontology_name!r} is not attached — "
                  f"attach it once via the Fabric portal (OneLake catalog) and re-run.")

    if args.step in ("instructions", "all"):
        stage_path = "Files/Config/draft/stage_config.json"
        if stage_path in parts_by_path:
            print("… Replace aiInstructions")
            p = parts_by_path[stage_path]
            j = decode(p)
            j["aiInstructions"] = AI_INSTRUCTIONS
            p["payload"] = b64(j)
        else:
            print("… Create stage_config.json with aiInstructions")
            d["parts"].append({
                "path": stage_path,
                "payloadType": "InlineBase64",
                "payload": b64({"aiInstructions": AI_INSTRUCTIONS}),
            })

    if args.step in ("kusto", "all"):
        kusto_path = _kusto_part_path(args.kql_db_name)
        kusto_ds = build_kusto_ds(ws_id, kql_db_id, args.kql_db_name)
        if kusto_path in parts_by_path:
            print(f"… Replace kusto-{args.kql_db_name}")
            parts_by_path[kusto_path]["payload"] = b64(kusto_ds)
        else:
            print(f"… Add kusto-{args.kql_db_name}")
            d["parts"].append({
                "path": kusto_path,
                "payloadType": "InlineBase64",
                "payload": b64(kusto_ds),
            })

    print(f"… Pushing {len(d['parts'])} parts")
    update_definition(ws_id, aid, d)
    print(f"✓ Data Agent configured ({args.data_agent_name})")
    print()
    print("Next step: open the Data Agent in the Fabric portal and click **Publish**.")
    print("The Foundry agent can only connect to a published Fabric Data Agent endpoint.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
