#!/usr/bin/env python3
"""Create, configure, and publish the OEE Data Agent — ontology-first (Fabric IQ).

Sources (a Data Agent takes up to five):
  • OEEFactoryOntology (ontology)     — the plant's business model: lines, stations, machines and
                                        their live telemetry, parts, work orders, SOPs, business
                                        rules, and the governed metrics
  • OEEAnalytics (semantic model)     — the governed KPI measures (the DAX twins of the ontology
                                        metrics), sliced by line, shift, station, or machine type
  • ManufacturingEH (KQL database)    — raw and live events: latest events, minute-level trends,
                                        single-record timelines
  • the ontology's graph (--graph)    — optional separate GQL source once the graph is materialized;
                                        the ontology source already traverses relationships

The script writes the draft configuration and publishes it — the published copy is what the
agent's endpoint, Microsoft Foundry, and Copilot Studio use — through the item definition API.
New-experience ontologies attach through their own definition part
(Files/Config/<stage>/ontologies/<name>/ontology.json); a datasource.json of type "ontology" only
works for old-experience items. Element lists come from the deployed ontology, semantic model,
and KQL schema, so optional entities that scripts/6-publish-ontology.py left out never appear.

Usage
-----
    python scripts/7-setup-data-agent.py --workspace-name "OEE Demo"
    python scripts/7-setup-data-agent.py --workspace-name "OEE Demo" --smoke
    python scripts/7-setup-data-agent.py --workspace-name "OEE Demo" --ask "Which machines on Line-C are faulted right now?"
    python scripts/7-setup-data-agent.py --workspace-name "OEE Demo" --draft-only

Authentication uses the current Azure CLI session ('az login').
"""
from __future__ import annotations

import argparse
import base64
import http.client
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

FABRIC_API = "https://api.fabric.microsoft.com/v1"
FABRIC_RESOURCE = "https://api.fabric.microsoft.com"
SCHEMA_BASE = "https://developer.microsoft.com/json-schemas/fabric/item/dataAgent/definition"
ASSISTANT_API_VERSION = "2024-05-01-preview"
DEFAULTS = {"agent": "OEE Data Agent", "ontology": "OEEFactoryOntology", "model": "OEEAnalytics",
            "kql": "ManufacturingEH"}
# Raw landing tables and scratch tables stay out of the agent's view.
KQL_EXCLUDE = re.compile(r"(_Raw|_stage)$|^StationDim$")
ID_NAMESPACE = uuid.UUID("6f1d3c52-8a0e-4c47-9a39-0e5d3b7f2a10")


def log(msg: str) -> None:
    print(msg, flush=True)


# ─── Auth + HTTP ──────────────────────────────────────────────────────────────

_tokens: dict[str, str] = {}


def token(resource: str) -> str:
    if resource not in _tokens:
        r = subprocess.run(f'az account get-access-token --resource "{resource}" --query accessToken -o tsv',
                           capture_output=True, text=True, shell=True)
        if r.returncode != 0 or not r.stdout.strip():
            sys.exit(f"az get-access-token failed for {resource}: {r.stderr.strip()}\nRun 'az login' first.")
        _tokens[resource] = r.stdout.strip()
    return _tokens[resource]


def request(method: str, url: str, body=None, resource: str = FABRIC_RESOURCE):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token(resource)}")
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    elif method == "POST":
        req.add_header("Content-Length", "0")
    for attempt in range(1, 4):
        try:
            with urllib.request.urlopen(req, timeout=180) as resp:
                raw = resp.read()
                return resp.status, {k.lower(): v for k, v in resp.headers.items()}, json.loads(raw) if raw.strip() else {}
        except urllib.error.HTTPError as e:
            raw = e.read() if e.fp else b""
            try:
                payload = json.loads(raw) if raw.strip() else {}
            except json.JSONDecodeError:
                payload = {"message": raw.decode(errors="replace")[:2000]}
            return e.code, {k.lower(): v for k, v in (e.headers or {}).items()}, payload
        except (http.client.HTTPException, OSError):
            # Dropped connections and truncated bodies happen on long polls; only GETs are safe to repeat.
            if method != "GET" or attempt == 3:
                raise
            time.sleep(3 * attempt)


def get_all(path: str) -> list[dict]:
    url, values = f"{FABRIC_API}/{path}", []
    while url:
        status, _, body = request("GET", url)
        if status >= 400:
            sys.exit(f"GET {path} → HTTP {status}: {json.dumps(body)[:500]}")
        values.extend(body.get("value", []))
        url = body.get("continuationUri")
    return values


def post_lro(path: str, body=None, timeout: int = 600) -> dict:
    """POST that may answer 202; polls /operations/{x-ms-operation-id} and surfaces the real error."""
    status, headers, payload = request("POST", f"{FABRIC_API}/{path}", body)
    if status in (200, 201):
        return payload
    if status != 202:
        sys.exit(f"POST {path.split('?')[0]} → HTTP {status}: {payload.get('message') or json.dumps(payload)[:1500]}")
    op = headers.get("x-ms-operation-id")
    waited = 0
    while op and waited < timeout:
        time.sleep(3)
        waited += 3
        _, _, state = request("GET", f"{FABRIC_API}/operations/{op}")
        phase = (state.get("status") or "").lower()
        if phase == "succeeded":
            st, _, result = request("GET", f"{FABRIC_API}/operations/{op}/result")
            return result if st < 400 else {}
        if phase in ("failed", "cancelled", "canceled"):
            error = state.get("error") or state
            sys.exit(f"POST {path.split('?')[0]} failed: {error.get('message') or json.dumps(error)[:1500]}")
    if op:
        sys.exit(f"operation {op} still running after {timeout}s")
    return payload


