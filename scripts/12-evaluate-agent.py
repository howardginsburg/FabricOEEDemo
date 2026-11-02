#!/usr/bin/env python3
# =============================================================================
# 12-evaluate-agent.py — Evaluate the OEE Factory IQ agent on the persona question set
# and publish the results to Foundry Evaluations.
#
# agent/evals/cases.json is the question set: each case is a persona's question, the
# knowledge its answer needs, the facts it must contain, and a reference answer (see the
# file's description). This script:
#   1. Resolves the facts that exist only in reference data (facts_kql) by querying the
#      Eventhouse, so the question set never copies the seed values.
#   2. Asks the agent every question as the signed-in user, a few at a time. The Fabric
#      IQ tools and the knowledge base's ontology source act on behalf of the caller,
#      which a server-side agent-target evaluation can't do, so the responses are
#      generated here and judged in Foundry.
#   3. Checks each response locally:
#        routing        — the agent called a tool for every knowledge source the case
#                         needs (which tools count depends on the agent's knowledge mode);
#        required_facts — the answer contains every required fact.
#   4. Uploads the responses as a project dataset and adds a run to the Foundry
#      evaluation "<agent> persona set" (created on first use, so the portal keeps a
#      history of runs). Testing criteria:
#        routing, required_facts — string checks on the local results;
#        intent_resolution, task_adherence (against the agent's own instructions),
#        tool_call_success, groundedness (are the answer's claims supported by the tool
#        results?), response_completeness (against the case's reference answer) —
#        Foundry's built-in AI judges, run on --judge-model.
#   5. Prints a per-case scorecard and the run's report URL, and saves the responses,
#      checks, and judge results to agent/evals/results/ (git-ignored).
#
# Prerequisites:
#   - Azure CLI logged in (`az login`) as a user who can use the agent and read the
#     Fabric workspace: the agent's Fabric IQ tools act as that user.
#   - Python packages:  pip install "azure-ai-projects>=2.2.0" azure-identity openai
#   - A judge deployment that isn't the agent's model, so the agent isn't graded by
#     itself: scripts/8-setup-foundry.sh deploys gpt-5.4-mini.
#
# Usage:
#   python scripts/12-evaluate-agent.py \
#     --foundry-resource <FOUNDRY_RESOURCE_NAME> \
#     --project          <FOUNDRY_PROJECT_NAME> \
#     --fabric-workspace "OEE Demo"
#   Add --case <id> (repeatable) or --persona <name> for a subset, --skip-foundry for the
#   local checks only, or --resubmit <results.json> to check and judge saved responses
#   again without asking the agent.
#   python scripts/12-evaluate-agent.py --write-samples   # regenerate agent/samples/queries.md
# =============================================================================
import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

FABRIC_API = "https://api.fabric.microsoft.com/v1"
REPO_ROOT = Path(__file__).resolve().parent.parent
CASES_FILE = REPO_ROOT / "agent" / "evals" / "cases.json"
SAMPLES_FILE = REPO_ROOT / "agent" / "samples" / "queries.md"
RESULTS_DIR = REPO_ROOT / "agent" / "evals" / "results"

# Bump when the item schema or the testing criteria change, so the next run starts a new
# Foundry evaluation instead of adding a run to one whose criteria differ.
CRITERIA_VERSION = "1"
BACKGROUND_MODELS = ("gpt-5.4", "gpt-5.5")
REASONING_JUDGES = ("gpt-5", "o1", "o3", "o4")
# Tool results go to the judges with the conversation; the knowledge base's answers often run past
# 12,000 characters, and a truncated result makes the judges call supported claims unsupported.
TOOL_RESULT_CHARS = 40000

