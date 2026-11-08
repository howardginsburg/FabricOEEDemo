#!/usr/bin/env python3
"""Publish the OEE factory ontology (Fabric IQ, new experience) from its TMDL folder.

The checked-in TMDL under ontology/OEEFactoryOntology.Ontology/ is the source of truth. Its tables bind
four kinds of source, recognized by their partitions:
  • the ManufacturingLH lakehouse (Direct Lake through its SQL analytics endpoint): the plant's structure
    and records, everything the graph loads;
  • the ManufacturingEH Eventhouse (DirectQuery, AzureDataExplorer.Contents): machine telemetry, work order
    steps, and part passes, live;
  • the OeeGovernance SQL database (Direct Lake through its SQL analytics endpoint): the OEE targets the
    report's write-back button sets;
  • the OEEAnalytics semantic model (DirectQuery to the model): its DAX measures, referenced with
    EXTERNALMEASURE, are the ontology's metrics, so each KPI is defined once, in the model.

This publisher:
  1. Resolves the workspace and every source item, and the optional resource-link targets (OEEAnalytics
     report, OEE Real-Time Dashboard).
  2. Leaves out entities whose source doesn't exist yet (OeeTarget until scripts/2-setup-translytical.sh
     creates OeeGovernance, the KPI scorecard until scripts/4-setup-powerbi.sh deploys OEEAnalytics, FloorEvent
     until scripts/3-setup-floor-ops.sh), everything that references them, and resource links whose item
     doesn't exist. Re-run after those scripts to add them.
  3. Checks that every measure the ontology references exists in OEEAnalytics with the same data type, and
     copies each one's description, format, and lineage tag from the model's TMDL.
  4. Injects each source's connection and adds the ONT_* partition annotations that identify the item behind
     every table. Without them the ontology accepts the definition but the graph and the agents can't
     resolve the source.
  5. Creates or updates the Ontology item, polling the long-running operation by x-ms-operation-id, then
     reads the definition back to prove nothing was dropped. An unchanged definition isn't sent again: every
     publish re-ingests the data bound to the materialized graph, which is billed per second of graph compute.
  6. Once the ontology's graph is materialized (a portal step: ontology → Manage graph), validates the GQL in
     ontology/graph-queries.json against it and saves the passing queries as the "OEE Graph Queries"
     queryset, when the saved queryset doesn't match the file. --refresh-graph reloads the graph's data and
     re-validates the queries.
  7. --export-ttl writes the ontology as RDF Turtle (OWL classes, datatype and object properties, labels,
     descriptions, synonyms, inheritance) with the same concept mapping as the portal's Export, for RDF and
     knowledge-graph tools. It's generated from the TMDL on demand, so it isn't checked in.

Usage
-----
    python scripts/6-publish-ontology.py --workspace-name "OEE Demo"
    python scripts/6-publish-ontology.py --workspace-name "OEE Demo" --refresh-graph
    python scripts/6-publish-ontology.py --dry-run --out .tmp/ontology-parts
    python scripts/6-publish-ontology.py --export-ttl ontology/OEEFactoryOntology.ttl   # RDF/OWL, offline

Authentication uses the current Azure CLI session ('az login').
"""
from __future__ import annotations

import argparse
import base64
import datetime
import http.client
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

FABRIC_API = "https://api.fabric.microsoft.com/v1"
FABRIC_RESOURCE = "https://api.fabric.microsoft.com"
PBI_API = "https://api.powerbi.com/v1.0/myorg"
PBI_RESOURCE = "https://analysis.windows.net/powerbi/api"

REPO = Path(__file__).resolve().parent.parent
DEFAULT_DEFINITION = REPO / "ontology" / "OEEFactoryOntology.Ontology"
# Kept outside the definition folder: every file in that folder is sent as an ontology part.
GRAPH_QUERIES = REPO / "ontology" / "graph-queries.json"
# The model's measures, whose descriptions, formats, and lineage tags the ontology's metrics take.
MODEL_MEASURES_TMDL = REPO / "powerbi" / "OEEAnalytics.SemanticModel" / "definition" / "tables" / "_Measures.tmdl"
QUERYSET_NAME = "OEE Graph Queries"
LAKEHOUSE_NAME = "ManufacturingLH"
KQL_DATABASE_NAME = "ManufacturingEH"
SQL_DATABASE_NAME = "OeeGovernance"
SEMANTIC_MODEL_NAME = "OEEAnalytics"
LINK_TARGETS = {  # placeholder -> (item type, display name)
    "__REPORT_ID__": ("Report", "OEEAnalytics"),
    "__DASHBOARD_ID__": ("KQLDashboard", "OEE Manufacturing Dashboard"),
}
# Lakehouse tables created by optional setup scripts; their entities wait until present.
OPTIONAL_SOURCES = {
    "FloorEvent": "scripts/3-setup-floor-ops.sh",
}
# Source items created by later setup scripts; the entities bound to them wait until the item exists.
OPTIONAL_ITEMS = {
    "sqldb": ("SQLDatabase", SQL_DATABASE_NAME, "scripts/2-setup-translytical.sh"),
    "model": ("SemanticModel", SEMANTIC_MODEL_NAME, "scripts/4-setup-powerbi.sh"),
}
# ONT_* annotations the service keeps on a table of each kind (Eventhouse tables add ONT_SourceSchema).
EXPECTED_ANNOTATIONS = {"lakehouse": 8, "sqldb": 8, "eventhouse": 7, "model": 6}
# Model measure data types (INFO.VIEW.MEASURES) as EXTERNALMEASURE spells them.
EXTERNAL_TYPES = {"Integer": "INTEGER", "Number": "DOUBLE", "Decimal": "DOUBLE", "Currency": "CURRENCY",
                  "Text": "STRING", "Boolean": "BOOLEAN", "DateTime": "DATETIME"}
INHERITANCE_ERRORS = ("inherit", "baseentitytype", "redefines", "overriddenmetadatafield")


def log(msg: str) -> None:
    print(msg, flush=True)


# ─── Auth + HTTP ──────────────────────────────────────────────────────────────

_tokens: dict[str, str] = {}


def token(resource: str) -> str:
    if resource not in _tokens:
        # On Windows the executable is az.cmd; shell=True resolves either form.
        r = subprocess.run(f'az account get-access-token --resource "{resource}" --query accessToken -o tsv',
                           capture_output=True, text=True, shell=True)
        if r.returncode != 0 or not r.stdout.strip():
            sys.exit(f"az get-access-token failed for {resource}: {r.stderr.strip()}\nRun 'az login' first.")
        _tokens[resource] = r.stdout.strip()
    return _tokens[resource]


def _parse(raw: bytes):
    if not raw:
        return {}
    try:
        return json.loads(raw.decode("utf-8-sig"))
    except json.JSONDecodeError:
        return {"_raw": raw.decode(errors="replace")}