def get_definition(ws: str, item: str, fmt: str | None = None) -> dict[str, str]:
    result = post_lro(f"workspaces/{ws}/items/{item}/getDefinition" + (f"?format={fmt}" if fmt else ""))
    return {p["path"]: base64.b64decode(p["payload"]).decode("utf-8-sig")
            for p in result.get("definition", {}).get("parts", [])}


def find_item(ws: str, item_type: str, name: str) -> str | None:
    return next((i["id"] for i in get_all(f"workspaces/{ws}/items?type={item_type}") if i["displayName"] == name), None)


def require_item(ws: str, item_type: str, name: str, hint: str) -> str:
    return find_item(ws, item_type, name) or sys.exit(f"{item_type} {name!r} not found — {hint}")


def element_id(*parts: str) -> str:
    return str(uuid.uuid5(ID_NAMESPACE, "/".join(parts)))


# ─── Data source elements ─────────────────────────────────────────────────────


def ontology_context(ws: str, ontology_id: str) -> tuple[list[dict], list[tuple[str, str]], dict[str, list[str]]]:
    """Entity elements (described by each entity's doc comment), the business rules' statements, the governed
    metrics, and each entity's time-series properties.

    The Data Agent's ontology connector exposes entity data but not rules, so the rules are rendered into
    the agent instructions from the deployed ontology — defined once, derived at publish time.
    """
    elements, rules, facts = [], [], {"metrics": [], "timeseries": []}
    for path, text in sorted(get_definition(ws, ontology_id).items()):
        if path.startswith("entities/"):
            match = re.search(r"((?:^///.*\n)*)^entity (\S+)", text, re.M)
            doc = " ".join(line[3:].strip() for line in match.group(1).splitlines())
            elements.append({"id": match.group(2), "is_selected": True, "display_name": match.group(2),
                             "type": "ontology.entity", "description": doc or None, "children": []})
            series = re.findall(r"^\tproperty (\S+)\n\t\tdataType: TimeSeries<", text, re.M)
            if series:
                facts["timeseries"].append(f"{match.group(2).split('#')[-1]}: {', '.join(series)}")
        elif path.startswith("rules/"):
            name = re.search(r"^rule (\S+)", text, re.M).group(1)
            statement = re.search(r"^\tstatement: (.+)$", text, re.M)
            if statement:
                rules.append((name, statement.group(1).strip()))
        elif path.startswith("metrics/"):
            facts["metrics"].append(re.search(r"^metric (\S+)", text, re.M).group(1))
    return elements, rules, facts


def render_instructions(rules: list[tuple[str, str]], facts: dict[str, list[str]], ontology_name: str) -> str:
    """AI_INSTRUCTIONS with the ontology's metrics, time-series properties, and business rules filled in."""
    text = (AI_INSTRUCTIONS.replace("__METRICS__", ", ".join(facts["metrics"]) or "none")
            .replace("__TIMESERIES__", "; ".join(facts["timeseries"]) or "none"))
    if not rules:
        return text
    lines = [f"- {name}: {statement}" for name, statement in rules]
    return (text + f"\n## Business rules (generated from the {ontology_name} ontology; cite the rule name)\n"
            + "\n".join(lines) + "\n")


def _tmdl_name(raw: str) -> str:
    raw = raw.strip()
    return raw[1:-1].replace("''", "'") if raw.startswith("'") and raw.endswith("'") else raw


def semantic_model_elements(ws: str, model_id: str) -> list[dict]:
    """Tables with their columns and measures; measure doc comments become descriptions."""
    elements = []
    for path, text in sorted(get_definition(ws, model_id, "TMDL").items()):
        if not path.startswith("definition/tables/"):
            continue
        lines = text.splitlines()
        table = _tmdl_name(re.search(r"^table (.+)$", text, re.M).group(1))
        children, doc = [], []
        for n, line in enumerate(lines):
            if line.startswith("\t///"):
                doc.append(line[4:].strip())
                continue
            column = re.match(r"^\tcolumn ('[^']+'|\S+)", line)
            measure = re.match(r"^\tmeasure ('(?:[^']|'')+'|\S+)\s*=", line)
            if column:
                name = _tmdl_name(column.group(1))
                dtype = next((m.group(1) for m in (re.match(r"^\t\tdataType: (\S+)", x) for x in lines[n + 1:n + 6]) if m),
                             None)
                if name != "Value" or table != "_Measures":
                    children.append({"id": element_id(model_id, table, name), "is_selected": True, "display_name": name,
                                     "type": "semantic_model.column", "data_type": dtype,
                                     "description": " ".join(doc) or None})
            elif measure:
                name = _tmdl_name(measure.group(1))
                children.append({"id": element_id(model_id, table, name), "is_selected": True, "display_name": name,
                                 "type": "semantic_model.measure", "description": " ".join(doc) or None})
            if not line.startswith("\t///"):
                doc = []
        elements.append({"id": element_id(model_id, table), "is_selected": True, "display_name": table,
                         "type": "semantic_model.table", "description": None, "children": children})
    return elements