# The agent tools that can supply each knowledge source, per knowledge mode
# (scripts/10-setup-foundry-agent.py --knowledge). The data agent also reads the ontology.
SOURCE_TOOLS = {
    "knowledge-base": {"sop": {"oee-knowledge"}, "ontology": {"oee-knowledge", "oee-data-agent"},
                       "data": {"oee-data-agent"}},
    "tools": {"sop": {"azure_ai_search"}, "ontology": {"oee-ontology", "oee-data-agent"},
              "data": {"oee-data-agent"}},
}
SOURCE_NAMES = {"sop": "SOPs", "ontology": "Ontology", "data": "Data agent"}
CHECKS = ("routing", "required_facts")
JUDGES = ("intent_resolution", "task_adherence", "tool_call_success", "groundedness", "response_completeness")
SHORT = {"routing": "route", "required_facts": "facts", "intent_resolution": "intent", "task_adherence": "task",
         "tool_call_success": "tools", "groundedness": "grounded", "response_completeness": "complete"}

ITEM_SCHEMA = {
    "type": "object",
    "properties": {
        "case_id": {"type": "string"}, "persona": {"type": "string"}, "query": {"type": "string"},
        "query_messages": {"type": "array"}, "response": {"type": "string"}, "response_messages": {"type": "array"},
        "tool_definitions": {"type": "array"}, "ground_truth": {"type": "string"},
        "routing_check": {"type": "string"}, "facts_check": {"type": "string"},
        "tools_used": {"type": "string"}, "missing": {"type": "string"},
    },
    "required": ["case_id", "query", "response"],
}


def log(msg):
    print(f"   {msg}", flush=True)


def step(msg):
    print(f"\n\u2500\u2500 {msg}", flush=True)


