#!/usr/bin/env python3
# =============================================================================
# 10-setup-foundry-agent.py — Create the OEE Factory IQ prompt agent and wire it to
# the plant's knowledge: the Fabric IQ ontology, the Fabric data agent, and the
# Azure AI Search SOP index.
#
# Two knowledge modes (--knowledge):
#   knowledge-base (default) — a Foundry IQ knowledge base in Azure AI Search with two
#       knowledge sources: the oee-sops index (searchIndex) and the OEEFactoryOntology
#       ontology (fabricOntology). It plans subqueries across both and synthesizes a
#       cited answer. The agent reaches it as an MCP tool (knowledge_base_retrieve) and
#       uses the Fabric IQ data agent tool for numbers.
#   tools — separate tools: AzureAISearchTool on oee-sops, and Fabric IQ tools for the
#       ontology and the data agent.
#
# It:
#   1. Creates a project connection to Azure AI Search (CognitiveSearch, ApiKey).
#   2. Creates two Fabric IQ project connections (RemoteTool, UserEntraToken —
#      on-behalf-of the signed-in user, audience https://analysis.windows.net/powerbi/api):
#        • fabriciq-ontology  → the OEEFactoryOntology MCP endpoint
#          /v1/mcp/dataPlane/workspaces/{ws}/items/{ontology}/ontologyEndpoint
#        • fabriciq-dataagent → the published OEE Data Agent MCP endpoint
#          /v1/mcp/workspaces/{ws}/dataagents/{agent}/agent
#   3. knowledge-base mode: creates the knowledge sources and the knowledge base
#      (api-version 2026-08-01-preview), grants the project's managed identity Search
#      Index Data Reader on the search service, and creates a RemoteTool connection
#      (ProjectManagedIdentity, audience https://search.azure.com/) to the knowledge
#      base's MCP endpoint.
#   4. Creates a Foundry prompt agent (PromptAgentDefinition) with the mode's tools and
#      agent/system-prompt.md (rendered for the mode) as its instructions.
#   5. Removes the legacy fabric_dataagent_preview connection (fabric-oee-dataagent),
#      which the Fabric IQ tool replaces.
#
# Run AFTER scripts/8-setup-foundry.sh, scripts/9-setup-aisearch.sh, and
# scripts/6-publish-ontology.py + scripts/7-setup-data-agent.py (the data agent must
# be published; script 7 publishes it).
#
# Prerequisites:
#   - Azure CLI logged in (`az login`) as a user who can read the Fabric workspace —
#     used by DefaultAzureCredential, to resolve the subscription id, and as the
#     identity the Fabric IQ tools run as during --smoke. Assigning the search role
#     needs Owner or User Access Administrator on the search service.
#   - Python packages:  pip install "azure-ai-projects>=2.2.0" azure-identity openai httpx
#   - A chat model that supports background mode (gpt-5.5 or gpt-5.4, deployed by
#     scripts/8-setup-foundry.sh) so long-running data agent calls can finish. The
#     knowledge base uses the same deployment for query planning and answer synthesis.
#
# Field notes baked in:
#   - The Foundry connections ARM endpoint intermittently returns HTTP 500
#     (ServiceError). Connection PUTs are retried.
#   - Fabric IQ connections pass the caller's Entra identity through: every user of
#     the agent needs read access to the ontology, the data agent, and the sources the
#     ontology binds (ManufacturingLH, ManufacturingEH, the OeeGovernance SQL database,
#     and Read and Build on the OEEAnalytics semantic model). The ontology endpoint
#     doesn't accept service principals.
#   - The ontology knowledge source queries Fabric on behalf of the caller: Agent
#     Service sends the user's token in x-ms-query-source-authorization. Without it the
#     knowledge base answers from the SOP index only (HTTP 206, the ontology source
#     reports "Invalid header"). Fabric ontology sources don't support the "minimal"
#     retrieval effort.
#   - The ontology knowledge source answers each query with a live natural-language
#     query over the ontology's data. A question it can't answer quickly (computing or
#     ranking KPIs, checking a condition over a time window) runs until its own
#     100-second HTTP timeout. The knowledge base's MCP tool doesn't set a runtime, so
#     the service default of 90 seconds failed the whole agent response. The knowledge
#     base stores retrieveDefaults.maxRuntimeInSeconds (--retrieval-runtime, 150) so a
#     slow ontology query degrades to an SOP-only answer (HTTP 206), and its retrieval
#     instructions keep procedure, condition, and KPI questions off the ontology source.
#
# Usage:
#   python scripts/10-setup-foundry-agent.py \
#     --foundry-resource <FOUNDRY_RESOURCE_NAME> \
#     --project          <FOUNDRY_PROJECT_NAME> \
#     --resource-group   <RG> \
#     --search-service   <SEARCH_SERVICE_NAME> \
#     --fabric-workspace "OEE Demo" \
#     --replace --smoke
# =============================================================================
import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