def kql_elements(cluster: str, db: str, db_id: str) -> list[dict]:
    """The portal's shape: a 'Tables' grouping of kusto.table elements with their columns.

    The agent's query generator validates against these tables only — stored functions are invisible to it —
    so the OEE functions reach it as let statements inside the example queries (see kql_fewshots)."""
    status, _, body = request("POST", f"{cluster}/v1/rest/mgmt",
                              {"db": db, "csl": f".show database ['{db}'] schema as json"}, resource=cluster)
    if status >= 400:
        sys.exit(f"KQL schema query failed: HTTP {status}: {json.dumps(body)[:500]}")
    # The schema keys databases by internal name; the response holds just this one.
    schema = next(iter(json.loads(body["Tables"][0]["Rows"][0][0])["Databases"].values()))["Tables"]
    tables = []
    for name in sorted(schema):
        if KQL_EXCLUDE.search(name):
            continue
        columns = [{"id": c["Name"], "is_selected": True, "display_name": c["Name"], "type": "kusto.column",
                    "data_type": c["Type"], "description": None} for c in schema[name]["OrderedColumns"]]
        tables.append({"id": element_id(db_id, name), "is_selected": True, "display_name": name, "type": "kusto.table",
                       "description": None, "children": columns})
    return [{"id": element_id(db_id, "Tables"), "is_selected": True, "display_name": "Tables",
             "type": "table_grouping", "description": None, "children": tables}]


def kql_fewshots(cluster: str, db: str) -> list[tuple[str, str]]:
    """KQL_FEWSHOTS with each referenced OEE function inlined as a let statement read from the database,
    so the examples always carry the deployed definition (scripts/1-setup-fabric.sh owns it)."""
    status, _, body = request("POST", f"{cluster}/v1/rest/mgmt", resource=cluster, body={
        "db": db, "csl": ".show functions | where Name in ('OeeFacts', 'OeeKpis') | project Name, Parameters, Body"})
    if status >= 400:
        sys.exit(f"Reading the OEE functions failed: HTTP {status}: {json.dumps(body)[:500]}")
    lets = {name: f"let {name} = {params} {fn_body.strip()};" for name, params, fn_body in body["Tables"][0]["Rows"]}
    shots = []
    for question, query in KQL_FEWSHOTS:
        used = [name for name in ("OeeFacts", "OeeKpis") if re.search(rf"\b{name}\(", query)]
        missing = [name for name in used if name not in lets]
        if missing:
            sys.exit(f"KQL function(s) {', '.join(missing)} not found in {db} — re-run scripts/1-setup-fabric.sh.")
        shots.append((question, "\n".join([lets[name] for name in used] + [query])))
    return shots


# ─── Instructions ─────────────────────────────────────────────────────────────