def request(method: str, url: str, resource: str = FABRIC_RESOURCE, body: dict | None = None):
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
                return resp.status, {k.lower(): v for k, v in resp.headers.items()}, _parse(resp.read())
        except urllib.error.HTTPError as e:
            headers = {k.lower(): v for k, v in (e.headers or {}).items()}
            return e.code, headers, _parse(e.read() if e.fp else b"")
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


class OperationError(RuntimeError):
    """A failed Fabric call; ontology validation issues are listed one per line."""

    def __init__(self, detail: dict | str):
        self.detail = detail if isinstance(detail, dict) else {"message": detail}
        message = self.detail.get("message") or json.dumps(self.detail)[:3000]
        code = self.detail.get("errorCode")
        issues = re.search(r"Issues: (\[.*\])", message, re.S)
        if issues:
            try:
                listed = "".join(f"\n    - {i.get('Code')}: {i.get('Message')} ({i.get('JsonPath')})"
                                 for i in json.loads(issues.group(1)))
                message = message[:issues.start()].strip() + listed
            except json.JSONDecodeError:
                pass
        super().__init__(f"{code}: {message}" if code else message)


def post_lro(path: str, body: dict | None = None, timeout: int = 900) -> dict:
    """POST that may answer 202; polls /operations/{x-ms-operation-id} until terminal."""
    status, headers, payload = request("POST", f"{FABRIC_API}/{path}", body=body)
    if status in (200, 201):
        return payload
    if status != 202:
        raise OperationError(payload if payload.get("message") else f"HTTP {status}: {json.dumps(payload)[:3000]}")
    op = headers.get("x-ms-operation-id")
    if not op:
        return payload
    waited = 0
    while waited < timeout:
        time.sleep(3)
        waited += 3
        _, _, state = request("GET", f"{FABRIC_API}/operations/{op}")
        phase = (state.get("status") or "").lower()
        if phase == "succeeded":
            st, _, result = request("GET", f"{FABRIC_API}/operations/{op}/result")
            return result if st < 400 else {}
        if phase in ("failed", "cancelled", "canceled"):
            raise OperationError(state.get("error") or state)
    raise OperationError(f"operation {op} still running after {timeout}s")


# ─── TMDL helpers ─────────────────────────────────────────────────────────────


def read_definition(folder: Path) -> dict[str, str]:
    return {f.relative_to(folder).as_posix(): f.read_text(encoding="utf-8").replace("\r\n", "\n")
            for f in sorted(folder.rglob("*")) if f.is_file()}


def top_level_blocks(text: str) -> list[tuple[str, list[str]]]:
    """(header line, block lines) for each column-0 object, with its /// doc lines."""
    lines = text.rstrip("\n").split("\n")
    headers = [i for i, line in enumerate(lines) if line and not line[0].isspace() and not line.startswith("///")]
    starts = []
    for h in headers:
        s = h
        while s > 0 and lines[s - 1].startswith("///"):
            s -= 1
        starts.append(s)
    return [(lines[h], lines[s:(starts[n + 1] if n + 1 < len(starts) else len(lines))])
            for n, (h, s) in enumerate(zip(headers, starts))]


def join_blocks(blocks: list[list[str]]) -> str:
    return "\n".join(line for block in blocks for line in block).rstrip("\n") + "\n"


def remove_children(text: str, drop) -> str:
    """Remove indent-1 child objects (and their /// docs) for which drop(header, block_text) is true."""
    lines = text.rstrip("\n").split("\n")
    out: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("\t") and not line.startswith("\t\t") and not line.startswith("\t///") and line.strip():
            j = i + 1
            while j < len(lines) and (not lines[j].strip() or lines[j].startswith("\t\t")):
                j += 1
            k = len(out)
            while k > 0 and out[k - 1].startswith("\t///"):
                k -= 1
            if drop(line.strip(), "\n".join(out[k:] + lines[i:j])):
                del out[k:]
            else:
                out.extend(lines[i:j])
            i = j
            continue
        out.append(line)
        i += 1
    return "\n".join(out).rstrip("\n") + "\n"


def table_bindings(files: dict[str, str]) -> dict[str, tuple[str, str]]:
    """TOM table name -> (source kind, source table). Kinds: lakehouse, sqldb, eventhouse, model."""
    out = {}
    for path, text in files.items():
        if not path.startswith("tables/"):
            continue
        table = re.search(r"^table (\S+)", text, re.M).group(1)
        kql = re.search(r'AzureDataExplorer\.Contents\("[^"]*",\s*"[^"]*",\s*"([^"]+)"\)', text)
        entity = re.search(r"entityName:\s*(\S+)", text)
        expression = re.search(r"expressionSource:\s*'([^']+)'", text)
        if kql:
            out[table] = ("eventhouse", kql.group(1))
        elif expression and expression.group(1).startswith("DirectQuery to AS"):
            out[table] = ("model", entity.group(1))
        elif expression and expression.group(1) == f"DirectLake - {SQL_DATABASE_NAME}":
            out[table] = ("sqldb", entity.group(1))
        else:
            out[table] = ("lakehouse", entity.group(1))
    return out


def entity_info(files: dict[str, str]) -> dict[str, dict]:
    info = {}
    for path, text in files.items():
        if path.startswith("entities/"):
            name = re.search(r"^entity (\S+)", text, re.M).group(1)
            table = re.search(r"^\tbackingTable: (\S+)", text, re.M)
            base = re.search(r"^\tbaseEntityType: (\S+)", text, re.M)
            info[name] = {"path": path, "table": table.group(1) if table else None,
                          "extra": re.findall(r"^\t\ttable: (\S+)", text, re.M),
                          "base": base.group(1) if base else None}
    return info


def prune(files: dict[str, str], drop_tables: set[str], drop_entities: set[str]) -> dict[str, list[str]]:
    """Remove TOM tables/entities and everything that references them. Returns what was removed."""
    removed: dict[str, list[str]] = {"tables": sorted(drop_tables), "entities": [], "relationships": [],
                                     "entityRelationships": [], "metrics": []}
    info = entity_info(files)
    drop_entities = set(drop_entities) | {n for n, e in info.items()
                                          if e["table"] in drop_tables or set(e["extra"]) & drop_tables}
    # A derived entity can't outlive its base.
    drop_entities |= {n for n, e in info.items() if e["base"] in drop_entities}
    removed["entities"] = sorted(drop_entities)

    dropped_rels: set[str] = set()
    if "relationships.tmdl" in files:
        kept = []
        for header, block in top_level_blocks(files["relationships.tmdl"]):
            body = "\n".join(block)
            if any(re.search(rf"Column: {re.escape(t)}\.", body) for t in drop_tables):
                dropped_rels.add(header.split()[1])
            else:
                kept.append(block)
        files["relationships.tmdl"] = join_blocks(kept)
    removed["relationships"] = sorted(dropped_rels)

    dropped_entity_rels: set[str] = set()
    if "entityRelationships.tmdl" in files:
        kept = []
        for header, block in top_level_blocks(files["entityRelationships.tmdl"]):
            body = "\n".join(block)
            refs = set(re.findall(r"^\t(?:fromEntity|toEntity): (\S+)", body, re.M))
            backing = set(re.findall(r"^\t\t(?:relationship|fromRelationship|toRelationship): (\S+)", body, re.M))
            junction = set(re.findall(r"^\t\ttable: (\S+)", body, re.M))
            if refs & drop_entities or backing & dropped_rels or junction & drop_tables:
                dropped_entity_rels.add(header.split()[1])
            else:
                kept.append(block)
        files["entityRelationships.tmdl"] = join_blocks(kept)
    removed["entityRelationships"] = sorted(dropped_entity_rels)

    for path in list(files):
        if path.startswith("rules/"):
            files[path] = remove_children(files[path], lambda header, _: (
                (header.startswith("ruleReferencedEntity ") and header.split(None, 1)[1] in drop_entities)
                or (header.startswith("ruleReferencedRelationship ") and header.split(None, 1)[1] in dropped_entity_rels)))
    for name in drop_entities:
        files.pop(info[name]["path"], None)
    for table in drop_tables:
        files.pop(f"tables/{table}.tmdl", None)
    return removed


