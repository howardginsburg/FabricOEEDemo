#!/usr/bin/env python3
"""Apply powerbi/translytical/OeeTarget.schema.sql to the OeeGovernance Fabric SQL database.

A fallback for when `sqlcmd` is not available (see scripts/2-setup-translytical.sh). Connects to
the Fabric SQL database's T-SQL endpoint using an Entra access token (no secrets) and runs the
schema — creating and seeding dbo.OeeTarget so the set_oee_target UDF has a MERGE target and the
Direct Lake model's `Target OEE` measure resolves.

Requires: pyodbc + "ODBC Driver 18 for SQL Server", and an `az login` session (the token is
acquired for the Azure SQL data plane, resource https://database.windows.net/).

Usage:
    python scripts/2a-apply-oee-target-schema.py --workspace-name "OEE Demo"
    python scripts/2a-apply-oee-target-schema.py --server <fqdn,1433> --database <db-name>
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import subprocess
import sys
import urllib.request
from pathlib import Path

FABRIC_API = "https://api.fabric.microsoft.com/v1"
FABRIC_RESOURCE = "https://api.fabric.microsoft.com"
SQL_RESOURCE = "https://database.windows.net/"
GOV_DB_NAME = "OeeGovernance"
SQL_COPT_SS_ACCESS_TOKEN = 1256

SCHEMA_SQL = Path(__file__).resolve().parent.parent / "powerbi" / "translytical" / "OeeTarget.schema.sql"


def az_token(resource: str) -> str:
    out = subprocess.run(
        ["az", "account", "get-access-token", "--resource", resource, "--query", "accessToken", "-o", "tsv"],
        capture_output=True, text=True, shell=(os.name == "nt"),
    )
    if out.returncode != 0 or not out.stdout.strip():
        sys.exit(f"Failed to get an access token for {resource}. Run 'az login' first.\n{out.stderr}")
    return out.stdout.strip()


def resolve_sql_db(workspace_name: str) -> tuple[str, str]:
    """Return (server_fqdn_with_port, database_name) for the OeeGovernance Fabric SQL database."""
    tok = az_token(FABRIC_RESOURCE)

    def get(path: str):
        req = urllib.request.Request(f"{FABRIC_API}/{path}", headers={"Authorization": f"Bearer {tok}"})
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read().decode())

    ws = next((w for w in get("workspaces")["value"] if w["displayName"] == workspace_name), None)
    if not ws:
        sys.exit(f"Workspace '{workspace_name}' not found.")
    dbs = get(f"workspaces/{ws['id']}/sqlDatabases")["value"]
    db = next((d for d in dbs if d["displayName"] == GOV_DB_NAME), None)
    if not db:
        sys.exit(f"'{GOV_DB_NAME}' Fabric SQL database not found — run scripts/2-setup-translytical.sh first.")
    detail = get(f"workspaces/{ws['id']}/sqlDatabases/{db['id']}")
    props = detail.get("properties", {})
    server = props.get("serverFqdn")
    database = props.get("databaseName")
    if not server or not database:
        sys.exit("Could not resolve the SQL server/database name from the Fabric API.")
    return server, database


def apply_schema(server: str, database: str) -> None:
    try:
        import pyodbc
    except ImportError:
        sys.exit("pyodbc is not installed. Install it (pip install pyodbc) plus 'ODBC Driver 18 for SQL Server'.")

    tok = az_token(SQL_RESOURCE).encode("utf-16-le")
    tokstruct = struct.pack(f"<I{len(tok)}s", len(tok), tok)

    conn = pyodbc.connect(
        f"Driver={{ODBC Driver 18 for SQL Server}};Server={server};Database={database};"
        f"Encrypt=yes;TrustServerCertificate=no;",
        attrs_before={SQL_COPT_SS_ACCESS_TOKEN: tokstruct},
        autocommit=True,
    )
    cur = conn.cursor()

    sql = SCHEMA_SQL.read_text(encoding="utf-8")
    batches, buf = [], []
    for line in sql.splitlines():
        if line.strip().upper() == "GO":
            batches.append("\n".join(buf)); buf = []
        else:
            buf.append(line)
    if "\n".join(buf).strip():
        batches.append("\n".join(buf))

    for i, b in enumerate(batches, 1):
        if b.strip():
            cur.execute(b)

    cur.execute("SELECT COUNT(*) FROM dbo.OeeTarget")
    n = cur.fetchone()[0]
    conn.close()
    print(f"   [ok] dbo.OeeTarget applied ({n} rows).")


def main() -> None:
    p = argparse.ArgumentParser(description="Apply the OeeTarget schema to the OeeGovernance Fabric SQL database.")
    p.add_argument("--workspace-name", help="Fabric workspace display name (to resolve the SQL DB automatically).")
    p.add_argument("--server", help="SQL server FQDN with port, e.g. <host>.database.fabric.microsoft.com,1433.")
    p.add_argument("--database", help="SQL database name (Fabric appends the item GUID).")
    args = p.parse_args()

    if args.server and args.database:
        server, database = args.server, args.database
    elif args.workspace_name:
        server, database = resolve_sql_db(args.workspace_name)
    else:
        p.error("Provide either --workspace-name, or both --server and --database.")

    print(f"   Applying {SCHEMA_SQL.name} to {database} on {server} ...")
    apply_schema(server, database)


if __name__ == "__main__":
    main()