AI_INSTRUCTIONS = """You are the plant-floor analyst for a five-line discrete manufacturing plant (Line-A to Line-E, 30 stations). You answer operators, maintenance technicians, quality engineers, line managers, and executives.

## Sources and routing
Pick the source before you query. Start with the ontology; use the others for what it can't answer.

1. OEEFactoryOntology (ontology) — START HERE. The plant's business model: entity types in five namespaces (equipment, production, maintenance, knowledge, floorops), relationships, rules, and governed metrics (__METRICS__). Use it for:
   - what/which/who questions about lines, stations, machines, machine types, shifts, schedules, OEE targets, parts, work orders, technicians, fault types, SOPs, policies, and floor issues;
   - relationships: a line's stations, a station's machine and SOPs, a work order's technician, the stations a part passed through (genealogy);
   - current machine state from the time-series properties (__TIMESERIES__): the latest value per machine;
   - rules and thresholds (Station.target_reject_rate, OeeTarget.target_oee): quote rules by name from "Business rules" below;
   - plant-wide values of the governed metrics.
   Not for whether a work order is open, or anything else from the last few minutes: see Freshness below.
2. OEEAnalytics (semantic model) — governed KPI measures over the full history, sliced by line, shift, station, or machine type: OEE, Availability, Performance, Quality, Rejection Rate, Throughput, Parts Finished, Schedule Adherence, MTTR (min), MTBF (min), Target OEE, OEE vs Target, OEE — Day, OEE — Night, and the floor-ops measures (Open Issues, Critical Open, Resolution Rate, Human MTTA (min), Human MTTR (min), Scrap Qty). Use its measures instead of recomputing a KPI. It has no time dimension: never use it for a time window, the latest data, or how long a condition lasted.
3. ManufacturingEH (KQL database) — raw and live events: the latest N events, minute-level trends, KPIs for a time window (with the OeeFacts/OeeKpis definitions from its example queries), part and work-order timelines, starved/blocked cascades, and rule checks over a window.

Freshness: the ontology and OEEAnalytics read OneLake copies of the event tables, which trail the live stream by a few minutes. So whether a work order is open, and anything else from the last few minutes such as a fault that was just raised, always comes from ManufacturingEH, together with the details asked for (technician names are in its TechnicianMaster table).

Split mixed questions. Example: "Which Line-B machines are down, and do they have open work orders?" → machine state from the ontology, then open work orders (latest step isn't Resolved) from ManufacturingEH.

Rule checks: whether a rule with a duration or a rolling window fired (OEE below 60% for more than 15 minutes or an hour, a rolling-hour reject rate, work orders within an hour) is always checked in ManufacturingEH, never inferred from a full-history KPI. If the question also asks for KPIs or targets, get those from OEEAnalytics. Pass ManufacturingEH the user's wording and the rule's threshold without prescribing a method (a window length, consecutive buckets): its example queries define each check.

If a source can't answer (no query, an error, a missing column), ask the next source that has the data before saying you can't. ManufacturingEH has every telemetry, part, and work-order column.

## KPI definitions (the same in every source)
- Availability = avg(is_running) over machine samples; Idle (starved or blocked), Fault, and Maintenance count as not running.
- Performance = sum(ideal_cycle_time) ÷ sum(actual_cycle_time) over Running samples with actual_cycle_time > 0, capped at 1: a ratio of sums, never an average of ratios.
- Quality (first-pass yield) = completed ÷ (completed + rejected) station passes. Reject rate = rejected ÷ (completed + rejected), compared with the station's own target_reject_rate, not with the line's target OEE.
- OEE = Availability × Performance × Quality.
- Parts finished (throughput) = parts completed at the line's last station (station_count). "Parts Completed" counts every station pass; don't report it as output.
- Schedule adherence = parts finished ÷ expected parts; expected = planned parts per 12-hour shift × minutes the line's first station reported telemetry ÷ 720.
- MTTR = average minutes from Created to Resolved per work order. MTBF = running minutes (samples ÷ 6) ÷ work orders.
- Time in a state = samples × 10 seconds (minutes = samples ÷ 6). Never subtract timestamps: telemetry has gaps when the plant isn't running.

## Identifiers
- line_id: Line-A … Line-E. device_id: line-a-station-1 (lowercase line, then position). station_position runs 1..N in flow order; upstream = position − 1, downstream = position + 1.
- shift: "Day" (06:00–18:00) or "Night" (18:00–06:00); event tables call it shift_id.
- technician_id: T001–T008 (names on Technician). Fault codes (issue_type) roll up to six IssueType.category values; machine types roll up to six process families (MachineType.category).
- Work orders move Created → Acknowledged → InProgress → Resolved. Open = the latest step isn't Resolved.

## Answering
1. Lead with the answer, then the evidence: source, filters, and time window (KPIs without a window cover all available data).
2. For OEE, show Availability, Performance, and Quality, and name the biggest loss.
3. A station that stops or slows starves the stations after it (downstream) and blocks the stations before it (upstream); describe its impact that way round ("it starved the stations after it and blocked the ones before it"), never as starving upstream or blocking downstream. Starved or blocked time counts against root_cause_device_id (rule StarvedBlockedRootCause): to find the station that caused the most, group by root_cause_device_id, never by the idle station's device_id. Give time in a state in minutes (samples ÷ 6), not as a sample count.
4. Current state is each machine's latest sample.
5. Name only the sources you queried; there's no precomputed OEE table. Don't overstate empty results: say what was checked.
6. For an SOP or policy, give its title and file_name; the full text is in the Foundry agent's search index.
7. Label every line with its line_id, then its name as stored (Line-A — Precision Machining, from DimLine / ProductionLine line_name). Never infer either from position or order.
8. For a duration rule, give each line's or station's minutes in breach, since when, and which tier of the rule applies.

## Ontology notes
- Entity names are namespaced (equipment#Station). Station is the process position (key device_id, the same as its machine's).
- PartPass and MaintenanceEvent are keyless events: one row per station pass and per work-order step. SOP and Policy derive from Document; query SOP or Policy directly, because querying Document returns neither.
- WorkOrder and MaintenanceEvent rows trail the live stream by a few minutes, so the ontology can't tell whether a work order is open now: ask ManufacturingEH.
- For time in a state (idle, starved, blocked, running, down), ask the ontology for sample counts, not minutes: asked for minutes, it subtracts timestamps, which also counts the gaps when the plant wasn't running.
- Support group by in GQL.
"""
MODEL_INSTRUCTIONS = (
    "Governed KPI measures in a Direct Lake model. Use the measures (OEE, Availability, Performance, Quality, "
    "Rejection Rate, Throughput, Parts Finished, Schedule Adherence, MTTR (min), MTBF (min), Target OEE, "
    "OEE vs Target), sliced by DimLine, DimShift, DimMachineType, and StationDim; never recompute a measure from "
    "fact columns. Group lines by DimLine[line_id] and show DimLine[line_name] next to it. The model has no date "
    "dimension, so measures cover the full history. Time windows, the latest data, and how long a condition "
    "lasted (such as OEE below 60% for more than 15 minutes) belong to ManufacturingEH: don't approximate them "
    "with timestamp filters or report from these measures whether a duration rule fired."
)
KQL_INSTRUCTIONS = (
    "Raw and live events: MachineEvents (a sample per station about every 10 seconds), PartEvents, "
    "MaintenanceEvents (work-order steps), the derived WorkOrders, Parts, and PartPasses, and master tables. "
    "For OEE, Availability, Performance, or Quality over a window, follow the OEE example queries exactly: start "
    "from their 'let OeeFacts = ...;' and 'let OeeKpis = ...;' definitions, copied unchanged, then "
    "OeeFacts(start, end[, bucket]) | summarize samples = sum(samples), running = sum(running), ideal = sum(ideal), "
    "actual = sum(actual), completed = sum(completed), rejected = sum(rejected) by <grain> | invoke OeeKpis(). "
    "'The latest hour of data' ends at the latest event: toscalar(MachineEvents | summarize max(timestamp)), or "
    "max(passed_at) for PartPasses. ago() windows end now and are empty when nothing is streaming; if one returns "
    "nothing, say when the latest event was. "
    "Duration rules (OEE below 60% for more than 15 minutes) use OEE in 5-minute buckets as in the example "
    "queries: below 60% since the bucket after the last one at or above 60%, measured to the latest event, not by "
    "numbering consecutive rows. A bucket with Availability 0 counts as OEE 0. The station rule "
    "(StationOeeEscalation) leaves Idle samples out of Availability (samples - idle), as the OEE targets policy "
    "does, because idle time counts against the station that caused it; the line rule uses all samples. "
    "The reject-rate quarantine check (RejectRateQuarantine) also needs at least 3 rejected parts in the hour. "
    "Open work orders: summarize arg_max(timestamp, *) by work_order_id, then action != 'Resolved'. "
    "Starved and Blocked time belongs to root_cause_device_id (rule StarvedBlockedRootCause), not to the idle "
    "device_id; group by it as in its example query. "
    "Fault codes roll up with IssueTypeMaster.category and machine types with MachineTypeMaster.category; "
    "TechnicianMaster.name has technician names; StationMaster has each station's ideal_cycle_time and "
    "target_reject_rate."
)

