#!/usr/bin/env python3
"""Publish the simulator's event contracts as a Fabric Event Schema Set ("OEE Telemetry Events").

eventschemas/oee-telemetry-events.json is the single description of the three events the simulator
sends (machine_telemetry, part_event, maintenance_event): one JSON Schema (draft-07) per event type.
This script:
  1. Checks each schema against its Eventhouse Bronze table (column names and types), so the
     contract can't drift from what the Eventstream actually lands. A mismatch stops the publish.
  2. Converts the contract to the EventSchemaSet definition: one CloudEvents/1.0 event type per
     event (ce-type = the event id, which is also the payload's event_type) that points to a
     JsonSchema/draft-07 schema with one version per contract version.
  3. Creates the Event Schema Set or overrides its definition, then reads it back.

The schemas appear in the Fabric Real-Time hub schema registry. A schema-aware Eventstream (preview)
can associate them with its source; that association is a portal step (see docs).

Usage
-----
    python scripts/1a-publish-event-schemas.py --workspace-name "OEE Demo"
    python scripts/1a-publish-event-schemas.py --workspace-name "OEE Demo" --dry-run   # print the definition

Authentication uses the Azure CLI session ('az login') as a user; the Event Schema Set APIs are
documented for delegated identities. scripts/1-setup-fabric.sh runs this after creating the tables.
"""
from __future__ import annotations

import argparse
import base64
import http.client
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

FABRIC_API = "https://api.fabric.microsoft.com/v1"
FABRIC_RESOURCE = "https://api.fabric.microsoft.com"
REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CONTRACT = REPO_ROOT / "eventschemas" / "oee-telemetry-events.json"
DEFINITION_PART = "EventSchemaSetDefinition.json"
SCHEMA_FORMAT = "JsonSchema/draft-07"
EVENT_FORMAT = "CloudEvents/1.0"

# KQL column type → the JSON Schema type that carries it. datetime arrives as an ISO 8601 string.
KQL_TO_JSON = {"string": "string", "int": "integer", "long": "integer", "real": "number", "decimal": "number",
               "bool": "boolean", "datetime": "string", "dynamic": "object", "guid": "string", "timespan": "string"}


def log(msg: str) -> None:
    print(msg, flush=True)


# ─── Auth + HTTP ──────────────────────────────────────────────────────────────

_tokens: dict[str, str] = {}


def token(resource: str) -> str:
    if resource not in _tokens:
        try:
            r = subprocess.run(f'az account get-access-token --resource "{resource}" --query accessToken -o tsv',
                               capture_output=True, text=True, shell=True, timeout=120)
        except subprocess.TimeoutExpired:
            sys.exit("az account get-access-token didn't answer within 120s. Check 'az login'.")
        if r.returncode != 0 or not r.stdout.strip():
            sys.exit(f"az account get-access-token failed: {r.stderr.strip()}\nRun 'az login' first.")
        _tokens[resource] = r.stdout.strip()
    return _tokens[resource]


def request(method: str, url: str, body=None, resource: str = FABRIC_RESOURCE):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token(resource))
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
            # Dropped connections happen on long polls; only GETs are safe to repeat.
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
    op, waited = headers.get("x-ms-operation-id"), 0
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


def get_parts(ws: str, item: str) -> dict[str, str]:
    result = post_lro(f"workspaces/{ws}/items/{item}/getDefinition")
    return {p["path"]: base64.b64decode(p["payload"]).decode("utf-8-sig")
            for p in result.get("definition", {}).get("parts", [])}


def definition_part(parts: dict[str, str]) -> tuple[str, str]:
    """The schema set's definition part (path, text); getDefinition also returns .platform."""
    return next(((path, text) for path, text in parts.items() if path != ".platform"), (DEFINITION_PART, "{}"))


# ─── Contract ─────────────────────────────────────────────────────────────────


def build_definition(contract: dict) -> dict:
    event_types, schemas = [], []
    for event in contract["eventTypes"]:
        schema = event["schema"]
        schema_id = schema.get("title") or event["id"]
        event_types.append({
            "id": event["id"],
            "description": event.get("description", ""),
            "eventTypeCategory": "EventType",
            "format": EVENT_FORMAT,
            "envelopeMetadata": {
                "id": {"type": "string", "required": True},
                "type": {"type": "string", "required": True, "value": event["id"]},
                "source": {"type": "string", "required": True},
                "specversion": {"type": "string", "required": True},
            },
            "schemaUrl": f"#/schemas/{schema_id}",
            "schemaFormat": SCHEMA_FORMAT,
        })
        schemas.append({
            "id": schema_id,
            "description": f"Payload of the {event['id']} event.",
            "format": SCHEMA_FORMAT,
            "versions": [{"id": event.get("version", "v1"), "format": SCHEMA_FORMAT,
                          "schema": json.dumps(schema, indent=2)}],
        })
    return {"eventTypes": event_types, "schemas": schemas}


def kql_columns(cluster: str, database: str, table: str) -> dict[str, str] | None:
    status, _, body = request("POST", f"{cluster.rstrip('/')}/v1/rest/mgmt",
                              {"db": database, "csl": f".show table ['{table}'] cslschema"}, resource=cluster)
    if status >= 400:
        return None
    rows = body["Tables"][0]["Rows"]
    if not rows:
        return None
    return dict(col.split(":", 1) for col in rows[0][1].split(","))


