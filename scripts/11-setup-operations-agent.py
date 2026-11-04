#!/usr/bin/env python3
"""Create or update the OEE operations agent: continuous monitoring of the plant's ontology rules.

The agent watches the ManufacturingEH Eventhouse about every five minutes. When one of the OEEFactoryOntology
ontology's alert rules starts to fire, it messages the recipient in Microsoft Teams and records the alert in
its activity log. The simulator's demo
scenarios trigger the rules on cue: "Long outage" on a bottleneck → BottleneckDowntime, "Repeat faults" →
RepeatFaultsPreventiveMaintenance, "Reject spike" → RejectRateQuarantine, "Slow cycles" →
StationOeeEscalation, and a sustained drop in a line's OEE → LineOeeEscalation.

The agent instructions embed the ontology's rule statements, read from the deployed ontology at publish
time, so each rule is stated once (in ontology/OEEFactoryOntology.Ontology/rules/). Each alert rule is
checked by a stored function in ManufacturingEH, Rule<RuleName>() (created by scripts/1-setup-fabric.sh),
that returns every reporting station or line, keyed by alert_id, with fired true where the rule fires and
the evidence for the message; the agent alerts when fired changes to true, once per episode. The knowledge source
is the Eventhouse, not the ontology: an operations agent over an ontology can only evaluate a property's
latest value (no aggregations, time series bound to an Eventhouse), and every alert rule here counts
events or computes a rate or an OEE over a time window.

The script configures the agent through its item definition (Configurations.json), then generates the
playbook (the rules the agent evaluates) through the operations agent's remote MCP endpoint
(/v1/mcp/workspaces/{ws}/operationsAgents/{id}/configure). Generation takes several minutes. It runs
when the agent has no playbook or its instructions or source changed, or with --generate-playbook. A
generated playbook can't be edited: writing the definition with a modified playbook fails and clears it.
The agent is created stopped so it doesn't use capacity until the demo; pass --start and --stop around it.

Usage
-----
    python scripts/11-setup-operations-agent.py --workspace-name "OEE Demo"
    python scripts/11-setup-operations-agent.py --workspace-name "OEE Demo" --start
    python scripts/11-setup-operations-agent.py --workspace-name "OEE Demo" --stop

Prerequisites: scripts/1-setup-fabric.sh created ManufacturingEH and scripts/6-publish-ontology.py
published the ontology. For Teams messages, the recipient has the "Fabric Operations Agent" Teams app
installed; without it, the alerts are in the agent's activity log.
Authentication uses the Azure CLI session ('az login').
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
from datetime import datetime, timezone

FABRIC_API = "https://api.fabric.microsoft.com/v1"
FABRIC_RESOURCE = "https://api.fabric.microsoft.com"
DEFINITION_PART = "Configurations.json"
SOURCE_TYPE = "KustoDatabase"

# Ontology rules the agent alerts on. Each has a stored check function in the Eventhouse (RULE_FUNCTION,
# created by scripts/1-setup-fabric.sh) that returns one row per reporting station or line, keyed by alert_id,
# with fired true where the rule fires and every field the message needs. The playbook generator builds a query
# per rule; given a ready-made function it binds every rule, while asked to derive windowed counts, rates, and
# OEE from the tables it dropped joins and failed rules at random. ShiftHandoverAgedWorkOrders is a handover
# report, not a condition to monitor.
ALERT_RULES = (
    "BottleneckDowntime", "RepeatFaultsPreventiveMaintenance", "RejectRateQuarantine",
    "StationOeeEscalation", "LineOeeEscalation", "ConcurrentOpenWorkOrders",
)
RULE_FUNCTION = "Rule{}"
# A rule's query must call its check function (otherwise the generator derived the rule from the tables itself)
# and evaluate it now or at the check's end: as of startTime, a window that reaches back an hour misses new events.
RULE_CALL = re.compile(r"\bRule[A-Za-z]+'?\]?\(((?:[^()]|\([^()]*\))*)\)")
CURRENT_TIME_ARGS = {"", "datetime(null)", "endTime", "asOf=endTime"}

INSTRUCTIONS = """You monitor the five production lines of a discrete manufacturing plant through the ManufacturingEH KQL database. Your alert rules are business rules of the plant's {ontology} ontology, its shared business model, so you apply the same rules as the plant's other agents and reports.