def drop_unused_expressions(files: dict[str, str]) -> list[str]:
    """Remove shared expressions no remaining table reads (a pruned source's connection would still be resolved)."""
    used = {m for path, text in files.items() if path.startswith("tables/")
            for m in re.findall(r"expressionSource:\s*'([^']+)'", text)}
    kept, dropped = [], []
    for header, block in top_level_blocks(files.get("expressions.tmdl", "")):
        name = re.match(r"expression '([^']+)'", header)
        if name and name.group(1) not in used:
            dropped.append(name.group(1))
        else:
            kept.append(block)
    if dropped:
        files["expressions.tmdl"] = join_blocks(kept)
    return dropped


def strip_inheritance(files: dict[str, str]) -> list[str]:
    """Flatten inheritance: derived entities keep their own properties; abstract bases go."""
    info = entity_info(files)
    abstract = {e["base"] for e in info.values() if e["base"] and info.get(e["base"], {}).get("table") is None}
    for path in [p for p in files if p.startswith("entities/")]:
        text = re.sub(r"^\tbaseEntityType: .*\n", "", files[path], flags=re.M)
        text = re.sub(r"^\t\tredefines: .*\n", "", text, flags=re.M)
        files[path] = re.sub(r"^\toverriddenMetadataField .*\n", "", text, flags=re.M)
    for base in abstract:
        files.pop(info[base]["path"], None)
    for path in [p for p in files if p.startswith("rules/")]:
        files[path] = remove_children(files[path], lambda header, _: (
            header.startswith("ruleReferencedEntity ") and header.split(None, 1)[1] in abstract))
    return sorted(abstract)


def resolve_links(files: dict[str, str], workspace_id: str, link_ids: dict[str, str | None]) -> list[str]:
    """Fill resource-link placeholders; drop links whose target item doesn't exist."""
    dropped = []
    for path in [p for p in files if p.startswith("entities/")]:
        def missing(header: str, block: str, path=path) -> bool:
            gone = header == "resourceLink" and any(ph in block and not link_ids.get(ph) for ph in LINK_TARGETS)
            if gone:
                dropped.append(path)
            return gone
        text = remove_children(files[path], missing).replace("__WORKSPACE_ID__", workspace_id)
        for placeholder, item_id in link_ids.items():
            if item_id:
                text = text.replace(placeholder, item_id)
        files[path] = text
    return dropped


def table_columns(text: str) -> list[tuple[str, str]]:
    """(column, data type) of a TOM table."""
    return re.findall(r"^\tcolumn (\S+)\n(?:\t\t.*\n)*?\t\tdataType: (\S+)", text, re.M)


def model_measure_docs() -> dict[str, dict]:
    """Measure name -> description, format string, and lineage tag, from the OEEAnalytics model's TMDL."""
    text = MODEL_MEASURES_TMDL.read_text(encoding="utf-8").replace("\r\n", "\n")
    out = {}
    for m in re.finditer(r"((?:^\t///.*\n)*)^\tmeasure ('(?:[^']|'')+'|[^\s=]+) = [\s\S]*?(?=^\t(?:measure|column|partition|///)|\Z)",
                         text, re.M):
        block = m.group(0)
        tag = re.search(r"^\t\tlineageTag: (\S+)", block, re.M)
        fmt = re.search(r"^\t\tformatString: (.+)$", block, re.M)
        doc = [line.strip()[3:].strip() for line in m.group(1).splitlines()]
        out[_unquote(m.group(2))] = {"lineageTag": tag.group(1) if tag else None,
                                     "formatString": fmt.group(1).strip() if fmt else None,
                                     "doc": " ".join(d for d in doc if d and not d.startswith("──"))}
    return out


def model_column_tags() -> dict[str, str]:
    """Column name -> lineage tag of the OEEAnalytics measures table's columns, from the model's TMDL."""
    text = MODEL_MEASURES_TMDL.read_text(encoding="utf-8").replace("\r\n", "\n")
    return {_unquote(name): tag for name, tag in
            re.findall(r"^\tcolumn ('[^']+'|\S+)\n(?:\t\t.*\n)*?\t\tlineageTag: (\S+)", text, re.M)}


def enrich_measures(files: dict[str, str]) -> list[str]:
    """Give each EXTERNALMEASURE the model measure's description, format, and source lineage tag, and each column
    of a model-bound table its model column's source lineage tag, so they're defined once, in the model. Returns
    the referenced measures and columns the model's TMDL doesn't have."""
    docs, columns, missing = model_measure_docs(), model_column_tags(), []

    def add(m: re.Match) -> str:
        info = docs.get(m.group("name"))
        if not info:
            missing.append(m.group("name"))
            return m.group(0)
        return ((f"\t/// {info['doc']}\n" if info["doc"] else "") + m.group("head")
                + (f"\t\tformatString: {info['formatString']}\n" if info["formatString"] else "") + m.group("tag")
                + (f"\t\tsourceLineageTag: {info['lineageTag']}\n" if info["lineageTag"] else ""))

    def add_column(m: re.Match) -> str:
        tag = columns.get(_unquote(m.group("name")))
        if not tag:
            missing.append(m.group("name"))
            return m.group(0)
        return m.group(0) + f"\t\tsourceLineageTag: {tag}\n"
    for path in [p for p in files if p.startswith("tables/")]:
        files[path] = re.sub(r'(?P<head>^\tmeasure .+ = EXTERNALMEASURE\("(?P<name>[^"]+)",[^\n]*\n)(?P<tag>\t\tlineageTag: \S+\n)',
                             add, files[path], flags=re.M)
        if "expressionSource: 'DirectQuery to AS - " in files[path]:
            files[path] = re.sub(r"^\tcolumn (?P<name>'[^']+'|\S+)\n(?:\t\t.*\n)*?\t\tlineageTag: \S+\n", add_column,
                                 files[path], flags=re.M)
    return missing