ARM = "https://management.azure.com"
FABRIC_API = "https://api.fabric.microsoft.com/v1"
SEARCH_CONN_API = "2025-04-01-preview"
REMOTE_TOOL_CONN_API = "2025-10-01-preview"
SEARCH_KEYS_API = "2023-11-01"
SEARCH_KB_API = "2026-08-01-preview"
FOUNDRY_API = "2025-06-01"
ROLE_ASSIGNMENT_API = "2022-04-01"
FABRIC_IQ_AUDIENCE = "https://analysis.windows.net/powerbi/api"
SEARCH_AUDIENCE = "https://search.azure.com/"
SEARCH_INDEX_DATA_READER = "1407120a-92aa-4202-b7e9-c0e197c71c8f"
LEGACY_FABRIC_CONNECTION = "fabric-oee-dataagent"
BACKGROUND_MODELS = ("gpt-5.4", "gpt-5.5")
SOP_KNOWLEDGE_SOURCE = "oee-sops-ks"
ONTOLOGY_KNOWLEDGE_SOURCE = "oee-ontology-ks"

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SYS_PROMPT = os.path.join(REPO_ROOT, "agent", "system-prompt.md")

QUERY_TYPES = {
    "simple": "SIMPLE",
    "semantic": "SEMANTIC",
    "vector": "VECTOR",
    "vector_simple_hybrid": "VECTOR_SIMPLE_HYBRID",
    "vector_semantic_hybrid": "VECTOR_SEMANTIC_HYBRID",
}

SMOKE_QUESTIONS = {
    "knowledge-base": [
        ("Knowledge base: SOP",
         "What are the corrective actions for a Nozzle-Clog fault on an SMT-Placement station? Cite the SOP."),
        ("Knowledge base: ontology rule",
         "According to the plant's business rules, what must happen when a line's OEE stays below 60%?"),
        ("Knowledge base: ontology + SOP",
         "What is the target reject rate of line-d-station-5, and what should happen to its rejected parts?"),
        ("Fabric IQ data agent",
         "What is OEE by line, with availability, performance, and quality?"),
    ],
    "tools": [
        ("AI Search (SOP)",
         "What are the corrective actions for a Nozzle-Clog fault on an SMT-Placement station? Cite the SOP."),
        ("Fabric IQ ontology",
         "According to the plant's business rules, what must happen when a line's OEE stays below 60%?"),
        ("Fabric IQ data agent",
         "What is OEE by line, with availability, performance, and quality?"),
    ],
}