_OEE_SUMS = ("samples = sum(samples), running = sum(running), ideal = sum(ideal), actual = sum(actual), "
             "completed = sum(completed), rejected = sum(rejected)")


def _below_60_query(keys: str, policy_availability: bool = False) -> str:
    """How long each line or station has stayed below 60% OEE, from the last complete 5-minute bucket at or above
    it, the same way the Rule*OeeEscalation functions check it: the bucket still in progress is left out, and a
    bucket with Availability 0 or no finished or rejected part counts as 0. policy_availability leaves Idle samples
    out of Availability, as the station escalation rule does, so a bucket the station spent wholly idle is left out."""
    sums, idle = (f"{_OEE_SUMS}, idle = sum(idle)", "| extend samples = samples - coalesce(idle, 0)\n") \
        if policy_availability else (_OEE_SUMS, "")
    wholly_idle = "| where isnotnull(Availability)\n" if policy_availability else ""
    return ("let LatestEvent = toscalar(MachineEvents | summarize max(timestamp));\n"
            "OeeFacts(LatestEvent - 3h, LatestEvent, 5m)\n| where bucket_start + 5m <= LatestEvent\n"
            f"| summarize {sums} by bucket_start, {keys}\n"
            f"{idle}| invoke OeeKpis()\n{wholly_idle}| extend OEE = iff(Availability == 0 or isnull(OEE), 0.0, OEE)\n"
            "| summarize last_at_or_above_60 = maxif(bucket_start, OEE >= 0.6), first_bucket = min(bucket_start), "
            f"arg_max(bucket_start, OEE) by {keys}\n"
            "| extend below_60_since = iff(OEE >= 0.6 or isnull(OEE), datetime(null), "
            "iff(isnull(last_at_or_above_60), first_bucket, last_at_or_above_60 + 5m))\n"
            "| extend minutes_below_60 = iff(isnull(below_60_since), 0, "
            "datetime_diff('minute', LatestEvent, below_60_since))\n"
            "| lookup kind=leftouter (LineMaster | project line_id, line_name) on line_id\n"
            f"| project {keys}, line_name, latest_5m_oee = round(OEE, 3), below_60_since, minutes_below_60, "
            "over_15_minutes = minutes_below_60 > 15, over_1_hour = minutes_below_60 > 60, "
            "window_start = LatestEvent - 3h, window_end = LatestEvent\n"
            "| order by minutes_below_60 desc")