def bind_sources(files: dict[str, str], *, workspace_id: str, workspace_name: str, lakehouse: tuple[str, str],
                 kql: tuple[str, str, str], sqldb: tuple[str, str] | None, model: str | None) -> None:
    """Inject each source's connection and annotate every partition with the item behind it.

    lakehouse: (item id, SQL analytics endpoint); kql: (database id, database name, cluster query URI);
    sqldb: (item id, SQL analytics endpoint); model: semantic model id. A pruned source is None.
    """
    pinned = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    kinds = table_bindings(files)
    item = {
        "lakehouse": [("ONT_ItemId", lakehouse[0]), ("ONT_ItemKind", "Lakehouse"), ("ONT_ItemName", LAKEHOUSE_NAME),
                      ("ONT_WorkspaceName", workspace_name), ("ONT_SqlEndpoint", lakehouse[1]),
                      ("ONT_SqlDatabase", LAKEHOUSE_NAME)],
        "eventhouse": [("ONT_ItemId", kql[0]), ("ONT_ItemKind", "KQLDatabase"), ("ONT_ItemName", kql[1]),
                       ("ONT_WorkspaceName", workspace_name)],
    }
    expressions = files["expressions.tmdl"].replace("__SQL_ENDPOINT__", lakehouse[1])
    if sqldb:
        item["sqldb"] = [("ONT_ItemId", sqldb[0]), ("ONT_ItemKind", "SQLDatabase"), ("ONT_ItemName", SQL_DATABASE_NAME),
                         ("ONT_WorkspaceName", workspace_name), ("ONT_SqlEndpoint", sqldb[1]),
                         ("ONT_SqlDatabase", SQL_DATABASE_NAME)]
        expressions = expressions.replace("__OEEGOVERNANCE_SQL_ENDPOINT__", sqldb[1])
    if model:
        item["model"] = [("ONT_ItemId", model), ("ONT_ItemKind", "Dataset"), ("ONT_ItemName", SEMANTIC_MODEL_NAME),
                         ("ONT_WorkspaceName", workspace_name)]
        expressions = (expressions.replace("__WORKSPACE_ID__", workspace_id).replace("__SEMANTIC_MODEL_ID__", model)
                       .replace("__WORKSPACE_NAME__", workspace_name))
    files["expressions.tmdl"] = expressions
    for path in [p for p in files if p.startswith("tables/")]:
        kind = kinds[re.search(r"^table (\S+)", files[path], re.M).group(1)][0]
        text = files[path]
        if kind == "eventhouse":
            text = text.replace("__KQL_CLUSTER_URI__", kql[2]).replace("__KQL_DATABASE__", kql[1])
        if kind == "model":
            text = text.replace("__WORKSPACE_ID__", workspace_id).replace("__SEMANTIC_MODEL_ID__", model)
        pairs = [("ONT_WorkspaceId", workspace_id)] + item[kind] + [("ONT_PinnedAtUtc", pinned)]
        text = text.rstrip("\n") + "\n\n" + "\n".join(f"\t\tannotation {k} = {v}" for k, v in pairs) + "\n"
        if kind == "eventhouse":
            # The portal's Eventhouse binding records the source columns on the table.
            schema = {"version": 1, "columns": [{"name": n, "dataType": t} for n, t in table_columns(text)]}
            text += f"\n\tannotation ONT_SourceSchema = {json.dumps(schema, separators=(',', ':'))}\n"
        files[path] = text


def to_parts(files: dict[str, str]) -> list[dict]:
    return [{"path": path, "payload": base64.b64encode(text.encode("utf-8")).decode(), "payloadType": "InlineBase64"}
            for path, text in files.items()]


# ─── Workspace resolution ─────────────────────────────────────────────────────


def resolve_workspace(name_or_id: str) -> tuple[str, str]:
    for ws in get_all("workspaces"):
        if name_or_id in (ws["displayName"], ws["id"]):
            return ws["id"], ws["displayName"]
    sys.exit(f"Workspace {name_or_id!r} not found.")


def find_item(ws: str, item_type: str, name: str) -> str | None:
    return next((i["id"] for i in get_all(f"workspaces/{ws}/items?type={item_type}") if i["displayName"] == name), None)


def resolve_lakehouse(ws: str) -> tuple[str, str, str]:
    lh = next((i for i in get_all(f"workspaces/{ws}/lakehouses") if i["displayName"] == LAKEHOUSE_NAME), None)
    if not lh:
        sys.exit(f"Lakehouse {LAKEHOUSE_NAME!r} not found — run scripts/1-setup-fabric.sh first.")
    sql = lh.get("properties", {}).get("sqlEndpointProperties") or {}
    if not sql.get("connectionString") or not sql.get("id"):
        sys.exit(f"{LAKEHOUSE_NAME} SQL analytics endpoint isn't provisioned yet — retry in a minute.")
    return lh["id"], sql["connectionString"], sql["id"]


def refresh_sql_endpoint(ws: str, sql_endpoint_id: str) -> None:
    """Sync the SQL analytics endpoint with OneLake so new shortcuts and the latest Delta versions are visible.

    The ontology binds its tables through this endpoint, and its metadata sync can lag far behind
    (tables created by shortcuts stay invisible until it runs).
    """
    try:
        result = post_lro(f"workspaces/{ws}/sqlEndpoints/{sql_endpoint_id}/refreshMetadata",
                          {"timeout": {"timeUnit": "Minutes", "value": 10}})
    except OperationError as err:
        log(f"! SQL endpoint metadata refresh failed ({err}) — new tables may not be queryable yet")
        return
    failed = [t["tableName"] for t in result.get("value", []) if t.get("status") not in ("Success", "NotRun")]
    if failed:
        log(f"! SQL endpoint couldn't sync: {', '.join(failed)}")
    else:
        log(f"✓ SQL endpoint synced ({len(result.get('value', []))} tables)")


def lakehouse_tables(ws: str, lakehouse_id: str) -> set[str]:
    return {s["name"] for s in get_all(f"workspaces/{ws}/items/{lakehouse_id}/shortcuts")
            if s.get("path", "").strip("/") == "Tables/dbo"}


def resolve_kql(ws: str) -> tuple[str, str, str]:
    """(database id, database name, cluster query URI) of the ManufacturingEH KQL database."""
    db = next((d for d in get_all(f"workspaces/{ws}/kqlDatabases") if d["displayName"] == KQL_DATABASE_NAME), None)
    if not db:
        sys.exit(f"KQL database {KQL_DATABASE_NAME!r} not found — run scripts/1-setup-fabric.sh first.")
    return db["id"], db["displayName"], db["properties"]["queryServiceUri"]


def kql_tables(cluster: str, database: str) -> set[str] | None:
    """Tables in the KQL database, or None when they can't be listed."""
    status, _, body = request("POST", f"{cluster}/v1/rest/mgmt", cluster,
                              {"db": database, "csl": ".show tables | project TableName"})
    if status >= 400 or not body.get("Tables"):
        return None
    return {row[0] for row in body["Tables"][0]["Rows"]}