KB_DESCRIPTION = (
    "The OEE plant's knowledge: the Fabric IQ ontology (lines, stations, machines and their live telemetry, parts "
    "and station passes, work orders and their steps, technicians, OEE targets and target reject rates, business "
    "rules, and the governed metrics from the OEEAnalytics semantic model) and the SOP and policy documents."
)
KB_RETRIEVAL_INSTRUCTIONS = (
    f"{SOP_KNOWLEDGE_SOURCE} holds the SOPs and plant policies: procedures, corrective actions, preventive "
    "maintenance, lockout/tagout, quality disposition, escalation, and the plant design facts they document, such "
    f"as each line's bottleneck station, KPI targets, and pause thresholds. {ONTOLOGY_KNOWLEDGE_SOURCE} answers by "
    "querying the plant's data through the Fabric IQ ontology, which reads each part from the source that holds it: "
    "machines' current status and work orders' steps live from the Eventhouse; lines, stations, machine types, "
    "shifts, production schedules, target reject rates, parts and their station passes, technicians, and floor "
    "issues from the lakehouse; each line's OEE target from the database the Power BI report writes it to; and the "
    "ontology's business rules. Use "
    f"{ONTOLOGY_KNOWLEDGE_SOURCE} for a direct question about those facts, about whether a work order is open, or "
    "about what a business rule says. A "
    "question that describes a condition (\"if rejects exceed 8%\", \"when a line is below target\") or asks what to "
    f"do is a procedure question: use {SOP_KNOWLEDGE_SOURCE}. Never use {ONTOLOGY_KNOWLEDGE_SOURCE} to compute, rank, "
    "or trend KPIs, to check which lines or stations miss a target, or to derive a bottleneck from data; "
    f"bottlenecks are design facts in {SOP_KNOWLEDGE_SOURCE}."
)
KB_ANSWER_INSTRUCTIONS = (
    "Answer in plain business language. Identify stations by device_id (line-x-station-N) and keep numbers exactly "
    "as retrieved. Cite each SOP or policy by file name and each ontology fact by its entity or rule name."
)


def log(msg):
    print(f"   {msg}", flush=True)


def step(msg):
    print(f"\n\u2500\u2500 {msg}", flush=True)