KQL_FEWSHOTS = [
    ("What is Performance by line over the last hour?",
     f"OeeFacts(ago(1h), now())\n| summarize {_OEE_SUMS} by line_id\n| invoke OeeKpis()\n"
     "| project line_id, Performance\n| order by line_id asc"),
    ("What is OEE by line for the last 8 hours, broken into availability, performance, and quality?",
     f"OeeFacts(ago(8h), now())\n| summarize {_OEE_SUMS} by line_id\n| invoke OeeKpis()\n"
     "| project line_id, Availability, Performance, Quality, OEE\n| order by OEE asc"),
    ("What is OEE by line over the latest hour of data, with its biggest loss, flagging any line under 60%?",
     "let LatestEvent = toscalar(MachineEvents | summarize max(timestamp));\n"
     f"OeeFacts(LatestEvent - 1h, LatestEvent)\n| summarize {_OEE_SUMS} by line_id\n| invoke OeeKpis()\n"
     "| extend biggest_loss = case(Availability <= Performance and Availability <= Quality, \"Availability\", "
     "Performance <= Quality, \"Performance\", \"Quality\"), below_60 = OEE < 0.6\n"
     "| lookup kind=leftouter (LineMaster | project line_id, line_name) on line_id\n"
     "| project line_id, line_name, Availability, Performance, Quality, OEE, biggest_loss, below_60, "
     "window_start = LatestEvent - 1h, window_end = LatestEvent\n| order by OEE asc"),
    ("Show OEE by line in 15-minute intervals for the last 4 hours.",
     f"OeeFacts(ago(4h), now(), 15m)\n| summarize {_OEE_SUMS} by bucket_start, line_id\n| invoke OeeKpis()\n"
     "| project bucket_start, line_id, OEE\n| order by bucket_start asc, line_id asc"),
    ("Which lines' OEE has stayed below 60% for more than 15 minutes, or more than an hour, in the latest data, "
     "and since when?",
     _below_60_query("line_id")),
    ("Which stations' OEE has stayed below 60% for more than 15 minutes in the latest data, and since when?",
     _below_60_query("line_id, device_id", policy_availability=True)),
    ("What is schedule adherence by line and shift for the last 8 hours?",
     "let Window = 8h;\nlet LastStation = LineMaster | project line_id, last_station = station_count;\n"
     "let Finished = PartEvents\n| where timestamp > ago(Window) and action == \"completed\"\n"
     "| join kind=inner LastStation on line_id\n| where station_position == last_station\n"
     "| summarize finished_parts = count() by line_id, shift = shift_id;\n"
     "let RunMinutes = MachineEvents\n| where timestamp > ago(Window) and station_position == 1\n"
     "| summarize minutes_run = count_distinct(bin(timestamp, 1m)) by line_id, shift = shift_id;\n"
     "RunMinutes\n| join kind=leftouter Finished on line_id, shift\n| join kind=inner ProductionSchedule on line_id, shift\n"
     "| extend finished_parts = coalesce(finished_parts, 0), expected_parts = planned_parts * minutes_run / 720.0\n"
     "| project line_id, shift, finished_parts, expected_parts = round(expected_parts, 0), "
     "adherence_pct = round(100.0 * finished_parts / expected_parts, 1)\n| order by line_id asc, shift asc"),
    ("Show open work orders on Line-B.",
     "MaintenanceEvents\n| where line_id == \"Line-B\"\n| summarize arg_max(timestamp, *) by work_order_id\n"
     "| where action != \"Resolved\"\n| lookup kind=leftouter TechnicianMaster on technician_id\n"
     "| project work_order_id, device_id, issue_type, current_step = action, technician = coalesce(name, technician_id), "
     "since = timestamp\n| order by since asc"),
    ("Which stations were starved or blocked in the last 15 minutes, and which station caused it?",
     "MachineEvents\n| where timestamp > ago(15m) and idle_reason in (\"Starved\", \"Blocked\")\n"
     "| summarize samples = count(), last_seen = max(timestamp) by line_id, device_id, idle_reason, root_cause_device_id\n"
     "| order by samples desc"),
    ("Which station caused the most starved or blocked idle time on Line-B, and on which stations?",
     "MachineEvents\n| where line_id == \"Line-B\" and idle_reason in (\"Starved\", \"Blocked\") "
     "and isnotempty(root_cause_device_id)\n"
     "| summarize samples = count() by root_cause_device_id, device_id, idle_reason\n"
     "| summarize idle_minutes_caused = round(sum(samples) / 6.0, 1), "
     "affected = make_list(strcat(device_id, \" \", idle_reason, \" \", round(samples / 6.0, 1), \" min\")) "
     "by root_cause_device_id\n"
     "| order by idle_minutes_caused desc"),
    ("Which stations meet the reject-rate quarantine rule over the last hour?",
     "PartPasses\n| where passed_at > ago(1h)\n"
     "| summarize completed = sum(is_completed), rejected = sum(is_rejected) by line_id, device_id\n"
     "| lookup kind=inner (StationMaster | project device_id, target_reject_rate) on device_id\n"
     "| extend reject_rate = todouble(rejected) / (completed + rejected)\n"
     "| where rejected >= 3 and reject_rate > 2 * target_reject_rate\n"
     "| project line_id, device_id, completed, rejected, reject_rate = round(reject_rate, 3), target_reject_rate, "
     "quarantine_threshold = 2 * target_reject_rate\n| order by reject_rate desc"),
    ("Show the hourly reject-rate trend of line-e-station-4 over the latest 12 hours of data, with its target.",
     "let LatestPass = toscalar(PartPasses | summarize max(passed_at));\n"
     "PartPasses\n| where device_id == \"line-e-station-4\" and passed_at > LatestPass - 12h\n"
     "| summarize completed = sum(is_completed), rejected = sum(is_rejected) by hour = bin(passed_at, 1h)\n"
     "| extend reject_rate = round(todouble(rejected) / (completed + rejected), 3)\n"
     "| extend target_reject_rate = toscalar(StationMaster | where device_id == \"line-e-station-4\" "
     "| project target_reject_rate)\n| order by hour asc"),
    ("How many faults happened today by fault family?",
     "MaintenanceEvents\n| where timestamp > startofday(now()) and action == \"Created\"\n"
     "| lookup kind=leftouter IssueTypeMaster on issue_type\n| summarize faults = count() by category = coalesce(category, \"Uncategorized\")\n"
     "| order by faults desc"),
]

SMOKE_QUESTIONS = [
    "Which stations are on Line-C, and what machine type runs at each?",
    "What is the current status of each machine on Line-B?",
    "What is OEE by line, with availability, performance, and quality?",
    "Show the five most recent maintenance events on Line-B.",
    "What should happen when a line's OEE falls below its target?",
]


# ─── Definition ───────────────────────────────────────────────────────────────


def datasource(ds_type: str, artifact: str, ws: str, name: str, instructions: str, elements: list[dict]) -> dict:
    return {"$schema": f"{SCHEMA_BASE}/dataSource/1.0.0/schema.json", "artifactId": artifact, "workspaceId": ws,
            "dataSourceInstructions": instructions, "displayName": name, "type": ds_type, "userDescription": None,
            "metadata": {}, "elements": elements}


def ontology_source(artifact: str, ws: str, name: str, elements: list[dict]) -> dict:
    """New-experience ontologies use their own part (ontologies/<name>/ontology.json), not a datasource.json."""
    return {"$schema": f"{SCHEMA_BASE}/ontology/1.0.0/schema.json", "artifactId": artifact, "workspaceId": ws,
            "displayName": name, "elements": elements, "entitiesWithUserAuthoredDescriptions": []}