def resolve_sql_database(ws: str) -> tuple[str, str, str] | None:
    """(item id, SQL analytics endpoint, endpoint id) of the OeeGovernance SQL database; None until it exists.
    Fabric names a SQL database's SQL analytics endpoint after the database. A database whose endpoint can't be
    resolved stops the publish instead: treating it as absent would publish the ontology without OeeTarget."""
    database = find_item(ws, "SQLDatabase", SQL_DATABASE_NAME)
    if not database:
        return None
    endpoint = find_item(ws, "SQLEndpoint", SQL_DATABASE_NAME)
    if not endpoint:
        sys.exit(f"{SQL_DATABASE_NAME}'s SQL analytics endpoint isn't provisioned yet — retry in a minute.")
    status, _, body = request("GET", f"{FABRIC_API}/workspaces/{ws}/sqlEndpoints/{endpoint}/connectionString")
    if status >= 400 or not body.get("connectionString"):
        sys.exit(f"Couldn't read {SQL_DATABASE_NAME}'s SQL analytics endpoint (HTTP {status}) — retry in a minute.")
    return database, body["connectionString"], endpoint


def check_model_measures(files: dict[str, str], model: str) -> list[str]:
    """Measures the ontology references that the deployed model lacks or types differently."""
    refs = {m.group(1): m.group(2) for path, text in files.items() if path.startswith("tables/")
            for m in re.finditer(r'EXTERNALMEASURE\("([^"]+)",\s*(\w+),', text)}
    if not refs:
        return []
    status, _, body = request("POST", f"{PBI_API}/datasets/{model}/executeQueries", PBI_RESOURCE,
                              {"queries": [{"query": 'EVALUATE SELECTCOLUMNS(INFO.VIEW.MEASURES(), "n", [Name], '
                                                     '"t", [DataType])'}]})
    if status >= 400:
        log(f"! Couldn't list {SEMANTIC_MODEL_NAME}'s measures (HTTP {status}) — measure references not checked")
        return []
    types = {row["[n]"]: row["[t]"] for row in body["results"][0]["tables"][0]["rows"]}
    problems = []
    for name, data_type in sorted(refs.items()):
        if name not in types:
            problems.append(f"{name}: not in {SEMANTIC_MODEL_NAME}")
        elif EXTERNAL_TYPES.get(types[name]) != data_type:
            problems.append(f"{name}: {data_type} in the ontology, {types[name]} in {SEMANTIC_MODEL_NAME}")
    return problems


# ─── Deploy ───────────────────────────────────────────────────────────────────


def deploy(ws: str, name: str, description: str, files: dict[str, str], recreate: bool) -> str:
    existing = find_item(ws, "Ontology", name)
    if existing and recreate:
        log(f"… Deleting existing ontology {existing}")
        status, _, _ = request("DELETE", f"{FABRIC_API}/workspaces/{ws}/items/{existing}")
        if status >= 400:
            sys.exit(f"DELETE failed: HTTP {status}")
        existing = None
    definition = {"parts": to_parts(files)}
    if existing:
        log(f"… Updating ontology {name} ({existing})")
        post_lro(f"workspaces/{ws}/items/{existing}/updateDefinition?updateMetadata=true", {"definition": definition})
        return existing
    log(f"… Creating ontology {name}")
    body = {"displayName": name, "description": description, "type": "Ontology", "definition": definition}
    waited = 0
    while True:
        try:
            result = post_lro(f"workspaces/{ws}/items", body)
            break
        except OperationError as err:
            # Fabric reserves a deleted item's display name for a few minutes.
            if "NotAvailableYet" in str(err) and waited < 600:
                log(f"  waiting for the display name to free up… ({waited}s)")
                time.sleep(30)
                waited += 30
                continue
            raise
    return result.get("id") or find_item(ws, "Ontology", name) or sys.exit("Ontology created but not found.")


def read_back(ws: str, item: str) -> dict[str, str]:
    result = post_lro(f"workspaces/{ws}/items/{item}/getDefinition")
    return {p["path"]: base64.b64decode(p["payload"]).decode("utf-8-sig").replace("\r\n", "\n")
            for p in result.get("definition", {}).get("parts", [])}


SERVICE_PARTS = {".platform", "model.tmdl"}  # written by the service; never compared


def canonical_tmdl(text: str) -> list:
    """TMDL as an order-insensitive tree (each object with its /// doc lines, children sorted). The service
    re-serializes what it stores: blank lines between synonyms, synonyms moved after overriddenMetadataField,
    enum casing (dialect: sQL), ALM placeholders for the Sql.Database arguments and for the workspace in the
    semantic model connection (the ONT_* annotations still carry the binding), and quotes on object names.
    Those all compare equal, as does ONT_PinnedAtUtc, which bind_sources stamps with the publish time (the
    service re-stamps it on Eventhouse tables); any added, removed, or edited line doesn't."""
    root: list = []
    stack: list = [(-1, root)]
    doc: list[str] = []
    for raw in text.replace("\r\n", "\n").splitlines():
        if not raw.strip():
            continue
        depth = len(raw) - len(raw.lstrip("\t"))
        line = re.sub(r"^(dialect:\s*)(\S+)$", lambda m: m.group(1) + m.group(2).lower(), raw.strip())
        line = re.sub(r'Sql\.Database\("[^"]*", "[^"]*"\)', "Sql.Database()", line)
        line = re.sub(r'(AnalysisServices\.Database\("powerbi://api\.powerbi\.com/v1\.0/myorg/)[^"]*"', r'\1"', line)
        line = re.sub(r"^(partition|table|measure|column) '([\w.-]+)'", r"\1 \2", line)
        line = re.sub(r"^(annotation ONT_PinnedAtUtc\s*=).*$", r"\1", line)
        if line.startswith("///"):
            doc.append(line)
            continue
        while stack[-1][0] >= depth:
            stack.pop()
        node = ("\n".join(doc + [line]), [])
        doc = []
        stack[-1][1].append(node)
        stack.append((depth, node[1]))

    def freeze(nodes: list) -> list:
        return sorted((head, freeze(children)) for head, children in nodes)
    return freeze(root)


def changed_parts(files: dict[str, str], deployed: dict[str, str]) -> list[str]:
    """Parts whose content differs from the deployed definition, ignoring how the service re-serializes it."""
    paths = (set(files) | set(deployed)) - SERVICE_PARTS
    return sorted(p for p in paths if canonical_tmdl(files.get(p, "")) != canonical_tmdl(deployed.get(p, "")))


def summarize(files: dict[str, str]) -> str:
    count = lambda prefix: sum(1 for p in files if p.startswith(prefix))  # noqa: E731
    rels = len(top_level_blocks(files.get("entityRelationships.tmdl", "")))
    metrics = sum(text.count("EXTERNALMEASURE(") for path, text in files.items() if path.startswith("tables/"))
    kinds = sorted({kind for kind, _ in table_bindings(files).values()})
    return (f"{count('entities/')} entity types, {rels} relationship types, {count('rules/')} rules, "
            f"{metrics} model metrics, {count('tables/')} backing tables ({', '.join(kinds)})")


# ─── Ontology graph ───────────────────────────────────────────────────────────