def die(msg):
    print(f"   \u2717 ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def az_subscription_id():
    try:
        out = subprocess.check_output(
            ["az", "account", "show", "--query", "id", "-o", "tsv"],
            text=True, stderr=subprocess.DEVNULL, shell=(os.name == "nt"),
        ).strip()
        return out or None
    except Exception:
        return None


def http_json(method, url, token, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = {"raw": raw}
        return e.code, parsed


def put_connection_with_retry(token, conn_id, properties, api_version, attempts=10, delay=20):
    """PUT a project connection, retrying the transient account-RP 500s."""
    url = f"{ARM}{conn_id}?api-version={api_version}"
    for i in range(1, attempts + 1):
        status, resp = http_json("PUT", url, token, {"properties": properties})
        if status in (200, 201):
            return resp
        text = json.dumps(resp)
        transient = status == 500 or "InternalServerError" in text or "ServiceError" in text
        if transient and i < attempts:
            log(f"[{i}/{attempts}] connection PUT {status} (transient) — retrying in {delay}s")
            time.sleep(delay)
            continue
        die(f"connection PUT failed (HTTP {status}): {text[:500]}")
    die("connection PUT exhausted retries")


def fabric_items(token, path):
    status, body = http_json("GET", f"{FABRIC_API}/{path}", token)
    if status >= 400:
        die(f"Fabric GET {path} failed (HTTP {status}): {json.dumps(body)[:300]}")
    return body.get("value", [])


def resolve_fabric(token, workspace, ontology_name, agent_name):
    """Workspace id + the ontology and data agent ids, by display name."""
    ws = next((w["id"] for w in fabric_items(token, "workspaces") if workspace in (w["displayName"], w["id"])), None)
    if not ws:
        die(f"Fabric workspace {workspace!r} not found (or no access).")
    find = lambda kind, name: next(  # noqa: E731
        (i["id"] for i in fabric_items(token, f"workspaces/{ws}/items?type={kind}") if i["displayName"] == name), None)
    ontology = find("Ontology", ontology_name) or die(
        f"Ontology {ontology_name!r} not found — run scripts/6-publish-ontology.py first.")
    agent = find("DataAgent", agent_name) or die(
        f"Data agent {agent_name!r} not found — run scripts/7-setup-data-agent.py first.")
    return ws, ontology, agent


def search_json(method, url, key, body=None):
    """Azure AI Search data-plane call with the admin key (never printed)."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("api-key", key)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw}


def ensure_role(token, sub, scope, principal_id, role_id, label):
    """Assign a built-in role to a managed identity at a scope (idempotent)."""
    name = uuid.uuid5(uuid.NAMESPACE_URL, f"{scope}|{principal_id}|{role_id}")
    url = f"{ARM}{scope}/providers/Microsoft.Authorization/roleAssignments/{name}?api-version={ROLE_ASSIGNMENT_API}"
    status, resp = http_json("PUT", url, token, {"properties": {
        "roleDefinitionId": f"/subscriptions/{sub}/providers/Microsoft.Authorization/roleDefinitions/{role_id}",
        "principalId": principal_id, "principalType": "ServicePrincipal"}})
    if status in (200, 201) or "RoleAssignmentExists" in json.dumps(resp):
        log(f"{label} assigned (or already present)")
        return
    die(f"Role assignment '{label}' failed (HTTP {status}): {json.dumps(resp)[:400]}. "
        "Assign it in the Azure portal (needs Owner or User Access Administrator), then re-run.")


def ensure_knowledge_base(args, mgmt_token, sub, search_key, ws_id, ontology_id):
    """Knowledge sources (SOP index + Fabric ontology) and the knowledge base; returns its MCP endpoint."""
    endpoint = f"https://{args.search_service}.search.windows.net"
    status, index = search_json("GET", f"{endpoint}/indexes/{args.search_index}?api-version={SEARCH_KB_API}", search_key)
    if status != 200:
        die(f"Search index '{args.search_index}' not found (HTTP {status}) — run scripts/9-setup-aisearch.sh first.")
    semantic = [c["name"] for c in (index.get("semantic") or {}).get("configurations", [])]
    vectorizers = (index.get("vectorSearch") or {}).get("vectorizers") or []
    aoai_uri = next((v.get("azureOpenAIParameters", {}).get("resourceUri") for v in vectorizers), None)
    if not aoai_uri:
        die(f"Index '{args.search_index}' has no Azure OpenAI vectorizer to take the model endpoint from.")

    model = args.knowledge_base_model or args.model
    deployment_url = (f"{ARM}/subscriptions/{sub}/resourceGroups/{args.resource_group}/providers/"
                      f"Microsoft.CognitiveServices/accounts/{args.foundry_resource}/deployments/{model}"
                      f"?api-version={FOUNDRY_API}")
    status, deployment = http_json("GET", deployment_url, mgmt_token)
    if status != 200:
        die(f"Model deployment '{model}' not found on {args.foundry_resource} — run scripts/8-setup-foundry.sh.")
    model_name = deployment["properties"]["model"]["name"]

    sources = [
        {"name": SOP_KNOWLEDGE_SOURCE, "kind": "searchIndex",
         "description": "Per-station SOPs and plant-wide policy and reference documents (PDF chunks).",
         "searchIndexParameters": {
             "searchIndexName": args.search_index,
             **({"semanticConfigurationName": semantic[0]} if semantic else {}),
             "sourceDataFields": [{"name": "metadata_storage_name"}, {"name": "line_id"},
                                  {"name": "station_position"}]}},
        {"name": ONTOLOGY_KNOWLEDGE_SOURCE, "kind": "fabricOntology",
         "description": f"The {args.ontology_name} Fabric IQ ontology: the plant's entities, relationships, live "
                        "machine state and work order steps, OEE targets, business rules, and metrics (the "
                        "OEEAnalytics model's measures), queried live as the signed-in user.",
         "fabricOntologyParameters": {"workspaceId": ws_id, "ontologyId": ontology_id}},
    ]
    for source in sources:
        status, resp = search_json("PUT", f"{endpoint}/knowledgesources/{source['name']}?api-version={SEARCH_KB_API}",
                                   search_key, source)
        if status not in (200, 201, 204):
            die(f"Knowledge source '{source['name']}' failed (HTTP {status}): {json.dumps(resp)[:500]}")
        log(f"Knowledge source ready: {source['name']} ({source['kind']})")

    kb = {
        "name": args.knowledge_base_name,
        "description": KB_DESCRIPTION,
        "retrievalInstructions": KB_RETRIEVAL_INSTRUCTIONS,
        "answerInstructions": KB_ANSWER_INSTRUCTIONS,
        "outputMode": "answerSynthesis",
        "knowledgeSources": [{"name": s["name"]} for s in sources],
        "models": [{"kind": "azureOpenAI", "azureOpenAIParameters": {
            "resourceUri": aoai_uri, "deploymentId": model, "modelName": model_name}}],
        "retrievalReasoningEffort": {"kind": args.retrieval_effort},
        "retrieveDefaults": {"maxRuntimeInSeconds": args.retrieval_runtime},
    }
    status, resp = search_json(
        "PUT", f"{endpoint}/knowledgebases/{args.knowledge_base_name}?api-version={SEARCH_KB_API}", search_key, kb)
    if status not in (200, 201, 204):
        die(f"Knowledge base '{args.knowledge_base_name}' failed (HTTP {status}): {json.dumps(resp)[:500]}")
    log(f"Knowledge base ready: {args.knowledge_base_name} (model {model}, {args.retrieval_effort} effort, "
        f"{args.retrieval_runtime} s retrieve budget)")
    return f"{endpoint}/knowledgebases/{args.knowledge_base_name}/mcp?api-version={SEARCH_KB_API}"


def render_prompt(text, mode):
    """Keep the system prompt's <!-- mode: X --> blocks for the chosen mode, drop the others and any comments."""
    text = re.sub(r"<!-- mode: ([\w-]+) -->\n(.*?)<!-- /mode -->\n",
                  lambda m: m.group(2) if m.group(1) == mode else "", text, flags=re.S)
    return re.sub(r"\n*<!--.*?-->\n*", "\n\n", text, flags=re.S).strip() + "\n"


def main():
    p = argparse.ArgumentParser(description="Create the OEE Factory IQ Foundry prompt agent.")
    p.add_argument("--foundry-resource", required=True)
    p.add_argument("--project", required=True)
    p.add_argument("--resource-group", required=True)
    p.add_argument("--subscription", default=None, help="Defaults to the active az subscription.")
    p.add_argument("--search-service", required=True)
    p.add_argument("--search-resource-group", default=None,
                   help="RG of the search service (default: --resource-group).")
    p.add_argument("--search-index", default="oee-sops")
    p.add_argument("--search-query-type", default="vector_semantic_hybrid", choices=list(QUERY_TYPES))
    p.add_argument("--search-top-k", type=int, default=5)
    p.add_argument("--fabric-workspace", "--fabric-workspace-id", dest="fabric_workspace", required=True,
                   help="Fabric workspace display name or GUID.")
    p.add_argument("--ontology-name", default="OEEFactoryOntology")
    p.add_argument("--data-agent-name", default="OEE Data Agent")
    p.add_argument("--model", default="gpt-5.5", help="Chat deployment name (default: gpt-5.5).")
    p.add_argument("--agent-name", default="oee-factory-iq")
    p.add_argument("--system-prompt", default=DEFAULT_SYS_PROMPT)
    p.add_argument("--search-connection-name", default="aisearch-sops")
    p.add_argument("--ontology-connection-name", default="fabriciq-ontology")
    p.add_argument("--data-agent-connection-name", default="fabriciq-dataagent")
    p.add_argument("--knowledge", choices=("knowledge-base", "tools"), default="knowledge-base",
                   help="knowledge-base: one Foundry IQ knowledge base over the SOP index and the ontology "
                        "(default); tools: separate AI Search and Fabric IQ ontology tools.")
    p.add_argument("--knowledge-base-name", default="oee-factory-kb")
    p.add_argument("--knowledge-base-connection-name", default="oee-knowledge-base")
    p.add_argument("--knowledge-base-model", default=None,
                   help="Deployment for the knowledge base's query planning and answer synthesis (default: --model).")
    p.add_argument("--retrieval-effort", choices=("low", "medium"), default="low",
                   help="Knowledge base retrieval reasoning effort (Fabric ontology sources don't support minimal).")
    p.add_argument("--retrieval-runtime", type=int, default=150,
                   help="Seconds a knowledge base retrieve may run (10-600, default 150), stored as the knowledge "
                        "base's retrieveDefaults.maxRuntimeInSeconds; the service default is 90.")
    p.add_argument("--replace", action="store_true",
                   help="Create a new agent version even if the agent already exists.")
    p.add_argument("--smoke", action="store_true",
                   help="Ask one question per tool and knowledge source.")
    args = p.parse_args()
    if not 10 <= args.retrieval_runtime <= 600:
        die("--retrieval-runtime must be between 10 and 600 seconds.")

    try:
        from azure.identity import DefaultAzureCredential
        from azure.ai.projects import AIProjectClient
        from azure.ai.projects.models import (
            PromptAgentDefinition,
            AzureAISearchTool, AzureAISearchToolResource, AISearchIndexResource,
            AzureAISearchQueryType,
            FabricIQPreviewTool,
            MCPTool,
        )
    except ImportError as e:
        die(f"Missing SDK ({e}). Install with: pip install \"azure-ai-projects>=2.2.0\" azure-identity openai httpx")

    sub = args.subscription or az_subscription_id()
    if not sub:
        die("Could not resolve a subscription id. Run 'az login' or pass --subscription.")
    search_rg = args.search_resource_group or args.resource_group

    if not os.path.isfile(args.system_prompt):
        die(f"System prompt not found: {args.system_prompt}")
    with open(args.system_prompt, encoding="utf-8") as f:
        instructions = render_prompt(f.read(), args.knowledge)

    cred = DefaultAzureCredential(exclude_interactive_browser_credential=True)
    mgmt_token = cred.get_token(f"{ARM}/.default").token
    fabric_token = cred.get_token("https://api.fabric.microsoft.com/.default").token

    step(f"Resolving Fabric items in workspace '{args.fabric_workspace}'")
    ws_id, ontology_id, agent_id = resolve_fabric(fabric_token, args.fabric_workspace,
                                                  args.ontology_name, args.data_agent_name)
    ontology_url = f"{FABRIC_API}/mcp/dataPlane/workspaces/{ws_id}/items/{ontology_id}/ontologyEndpoint"
    agent_url = f"{FABRIC_API}/mcp/workspaces/{ws_id}/dataagents/{agent_id}/agent"
    log(f"Ontology:   {args.ontology_name} ({ontology_id})")
    log(f"Data agent: {args.data_agent_name} ({agent_id})")

    conn_base = (
        f"/subscriptions/{sub}/resourceGroups/{args.resource_group}"
        f"/providers/Microsoft.CognitiveServices/accounts/{args.foundry_resource}"
        f"/projects/{args.project}/connections"
    )
    search_conn_id = f"{conn_base}/{args.search_connection_name}"
    ontology_conn_id = f"{conn_base}/{args.ontology_connection_name}"
    agent_conn_id = f"{conn_base}/{args.data_agent_connection_name}"
    kb_conn_id = f"{conn_base}/{args.knowledge_base_connection_name}"

    # ── 1. Search admin key (server-side only; never printed) ────────────────
    step(f"Resolving admin key for search service '{args.search_service}'")
    keys_url = (
        f"{ARM}/subscriptions/{sub}/resourceGroups/{search_rg}"
        f"/providers/Microsoft.Search/searchServices/{args.search_service}"
        f"/listAdminKeys?api-version={SEARCH_KEYS_API}"
    )
    kstatus, kresp = http_json("POST", keys_url, mgmt_token)
    if kstatus != 200 or "primaryKey" not in kresp:
        die(f"Could not read search admin keys (HTTP {kstatus}): {json.dumps(kresp)[:300]}")
    search_key = kresp["primaryKey"]
    log("Admin key resolved")

    # ── 2. AI Search connection (CognitiveSearch / ApiKey) ───────────────────
    step(f"Connection: {args.search_connection_name} (Azure AI Search)")
    search_res_id = (
        f"/subscriptions/{sub}/resourceGroups/{search_rg}"
        f"/providers/Microsoft.Search/searchServices/{args.search_service}"
    )
    put_connection_with_retry(mgmt_token, search_conn_id, {
        "category": "CognitiveSearch",
        "target": f"https://{args.search_service}.search.windows.net",
        "authType": "ApiKey",
        "isSharedToAll": True,
        "credentials": {"key": search_key},
        "metadata": {"ApiType": "Azure", "ResourceId": search_res_id},
    }, SEARCH_CONN_API)
    log("AI Search connection ready")

    # ── 3. Fabric IQ connections (RemoteTool / on-behalf-of the user) ────────
    for name, conn_id, target in ((args.ontology_connection_name, ontology_conn_id, ontology_url),
                                  (args.data_agent_connection_name, agent_conn_id, agent_url)):
        step(f"Connection: {name} (Fabric IQ)")
        put_connection_with_retry(mgmt_token, conn_id, {
            "category": "RemoteTool",
            "authType": "UserEntraToken",
            "target": target,
            "audience": FABRIC_IQ_AUDIENCE,
            "isSharedToAll": True,
        }, REMOTE_TOOL_CONN_API)
        log(f"Fabric IQ connection ready → {target}")

    legacy_url = f"{ARM}{conn_base}/{LEGACY_FABRIC_CONNECTION}?api-version={SEARCH_CONN_API}"
    status, _ = http_json("GET", legacy_url, mgmt_token)
    if status == 200:
        http_json("DELETE", legacy_url, mgmt_token)
        log(f"Removed the legacy data-agent connection '{LEGACY_FABRIC_CONNECTION}' (replaced by Fabric IQ)")

    # ── 4. Foundry IQ knowledge base (knowledge-base mode) ───────────────────
    kb_mcp_url = None
    if args.knowledge == "knowledge-base":
        step(f"Foundry IQ knowledge base: {args.knowledge_base_name}")
        kb_mcp_url = ensure_knowledge_base(args, mgmt_token, sub, search_key, ws_id, ontology_id)
        project_url = (f"{ARM}/subscriptions/{sub}/resourceGroups/{args.resource_group}/providers/"
                       f"Microsoft.CognitiveServices/accounts/{args.foundry_resource}/projects/{args.project}"
                       f"?api-version={FOUNDRY_API}")
        status, project_res = http_json("GET", project_url, mgmt_token)
        principal = ((project_res or {}).get("identity") or {}).get("principalId")
        if status != 200 or not principal:
            die(f"Project '{args.project}' has no system-assigned managed identity (HTTP {status}); enable it "
                "in the Azure portal (project → Identity) and re-run.")
        ensure_role(mgmt_token, sub, search_res_id, principal, SEARCH_INDEX_DATA_READER,
                    "Search Index Data Reader for the project's managed identity")
        step(f"Connection: {args.knowledge_base_connection_name} (knowledge base MCP)")
        put_connection_with_retry(mgmt_token, kb_conn_id, {
            "category": "RemoteTool",
            "authType": "ProjectManagedIdentity",
            "target": kb_mcp_url,
            "audience": SEARCH_AUDIENCE,
            "isSharedToAll": True,
            "metadata": {"ApiType": "Azure"},
        }, REMOTE_TOOL_CONN_API)
        log(f"Knowledge base connection ready → {kb_mcp_url}")

    # ── 5. Prompt agent with the mode's tools ────────────────────────────────
    endpoint = f"https://{args.foundry_resource}.services.ai.azure.com/api/projects/{args.project}"
    project = AIProjectClient(endpoint=endpoint, credential=cred)

    if not args.replace:
        try:
            existing = list(project.agents.list_versions(args.agent_name))
        except Exception:
            existing = []
        if existing:
            ver = getattr(existing[-1], "version", "?")
            log(f"Agent '{args.agent_name}' already exists (version {ver}). "
                f"Use --replace to add a new version. Skipping creation.")
            _maybe_smoke(args, project)
            _summary(args, endpoint, ver)
            return

    data_agent_tool = FabricIQPreviewTool(project_connection_id=agent_conn_id, server_label="oee-data-agent",
                                          require_approval="never")
    if args.knowledge == "knowledge-base":
        tools = [
            MCPTool(server_label="oee-knowledge", server_url=kb_mcp_url, require_approval="never",
                    allowed_tools=["knowledge_base_retrieve"], project_connection_id=kb_conn_id),
            data_agent_tool,
        ]
        description = ("Multi-persona OEE Factory IQ assistant: a Foundry IQ knowledge base over the plant ontology "
                       "and the SOP corpus, plus the OEE data agent through Fabric IQ.")
    else:
        tools = [
            AzureAISearchTool(azure_ai_search=AzureAISearchToolResource(indexes=[
                AISearchIndexResource(
                    project_connection_id=search_conn_id,
                    index_name=args.search_index,
                    query_type=getattr(AzureAISearchQueryType, QUERY_TYPES[args.search_query_type]),
                    top_k=args.search_top_k,
                )
            ])),
            FabricIQPreviewTool(project_connection_id=ontology_conn_id, server_label="oee-ontology",
                                require_approval="never"),
            data_agent_tool,
        ]
        description = ("Multi-persona OEE Factory IQ assistant: the plant ontology and the OEE data agent through "
                       "Fabric IQ, plus the SOP corpus in Azure AI Search.")

    step(f"Creating prompt agent: {args.agent_name} (model: {args.model}, knowledge: {args.knowledge})")
    agent = project.agents.create_version(
        agent_name=args.agent_name,
        definition=PromptAgentDefinition(model=args.model, instructions=instructions, tools=tools),
        description=description,
    )
    log(f"Created agent '{agent.name}' version {agent.version}")
    _maybe_smoke(args, project)
    _summary(args, endpoint, agent.version)


def _maybe_smoke(args, project):
    if not args.smoke:
        return
    step("Smoke test")
    background = args.model.startswith(BACKGROUND_MODELS)
    with project.get_openai_client(agent_name=args.agent_name) as oa:
        for label, question in SMOKE_QUESTIONS[args.knowledge]:
            try:
                started = time.time()
                resp = oa.responses.create(input=question, background=background)
                while getattr(resp, "status", "completed") in ("queued", "in_progress") and time.time() - started < 600:
                    time.sleep(5)
                    resp = oa.responses.retrieve(resp.id)
                tools = []
                for item in getattr(resp, "output", None) or []:
                    kind = getattr(item, "type", "")
                    if kind.endswith("_call") and kind not in ("function_call",):
                        tools.append(getattr(item, "server_label", None) or kind.replace("_call", ""))
                print(f"\n   [{label}] tools: {', '.join(dict.fromkeys(tools)) or 'none'} "
                      f"({getattr(resp, 'status', '?')}, {time.time() - started:.0f}s)", flush=True)
                print("   " + (resp.output_text or "").strip()[:900].replace("\n", "\n   "), flush=True)
            except Exception as e:  # noqa: BLE001
                log(f"[{label}] smoke query failed: {e}")


def _summary(args, endpoint, version):
    step("Done")
    log(f"Project endpoint: {endpoint}")
    log(f"Agent:            {args.agent_name} (version {version}), model {args.model}")
    if args.knowledge == "knowledge-base":
        log(f"Knowledge base:   {args.knowledge_base_name} ({SOP_KNOWLEDGE_SOURCE} + {ONTOLOGY_KNOWLEDGE_SOURCE}) "
            f"via connection {args.knowledge_base_connection_name}")
        log(f"Fabric IQ tool:   oee-data-agent via {args.data_agent_connection_name}")
    else:
        log(f"AI Search tool:   index '{args.search_index}' via connection {args.search_connection_name}")
        log(f"Fabric IQ tools:  oee-ontology via {args.ontology_connection_name}, "
            f"oee-data-agent via {args.data_agent_connection_name}")
    log("Open it in the Foundry portal: https://ai.azure.com \u2192 project \u2192 Agents")


if __name__ == "__main__":
    main()