def build_definition(sources: list[tuple[str, dict, list | None]], publish: bool, description: str,
                     instructions: str) -> list[dict]:
    """sources: (path within the stage folder, body, fewshots or None). Draft always; published when publishing."""
    files = {"Files/Config/data_agent.json": {"$schema": f"{SCHEMA_BASE}/dataAgent/2.1.0/schema.json"}}
    stages = ["draft", "published"] if publish else ["draft"]
    for stage in stages:
        files[f"Files/Config/{stage}/stage_config.json"] = {
            "$schema": f"{SCHEMA_BASE}/stageConfiguration/1.0.0/schema.json", "aiInstructions": instructions}
        for relpath, body, fewshots in sources:
            files[f"Files/Config/{stage}/{relpath}"] = body
            if fewshots:
                files[f"Files/Config/{stage}/{relpath.rsplit('/', 1)[0]}/fewshots.json"] = {
                    "$schema": f"{SCHEMA_BASE}/fewShots/1.0.0/schema.json",
                    "fewShots": [{"id": element_id("fewshot", q), "question": q, "query": k} for q, k in fewshots]}
    if publish:
        files["Files/Config/publish_info.json"] = {"$schema": f"{SCHEMA_BASE}/publishInfo/1.0.0/schema.json",
                                                   "description": description}
    return [{"path": path, "payloadType": "InlineBase64",
             "payload": base64.b64encode(json.dumps(body, indent=2, ensure_ascii=False).encode("utf-8")).decode()}
            for path, body in files.items()]


def create_agent(ws: str, name: str) -> str:
    waited = 0
    while True:
        status, headers, body = request("POST", f"{FABRIC_API}/workspaces/{ws}/items", {"displayName": name, "type": "DataAgent"})
        if status in (200, 201):
            return body["id"]
        if status == 202:
            post_lro_wait(headers)
            return require_item(ws, "DataAgent", name, "the create operation finished but the item isn't listed yet")
        if "NotAvailableYet" in json.dumps(body) and waited < 600:
            log(f"  waiting for the display name to free up… ({waited}s)")
            time.sleep(30)
            waited += 30
            continue
        sys.exit(f"Create Data Agent failed: HTTP {status}: {body.get('message') or body}")


def post_lro_wait(headers: dict, timeout: int = 300) -> None:
    op, waited = headers.get("x-ms-operation-id"), 0
    while op and waited < timeout:
        time.sleep(3)
        waited += 3
        _, _, state = request("GET", f"{FABRIC_API}/operations/{op}")
        if (state.get("status") or "").lower() in ("succeeded", "failed", "cancelled", "canceled"):
            return


# ─── Smoke test (the published agent's OpenAI-Assistants-compatible endpoint) ──


def ask(ws: str, agent: str, question: str, timeout: int = 300) -> bool:
    base = f"{FABRIC_API}/workspaces/{ws}/dataagents/{agent}/aiassistant/openai"

    def call(method: str, path: str, body=None) -> dict:
        sep = "&" if "?" in path else "?"
        status, _, out = request(method, f"{base}/{path}{sep}api-version={ASSISTANT_API_VERSION}", body)
        if status >= 400:
            raise RuntimeError(f"{method} {path} → HTTP {status}: {json.dumps(out)[:600]}")
        return out

    log(f"\n? {question}")
    try:
        assistant = call("POST", "assistants", {"model": "not used"})
        thread = call("POST", "threads", {})
        call("POST", f"threads/{thread['id']}/messages", {"role": "user", "content": question})
        run = call("POST", f"threads/{thread['id']}/runs", {"assistant_id": assistant["id"]})
        started = time.time()
        while run.get("status") in ("queued", "in_progress", "requires_action") and time.time() - started < timeout:
            time.sleep(3)
            run = call("GET", f"threads/{thread['id']}/runs/{run['id']}")
        routes = []
        for step in call("GET", f"threads/{thread['id']}/runs/{run['id']}/steps?order=asc").get("data", []):
            for tc in (step.get("step_details") or {}).get("tool_calls") or []:
                fn = tc.get("function") or {}
                try:
                    args = json.loads(fn.get("arguments") or "{}")
                except json.JSONDecodeError:
                    args = {}
                if "datasource_type" in args and "fewshots" not in fn.get("name", ""):
                    route = f"{args.get('datasource_type', '?')}:{args.get('datasource_name', '?')}"
                    if route not in routes:
                        routes.append(route)
        answer = ""
        for message in call("GET", f"threads/{thread['id']}/messages?order=asc").get("data", []):
            if message.get("role") == "assistant":
                answer = " ".join(c["text"]["value"] for c in message.get("content", []) if c.get("type") == "text")
        call("DELETE", f"threads/{thread['id']}")
    except (RuntimeError, OSError, http.client.HTTPException) as err:
        log(f"  ✗ {err}")
        return False
    log(f"  sources: {', '.join(routes) or 'none'}   ({run.get('status')}, {time.time() - started:.0f}s)")
    log("  " + answer.strip().replace("\n", "\n  ")[:1500])
    return run.get("status") == "completed" and bool(answer.strip())