def ontology_graph(ws: str, ontology_id: str, name: str) -> str | None:
    """The GraphModel every new-experience ontology creates for itself (empty until materialized)."""
    return find_item(ws, "GraphModel", f"{name}_graph_{ontology_id.replace('-', '')}")


def graph_labels(ws: str, graph_id: str) -> set[str] | None:
    """GQL node and edge labels of the materialized graph, or None while it isn't materialized."""
    status, _, body = request("GET", f"{FABRIC_API}/workspaces/{ws}/graphModels/{graph_id}/getQueryableGraphType?beta=true")
    if status >= 400 or not body or not body.get("nodeTypes"):
        return None
    return {label for kind in ("nodeTypes", "edgeTypes") for t in body.get(kind) or [] for label in t.get("labels", [])}


def refresh_graph(ws: str, graph_id: str, timeout: int = 1800) -> None:
    """Reload the materialized graph from the bound lakehouse tables (on-demand RefreshGraph job)."""
    status, headers, body = request("POST", f"{FABRIC_API}/workspaces/{ws}/items/{graph_id}/jobs/RefreshGraph/instances")
    if status != 202:
        log(f"! Graph refresh didn't start: HTTP {status} {body.get('message', '')}")
        return
    log("… Refreshing the graph (queued jobs can take a few minutes)")
    location, waited = headers.get("location"), 0
    while location and waited < timeout:
        time.sleep(20)
        waited += 20
        _, _, job = request("GET", location)
        if job.get("status") in ("Completed", "Failed", "Cancelled", "Deduped"):
            if job["status"] == "Completed":
                log(f"✓ Graph refreshed ({waited}s)")
            else:
                log(f"! Graph refresh {job['status']}: {json.dumps(job.get('failureReason'))[:500]}")
            return
    log(f"! Graph refresh still running after {timeout}s — check the graph's job history")


def query_labels(gql: str) -> set[str]:
    """Node and edge labels a GQL query matches on."""
    return set(re.findall(r"[(\[]\w*:(\w+)", gql))


def queryset_current(ws: str, labels: set[str]) -> bool:
    """True when the saved queryset holds exactly the graph-queries.json queries the graph's labels allow.
    It reads the queryset's definition only, so the graph engine (billed per second it runs) isn't woken."""
    existing = find_item(ws, "GraphQuerySet", QUERYSET_NAME)
    if not existing or not GRAPH_QUERIES.exists():
        return False
    try:
        parts = {p["path"]: base64.b64decode(p["payload"]).decode("utf-8-sig") for p in
                 post_lro(f"workspaces/{ws}/items/{existing}/getDefinition").get("definition", {}).get("parts", [])}
        saved = json.loads(json.loads(parts["exportedDefinition.json"])["ArtifactContents"][0]["Value"])["queries"]
    except (KeyError, IndexError, TypeError, ValueError, OperationError):
        return False
    expected = {(q["name"], q["gql"]) for q in json.loads(GRAPH_QUERIES.read_text(encoding="utf-8"))
                if not query_labels(q["gql"]) - labels}
    return {(q.get("displayName"), q.get("gqlQueryText")) for q in saved} == expected


def publish_graph_queries(ws: str, graph_id: str, labels: set[str]) -> None:
    """Validate each GQL query in ontology/graph-queries.json and save the passing ones as a GraphQuerySet."""
    if not GRAPH_QUERIES.exists():
        return
    saved = []
    for query in json.loads(GRAPH_QUERIES.read_text(encoding="utf-8")):
        missing = query_labels(query["gql"]) - labels
        if missing:
            log(f"  · skipped {query['name']!r}: {', '.join(sorted(missing))} not in the graph")
            continue
        status, _, body = request("POST", f"{FABRIC_API}/workspaces/{ws}/graphModels/{graph_id}/executeQuery?beta=true",
                                  body={"query": query["gql"]})
        code = (body.get("status") or {}).get("code") or ""
        # GQL class 02 is "no data": a valid query with an empty result (seen right after a graph refresh).
        if status >= 400 or not code.startswith(("00", "02")):
            log(f"  ! {query['name']!r} failed validation: {json.dumps(body.get('status') or body)[:300]}")
            continue
        saved.append({"displayName": query["name"], "id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"oee-gql/{query['name']}")),
                      "queryMode": "GQLCode", "gqlQueryText": query["gql"], "nodes": [], "edges": []})
    if not saved:
        return
    queryset = {"graphInstanceObjectId": graph_id, "graphInstanceFolderObjectId": ws, "queries": saved}
    exported = {"dependencies": [], "indirectDependencies": [], "ConfigurationCategories": [],
                "ArtifactContents": [{"ContentType": 1, "Value": json.dumps(queryset), "ContentId": None}]}
    parts = [{"path": "exportedDefinition.json", "payloadType": "InlineBase64",
              "payload": base64.b64encode(json.dumps(exported).encode("utf-8")).decode()}]
    existing = find_item(ws, "GraphQuerySet", QUERYSET_NAME)
    if existing:
        post_lro(f"workspaces/{ws}/items/{existing}/updateDefinition", {"definition": {"parts": parts}})
    else:
        post_lro(f"workspaces/{ws}/items", {"displayName": QUERYSET_NAME, "type": "GraphQuerySet",
                                             "description": "GQL over the OEE ontology graph",
                                             "definition": {"parts": parts}})
    log(f"✓ Graph queryset '{QUERYSET_NAME}': {len(saved)} validated GQL queries")


# ─── RDF export ───────────────────────────────────────────────────────────────

XSD_RANGES = {"string": "xsd:string", "int64": "xsd:long", "double": "xsd:double", "decimal": "xsd:decimal",
              "boolean": "xsd:boolean", "dateTime": "xsd:dateTime"}


def _unquote(raw: str) -> str:
    raw = raw.strip()
    return raw[1:-1].replace("''", "'") if len(raw) > 1 and raw[0] == raw[-1] == "'" else raw


def _literal(text: str) -> str:
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def _parse_tmdl_objects(text: str, keyword: str) -> list[dict]:
    """Objects declared with `keyword` at the top level: name, doc comment, top-level settings, entity-level
    synonyms, and properties (doc, data type, redefines, synonyms)."""
    objects, doc, current, prop = [], [], None, None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("///"):
            doc.append(stripped[3:].strip())
            continue
        head = re.match(rf"^{keyword} (\S+)", line)
        if head:
            current = {"name": head.group(1), "doc": " ".join(doc), "settings": {}, "synonyms": [], "props": []}
            objects.append(current)
            doc, prop = [], None
            continue
        if current is None:
            doc = []
            continue
        if line.startswith("\t\t") and prop is not None:
            setting = re.match(r"^\t\t(dataType|redefines): (.+)$", line)
            if setting:
                prop[setting.group(1)] = setting.group(2).strip()
            elif stripped.startswith("synonym "):
                prop["synonyms"].append(_unquote(stripped[len("synonym "):]))
            continue
        if line.startswith("\t") and not line.startswith("\t\t"):
            prop = None
            declared = re.match(r"^\tproperty (\S+)", line)
            if declared:
                prop = {"name": declared.group(1), "doc": " ".join(doc), "synonyms": []}
                current["props"].append(prop)
            elif stripped.startswith("synonym "):
                current["synonyms"].append(_unquote(stripped[len("synonym "):]))
            else:
                setting = re.match(r"^\t(\w+): (.+)$", line)
                if setting:
                    current["settings"][setting.group(1)] = setting.group(2).strip()
            doc = []
    return objects


