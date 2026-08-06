#!/usr/bin/env python3
"""Publish an OEE Manufacturing ontology to a Fabric workspace via REST.

Replaces the prior notebook + fabriciq wheel deployment. Reads
``ontology/ontology.yaml``, validates it, generates the Fabric Ontology
multi-part definition (deterministic 64-bit IDs, per-binding GUIDs),
and creates or updates the ``Ontology`` item in the workspace.

Usage
-----
    python scripts/6-publish-ontology.py --workspace-name <NAME>
    python scripts/6-publish-ontology.py --workspace-name <NAME> --recreate
    python scripts/6-publish-ontology.py --dry-run --out /tmp/parts/

Authentication uses the current Azure CLI session
(``az login`` against the Fabric API resource
``https://api.fabric.microsoft.com``).

Hardcoded source items (intentional for this demo):
    - Lakehouse:  ManufacturingLH
    - Eventhouse: ManufacturingEH (KQL database same name)

YAML schema (informal)
----------------------
    ontology:
      name: <ontology display name>
    entities:
      - name: <EntityType>
        identifiers: [<prop>, ...]
        displayName: <prop>          # optional; defaults to first identifier
        timestampProperty: <prop>    # required iff `timeseries:` present
        properties:                  # static (NonTimeSeries) properties
          - {name, type}             # type ∈ String|BigInt|Double|Boolean|DateTime
        timeseries: []               # TimeSeries properties (eventhouse only)
        bindings:
          - target: lakehouse|eventhouse
            table: <kql or delta table name>
            columns: {prop: column}  # optional rename map
            slicers: [<prop>, ...]   # extra static props bound on TS side
    relationships:
      - name, source, target
        binding: {table, sourceKey: [...], targetKey: [...]}
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required. Install: pip install pyyaml")


# ─── Constants ────────────────────────────────────────────────────────────────

FABRIC_API = "https://api.fabric.microsoft.com/v1"
FABRIC_RESOURCE = "https://api.fabric.microsoft.com"
LAKEHOUSE_NAME = "ManufacturingLH"
EVENTHOUSE_NAME = "ManufacturingEH"
EVENTHOUSE_DB = "ManufacturingEH"
LAKEHOUSE_SCHEMA = "dbo"
NAMESPACE = "usertypes"
ID_NAMESPACE = uuid.UUID("9c2f1c30-1f6b-4f1f-9b3a-9e2c1ab51e00")  # publisher salt
ALLOWED_TYPES = {"String", "BigInt", "Double", "Boolean", "DateTime"}
ID_TYPES = {"String", "BigInt"}


# ─── Auth + HTTP ──────────────────────────────────────────────────────────────


def _az_token(resource: str) -> str:
    """Get an access token from the local Azure CLI session."""
    # On Windows the executable is az.cmd; shell=True resolves either form.
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
    """Send an HTTP request. Returns (status, headers, body_json_or_text)."""
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


def fabric_post(path: str, body: dict, expect: tuple[int, ...] = (200, 201, 202)) -> tuple[int, dict, dict]:
    status, headers, payload = _request("POST", f"{FABRIC_API}/{path}", body)
    if status not in expect and status >= 400:
        sys.exit(f"POST {path} → {status}: {payload}")
    return status, headers, payload


def fabric_delete(path: str) -> int:
    status, _, _ = _request("DELETE", f"{FABRIC_API}/{path}")
    return status


def wait_lro(headers: dict, timeout: int = 300) -> dict:
    """Poll an LRO until terminal. Returns the final operation body."""
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
            return body
        if state in ("failed", "canceled"):
            sys.exit(f"LRO failed: {body}")
        time.sleep(5)
        elapsed += 5
    sys.exit(f"LRO timed out after {timeout}s")


# ─── Deterministic IDs ────────────────────────────────────────────────────────


def big_id(*parts: str) -> str:
    """Stable positive 63-bit BigInt for entity/property/relationship IDs."""
    h = hashlib.blake2b("|".join(parts).encode(), digest_size=8).digest()
    return str(int.from_bytes(h, "big") & 0x7FFFFFFFFFFFFFFF)


def guid(*parts: str) -> str:
    """Stable UUIDv5 for DataBinding / Contextualization IDs."""
    return str(uuid.uuid5(ID_NAMESPACE, "|".join(parts)))


# ─── YAML model + validation ──────────────────────────────────────────────────


@dataclass
class Prop:
    name: str
    type: str
    is_timeseries: bool = False


@dataclass
class Binding:
    target: str               # "lakehouse" | "eventhouse"
    table: str
    columns: dict[str, str] = field(default_factory=dict)
    slicers: list[str] = field(default_factory=list)
    # Optional allowlist of timeseries property names this binding contributes.
    # When None, all entity timeseries properties bind to this source. When set,
    # only the listed names are bound — used when one entity has multiple
    # eventhouse sources (e.g., Station ← MachineEvents + PartEvents) that
    # each carry a different subset of the entity's TS column union.
    timeseries: list[str] | None = None
    # Optional override of the entity-level timestampProperty. Required when
    # the entity has multiple eventhouse bindings, because Fabric rejects
    # reuse of a single TS property across mappings — each binding must have
    # its own distinct DateTime timestamp property on the entity.
    timestamp_property: str | None = None


@dataclass
class Entity:
    name: str
    identifiers: list[str]
    display_name: str
    timestamp_property: str | None
    properties: list[Prop]
    timeseries: list[Prop]
    bindings: list[Binding]


@dataclass
class RelBinding:
    table: str
    source_key: list[str]
    target_key: list[str]


@dataclass
class Relationship:
    name: str
    source: str
    target: str
    binding: RelBinding


@dataclass
class Ontology:
    name: str
    entities: list[Entity]
    relationships: list[Relationship]


def _validate(yobj: dict) -> Ontology:
    errors: list[str] = []
    onto_name = yobj.get("ontology", {}).get("name")
    if not onto_name:
        errors.append("ontology.name is required")

    entities: list[Entity] = []
    entities_by_name: dict[str, Entity] = {}
    for raw in yobj.get("entities", []):
        ename = raw["name"]
        ids = raw.get("identifiers", [])
        props = [Prop(p["name"], p["type"]) for p in raw.get("properties", [])]
        tprops = [Prop(p["name"], p["type"], True) for p in raw.get("timeseries", [])]
        prop_names = {p.name for p in props}
        tprop_names = {p.name for p in tprops}
        all_names = prop_names | tprop_names

        for p in props + tprops:
            if p.type not in ALLOWED_TYPES:
                errors.append(f"{ename}.{p.name}: type {p.type!r} not in {sorted(ALLOWED_TYPES)}")
        for id_name in ids:
            if id_name not in prop_names:
                errors.append(f"{ename}: identifier {id_name!r} not in properties:")
                continue
            ip = next(p for p in props if p.name == id_name)
            if ip.type not in ID_TYPES:
                errors.append(f"{ename}.{id_name}: identifier must be String or BigInt (got {ip.type})")

        display = raw.get("displayName") or (ids[0] if ids else None)
        if display and display not in all_names:
            errors.append(f"{ename}: displayName {display!r} not a declared property")

        ts_prop = raw.get("timestampProperty")
        eh_bindings_raw = [b for b in raw.get("bindings", []) if b.get("target") == "eventhouse"]
        if tprops and not ts_prop and not all(b.get("timestampProperty") for b in eh_bindings_raw):
            errors.append(f"{ename}: timestampProperty required at entity level OR on every eventhouse binding")
        if ts_prop:
            match = next((p for p in tprops if p.name == ts_prop), None)
            if not match:
                errors.append(f"{ename}: timestampProperty {ts_prop!r} not in timeseries:")
            elif match.type != "DateTime":
                errors.append(f"{ename}.{ts_prop}: timestampProperty must be DateTime")

        bindings: list[Binding] = []
        for b in raw.get("bindings", []):
            target = b["target"]
            if target not in ("lakehouse", "eventhouse"):
                errors.append(f"{ename}: binding target {target!r} not lakehouse|eventhouse")
            cols = b.get("columns", {}) or {}
            for prop_key in cols:
                if prop_key not in all_names:
                    errors.append(f"{ename}: binding columns key {prop_key!r} not a declared property")
            slicers = b.get("slicers", []) or []
            for s in slicers:
                if s not in prop_names:
                    errors.append(f"{ename}: slicer {s!r} not in static properties:")
            if target == "eventhouse" and not tprops:
                errors.append(f"{ename}: eventhouse binding requires timeseries: properties")
            ts_filter = b.get("timeseries")
            if ts_filter is not None:
                if target != "eventhouse":
                    errors.append(f"{ename}: per-binding 'timeseries' filter only valid for eventhouse bindings")
                for tn in ts_filter:
                    if tn not in tprop_names:
                        errors.append(f"{ename}: binding timeseries entry {tn!r} not in entity timeseries: properties")
            b_ts_prop = b.get("timestampProperty")
            if b_ts_prop is not None:
                if target != "eventhouse":
                    errors.append(f"{ename}: per-binding 'timestampProperty' only valid for eventhouse bindings")
                if b_ts_prop not in tprop_names:
                    errors.append(f"{ename}: binding timestampProperty {b_ts_prop!r} not in timeseries: properties")
                elif next(p for p in tprops if p.name == b_ts_prop).type != "DateTime":
                    errors.append(f"{ename}.{b_ts_prop}: binding timestampProperty must be DateTime")
                if ts_filter is not None and b_ts_prop not in ts_filter:
                    errors.append(f"{ename}: binding timestampProperty {b_ts_prop!r} must appear in its own 'timeseries' filter")
            bindings.append(Binding(
                target=target, table=b["table"], columns=cols,
                slicers=slicers, timeseries=ts_filter, timestamp_property=b_ts_prop,
            ))

        e = Entity(
            name=ename, identifiers=ids, display_name=display,
            timestamp_property=ts_prop, properties=props,
            timeseries=tprops, bindings=bindings,
        )
        # Fabric requires each TS property to map to exactly one source. Verify
        # no TS prop name appears in more than one eventhouse binding's filter
        # (or, when filters are omitted, that there's at most one eh binding).
        eh = [b for b in bindings if b.target == "eventhouse"]
        if len(eh) > 1:
            unfiltered = [b for b in eh if b.timeseries is None]
            if unfiltered:
                errors.append(f"{ename}: entity has {len(eh)} eventhouse bindings; each must declare a 'timeseries:' filter")
            seen_ts: dict[str, str] = {}
            for b in eh:
                for tn in (b.timeseries or []):
                    if tn in seen_ts:
                        errors.append(f"{ename}: TS property {tn!r} appears in both {seen_ts[tn]!r} and {b.table!r} bindings — each TS property must map to exactly one source")
                    else:
                        seen_ts[tn] = b.table
        entities.append(e)
        entities_by_name[ename] = e

    relationships: list[Relationship] = []
    for raw in yobj.get("relationships", []):
        rname = raw["name"]
        src = raw["source"]
        tgt = raw["target"]
        b = raw["binding"]
        if src not in entities_by_name:
            errors.append(f"{rname}: source {src!r} unknown entity")
        if tgt not in entities_by_name:
            errors.append(f"{rname}: target {tgt!r} unknown entity")
        sk = b.get("sourceKey", [])
        tk = b.get("targetKey", [])
        if src in entities_by_name:
            src_props = {p.name for p in entities_by_name[src].properties}
            for k in sk:
                if k not in src_props:
                    errors.append(f"{rname}: sourceKey {k!r} not a static property of {src}")
        if tgt in entities_by_name:
            tgt_props = {p.name for p in entities_by_name[tgt].properties}
            for k in tk:
                if k not in tgt_props:
                    errors.append(f"{rname}: targetKey {k!r} not a static property of {tgt}")
        relationships.append(Relationship(
            name=rname, source=src, target=tgt,
            binding=RelBinding(table=b["table"], source_key=sk, target_key=tk),
        ))

    if errors:
        print("Validation errors:", file=sys.stderr)
        for e in errors:
            print(f"  • {e}", file=sys.stderr)
        sys.exit(1)

    return Ontology(name=onto_name, entities=entities, relationships=relationships)


# ─── Definition builder ───────────────────────────────────────────────────────


def _b64(payload: dict) -> str:
    return base64.b64encode(json.dumps(payload, separators=(",", ":")).encode()).decode()


def _part(path: str, payload: dict) -> dict:
    return {"path": path, "payload": _b64(payload), "payloadType": "InlineBase64"}


def build_parts(onto: Ontology, *, workspace_id: str, lakehouse_id: str,
                eventhouse_id: str, eventhouse_uri: str) -> list[dict]:
    """Build the multi-part Fabric Ontology REST definition."""
    parts: list[dict] = []

    # .platform + empty definition.json
    parts.append(_part(".platform", {"metadata": {"type": "Ontology", "displayName": onto.name}}))
    parts.append(_part("definition.json", {}))

    # Pre-allocate IDs for property cross-references in bindings/relationships.
    entity_ids: dict[str, str] = {e.name: big_id(onto.name, e.name) for e in onto.entities}
    prop_ids: dict[tuple[str, str], str] = {}
    for e in onto.entities:
        for p in (*e.properties, *e.timeseries):
            prop_ids[(e.name, p.name)] = big_id(onto.name, e.name, p.name)

    lh_source = {
        "sourceType": "LakehouseTable",
        "workspaceId": workspace_id,
        "itemId": lakehouse_id,
        "sourceSchema": LAKEHOUSE_SCHEMA,
    }
    eh_source = {
        "sourceType": "KustoTable",
        "workspaceId": workspace_id,
        "itemId": eventhouse_id,
        "clusterUri": eventhouse_uri,
        "databaseName": EVENTHOUSE_DB,
    }

    for e in onto.entities:
        eid = entity_ids[e.name]

        properties = [{
            "id": prop_ids[(e.name, p.name)], "name": p.name,
            "redefines": None, "baseTypeNamespaceType": None, "valueType": p.type,
        } for p in e.properties]
        timeseries_properties = [{
            "id": prop_ids[(e.name, p.name)], "name": p.name,
            "redefines": None, "baseTypeNamespaceType": None, "valueType": p.type,
        } for p in e.timeseries]

        entity_def = {
            "id": eid,
            "namespace": NAMESPACE,
            "baseEntityTypeId": None,
            "name": e.name,
            "entityIdParts": [prop_ids[(e.name, n)] for n in e.identifiers],
            "displayNamePropertyId": prop_ids[(e.name, e.display_name)] if e.display_name else None,
            "namespaceType": "Custom",
            "visibility": "Visible",
            "properties": properties,
            "timeseriesProperties": timeseries_properties,
        }
        parts.append(_part(f"EntityTypes/{eid}/definition.json", entity_def))

        for b in e.bindings:
            bid = guid(onto.name, e.name, b.target, b.table)
            if b.target == "lakehouse":
                src = {**lh_source, "sourceTableName": b.table}
                bound_props = list(e.properties)   # all static properties
                cfg: dict[str, Any] = {
                    "dataBindingType": "NonTimeSeries",
                    "propertyBindings": [],
                    "sourceTableProperties": src,
                }
            else:  # eventhouse
                src = {**eh_source, "sourceTableName": b.table}
                # TS side: identifiers + declared slicers + (filtered) timeseries props
                included: list[Prop] = []
                seen: set[str] = set()
                for name in (*e.identifiers, *b.slicers):
                    if name in seen:
                        continue
                    p = next(pp for pp in e.properties if pp.name == name)
                    included.append(p)
                    seen.add(name)
                ts_subset = (
                    [p for p in e.timeseries if p.name in set(b.timeseries)]
                    if b.timeseries is not None else e.timeseries
                )
                for p in ts_subset:
                    if p.name not in seen:
                        included.append(p)
                        seen.add(p.name)
                bound_props = included
                ts_prop_name = b.timestamp_property or e.timestamp_property
                cfg = {
                    "dataBindingType": "TimeSeries",
                    "timestampColumnName": b.columns.get(ts_prop_name, ts_prop_name),
                    "propertyBindings": [],
                    "sourceTableProperties": src,
                }

            if b.target == "lakehouse":
                bind_set = bound_props
            else:
                bind_set = bound_props
            cfg["propertyBindings"] = [{
                "sourceColumnName": b.columns.get(p.name, p.name),
                "targetPropertyId": prop_ids[(e.name, p.name)],
            } for p in bind_set]

            parts.append(_part(
                f"EntityTypes/{eid}/DataBindings/{bid}.json",
                {"id": bid, "dataBindingConfiguration": cfg},
            ))

    # Relationship types + contextualizations
    for r in onto.relationships:
        rid = big_id(onto.name, "rel", r.name)
        parts.append(_part(f"RelationshipTypes/{rid}/definition.json", {
            "namespace": NAMESPACE,
            "id": rid,
            "name": r.name,
            "namespaceType": "Custom",
            "source": {"entityTypeId": entity_ids[r.source]},
            "target": {"entityTypeId": entity_ids[r.target]},
        }))
        cid = guid(onto.name, "ctx", r.name)
        parts.append(_part(
            f"RelationshipTypes/{rid}/Contextualizations/{cid}.json",
            {
                "id": cid,
                "dataBindingTable": {**{
                    "sourceType": "LakehouseTable",
                    "workspaceId": workspace_id,
                    "itemId": lakehouse_id,
                    "sourceTableName": r.binding.table,
                    "sourceSchema": LAKEHOUSE_SCHEMA,
                }},
                "sourceKeyRefBindings": [{
                    "sourceColumnName": k,
                    "targetPropertyId": prop_ids[(r.source, k)],
                } for k in r.binding.source_key],
                "targetKeyRefBindings": [{
                    "sourceColumnName": k,
                    "targetPropertyId": prop_ids[(r.target, k)],
                } for k in r.binding.target_key],
            },
        ))

    return parts


# ─── Workspace + item resolution ──────────────────────────────────────────────


def resolve_workspace(name_or_id: str) -> str:
    if _looks_like_guid(name_or_id):
        return name_or_id
    body = fabric_get("workspaces")
    for w in body.get("value", []):
        if w.get("displayName") == name_or_id:
            return w["id"]
    sys.exit(f"Workspace {name_or_id!r} not found.")


def _looks_like_guid(s: str) -> bool:
    try:
        uuid.UUID(s)
        return True
    except (ValueError, AttributeError):
        return False


def resolve_lakehouse(ws_id: str, name: str) -> str:
    body = fabric_get(f"workspaces/{ws_id}/lakehouses")
    for it in body.get("value", []):
        if it.get("displayName") == name:
            return it["id"]
    sys.exit(f"Lakehouse {name!r} not found in workspace.")


def resolve_eventhouse(ws_id: str, name: str) -> tuple[str, str]:
    """Return (eventhouse_id, query_service_uri)."""
    body = fabric_get(f"workspaces/{ws_id}/eventhouses")
    for it in body.get("value", []):
        if it.get("displayName") == name:
            uri = (it.get("properties") or {}).get("queryServiceUri")
            if not uri:
                sys.exit(f"Eventhouse {name!r} has no queryServiceUri.")
            return it["id"], uri
    sys.exit(f"Eventhouse {name!r} not found in workspace.")


def find_ontology(ws_id: str, name: str) -> str | None:
    body = fabric_get(f"workspaces/{ws_id}/items")
    for it in body.get("value", []):
        if it.get("type") == "Ontology" and it.get("displayName") == name:
            return it["id"]
    return None


# ─── CLI ──────────────────────────────────────────────────────────────────────


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--manifest", default=str(Path(__file__).resolve().parent.parent / "ontology" / "ontology.yaml"))
    ap.add_argument("--workspace-name", help="Fabric workspace display name or GUID")
    ap.add_argument("--recreate", action="store_true", help="Delete existing ontology and recreate")
    ap.add_argument("--dry-run", action="store_true", help="Write parts to --out and exit; no REST calls")
    ap.add_argument("--out", help="Output directory for --dry-run")
    args = ap.parse_args()

    manifest = Path(args.manifest)
    if not manifest.exists():
        sys.exit(f"Manifest not found: {manifest}")

    yobj = yaml.safe_load(manifest.read_text())
    onto = _validate(yobj)
    print(f"✓ Manifest validated: {len(onto.entities)} entities, "
          f"{len(onto.relationships)} relationships")

    if args.dry_run:
        if not args.out:
            sys.exit("--dry-run requires --out DIR")
        # Use placeholder identifiers so the layout can be inspected.
        parts = build_parts(
            onto,
            workspace_id="00000000-0000-0000-0000-000000000000",
            lakehouse_id="00000000-0000-0000-0000-000000000001",
            eventhouse_id="00000000-0000-0000-0000-000000000002",
            eventhouse_uri="https://example.kusto.fabric.microsoft.com",
        )
        out = Path(args.out)
        out.mkdir(parents=True, exist_ok=True)
        for p in parts:
            decoded = json.loads(base64.b64decode(p["payload"]))
            target = out / p["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps(decoded, indent=2))
        print(f"✓ Wrote {len(parts)} parts to {out}")
        return 0

    if not args.workspace_name:
        sys.exit("--workspace-name is required (unless --dry-run)")

    ws_id = resolve_workspace(args.workspace_name)
    print(f"✓ Workspace:  {args.workspace_name} ({ws_id})")
    lh_id = resolve_lakehouse(ws_id, LAKEHOUSE_NAME)
    print(f"✓ Lakehouse:  {LAKEHOUSE_NAME} ({lh_id})")
    eh_id, eh_uri = resolve_eventhouse(ws_id, EVENTHOUSE_NAME)
    print(f"✓ Eventhouse: {EVENTHOUSE_NAME} ({eh_id}) @ {eh_uri}")

    parts = build_parts(onto, workspace_id=ws_id, lakehouse_id=lh_id,
                        eventhouse_id=eh_id, eventhouse_uri=eh_uri)
    print(f"✓ Built {len(parts)} definition parts")

    existing = find_ontology(ws_id, onto.name)
    definition = {"parts": parts}

    if existing and args.recreate:
        print(f"… Deleting existing ontology {existing}")
        rc = fabric_delete(f"workspaces/{ws_id}/items/{existing}")
        if rc >= 400:
            sys.exit(f"DELETE failed: HTTP {rc}")
        existing = None
        # Fabric reserves the deleted display name for a few minutes.
        # Poll until the create succeeds rather than waiting a fixed time.

    if existing:
        print(f"… Updating existing ontology {existing}")
        status, headers, body = fabric_post(
            f"workspaces/{ws_id}/items/{existing}/updateDefinition",
            {"definition": definition},
        )
        if status == 202:
            wait_lro(headers)
        print(f"✓ Ontology updated ({onto.name})")
    else:
        print("… Creating ontology")
        create_body = {"displayName": onto.name, "type": "Ontology", "definition": definition}
        elapsed = 0
        while True:
            status, headers, body = _request("POST", f"{FABRIC_API}/workspaces/{ws_id}/items", create_body)
            if status in (200, 201, 202):
                break
            if status == 409 and "NotAvailableYet" in json.dumps(body) and elapsed < 600:
                print(f"  waiting for display name to free up… ({elapsed}s)")
                time.sleep(30)
                elapsed += 30
                continue
            sys.exit(f"Create failed: {status} {body}")
        if status == 202:
            wait_lro(headers)
        # Refetch ID
        new_id = find_ontology(ws_id, onto.name)
        print(f"✓ Ontology created: {onto.name} ({new_id})")

    print("\nNote: a GraphModel item is auto-provisioned asynchronously by Fabric.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