def die(msg):
    print(f"   \u2717 ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


# ─── Fabric + Eventhouse REST ─────────────────────────────────────────────────


def http_json(method, url, token, body=None, timeout=180):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, {"raw": raw[:2000]}


def fabric_list(token, path):
    url, values = f"{FABRIC_API}/{path}", []
    while url:
        status, body = http_json("GET", url, token)
        if status >= 400:
            die(f"Fabric GET {path} failed (HTTP {status}): {json.dumps(body)[:300]}")
        values.extend(body.get("value", []))
        url = body.get("continuationUri")
    return values


def kql_rows(cluster, database, token, query):
    status, body = http_json("POST", f"{cluster.rstrip('/')}/v1/rest/query", token, {"db": database, "csl": query})
    if status >= 400:
        die(f"KQL query failed (HTTP {status}): {json.dumps(body)[:500]}\n   Query: {query}")
    table = body["Tables"][0]
    names = [c["ColumnName"] for c in table["Columns"]]
    return [dict(zip(names, row)) for row in table["Rows"]]


# ─── Facts ────────────────────────────────────────────────────────────────────

_DASHES = dict.fromkeys(map(ord, "\u2010\u2011\u2012\u2013\u2014\u2015\u2212"), "-")


def normalize(text):
    """Lowercase, with plain dashes and spaces, no markdown emphasis, '±5' for '+/- 5', '5%' for '5 %', '5°c'."""
    t = (text or "").translate(_DASHES).replace("\u00a0", " ").replace("\u202f", " ").replace("+/-", "±")
    t = re.sub(r"[*`]", "", t)
    t = re.sub(r"±\s+", "±", t)
    t = re.sub(r"(\d)\s+%", r"\1%", t)
    t = re.sub(r"\s*°\s*", "°", t)
    t = re.sub(r"[ \t]+", " ", t)
    return t.lower()


def value_pattern(value):
    """Regex for one fact value. A number can't be part of a longer number and may use thousands separators.
    A station id (line-d-station-5) also matches the line_id + station_position form (Line-D station_position 5)."""
    text = normalize(str(value)).strip()
    station = re.fullmatch(r"(line-[a-z])-station-(\d+)", text)
    if station:
        line, position = station.groups()
        return (rf"(?:{re.escape(text)}(?!\d)|{line}\b[^\n]{{0,40}}?\b(?:station_position|station|position)"
                rf"[\s:=#]*0?{position}(?!\d))")
    if re.fullmatch(r"\d{4,}", text):
        head, groups = text, []
        while len(head) > 3:
            groups.insert(0, head[-3:])
            head = head[:-3]
        body = ",?".join([head, *groups])
    else:
        body = re.escape(text)
    if text[:1].isdigit():
        body = r"(?<![\w.,-])" + body
    if text[-1:].isdigit():
        body += r"(?!\d|[.,]\d)"
    return body


def compile_fact(spec):
    alternatives = spec if isinstance(spec, list) else [spec]
    return {"label": " | ".join(alternatives),
            "patterns": [re.compile(a[3:]) if a.startswith("re:") else re.compile(value_pattern(a))
                         for a in alternatives]}


def row_pattern(values):
    """All of a row's values on one line of the answer; a pair must also sit close together."""
    parts = [value_pattern(v) for v in values]
    if len(parts) == 1:
        return re.compile(parts[0])
    if len(parts) == 2:
        a, b = parts
        return re.compile("(?:" + a + r"[^\n]{0,120}?" + b + "|" + b + r"[^\n]{0,120}?" + a + ")")
    return re.compile("(?m)^" + "".join(r"(?=[^\n]*?" + p + ")" for p in parts))


def prepare_cases(cases, cred, args):
    """Compile each case's facts and resolve facts_kql against the Eventhouse."""
    for case in cases:
        case["_facts"] = [compile_fact(f) for f in case.get("facts", [])]
        case["_ground_truth"] = case["ground_truth"]
    kql_cases = [c for c in cases if c.get("facts_kql")]
    if not kql_cases:
        return
    fabric_token = cred.get_token("https://api.fabric.microsoft.com/.default").token
    ws = next((w["id"] for w in fabric_list(fabric_token, "workspaces")
               if args.fabric_workspace in (w["displayName"], w["id"])), None) \
        or die(f"Fabric workspace {args.fabric_workspace!r} not found (or no access).")
    db = next((d for d in fabric_list(fabric_token, f"workspaces/{ws}/kqlDatabases")
               if d["displayName"] == args.kql_db_name), None) \
        or die(f"KQL database {args.kql_db_name!r} not found — run scripts/1-setup-fabric.sh first.")
    cluster = db["properties"]["queryServiceUri"]
    kql_token = cred.get_token(f"{cluster}/.default").token
    for case in kql_cases:
        spec = case["facts_kql"]
        rows = kql_rows(cluster, args.kql_db_name, kql_token, spec["query"])
        if not rows:
            die(f"{case['id']}: facts_kql returned no rows. Is the reference data loaded?\n   Query: {spec['query']}")
        values = [[row[c] for c in spec["columns"]] for row in rows]
        texts = [": ".join(str(v) for v in row) for row in values]
        patterns = [row_pattern(row) for row in values]
        if spec.get("match") == "any":
            case["_facts"].append({"label": f"any of {len(rows)} {'/'.join(spec['columns'])} values",
                                   "patterns": patterns})
        else:
            case["_facts"].extend({"label": text, "patterns": [p]} for text, p in zip(texts, patterns))
            case["_ground_truth"] += f" {spec.get('label', 'Reference values')}: {'; '.join(texts)}."
    log(f"Resolved reference facts for {len(kql_cases)} cases from {args.kql_db_name}")


# ─── Agent runs ───────────────────────────────────────────────────────────────


def as_dict(obj):
    if isinstance(obj, dict):
        return obj
    for name in ("to_dict", "model_dump", "as_dict"):
        if hasattr(obj, name):
            return getattr(obj, name)()
    return dict(obj)


def tool_result_text(output):
    """A tool's result as text. The Fabric IQ data agent wraps its answer in {"response": ...} next to
    moderation annotations that aren't part of the answer."""
    try:
        payload = json.loads(output)
    except (TypeError, ValueError):
        payload = None
    text = payload["response"] if isinstance(payload, dict) and isinstance(payload.get("response"), str) \
        else str(output or "")
    return text if len(text) <= TOOL_RESULT_CHARS else text[:TOOL_RESULT_CHARS] + " …[truncated]"


def parse_output(output):
    """Tools called, their definitions, and the conversation in the evaluators' message format."""
    tools_used, tool_errors, definitions, messages = [], [], {}, []
    for raw in output or []:
        item = as_dict(raw)
        kind = item.get("type", "")
        if kind == "mcp_list_tools":
            for tool in item.get("tools") or []:
                definitions[tool["name"]] = {"name": tool["name"], "description": tool.get("description") or "",
                                             "parameters": tool.get("input_schema") or {}}
        elif kind == "mcp_call" or (kind.endswith("_call") and kind != "function_call"):
            label = item.get("server_label") or kind[: -len("_call")]
            name = item.get("name") or label
            tools_used.append(label)
            definitions.setdefault(name, {"name": name, "description": f"Built-in {label} tool", "parameters": {}})
            arguments = item.get("arguments") or {}
            if isinstance(arguments, str):
                try:
                    arguments = json.loads(arguments)
                except ValueError:
                    arguments = {"input": arguments}
            call_id = item.get("id")
            messages.append({"role": "assistant", "content": [
                {"type": "tool_call", "tool_call_id": call_id, "name": name, "arguments": arguments}]})
            if item.get("error"):
                tool_errors.append(f"{label}: {str(item['error'])[:300]}")
            result = item.get("output") or item.get("error")
            if result is not None:
                messages.append({"role": "tool", "tool_call_id": call_id, "content": [
                    {"type": "tool_result", "tool_result": tool_result_text(result)}]})
        elif kind == "message":
            text = "".join(c.get("text") or "" for c in item.get("content") or [])
            messages.append({"role": "assistant", "content": [{"type": "text", "text": text}]})
    return tools_used, tool_errors, list(definitions.values()), messages


def ask(oa, case, background, timeout):
    """Ask the agent one question; returns the record the checks and judges work from."""
    import openai

    record = {"id": case["id"], "persona": case["persona"], "question": case["question"], "answer": "",
              "status": None, "error": None, "tools_used": [], "tool_errors": [], "tool_definitions": [],
              "messages": [], "response_id": None, "usage": None}
    started = time.time()
    for attempt in range(1, 4):
        try:
            resp = oa.responses.create(input=case["question"], background=background)
            misses = 0
            while getattr(resp, "status", "completed") in ("queued", "in_progress") and time.time() - started < timeout:
                time.sleep(5)
                try:
                    resp = oa.responses.retrieve(resp.id)
                except openai.NotFoundError:
                    # A background response can be briefly invisible right after it's created.
                    misses += 1
                    if misses > 6:
                        raise
            break
        except (openai.RateLimitError, openai.APIConnectionError, openai.APITimeoutError,
                openai.InternalServerError) as err:
            if attempt == 3:
                record.update(status="error", error=str(err)[:500], latency_s=round(time.time() - started))
                return record
            time.sleep(20 * attempt)
        except Exception as err:  # noqa: BLE001
            record.update(status="error", error=str(err)[:500], latency_s=round(time.time() - started))
            return record
    if getattr(resp, "status", None) in ("queued", "in_progress"):
        try:
            resp = oa.responses.cancel(resp.id)
        except Exception:  # noqa: BLE001
            pass
    record["status"] = getattr(resp, "status", None)
    record["response_id"] = resp.id
    record["latency_s"] = round(time.time() - started)
    record["usage"] = as_dict(resp.usage) if getattr(resp, "usage", None) else None
    if record["status"] != "completed":
        detail = getattr(resp, "error", None) or getattr(resp, "incomplete_details", None)
        record["error"] = f"response {record['status']}: {detail}"[:500]
    record["answer"] = resp.output_text or ""
    record["tools_used"], record["tool_errors"], record["tool_definitions"], record["messages"] = \
        parse_output(resp.output)
    return record


def check(case, mode, record):
    used = set(record["tools_used"])
    record["missing_sources"] = [src for src in case["sources"]
                                 if not any(used & SOURCE_TOOLS[mode][alt] for alt in src.split("|"))]
    text = normalize(record["answer"])
    record["missing_facts"] = [f["label"] for f in case["_facts"] if not any(p.search(text) for p in f["patterns"])]
    failed = bool(record.get("error"))
    record["routing"] = "fail" if failed or record["missing_sources"] else "pass"
    record["required_facts"] = "fail" if failed or record["missing_facts"] else "pass"
    record["ground_truth"] = case["_ground_truth"]


# ─── Foundry evaluation ───────────────────────────────────────────────────────


def testing_criteria(judge):
    init = {"deployment_name": judge}
    if judge.startswith(REASONING_JUDGES):
        init["is_reasoning_model"] = True

    def ai_judge(name, mapping):
        return {"type": "azure_ai_evaluator", "name": name, "evaluator_name": f"builtin.{name}",
                "data_mapping": mapping, "initialization_parameters": init}

    messages = {"response": "{{item.response_messages}}", "tool_definitions": "{{item.tool_definitions}}"}
    return [
        {"type": "string_check", "name": "routing", "input": "{{item.routing_check}}", "operation": "eq",
         "reference": "pass"},
        {"type": "string_check", "name": "required_facts", "input": "{{item.facts_check}}", "operation": "eq",
         "reference": "pass"},
        ai_judge("intent_resolution", {"query": "{{item.query}}", "response": "{{item.response}}"}),
        # The system prompt goes in with the question, so the judge checks the agent's own instructions.
        ai_judge("task_adherence", {"query": "{{item.query_messages}}", **messages}),
        ai_judge("tool_call_success", messages),
        # Groundedness on the full conversation: are the answer's claims supported by the tool results?
        ai_judge("groundedness", {"query": "{{item.query}}", **messages}),
        ai_judge("response_completeness", {"response": "{{item.response}}", "ground_truth": "{{item.ground_truth}}"}),
    ]


def eval_item(record, instructions):
    response = record["answer"] or f"(no answer: {record.get('error') or record.get('status')})"
    return {
        "case_id": record["id"], "persona": record["persona"], "query": record["question"],
        "query_messages": [{"role": "system", "content": instructions},
                           {"role": "user", "content": [{"type": "text", "text": record["question"]}]}],
        "response": response,
        "response_messages": record["messages"] or [{"role": "assistant", "content": [{"type": "text", "text": response}]}],
        "tool_definitions": record["tool_definitions"], "ground_truth": record["ground_truth"],
        "routing_check": record["routing"], "facts_check": record["required_facts"],
        "tools_used": ", ".join(dict.fromkeys(record["tools_used"])) or "none",
        "missing": "; ".join(record["missing_sources"] + record["missing_facts"]),
    }


def ensure_evaluation(oa, name, agent, judge):
    for evaluation in oa.evals.list(limit=100):
        meta = evaluation.metadata or {}
        if evaluation.name == name and meta.get("criteria_version") == CRITERIA_VERSION and meta.get("judge") == judge:
            log(f"Evaluation: {name} ({evaluation.id})")
            return evaluation
    evaluation = oa.evals.create(
        name=name,
        data_source_config={"type": "custom", "item_schema": ITEM_SCHEMA, "include_sample_schema": False},
        testing_criteria=testing_criteria(judge),
        metadata={"agent": agent, "judge": judge, "criteria_version": CRITERIA_VERSION},
    )
    log(f"Created evaluation: {name} ({evaluation.id})")
    return evaluation


def judge_responses(project, oa, records, meta, args, stamp):
    """Upload the responses as a dataset, add an evaluation run, and wait for the judges."""
    # A response that failed before listing its tools still needs their definitions for the judges.
    known = {d["name"]: d for r in records for d in r["tool_definitions"]}
    for record in records:
        if not record["tool_definitions"]:
            record["tool_definitions"] = list(known.values())
    items = [eval_item(r, meta["instructions"]) for r in records]
    items_file = RESULTS_DIR / f"{stamp}-items.jsonl"
    items_file.write_text("".join(json.dumps(i, ensure_ascii=False) + "\n" for i in items), encoding="utf-8")
    try:
        dataset = project.datasets.upload_file(name=f"{args.agent_name}-persona-responses", version=stamp,
                                               file_path=str(items_file))
        source = {"type": "file_id", "id": dataset.id}
        log(f"Uploaded {len(items)} responses as dataset {args.agent_name}-persona-responses (version {stamp})")
    except Exception as err:  # noqa: BLE001
        log(f"! Dataset upload failed ({str(err)[:200]}); sending the responses inline")
        source = {"type": "file_content", "content": [{"item": i} for i in items]}

    evaluation = ensure_evaluation(oa, args.evaluation_name or f"{args.agent_name} persona set", args.agent_name,
                                   args.judge_model)
    run = oa.evals.runs.create(
        eval_id=evaluation.id,
        name=f"{args.agent_name} v{meta['version']} · {stamp}",
        metadata={"agent_version": str(meta["version"]), "model": meta["model"], "knowledge": meta["mode"],
                  "cases": str(len(records)),
                  "routing_passed": str(sum(r["routing"] == "pass" for r in records)),
                  "facts_passed": str(sum(r["required_facts"] == "pass" for r in records))},
        data_source={"type": "jsonl", "source": source},
    )
    log(f"Run {run.id} — judging with {args.judge_model}…")
    started, last = time.time(), None
    while run.status not in ("completed", "failed", "canceled") and time.time() - started < args.judge_timeout:
        time.sleep(10)
        try:
            run = oa.evals.runs.retrieve(run_id=run.id, eval_id=evaluation.id)
        except Exception as err:  # noqa: BLE001 — a slow token refresh or a dropped connection; keep polling
            log(f"! Polling the run failed ({type(err).__name__}: {str(err)[:120]}); retrying")
            continue
        counts = run.result_counts and (run.result_counts.passed or 0, run.result_counts.failed or 0,
                                        run.result_counts.errored or 0)
        if counts != last and run.result_counts:
            log(f"{run.status}: {run.result_counts.total or 0} items, {counts[0]} passed, {counts[1]} failed, "
                f"{counts[2]} errored ({time.time() - started:.0f}s)")
            last = counts
    judged = {}
    if run.status == "completed":
        for out in oa.evals.runs.output_items.list(run_id=run.id, eval_id=evaluation.id):
            out = as_dict(out)
            item = out.get("datasource_item") or {}
            case_id = item.get("case_id") or (item.get("item") or {}).get("case_id")
            results = {}
            for result in out.get("results") or []:
                result = as_dict(result)
                error = (result.get("sample") or {}).get("error")
                if isinstance(error, dict):
                    error = error.get("message") or json.dumps(error)[:300]
                results[result.get("name")] = {"passed": result.get("passed"), "score": result.get("score"),
                                               "reason": result.get("reason") or error}
            judged[case_id] = results
    return {"id": evaluation.id, "run_id": run.id, "status": run.status, "report_url": getattr(run, "report_url", None),
            "per_criterion": [as_dict(c) for c in (run.per_testing_criteria_results or [])],
            "error": as_dict(run.error) if getattr(run, "error", None) else None}, judged


# ─── Output ───────────────────────────────────────────────────────────────────


def mark(value):
    return {"pass": "\u2713", "fail": "\u2717", True: "\u2713", False: "\u2717"}.get(value, "!")


def scorecard(records, judged):
    columns = CHECKS + (JUDGES if judged else ())
    width = max(len(r["id"]) for r in records) + 2
    print("\n   " + "case".ljust(width) + "".join(SHORT[c].ljust(10) for c in columns) + "tools / seconds", flush=True)
    totals = dict.fromkeys(columns, 0)
    for record in records:
        cells = []
        for column in columns:
            if column in CHECKS:
                value = record[column]
                totals[column] += value == "pass"
            else:
                result = judged.get(record["id"], {}).get(column, {})
                value = result.get("passed")
                totals[column] += value is True
            cells.append(mark(value).ljust(10))
        tools = ", ".join(dict.fromkeys(record["tools_used"])) or "none"
        print("   " + record["id"].ljust(width) + "".join(cells) + f"{tools} / {record.get('latency_s', '?')}",
              flush=True)
    print("   " + "passed".ljust(width) + "".join(f"{totals[c]}/{len(records)}".ljust(10) for c in columns), flush=True)
    return totals


def details(records, judged):
    for record in records:
        lines = []
        if record.get("error"):
            lines.append(f"error: {record['error']}")
        if record["missing_sources"]:
            lines.append("no tool for: " + ", ".join(record["missing_sources"]))
        if record["missing_facts"]:
            lines.append("missing facts: " + "; ".join(record["missing_facts"]))
        if record["tool_errors"]:
            lines.append("tool errors: " + "; ".join(record["tool_errors"]))
        for name, result in judged.get(record["id"], {}).items():
            if name in JUDGES and result.get("passed") is not True:
                lines.append(f"{name} ({result.get('score')}): {str(result.get('reason') or '')[:220]}")
        if lines:
            print(f"\n   {record['id']}", flush=True)
            for line in lines:
                print(f"     - {line}", flush=True)


def write_samples(cases):
    lines = [
        "# OEE Factory IQ — Sample Queries", "",
        "<!-- Generated from agent/evals/cases.json by `python scripts/12-evaluate-agent.py --write-samples`.",
        "     Edit the cases file, then regenerate this one. -->", "",
        "Persona questions for demos. They're also the question set `scripts/12-evaluate-agent.py`",
        "evaluates the agent on. Each question names the knowledge its answer needs:", "",
        "- **SOPs**: the SOP and policy documents, through the Foundry IQ knowledge base (or the AI Search",
        "  tool in tools mode).",
        "- **Ontology**: the Fabric IQ ontology's entities, relationships, current machine state, and",
        "  business rules.",
        "- **Data agent**: the OEE data agent's governed KPIs from the Direct Lake semantic model and its",
        "  event detail from the Eventhouse.", "",
    ]
    number = 0
    for persona in dict.fromkeys(c["persona"] for c in cases):
        lines += [f"## {persona}", ""]
        for case in (c for c in cases if c["persona"] == persona):
            number += 1
            needs = " + ".join(
                f"({names})" if "|" in src and len(case["sources"]) > 1 else names
                for src in case["sources"]
                for names in [" or ".join(SOURCE_NAMES[s] for s in src.split("|"))])
            lines += [f"{number}. \"{case['question']}\"", f"   *{needs}*: {case['exercises']}.", ""]
    SAMPLES_FILE.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    log(f"Wrote {SAMPLES_FILE.relative_to(REPO_ROOT)} ({number} questions)")


# ─── Main ─────────────────────────────────────────────────────────────────────


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")
    p = argparse.ArgumentParser(description="Evaluate the OEE Factory IQ agent on the persona question set.")
    p.add_argument("--foundry-resource", help="Foundry (AIServices) resource name.")
    p.add_argument("--project", help="Foundry project name.")
    p.add_argument("--fabric-workspace", default="OEE Demo",
                   help="Fabric workspace name or id, for the reference facts (default: OEE Demo).")
    p.add_argument("--kql-db-name", default="ManufacturingEH", help="KQL database with the reference tables.")
    p.add_argument("--agent-name", default="oee-factory-iq", help="Foundry agent to evaluate.")
    p.add_argument("--knowledge", choices=("knowledge-base", "tools"),
                   help="The agent's knowledge mode (default: detected from its tools).")
    p.add_argument("--judge-model", default="gpt-5.4-mini",
                   help="Deployment for the AI judges (default: gpt-5.4-mini, from scripts/8-setup-foundry.sh).")
    p.add_argument("--evaluation-name", help="Foundry evaluation name (default: '<agent> persona set').")
    p.add_argument("--case", action="append", default=[], help="Run only this case id (repeatable).")
    p.add_argument("--persona", action="append", default=[], help="Run only this persona's cases (repeatable).")
    p.add_argument("--workers", type=int, default=3, help="Questions asked in parallel (default: 3).")
    p.add_argument("--timeout", type=int, default=600, help="Seconds to wait for one answer (default: 600).")
    p.add_argument("--judge-timeout", type=int, default=3600,
                   help="Seconds to wait for the evaluation run (default: 3600).")
    p.add_argument("--skip-foundry", action="store_true", help="Run the local checks only; don't judge in Foundry.")
    p.add_argument("--resubmit", help="Check and judge the responses saved in this results file again.")
    p.add_argument("--write-samples", action="store_true",
                   help=f"Write {SAMPLES_FILE.relative_to(REPO_ROOT)} from the cases and exit.")
    args = p.parse_args()

    spec = json.loads(CASES_FILE.read_text(encoding="utf-8"))
    cases = spec["cases"]
    if args.write_samples:
        write_samples(cases)
        return 0
    if not (args.foundry_resource and args.project):
        p.error("--foundry-resource and --project are required")
    unknown = sorted(set(args.case) - {c["id"] for c in cases})
    if unknown:
        p.error(f"unknown case id(s): {', '.join(unknown)}")
    if args.case or args.persona:
        cases = [c for c in cases if c["id"] in args.case or c["persona"] in args.persona]
    saved = json.loads(Path(args.resubmit).read_text(encoding="utf-8")) if args.resubmit else None
    if saved:
        answered = {r["id"] for r in saved["cases"]}
        cases = [c for c in cases if c["id"] in answered]
    if not cases:
        p.error("no cases selected")

    from azure.ai.projects import AIProjectClient
    from azure.identity import DefaultAzureCredential

    cred = DefaultAzureCredential(exclude_interactive_browser_credential=True)
    endpoint = f"https://{args.foundry_resource}.services.ai.azure.com/api/projects/{args.project}"
    project = AIProjectClient(endpoint=endpoint, credential=cred)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    step(f"Agent: {args.agent_name}")
    latest = as_dict(project.agents.get(agent_name=args.agent_name))["versions"]["latest"]
    definition = latest["definition"]
    tools = definition.get("tools") or []
    mode = args.knowledge or ("knowledge-base" if any(t.get("server_label") == "oee-knowledge" for t in tools)
                              else "tools")
    meta = {"version": latest["version"], "model": definition.get("model"), "mode": mode,
            "instructions": definition.get("instructions") or ""}
    if saved:
        meta.update({k: saved[k] for k in ("version", "model", "mode", "instructions") if k in saved})
    log(f"Version {meta['version']}, model {meta['model']}, knowledge mode {meta['mode']}")
    if meta["model"] == args.judge_model:
        log(f"! The judge ({args.judge_model}) is the agent's own model, so the agent grades itself.")

    step(f"Cases: {len(cases)} of {len(spec['cases'])}")
    prepare_cases(cases, cred, args)

    if saved:
        step(f"Reusing the responses in {args.resubmit}")
        records = [r for r in saved["cases"] if r["id"] in {c["id"] for c in cases}]
    else:
        step(f"Asking the agent ({args.workers} at a time)")
        background = (meta["model"] or "").startswith(BACKGROUND_MODELS)
        with project.get_openai_client(agent_name=args.agent_name) as agent_client, \
                ThreadPoolExecutor(max_workers=max(1, args.workers)) as pool:
            def run(case):
                record = ask(agent_client, case, background, args.timeout)
                log(f"{case['id']}: {record['status']} in {record.get('latency_s', '?')}s "
                    f"({', '.join(dict.fromkeys(record['tools_used'])) or 'no tools'})")
                return record
            records = list(pool.map(run, cases))
    by_id = {c["id"]: c for c in cases}
    for record in records:
        check(by_id[record["id"]], meta["mode"], record)

    # Saved before judging too, so a failure while judging doesn't lose the responses (--resubmit reuses them).
    out = RESULTS_DIR / f"{stamp}.json"

    def save(evaluation):
        out.write_text(json.dumps({"agent": args.agent_name, **meta, "judge": args.judge_model, "run_at": stamp,
                                   "evaluation": evaluation, "cases": records}, indent=2, ensure_ascii=False),
                       encoding="utf-8")
    save(None)

    evaluation, judged = None, {}
    if not args.skip_foundry:
        step("Foundry evaluation")
        with project.get_openai_client() as oa:
            evaluation, judged = judge_responses(project, oa, records, meta, args, stamp)
        for record in records:
            record["judges"] = judged.get(record["id"], {})

    step("Scorecard (\u2713 pass, \u2717 fail, ! error)")
    scorecard(records, judged)
    details(records, judged)
    save(evaluation)
    step("Done")
    log(f"Results: {out.relative_to(REPO_ROOT)}")
    if evaluation:
        log(f"Evaluation run {evaluation['status']}: {evaluation['report_url']}")
    failed_run = evaluation is not None and evaluation["status"] != "completed"
    return 1 if failed_run or any(r.get("error") for r in records) else 0


if __name__ == "__main__":
    sys.exit(main())