def export_turtle(files: dict[str, str], name: str, description: str, base: str) -> tuple[str, dict[str, int]]:
    """Serialize the ontology as RDF (Turtle) with the portal Export's concept mapping: entity types →
    owl:Class, properties → owl:DatatypeProperty (rdfs:domain, xsd rdfs:range), relationship types →
    owl:ObjectProperty, descriptions → rdfs:comment, names → rdfs:label, synonyms → skos:altLabel, and
    base entity types → rdfs:subClassOf. Rules and metrics have no RDF mapping and aren't exported.
    A redefined property is inherited from its base class, so it isn't declared again."""
    base = base if base.endswith(("/", "#")) else base + "/"
    entities = [e for path in sorted(files) if path.startswith("entities/")
                for e in _parse_tmdl_objects(files[path], "entity")]
    relationships = _parse_tmdl_objects(files.get("entityRelationships.tmdl", ""), "entityRelationship")
    namespaces = sorted({obj["name"].split("#")[0] for obj in entities + relationships})

    def iri(qualified: str) -> str:
        namespace, local = qualified.split("#", 1)
        return f"{namespace}:{local}"

    out = ["@prefix owl: <http://www.w3.org/2002/07/owl#> .",
           "@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .",
           "@prefix skos: <http://www.w3.org/2004/02/skos/core#> .",
           "@prefix xsd: <http://www.w3.org/2001/XMLSchema#> ."]
    out += [f"@prefix {ns}: <{base}{ns}#> ." for ns in namespaces]
    out += ["", f"<{base}> a owl:Ontology ;", f"    rdfs:label {_literal(name)}"
            + (f" ;\n    rdfs:comment {_literal(description)} ." if description else " ."), ""]

    def block(subject: str, kind: str, triples: list[tuple[str, str]], synonyms: list[str]) -> None:
        lines = [f"{subject} a {kind}"] + [f"    {p} {o}" for p, o in triples]
        if synonyms:
            lines.append("    skos:altLabel " + ", ".join(_literal(s) for s in synonyms))
        out.append(" ;\n".join(lines) + " .\n")

    counts = {"classes": 0, "datatypeProperties": 0, "objectProperties": 0}
    for entity in entities:
        subject = iri(entity["name"])
        triples = [("rdfs:label", _literal(entity["name"].split("#", 1)[1]))]
        if entity["doc"]:
            triples.append(("rdfs:comment", _literal(entity["doc"])))
        if entity["settings"].get("baseEntityType"):
            triples.append(("rdfs:subClassOf", iri(entity["settings"]["baseEntityType"])))
        block(subject, "owl:Class", triples, entity["synonyms"])
        counts["classes"] += 1
        for prop in entity["props"]:
            if prop.get("redefines"):
                continue
            data_type = re.sub(r"^TimeSeries<(\w+)>$", r"\1", prop.get("dataType", "string"))
            triples = [("rdfs:domain", subject), ("rdfs:range", XSD_RANGES.get(data_type, "xsd:string")),
                       ("rdfs:label", _literal(prop["name"]))]
            if prop["doc"]:
                triples.append(("rdfs:comment", _literal(prop["doc"])))
            block(f"{subject}.{prop['name']}", "owl:DatatypeProperty", triples, prop["synonyms"])
            counts["datatypeProperties"] += 1
    for rel in relationships:
        triples = [("rdfs:domain", iri(rel["settings"]["fromEntity"])), ("rdfs:range", iri(rel["settings"]["toEntity"])),
                   ("rdfs:label", _literal(rel["name"].split("#", 1)[1]))]
        if rel["doc"]:
            triples.append(("rdfs:comment", _literal(rel["doc"])))
        block(iri(rel["name"]), "owl:ObjectProperty", triples, rel["synonyms"])
        counts["objectProperties"] += 1
    return "\n".join(out), counts


# ─── CLI ──────────────────────────────────────────────────────────────────────