Each alert rule below is checked by a stored function in ManufacturingEH named after it, such as RuleBottleneckDowntime(). Call each function with no arguments, so it evaluates the rule now; never pass it startTime or a fixed datetime, which would evaluate the rule as of that moment at every check. It returns one row for each station or line that's reporting telemetry, and its "fired" column is true where the rule fires. Don't recompute the rules from the tables: the functions are their definitions.

Every function's rows have the same core columns: "alert_id" identifies the row, so use it as each row's identifier; "fired" is the alert's condition; "rule" is the rule name; "line_id" is the line identifier (Line-A to Line-E); for station rules, "device_id" is the station identifier (such as line-d-station-5), with "station_position" and "machine_type"; and "checked_at" is the evaluation time (UTC). The other columns are the rule's evidence.

Alert once per episode. Send one Teams message when a row's fired column becomes true, a transition from false (or no value) to true for its alert_id, with the columns the rule lists below and the action its statement requires. Don't send it again while fired stays true; when fired turns false and later becomes true again, that's a new episode."""


def log(msg: str) -> None:
    print(msg, flush=True)


# ─── Auth + HTTP ──────────────────────────────────────────────────────────────

_tokens: dict[str, str] = {}


def az(args: str, timeout: int = 120) -> str:
    try:
        r = subprocess.run(f"az {args}", capture_output=True, text=True, shell=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        sys.exit(f"az {args.split()[0]} didn't answer within {timeout}s. Check 'az login' and your network.")
    if r.returncode != 0:
        sys.exit(f"az {args.split()[0]} failed: {r.stderr.strip()}\nRun 'az login' first.")
    return r.stdout.strip()


def token(resource: str) -> str:
    if resource not in _tokens:
        _tokens[resource] = az(f'account get-access-token --resource "{resource}" --query accessToken -o tsv')
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


def find_item(ws: str, item_type: str, name: str) -> str | None:
    return next((i["id"] for i in get_all(f"workspaces/{ws}/items?type={item_type}") if i["displayName"] == name), None)


def get_parts(ws: str, item: str) -> dict[str, str]:
    result = post_lro(f"workspaces/{ws}/items/{item}/getDefinition")
    return {p["path"]: base64.b64decode(p["payload"]).decode("utf-8-sig")
            for p in result.get("definition", {}).get("parts", [])}


def read_definition(ws: str, item: str) -> dict:
    part = get_parts(ws, item).get(DEFINITION_PART)
    return json.loads(part) if part else {}


# ─── Instructions ─────────────────────────────────────────────────────────────


def ontology_rules(ws: str, ontology: str) -> dict[str, str]:
    """Rule name → statement, read from the deployed ontology definition."""
    rules = {}
    for path, text in get_parts(ws, ontology).items():
        if path.startswith("rules/"):
            name = re.search(r"^rule (\S+)", text, re.M)
            statement = re.search(r"^\tstatement: (.+)$", text, re.M)
            if name and statement:
                rules[name.group(1)] = statement.group(1).strip()
    return rules


def time_window(columns: list[str]) -> str:
    """The time window an alert reports, named by the check function's columns."""
    if "window_start" in columns:
        return "window_start to window_end"
    start = next((c for c in ("down_since", "below_60_since") if c in columns), None)
    return f"{start} to checked_at" if start else "as of checked_at"


def build_instructions(ontology_name: str, rules: dict[str, str], columns: dict[str, list[str]]) -> str:
    missing = [name for name in ALERT_RULES if name not in rules]
    if missing:
        log(f"⚠ The ontology has no rule named {', '.join(missing)}; the agent won't use it.")
    # The generator binds a rule reliably only when its entry names the condition column and the message columns.
    alerts = []
    for name in ALERT_RULES:
        if name in rules:
            fn = f"{RULE_FUNCTION.format(name)}()"
            cols = columns.get(RULE_FUNCTION.format(name), [])
            message = ", ".join(c for c in cols if c not in ("fired", "alert_id"))
            alerts.append(f"- {name}: {rules[name]}\n  Check it with {fn}: send the Teams message when a row's fired "
                          f"column becomes true for its alert_id, with no other filtering. Include the row's {message} "
                          f"columns in the message; the time window is {time_window(cols)}.")
    if not alerts:
        sys.exit("The ontology has none of the alert rules — publish it with scripts/6-publish-ontology.py.")
    return (INSTRUCTIONS.format(ontology=ontology_name)
            + f"\n\nAlert rules (from the {ontology_name} ontology):\n" + "\n".join(alerts))


def rule_functions(ws: str, kql_db: str, db_name: str) -> dict[str, list[str]]:
    """Output columns of each stored function in the KQL database's Rules folder (created by scripts/1-setup-fabric.sh)."""
    status, _, db = request("GET", f"{FABRIC_API}/workspaces/{ws}/kqlDatabases/{kql_db}")
    cluster = (db.get("properties") or {}).get("queryServiceUri") if status < 400 else None
    if not cluster:
        sys.exit(f"Couldn't read {db_name}'s query URI: HTTP {status}")
    status, _, body = request("POST", f"{cluster}/v1/rest/mgmt", resource=cluster, body={
        "db": db_name, "csl": ".show functions | where Folder == 'Rules' | project Name"})
    if status >= 400:
        sys.exit(f"Listing {db_name}'s functions failed: HTTP {status}: {json.dumps(body)[:300]}")
    columns = {}
    for row in body["Tables"][0]["Rows"]:
        status, _, out = request("POST", f"{cluster}/v1/rest/query", resource=cluster, body={
            "db": db_name, "csl": f"{row[0]}() | getschema | project ColumnName"})
        if status >= 400:
            sys.exit(f"Reading the columns of {row[0]}() failed: HTTP {status}: {json.dumps(out)[:300]}")
        columns[row[0]] = [r[0] for r in out["Tables"][0]["Rows"]]
    return columns


# ─── Playbook (operations agent MCP endpoint) ─────────────────────────────────


class Mcp:
    """Minimal client for the operations agent's remote MCP endpoint (Streamable HTTP, JSON-RPC)."""

    def __init__(self, url: str):
        self.url, self.session, self.next_id = url, None, 0
        self._initialize()

    def _initialize(self) -> None:
        self._send("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                  "clientInfo": {"name": "oee-setup", "version": "1.0"}})
        self._send("notifications/initialized", notify=True)

    def _send(self, method: str, params: dict | None = None, notify: bool = False, retry: bool = True,
              fail: bool = True):
        message = {"jsonrpc": "2.0", "method": method, **({"params": params} if params is not None else {})}
        if not notify:
            self.next_id += 1
            message["id"] = self.next_id
        req = urllib.request.Request(self.url, data=json.dumps(message).encode(), method="POST")
        req.add_header("Authorization", "Bearer " + token(FABRIC_RESOURCE))
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json, text/event-stream")
        if self.session:
            req.add_header("Mcp-Session-Id", self.session)
        try:
            with urllib.request.urlopen(req, timeout=300) as resp:
                self.session = resp.headers.get("Mcp-Session-Id") or self.session
                body, content_type = resp.read().decode("utf-8", "replace"), resp.headers.get("Content-Type", "")
        except urllib.error.HTTPError as e:
            if e.code in (401, 404) and retry and method != "initialize":
                # The session (or the token) can lapse while a playbook generates: open a new session once.
                _tokens.pop(FABRIC_RESOURCE, None)
                self.session = None
                self._initialize()
                return self._send(method, params, notify, retry=False, fail=fail)
            sys.exit(f"MCP {method} → HTTP {e.code}: {(e.read() or b'').decode('utf-8', 'replace')[:800]}")
        if notify:
            return None
        if "text/event-stream" in content_type:
            replies = [json.loads(line[5:]) for line in body.splitlines()
                       if line.startswith("data:") and line[5:].strip().startswith("{")]
            reply = next((r for r in replies if r.get("id") == message["id"]), {})
        else:
            reply = json.loads(body) if body.strip() else {}
        if "error" in reply:
            if not fail:
                return {"isError": True, "content": [{"type": "text", "text": reply["error"].get("message") or ""}]}
            sys.exit(f"MCP {method} failed: {reply['error'].get('message')}")
        return reply.get("result", {})

    def call(self, tool: str, arguments: dict | None = None, check: bool = True) -> str:
        result = self._send("tools/call", {"name": tool, "arguments": arguments or {}}, fail=check)
        text = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
        if result.get("isError"):
            if not check:
                return ""
            sys.exit(f"MCP {tool} failed: {text[:800]}")
        return text


GENERATION_TIMEOUT = 2400  # seconds; a generation still "InProgress" after this was orphaned


def latest_generation(mcp: Mcp) -> tuple[str, float | None]:
    """State of the latest playbook generation and its age in seconds (startTime is UTC), if there's one."""
    try:
        status = json.loads(mcp.call("get_generate_playbook_status", check=False) or "{}")
        started = datetime.strptime(status.get("startTime") or "", "%m/%d/%Y %I:%M:%S %p").replace(tzinfo=timezone.utc)
    except ValueError:
        return "", None
    return str(status.get("state") or "").lower(), (datetime.now(timezone.utc) - started).total_seconds()


def generate_playbook(mcp: Mcp, resume: bool, timeout: int = GENERATION_TIMEOUT) -> str | None:
    """Generate the playbook from the saved configuration and wait for it; the service saves the result.
    Generation takes several minutes. With resume, a recent generation that's still running is awaited instead
    of starting another. Returns the generator's feedback if the generation failed."""
    state, age = latest_generation(mcp) if resume else ("", None)
    if state == "inprogress" and age is not None and age < timeout:
        playbook_id, waited = None, int(age)
        log(f"… A playbook generation started {age / 60:.0f} minutes ago is still running; waiting for it")
    else:
        started = json.loads(mcp.call("generate_playbook"))
        playbook_id, waited = started.get("playbookId"), 0
        state = str(started.get("state") or started.get("status") or "")
        log(f"… Generating the playbook ({playbook_id}); this takes several minutes")
    while state.lower() not in ("completed", "succeeded", "failed") and waited < timeout:
        time.sleep(30)
        waited += 30
        status = json.loads(mcp.call("get_generate_playbook_status", {"playbookId": playbook_id} if playbook_id else {}))
        state = str(status.get("state") or status.get("status") or "")
        if state.lower() == "failed":
            return (status.get("error") or "(no feedback)").replace("[PlaybookGenerationApiUserException] ", "")
    if state.lower() not in ("completed", "succeeded"):
        sys.exit(f"✗ The playbook was still generating after {timeout // 60} minutes; check the agent in Fabric.")
    raw = mcp.call("get_playbook_rules")
    try:
        rules = json.loads(raw)
    except json.JSONDecodeError:
        log("✓ Playbook generated. Rules:\n" + raw[:2000])
        return
    rules = rules if isinstance(rules, list) else rules.get("rules", [])
    log(f"✓ Playbook generated: {len(rules)} rules")
    for rule in rules:
        log(f"    - {rule.get('name') or rule.get('displayName') or json.dumps(rule)[:120]}")


def review_rules(mcp: Mcp, expected: int) -> tuple[list[str], list[str]]:
    """Problems that make a playbook unusable (missing rules, rules that don't call their check function as of the
    current time), and warnings about rules that won't alert once per episode."""
    raw = mcp.call("get_playbook_rules")
    rules = json.loads(raw) if raw.strip().startswith(("[", "{")) else []
    rules = rules if isinstance(rules, list) else rules.get("rules", [])
    problems = [f"{expected - len(rules)} of the {expected} rules are missing"] if len(rules) < expected else []
    warnings = []
    for rule in rules:
        detail = json.loads(mcp.call("get_rule_details", {"ruleId": rule["id"]}) or "{}")
        detail = detail.get("rule") or detail
        expression = re.sub(r"//[^\n]*", "", (detail.get("classExpression") or {}).get("expression") or "")
        calls = RULE_CALL.findall(expression)
        if not calls:
            problems.append(f"{rule.get('name')} doesn't call its check function")
        elif any(re.sub(r"\s+", "", arg) not in CURRENT_TIME_ARGS for arg in calls):
            problems.append(f"{rule.get('name')} calls its check function with {', '.join(calls)}, not the current time")
        condition = str((detail.get("ruleCondition") or {}).get("$type") or "")
        if condition.lower() == "propertywhenistrue":
            warnings.append(f"{rule.get('name')} alerts at every check while fired is true (condition {condition})")
        if "alert_id" not in expression:
            warnings.append(f"{rule.get('name')} doesn't key its rows by alert_id")
    return problems, warnings


# ─── CLI ──────────────────────────────────────────────────────────────────────


def main() -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--workspace-name", required=True, help="Fabric workspace display name or GUID")
    ap.add_argument("--agent-name", default="OEE Operations Agent")
    ap.add_argument("--ontology-name", default="OEEFactoryOntology", help="Ontology whose rules the agent applies")
    ap.add_argument("--kql-db-name", default="ManufacturingEH", help="KQL database the agent monitors")
    ap.add_argument("--recipient", help="UPN that receives the agent's Teams messages (default: the signed-in az user)")
    ap.add_argument("--generate-playbook", action="store_true",
                    help="Generate the playbook again even if the configuration didn't change")
    state = ap.add_mutually_exclusive_group()
    state.add_argument("--start", action="store_true", help="Run the agent (it monitors continuously and uses capacity)")
    state.add_argument("--stop", action="store_true", help="Stop the agent")
    args = ap.parse_args()

    ws = next((w["id"] for w in get_all("workspaces") if args.workspace_name in (w["displayName"], w["id"])), None) \
        or sys.exit(f"Workspace {args.workspace_name!r} not found.")
    log(f"✓ Workspace:  {args.workspace_name} ({ws})")
    ontology = find_item(ws, "Ontology", args.ontology_name) \
        or sys.exit(f"Ontology {args.ontology_name!r} not found — run scripts/6-publish-ontology.py first.")
    log(f"✓ Ontology:   {args.ontology_name} ({ontology})")
    rules = ontology_rules(ws, ontology)
    log(f"✓ Rules:      {sum(n in rules for n in ALERT_RULES)} alert rules from the ontology")
    kql_db = find_item(ws, "KQLDatabase", args.kql_db_name) \
        or sys.exit(f"KQL database {args.kql_db_name!r} not found — run scripts/1-setup-fabric.sh first.")
    log(f"✓ Source:     {args.kql_db_name} ({kql_db})")
    functions = rule_functions(ws, kql_db, args.kql_db_name)
    missing = [RULE_FUNCTION.format(n) for n in ALERT_RULES if n in rules and RULE_FUNCTION.format(n) not in functions]
    if missing:
        sys.exit(f"{args.kql_db_name} has no {', '.join(missing)} — run scripts/1-setup-fabric.sh to create the "
                 "rule check functions.")
    log(f"✓ Checks:     {sum(n in rules for n in ALERT_RULES)} rule functions in {args.kql_db_name}")
    instructions = build_instructions(args.ontology_name, rules, functions)
    # The account name from the CLI profile (no Microsoft Graph call); for a user login it's the UPN.
    recipient = args.recipient or az("account show --query user.name -o tsv")
    log(f"✓ Recipient:  {recipient}")

    agent = find_item(ws, "OperationsAgent", args.agent_name)
    current = read_definition(ws, agent) if agent else {}
    stored_config = current.get("configuration", {})
    stored_types = [s.get("type") for s in stored_config.get("dataSources", {}).values() if isinstance(s, dict)]
    was_running = bool(current.get("shouldRun", False))
    want_run = args.start or (was_running and not args.stop)
    mcp = Mcp(f"{FABRIC_API}/mcp/workspaces/{ws}/operationsAgents/{agent}/configure") if agent else None
    # A generation orphaned mid-run (by a capacity pause, for example) stays "InProgress" and makes
    # generate_playbook fail with an internal error; writing the configuration again clears it.
    gen_state, gen_age = latest_generation(mcp) if mcp else ("", None)
    stuck = gen_state == "inprogress" and gen_age is not None and gen_age >= GENERATION_TIMEOUT
    if stuck:
        log(f"! The last playbook generation started {gen_age / 3600:.1f} hours ago and never finished; clearing it")
    # The readback doesn't echo the message destination, so an explicit --recipient always rewrites.
    changed = (not agent or stored_config.get("instructions") != instructions or stored_types != [SOURCE_TYPE]
               or bool(args.recipient) or stuck)
    if changed:
        configuration = {
            "instructions": instructions,
            # One knowledge source, keyed by its item id: playbook generation reads the key as the source's item
            # id, and an alias fails with "...data source item identifier must be a canonical GUID".
            "dataSources": {kql_db: {"id": kql_db, "type": SOURCE_TYPE, "workspaceId": ws}},
            "actions": {},
            "messageDestination": {"kind": "Recipient", "recipient": recipient},
        }
        # updateDefinition replaces the playbook too; it's generated again below for the new configuration.
        # The readback's item references are logical ids (all zeros outside Git), so it's never sent back.
        agent = write_definition(ws, agent, args.agent_name, {"configuration": configuration, "shouldRun": False})
        stored = read_definition(ws, agent).get("configuration", {})
        sources = [s for s in stored.get("dataSources", {}).values() if isinstance(s, dict)]
        if [s.get("type") for s in sources] != [SOURCE_TYPE]:
            sys.exit(f"✗ The stored definition doesn't have {args.kql_db_name} as its source: {json.dumps(sources)[:300]}")
        if stored.get("instructions") != instructions:
            sys.exit("✗ The stored instructions differ from the ones sent.")
        log(f"✓ Read back:  {args.kql_db_name} source, {len(instructions)}-char instructions")
    else:
        log("✓ Configuration unchanged")

    mcp = mcp or Mcp(f"{FABRIC_API}/mcp/workspaces/{ws}/operationsAgents/{agent}/configure")
    generate = changed or args.generate_playbook or not current.get("playbook")
    if not generate:
        log("✓ Playbook kept: the instructions and source are unchanged (--generate-playbook makes a new one)")
    # The generator doesn't always follow the instructions, so check each rule's query; generate again if needed.
    for attempt in range(3):
        if generate:
            failure = generate_playbook(mcp, resume=attempt == 0 and not (changed or args.generate_playbook))
            if failure:
                log("! Playbook generation failed. The generator's feedback:\n" + failure)
                if re.search(r"rate-limit|exceeded its limits|throttl", failure, re.I):
                    sys.exit("✗ The capacity is throttled, so the generator can't read the rule functions. Wait for it "
                             "to recover (or pause and resume it), then run the script again.")
                continue
        problems, warnings = review_rules(mcp, sum(n in rules for n in ALERT_RULES))
        if not problems:
            log("✓ Rule queries: each calls its rule check function as of the current time")
            for warning in warnings:
                log(f"! {warning}")
            break
        log("! The playbook isn't usable: " + "; ".join(problems))
        generate = True
    else:
        sys.exit("✗ No usable playbook after three generations; see the feedback above and run the script again.")

    if want_run and (args.start or changed):
        mcp.call("start_agent")
        log("✓ Agent started: it checks the rules about every five minutes and uses capacity while it runs")
    elif args.stop and was_running:
        mcp.call("stop_agent")
        log("✓ Agent stopped")

    running = bool(read_definition(ws, agent).get("shouldRun", False))
    log(f"✓ State:      {'running' if running else 'stopped'}")
    if not running:
        log("\nNext: run this script with --start before the demo and --stop after it. For Teams messages, the"
            " recipient installs the 'Fabric Operations Agent' app in Teams.")
    return 0


def write_definition(ws: str, agent: str | None, name: str, definition: dict) -> str:
    parts = [{"path": DEFINITION_PART, "payloadType": "InlineBase64",
              "payload": base64.b64encode(json.dumps(definition, indent=2).encode("utf-8")).decode()}]
    if agent:
        post_lro(f"workspaces/{ws}/items/{agent}/updateDefinition", {"definition": {"parts": parts}})
        log(f"✓ Operations agent updated: {name} ({agent}), shouldRun {definition['shouldRun']}")
        return agent
    post_lro(f"workspaces/{ws}/items", {"displayName": name, "type": "OperationsAgent",
                                         "description": "Monitors the plant against the OEE ontology's business rules "
                                                        "and messages the plant team in Teams.",
                                         "definition": {"parts": parts}})
    agent = find_item(ws, "OperationsAgent", name) or sys.exit("Created the agent but can't find it.")
    log(f"✓ Operations agent created: {name} ({agent})")
    return agent


if __name__ == "__main__":
    sys.exit(main())
