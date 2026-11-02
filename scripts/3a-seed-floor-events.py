#!/usr/bin/env python3
"""Seed the Floor Ops Console managed SQL database with realistic demo FloorEvents.

The Fabric app owns and writes `dbo.FloorEvents` in its managed SQL database. This
helper inserts a spread of realistic events (across lines / stations / shifts /
categories / priorities / statuses, timestamped within the telemetry window) so the
in-app Insights dashboard and the Power BI Floor Ops page populate immediately — without
having to click through the UI. Rows mirror to OneLake, where a shortcut surfaces them at
ManufacturingLH/dbo.FloorEvent for the Direct Lake OEE model.

Auth: current Azure CLI session token for the database (Entra). Requires pyodbc +
ODBC Driver 18 for SQL Server.

Usage:
    python scripts/3a-seed-floor-events.py --workspace-name "OEE Demo"
    python scripts/3a-seed-floor-events.py --workspace-name "OEE Demo" --count 80 --reset
"""
from __future__ import annotations

import argparse
import random
import struct
import subprocess
import sys
import uuid
from datetime import datetime, timedelta, timezone

try:
    import pyodbc
except ImportError:
    sys.exit("pyodbc is required: pip install pyodbc")

APP_DB_DISPLAY_NAME = "oee-downtime-logbook"  # the managed SQLDatabase item
LINES = ["Line-A", "Line-B", "Line-C", "Line-D", "Line-E"]
STATIONS_PER_LINE = 6
SHIFTS = ["Day", "Night"]

# category -> weight (Quality-Defect drives the quality blend)
CATEGORY_WEIGHTS = {
    "Mechanical-Wear": 20, "Jam-Feed": 16, "Fluid-Pressure": 8, "Thermal": 9,
    "Sensor-Vision-Calibration": 10, "Electrical-Other": 7, "Material-Shortage": 8,
    "Quality-Defect": 12, "Operator-Adjustment": 6, "Planned-Maintenance": 5, "Other": 3,
}
PRIORITY_WEIGHTS = {"Low": 20, "Medium": 40, "High": 28, "Critical": 12}
# status funnel — most events get resolved
STATUS_WEIGHTS = {"Resolved": 58, "In Progress": 14, "Acknowledged": 12, "Open": 16}

DESCRIPTIONS = {
    "Mechanical-Wear": ["Bearing noise on spindle", "Belt slipping under load", "Excessive vibration"],
    "Jam-Feed": ["Part jam at infeed", "Feeder misfeed repeating", "Gripper failed to release"],
    "Fluid-Pressure": ["Coolant pressure low", "Hydraulic leak at manifold", "Air pressure drop"],
    "Thermal": ["Zone over-temp alarm", "Reflow profile drifting hot", "Chiller not holding setpoint"],
    "Sensor-Vision-Calibration": ["Vision misreads fiducial", "Proximity sensor intermittent", "Camera needs recal"],
    "Electrical-Other": ["VFD fault code", "Contactor chattering", "E-stop nuisance trip"],
    "Material-Shortage": ["Component reel empty", "Solder paste out", "Awaiting kit from stores"],
    "Quality-Defect": ["Solder bridge on QFN", "Cold joint cluster", "Scratches on housing", "Missing component"],
    "Operator-Adjustment": ["Retuned placement offset", "Adjusted torque setting", "Re-seated fixture"],
    "Planned-Maintenance": ["Scheduled lubrication", "Filter change", "Preventive inspection"],
    "Other": ["Miscellaneous stop", "Unclassified event"],
}
DEFECT_TYPES = ["Solder bridge", "Cold joint", "Tombstone", "Missing part", "Misalignment", "Scratch"]
SEVERITIES = ["Minor", "Major", "Critical"]
OPERATORS = ["a.torres@contoso", "j.kim@contoso", "m.patel@contoso", "s.nguyen@contoso", "l.garcia@contoso"]
SUPERVISORS = ["r.okafor@contoso", "d.schmidt@contoso", "p.rossi@contoso"]


def _weighted(d: dict[str, int]) -> str:
    keys = list(d.keys())
    return random.choices(keys, weights=[d[k] for k in keys], k=1)[0]


def device_id(line_id: str, station_position: int) -> str:
    return f"{line_id.lower()}-station-{station_position}"


def token_struct(resource: str) -> bytes:
    r = subprocess.run(
        ["az", "account", "get-access-token", "--resource", resource, "--query", "accessToken", "-o", "tsv"],
        capture_output=True, text=True, shell=(sys.platform == "win32"),
    )
    if r.returncode != 0 or not r.stdout.strip():
        sys.exit("Not logged in — run 'az login' first.")
    enc = r.stdout.strip().encode("utf-16-le")
    return struct.pack(f"<I{len(enc)}s", len(enc), enc)


def resolve_conn(workspace_name: str) -> tuple[str, str]:
    """Return (server, database) for the managed app SQL database via Fabric REST."""
    def fab(path: str):
        import json, urllib.request
        r = subprocess.run(
            ["az", "account", "get-access-token", "--resource", "https://api.fabric.microsoft.com",
             "--query", "accessToken", "-o", "tsv"],
            capture_output=True, text=True, shell=(sys.platform == "win32"))
        tok = r.stdout.strip()
        req = urllib.request.Request(f"https://api.fabric.microsoft.com/v1/{path}",
                                     headers={"Authorization": f"Bearer {tok}"})
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())

    ws = next((w for w in fab("workspaces")["value"] if w["displayName"] == workspace_name), None)
    if not ws:
        sys.exit(f"Workspace {workspace_name!r} not found.")
    dbs = fab(f"workspaces/{ws['id']}/sqlDatabases").get("value", [])
    db = next((d for d in dbs if d["displayName"] == APP_DB_DISPLAY_NAME), None)
    if not db:
        sys.exit(f"App SQL database {APP_DB_DISPLAY_NAME!r} not found — deploy the app first (rayfin up).")
    props = db["properties"]
    server = props["serverFqdn"].split(",")[0]
    return server, props["databaseName"]