def main() -> int:
    # A cp1252 pipe on Windows can't encode the status marks; degrade them instead of crashing.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--workspace-name", help="Fabric workspace display name or GUID")
    ap.add_argument("--definition", default=str(DEFAULT_DEFINITION), help="Ontology TMDL folder")
    ap.add_argument("--name", help="Ontology display name (default: .platform displayName)")
    ap.add_argument("--no-inheritance", action="store_true", help="Flatten entity inheritance before publishing")
    ap.add_argument("--recreate", action="store_true", help="Delete the existing ontology and create it again")
    ap.add_argument("--refresh-graph", action="store_true",
                    help="Reload the materialized ontology graph from the lakehouse and wait for it")
    ap.add_argument("--dry-run", action="store_true", help="Write the final parts to --out; no REST calls")
    ap.add_argument("--out", help="Output directory for --dry-run")
    ap.add_argument("--export-ttl", metavar="PATH",
                    help="Write the ontology as RDF Turtle (portal Export mapping) to PATH and exit; no REST calls")
    ap.add_argument("--ttl-base", default="http://example.org/oee/", help="Base IRI for --export-ttl")
    args = ap.parse_args()

    folder = Path(args.definition)
    if not (folder / ".platform").exists():
        sys.exit(f"No ontology definition at {folder}")
    files = read_definition(folder)
    platform = json.loads(files[".platform"])
    name = args.name or platform["metadata"]["displayName"]
    platform["metadata"]["displayName"] = name
    files[".platform"] = json.dumps(platform, indent=2) + "\n"
    description = platform["metadata"].get("description", "")
    if args.export_ttl:
        turtle, counts = export_turtle(files, name, description, args.ttl_base)
        Path(args.export_ttl).write_text(turtle, encoding="utf-8")
        log(f"✓ Wrote {args.export_ttl}: {counts['classes']} classes, {counts['datatypeProperties']} datatype "
            f"properties, {counts['objectProperties']} object properties")
        return 0
    flattened = strip_inheritance(files) if args.no_inheritance else []

    if args.dry_run:
        if not args.out:
            sys.exit("--dry-run requires --out DIR")
        resolve_links(files, "00000000-0000-0000-0000-000000000000",
                      {ph: "00000000-0000-0000-0000-000000000001" for ph in LINK_TARGETS})
        enrich_measures(files)
        bind_sources(files, workspace_id="00000000-0000-0000-0000-000000000000", workspace_name="Example",
                     lakehouse=("00000000-0000-0000-0000-000000000002", "example.datawarehouse.fabric.microsoft.com"),
                     kql=("00000000-0000-0000-0000-000000000003", KQL_DATABASE_NAME, "https://example.kusto.fabric.microsoft.com"),
                     sqldb=("00000000-0000-0000-0000-000000000004", "example.datawarehouse.fabric.microsoft.com"),
                     model="00000000-0000-0000-0000-000000000005")
        out = Path(args.out)
        for path, text in files.items():
            target = out / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8")
        log(f"✓ Wrote {len(files)} parts to {out} ({summarize(files)})")
        return 0

    if not args.workspace_name:
        sys.exit("--workspace-name is required (unless --dry-run)")
    ws, ws_name = resolve_workspace(args.workspace_name)
    log(f"✓ Workspace:  {ws_name} ({ws})")
    lakehouse_id, sql_endpoint, sql_endpoint_id = resolve_lakehouse(ws)
    log(f"✓ Lakehouse:  {LAKEHOUSE_NAME} ({lakehouse_id}) @ {sql_endpoint}")
    refresh_sql_endpoint(ws, sql_endpoint_id)
    kql = resolve_kql(ws)
    log(f"✓ Eventhouse: {kql[1]} ({kql[0]}) @ {kql[2]}")

    bindings = table_bindings(files)
    sources = {t: s for t, (kind, s) in bindings.items() if kind == "lakehouse"}
    missing = set(sources.values()) - lakehouse_tables(ws, lakehouse_id)
    core = missing - set(OPTIONAL_SOURCES)
    if core:
        sys.exit(f"Lakehouse tables missing: {sorted(core)} — re-run scripts/1-setup-fabric.sh "
                 "(after enabling OneLake availability) and try again.")
    for delta in sorted(missing):
        removed = prune(files, {t for t, d in sources.items() if d == delta}, set())
        log(f"! {delta} isn't in {LAKEHOUSE_NAME} yet — leaving out {', '.join(removed['entities']) or 'its tables'}"
            f" (run {OPTIONAL_SOURCES[delta]}, then re-run this script)")
    live = kql_tables(kql[2], kql[1])
    absent = {s for kind, s in bindings.values() if kind == "eventhouse"} - (live or set())
    if live is not None and absent:
        sys.exit(f"Eventhouse tables missing from {kql[1]}: {sorted(absent)} — re-run scripts/1-setup-fabric.sh.")

    sqldb = resolve_sql_database(ws)
    model = find_item(ws, "SemanticModel", SEMANTIC_MODEL_NAME)
    for kind, present in (("sqldb", sqldb), ("model", model)):
        if not present:
            item_type, title, script = OPTIONAL_ITEMS[kind]
            removed = prune(files, {t for t, (k, _) in bindings.items() if k == kind}, set())
            log(f"! {item_type} {title!r} not found — leaving out {', '.join(removed['entities']) or 'its tables'}"
                f" (run {script}, then re-run this script)")
    if sqldb:
        log(f"✓ SQL database: {SQL_DATABASE_NAME} ({sqldb[0]}) @ {sqldb[1]}")
        refresh_sql_endpoint(ws, sqldb[2])
    if model and any(kind == "model" for kind, _ in table_bindings(files).values()):
        problems = check_model_measures(files, model)
        if problems:
            sys.exit(f"✗ The ontology references {SEMANTIC_MODEL_NAME} measures it doesn't have — fix "
                     "tables/_Measures.tmdl or redeploy the model (scripts/4-setup-powerbi.sh):\n    "
                     + "\n    ".join(problems))
        unknown = enrich_measures(files)
        if unknown:
            sys.exit(f"✗ Not in {MODEL_MEASURES_TMDL.relative_to(REPO)}: {', '.join(unknown)}")
        log(f"✓ Semantic model: {SEMANTIC_MODEL_NAME} ({model}); every referenced measure exists")
    drop_unused_expressions(files)

    link_ids = {ph: find_item(ws, kind, title) for ph, (kind, title) in LINK_TARGETS.items()}
    for ph, (kind, title) in LINK_TARGETS.items():
        if not link_ids[ph]:
            log(f"! {kind} {title!r} not found — its resource links are left out until it exists")
    resolve_links(files, ws, link_ids)
    bind_sources(files, workspace_id=ws, workspace_name=ws_name, lakehouse=(lakehouse_id, sql_endpoint), kql=kql,
                 sqldb=sqldb[:2] if sqldb else None, model=model)
    log(f"✓ Definition: {summarize(files)}")

    # Publishing re-ingests every table bound to the materialized graph, which is billed per second of graph
    # compute, so an unchanged definition isn't sent again (re-runs of scripts/1 call this script).
    existing = None if args.recreate else find_item(ws, "Ontology", name)
    changed = changed_parts(files, read_back(ws, existing)) if existing else None
    if existing and not changed:
        item = existing
        log(f"✓ Ontology unchanged: {name} ({item}) — not republished")
    else:
        if changed:
            log(f"… Changed: {', '.join(changed[:6])}" + (f" and {len(changed) - 6} more" if len(changed) > 6 else ""))
        try:
            item = deploy(ws, name, description, files, args.recreate)
        except OperationError as err:
            if flattened or not any(marker in str(err).lower() for marker in INHERITANCE_ERRORS):
                sys.exit(f"✗ Ontology publish failed: {err}")
            flattened = strip_inheritance(files)
            log(f"! The service rejected entity inheritance — {err}")
            log(f"! Publishing with {', '.join(flattened)} flattened into its derived entities"
                " (fix the TMDL, or pass --no-inheritance where entity inheritance isn't enabled)")
            try:
                item = deploy(ws, name, description, files, False)
            except OperationError as retry_err:
                sys.exit(f"✗ Ontology publish failed: {retry_err}")
        log(f"✓ Ontology published: {name} ({item})")

        returned = read_back(ws, item)
        dropped = sorted(set(files) - set(returned) - {".platform"})
        if dropped:
            sys.exit(f"✗ The service dropped parts it didn't accept: {dropped}")
        thin = [table for table, (kind, _) in table_bindings(files).items()
                if returned.get(f"tables/{table}.tmdl", "").count("annotation ONT_") < EXPECTED_ANNOTATIONS[kind]]
        if thin:
            log(f"! ONT_* annotations not fully retained on {', '.join(sorted(thin))} — the graph and the agents may"
                " not resolve their source")
        log(f"✓ Read back:  {summarize(returned)}; nothing dropped")

    graph = ontology_graph(ws, item, name)
    labels = graph_labels(ws, graph) if graph else None
    if labels is None:
        log("\nNext: materialize the ontology graph (open the ontology → Manage graph → select the eligible entities →"
            " Materialize), then re-run this script to add the GQL queryset. Then publish the Data Agent"
            " (scripts/7-setup-data-agent.py).")
        return 0
    if args.refresh_graph:
        refresh_graph(ws, graph)
    if args.refresh_graph or not queryset_current(ws, labels):
        publish_graph_queries(ws, graph, labels)
    else:
        log(f"✓ Graph queryset '{QUERYSET_NAME}' is current — not re-validated (--refresh-graph re-validates it)")
    log("\nNext: publish the Data Agent (scripts/7-setup-data-agent.py). After entity or relationship changes,"
        " update the graph projection in the ontology (Manage graph).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