# ─── CLI ──────────────────────────────────────────────────────────────────────


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--workspace-name", required=True, help="Fabric workspace display name or GUID")
    ap.add_argument("--data-agent-name", default=DEFAULTS["agent"])
    ap.add_argument("--ontology-name", default=DEFAULTS["ontology"])
    ap.add_argument("--semantic-model-name", default=DEFAULTS["model"])
    ap.add_argument("--kql-db-name", default=DEFAULTS["kql"])
    ap.add_argument("--graph", action="store_true",
                    help="Also add the ontology's materialized graph as a separate GQL source")
    ap.add_argument("--graph-name", help="GraphModel to add as a GQL source (implies --graph)")
    ap.add_argument("--draft-only", action="store_true", help="Update the draft without publishing")
    ap.add_argument("--recreate", action="store_true", help="Delete the existing Data Agent and create it again")
    ap.add_argument("--smoke", action="store_true", help="Ask the published agent one question per source")
    ap.add_argument("--ask", action="append", default=[], help="Ask the published agent a question (repeatable)")
    args = ap.parse_args()

    ws = next((w["id"] for w in get_all("workspaces") if args.workspace_name in (w["displayName"], w["id"])), None) \
        or sys.exit(f"Workspace {args.workspace_name!r} not found.")
    log(f"✓ Workspace:       {args.workspace_name} ({ws})")

    sources: list[tuple[str, dict, list | None]] = []
    ontology_id = require_item(ws, "Ontology", args.ontology_name, "run scripts/6-publish-ontology.py first")
    entities, rules, facts = ontology_context(ws, ontology_id)
    sources.append((f"ontologies/{args.ontology_name}/ontology.json",
                    ontology_source(ontology_id, ws, args.ontology_name, entities), None))
    log(f"✓ Ontology:        {args.ontology_name} ({len(entities)} entity types, {len(rules)} rules)")

    model_id = find_item(ws, "SemanticModel", args.semantic_model_name)
    if model_id:
        tables = semantic_model_elements(ws, model_id)
        sources.append((f"semantic-model-{args.semantic_model_name}/datasource.json",
                        datasource("semantic_model", model_id, ws, args.semantic_model_name, MODEL_INSTRUCTIONS, tables),
                        None))
        log(f"✓ Semantic model:  {args.semantic_model_name} ({len(tables)} tables, "
            f"{sum(1 for t in tables for c in t['children'] if c['type'] == 'semantic_model.measure')} measures)")
    else:
        log(f"! Semantic model {args.semantic_model_name!r} not found — run scripts/4-setup-powerbi.sh, then re-run this script")

    db = next((d for d in get_all(f"workspaces/{ws}/kqlDatabases") if d["displayName"] == args.kql_db_name), None) \
        or sys.exit(f"KQL database {args.kql_db_name!r} not found — run scripts/1-setup-fabric.sh first.")
    cluster = db["properties"]["queryServiceUri"]
    kql = kql_elements(cluster, args.kql_db_name, db["id"])
    fewshots = kql_fewshots(cluster, args.kql_db_name)
    sources.append((f"kusto-{args.kql_db_name}/datasource.json",
                    datasource("kusto", db["id"], ws, args.kql_db_name, KQL_INSTRUCTIONS, kql), fewshots))
    log(f"✓ KQL database:    {args.kql_db_name} ({len(kql[0]['children'])} tables, {len(fewshots)} example queries)")

    if args.graph or args.graph_name:
        graphs = get_all(f"workspaces/{ws}/items?type=GraphModel")
        graph = next((g for g in graphs if g["displayName"] == args.graph_name), None) if args.graph_name else \
            next((g for g in graphs if g["displayName"].startswith(f"{args.ontology_name}_graph")), None)
        if not graph:
            sys.exit(f"GraphModel {args.graph_name or args.ontology_name + '_graph*'!r} not found — materialize the "
                     "ontology's graph first (ontology → Manage graph).")
        sources.append((f"graph-{graph['displayName']}/datasource.json",
                        datasource("graph", graph["id"], ws, graph["displayName"],
                                   "The ontology's materialized graph. Use GQL for multi-hop traversals: part genealogy "
                                   "across stations, a fault's upstream and downstream reach, SOPs along a path.", []),
                        None))
        log(f"✓ Graph:           {graph['displayName']}")

    agent = find_item(ws, "DataAgent", args.data_agent_name)
    if agent and args.recreate:
        log(f"… Deleting Data Agent {agent}")
        status, _, _ = request("DELETE", f"{FABRIC_API}/workspaces/{ws}/items/{agent}")
        if status >= 400:
            sys.exit(f"DELETE failed: HTTP {status}")
        agent = None
    if not agent:
        log(f"… Creating Data Agent {args.data_agent_name!r}")
        agent = create_agent(ws, args.data_agent_name)

    publish = not args.draft_only
    description = (f"OEE plant-floor analyst: {args.ontology_name} ontology first, governed KPIs from "
                   f"{args.semantic_model_name}, live events from {args.kql_db_name}.")
    parts = build_definition(sources, publish, description, render_instructions(rules, facts, args.ontology_name))
    if not publish:
        # updateDefinition replaces every part, so carry the published copy over untouched.
        current = get_definition(ws, agent)
        parts += [{"path": path, "payloadType": "InlineBase64",
                   "payload": base64.b64encode(text.encode("utf-8")).decode()}
                  for path, text in current.items()
                  if path.startswith("Files/Config/published/") or path == "Files/Config/publish_info.json"]
    post_lro(f"workspaces/{ws}/items/{agent}/updateDefinition", {"definition": {"parts": parts}})
    # Folder names get normalized by the service, so compare what each stored source points at.
    def kind(path: str, body: dict) -> str | None:
        return "ontology" if path.endswith("/ontology.json") else body.get("type")

    stored = {(path.split("/")[2], kind(path, body), body.get("artifactId"))
              for path, text in get_definition(ws, agent).items()
              if path.endswith(("/datasource.json", "/ontology.json")) for body in [json.loads(text)]}
    expected = {(stage, kind(relpath, body), body["artifactId"])
                for stage in (["draft", "published"] if publish else ["draft"]) for relpath, body, _ in sources}
    if expected - stored:
        sys.exit(f"✗ The service didn't keep these sources: {sorted(expected - stored)}")
    log(f"✓ Data Agent {'published' if publish else 'draft updated'}: {args.data_agent_name} ({agent}) — "
        f"{len(sources)} sources")

    questions = (SMOKE_QUESTIONS if args.smoke else []) + args.ask
    if questions and not publish:
        log("! --smoke/--ask query the published agent; publishing was skipped (--draft-only)")
    ok = all([ask(ws, agent, q) for q in questions])
    if questions:
        log("\n✓ Smoke test passed" if ok else "\n✗ Smoke test: some questions failed")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