def make_events(count: int, window_hours: int) -> list[dict]:
    now = datetime.now(timezone.utc)
    events = []
    for _ in range(count):
        line = random.choice(LINES)
        sp = random.randint(1, STATIONS_PER_LINE)
        cat = _weighted(CATEGORY_WEIGHTS)
        pri = _weighted(PRIORITY_WEIGHTS)
        st = _weighted(STATUS_WEIGHTS)
        event_ts = now - timedelta(hours=random.uniform(0, window_hours))
        shift = "Day" if 6 <= (event_ts.hour) < 18 else "Night"

        ack_at = res_at = None
        res_by = rc = ca = None
        # response times scale a bit with priority (critical gets faster attention)
        base_ack = {"Critical": 4, "High": 8, "Medium": 15, "Low": 25}[pri]
        if st in ("Acknowledged", "In Progress", "Resolved"):
            ack_at = event_ts + timedelta(minutes=random.uniform(1, base_ack))
        if st == "Resolved":
            res_at = (ack_at or event_ts) + timedelta(minutes=random.uniform(10, 120))
            res_by = random.choice(SUPERVISORS)
            rc = random.choice(["Worn part replaced", "Recalibrated", "Cleared jam", "Topped fluid", "Adjusted setpoint"])
            ca = random.choice(["Replaced component", "PM performed", "Operator retrained", "Parameter updated"])

        ev = {
            "id": str(uuid.uuid4()),
            "device_id": device_id(line, sp),
            "line_id": line,
            "station_position": sp,
            "shift": shift,
            "event_ts": event_ts.replace(tzinfo=None),
            "category": cat,
            "priority": pri,
            "description": random.choice(DESCRIPTIONS[cat]),
            "status": st,
            "acknowledged_at": ack_at.replace(tzinfo=None) if ack_at else None,
            "resolved_at": res_at.replace(tzinfo=None) if res_at else None,
            "root_cause_code": rc,
            "corrective_action": ca,
            "defect_type": random.choice(DEFECT_TYPES) if cat == "Quality-Defect" else None,
            "severity": random.choice(SEVERITIES) if cat == "Quality-Defect" else None,
            "scrap_qty": random.randint(1, 25) if cat == "Quality-Defect" else None,
            "raised_by": random.choice(OPERATORS),
            "resolved_by": res_by,
            "logged_at": event_ts.replace(tzinfo=None),
        }
        events.append(ev)
    return events


COLUMNS = [
    "id", "device_id", "line_id", "station_position", "shift", "event_ts", "category",
    "priority", "description", "status", "acknowledged_at", "resolved_at", "root_cause_code",
    "corrective_action", "defect_type", "severity", "scrap_qty", "raised_by", "resolved_by", "logged_at",
]


def main() -> int:
    ap = argparse.ArgumentParser(description="Seed demo FloorEvents into the app's managed SQL database.")
    ap.add_argument("--workspace-name", required=True)
    ap.add_argument("--count", type=int, default=80)
    ap.add_argument("--window-hours", type=int, default=48, help="Spread events across the last N hours.")
    ap.add_argument("--reset", action="store_true", help="DELETE existing rows before seeding.")
    args = ap.parse_args()

    server, database = resolve_conn(args.workspace_name)
    print(f"[ok] App DB: {server} / {database}")

    ts = token_struct("https://database.windows.net/")
    cs = (f"Driver={{ODBC Driver 18 for SQL Server}};Server={server},1433;"
          f"Database={database};Encrypt=yes;TrustServerCertificate=no;")
    cn = pyodbc.connect(cs, attrs_before={1256: ts}, timeout=60)
    cur = cn.cursor()

    if args.reset:
        cur.execute("DELETE FROM dbo.FloorEvents")
        print("[ok] Cleared existing FloorEvents")

    events = make_events(args.count, args.window_hours)
    placeholders = ", ".join(["?"] * len(COLUMNS))
    collist = ", ".join(COLUMNS)
    sql = f"INSERT INTO dbo.FloorEvents ({collist}) VALUES ({placeholders})"
    cur.fast_executemany = True
    cur.executemany(sql, [[ev[c] for c in COLUMNS] for ev in events])
    cn.commit()

    cur.execute("SELECT COUNT(*) FROM dbo.FloorEvents")
    total = cur.fetchone()[0]
    cur.execute("SELECT status, COUNT(*) FROM dbo.FloorEvents GROUP BY status")
    by_status = {r[0]: r[1] for r in cur.fetchall()}
    cn.close()

    print(f"[ok] Inserted {len(events)} events. Table now has {total} rows.")
    print(f"     By status: {by_status}")
    print("     The managed DB mirrors to OneLake within a few minutes; then create/refresh")
    print("     the ManufacturingLH/dbo.FloorEvent shortcut and reframe the semantic model.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