def check_drift(contract: dict, cluster: str, database: str) -> list[str]:
    """Compare each schema's properties with its Bronze table's columns (names and types)."""
    problems = []
    for event in contract["eventTypes"]:
        table = event.get("kustoTable")
        if not table:
            continue
        columns = kql_columns(cluster, database, table)
        if columns is None:
            problems.append(f"{event['id']}: table {table} not found in {database}")
            continue
        props = event["schema"]["properties"]
        for name in sorted(set(props) - set(columns)):
            problems.append(f"{event['id']}: property {name} has no column in {table}")
        for name in sorted(set(columns) - set(props)):
            problems.append(f"{event['id']}: column {table}.{name} isn't in the schema")
        for name in sorted(set(props) & set(columns)):
            expected = KQL_TO_JSON.get(columns[name])
            declared = props[name].get("type")
            if expected and declared != expected:
                problems.append(f"{event['id']}: {name} is {declared} in the schema but {columns[name]} in {table}")
            if columns[name] == "datetime" and props[name].get("format") != "date-time":
                problems.append(f"{event['id']}: {name} is datetime in {table}; declare format date-time")
    return problems


# ─── CLI ──────────────────────────────────────────────────────────────────────


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--workspace-name", help="Fabric workspace display name or GUID")
    ap.add_argument("--name", default="OEE Telemetry Events", help="Event Schema Set display name")
    ap.add_argument("--contract", default=str(DEFAULT_CONTRACT), help="Event contract file (JSON)")
    ap.add_argument("--kql-db-name", default="ManufacturingEH", help="KQL database with the Bronze tables")
    ap.add_argument("--skip-drift-check", action="store_true", help="Publish without comparing to the Bronze tables")
    ap.add_argument("--dry-run", action="store_true", help="Print the EventSchemaSet definition and exit")
    args = ap.parse_args()

    contract = json.loads(Path(args.contract).read_text(encoding="utf-8"))
    definition = build_definition(contract)
    if args.dry_run:
        print(json.dumps(definition, indent=2))
        return 0
    if not args.workspace_name:
        ap.error("--workspace-name is required unless --dry-run")

    ws = next((w["id"] for w in get_all("workspaces") if args.workspace_name in (w["displayName"], w["id"])), None) \
        or sys.exit(f"Workspace {args.workspace_name!r} not found.")
    log(f"✓ Workspace:  {args.workspace_name} ({ws})")
    log(f"✓ Contract:   {Path(args.contract).name} — {', '.join(e['id'] for e in contract['eventTypes'])}")

    if not args.skip_drift_check:
        db = next((d for d in get_all(f"workspaces/{ws}/kqlDatabases") if d["displayName"] == args.kql_db_name), None)
        if not db:
            sys.exit(f"KQL database {args.kql_db_name!r} not found — run scripts/1-setup-fabric.sh first "
                     "(or pass --skip-drift-check).")
        problems = check_drift(contract, db["properties"]["queryServiceUri"], args.kql_db_name)
        if problems:
            log("✗ The contract doesn't match the Bronze tables:")
            for problem in problems:
                log(f"   - {problem}")
            return 1
        log(f"✓ Drift check: every schema matches its Bronze table in {args.kql_db_name}")

    item = next((i for i in get_all(f"workspaces/{ws}/eventSchemaSets") if i["displayName"] == args.name), None)
    if item:
        path, _ = definition_part(get_parts(ws, item["id"]))
        parts = [{"path": path, "payloadType": "InlineBase64",
                  "payload": base64.b64encode(json.dumps(definition, indent=2).encode("utf-8")).decode()}]
        post_lro(f"workspaces/{ws}/eventSchemaSets/{item['id']}/updateDefinition", {"definition": {"parts": parts}})
        item_id = item["id"]
        log(f"✓ Event Schema Set updated: {args.name} ({item_id})")
    else:
        parts = [{"path": DEFINITION_PART, "payloadType": "InlineBase64",
                  "payload": base64.b64encode(json.dumps(definition, indent=2).encode("utf-8")).decode()}]
        created = post_lro(f"workspaces/{ws}/eventSchemaSets",
                           {"displayName": args.name,
                            "description": "Contracts for the OEE simulator's telemetry: machine samples, part "
                                           "events, and maintenance work-order steps.",
                            "definition": {"parts": parts}})
        item_id = created.get("id") or next(
            (i["id"] for i in get_all(f"workspaces/{ws}/eventSchemaSets") if i["displayName"] == args.name), None)
        if not item_id:
            sys.exit("Created the Event Schema Set but can't find it.")
        log(f"✓ Event Schema Set created: {args.name} ({item_id})")

    stored = json.loads(definition_part(get_parts(ws, item_id))[1])
    stored_events = sorted(e.get("id") for e in stored.get("eventTypes", []))
    stored_schemas = sorted(s.get("id") for s in stored.get("schemas", []))
    if stored_events != sorted(e["id"] for e in definition["eventTypes"]) or \
            stored_schemas != sorted(s["id"] for s in definition["schemas"]):
        sys.exit(f"✗ Read back differs: event types {stored_events}, schemas {stored_schemas}")
    log(f"✓ Read back:  event types {', '.join(stored_events)}; schemas {', '.join(stored_schemas)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
