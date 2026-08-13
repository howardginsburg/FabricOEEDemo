#!/usr/bin/env python3
# =============================================================================
# 8-setup-foundry-agent.py — Create the OEE Factory IQ prompt agent and wire
# it to BOTH knowledge sources: the Azure AI Search SOP index and the published
# Fabric Data Agent.
#
# This automates what used to be manual Foundry-portal steps. It:
#   1. Creates a project connection to Azure AI Search
#      (category CognitiveSearch, ApiKey auth).
#   2. Creates a project connection to the Fabric Data Agent
#      (category CustomKeys: workspace-id + artifact-id,
#       metadata.type = fabric_dataagent_preview).
#   3. Creates a Foundry prompt agent (PromptAgentDefinition) whose tools are
#      AzureAISearchTool (over the oee-sops index) and MicrosoftFabricPreviewTool
#      (over the data-agent connection), using agent/system-prompt.md.
#
# Run AFTER scripts/4-setup-foundry.sh and scripts/5-setup-aisearch.sh, and after
# the Fabric Data Agent has been PUBLISHED in Fabric (README step 3).
#
# Prerequisites:
#   - Azure CLI logged in (`az login`) — used for DefaultAzureCredential and to
#     resolve the subscription id.
#   - Python packages:  pip install azure-ai-projects azure-identity openai httpx
#     (azure-ai-projects 2.x provides the prompt-agent + tool models used here;
#      httpx is a transitive import; openai is used only by --smoke. Some
#      pre-release azure-ai-projects builds do not pull httpx automatically.)
#
# Field notes baked in:
#   - The Foundry connections ARM endpoint intermittently returns HTTP 500
#     (ServiceError). Connection PUTs are retried.
#   - The Fabric tool uses identity passthrough (On-Behalf-Of): the caller (and
#     any end user) must have READ on the data agent and its data sources.
#
# Usage:
#   python scripts/8-setup-foundry-agent.py \
#     --foundry-resource <FOUNDRY_RESOURCE_NAME> \
#     --project          <FOUNDRY_PROJECT_NAME> \
#     --resource-group   <RG> \
#     --search-service   <SEARCH_SERVICE_NAME> \
#     --fabric-workspace-id <WORKSPACE_GUID> \
#     --fabric-artifact-id  <DATA_AGENT_GUID>
#
# The Fabric workspace/artifact GUIDs come from the published data agent URL:
#   https://<env>.fabric.microsoft.com/groups/<workspace-id>/aiskills/<artifact-id>
# =============================================================================
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

ARM = "https://management.azure.com"
CONN_API = "2025-04-01-preview"
SEARCH_KEYS_API = "2023-11-01"

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_SYS_PROMPT = os.path.join(REPO_ROOT, "agent", "system-prompt.md")

QUERY_TYPES = {
    "simple": "SIMPLE",
    "semantic": "SEMANTIC",
    "vector": "VECTOR",
    "vector_simple_hybrid": "VECTOR_SIMPLE_HYBRID",
    "vector_semantic_hybrid": "VECTOR_SEMANTIC_HYBRID",
}


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


def arm_request(method, url, token, body=None):
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


def put_connection_with_retry(token, conn_id, properties, attempts=10, delay=20):
    """PUT a project connection, retrying the transient account-RP 500s."""
    url = f"{ARM}{conn_id}?api-version={CONN_API}"
    body = {"properties": properties}
    for i in range(1, attempts + 1):
        status, resp = arm_request("PUT", url, token, body)
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
    p.add_argument("--fabric-workspace-id", required=True)
    p.add_argument("--fabric-artifact-id", required=True)
    p.add_argument("--model", default="gpt-4o", help="Chat deployment name (default: gpt-4o).")
    p.add_argument("--agent-name", default="oee-factory-iq")
    p.add_argument("--system-prompt", default=DEFAULT_SYS_PROMPT)
    p.add_argument("--search-connection-name", default="aisearch-sops")
    p.add_argument("--fabric-connection-name", default="fabric-oee-dataagent")
    p.add_argument("--replace", action="store_true",
                   help="Create a new agent version even if the agent already exists.")
    p.add_argument("--smoke", action="store_true", help="Run a quick SOP + live-telemetry smoke test.")
    args = p.parse_args()

    try:
        from azure.identity import DefaultAzureCredential
        from azure.ai.projects import AIProjectClient
        from azure.ai.projects.models import (
            PromptAgentDefinition,
            AzureAISearchTool, AzureAISearchToolResource, AISearchIndexResource,
            AzureAISearchQueryType,
            MicrosoftFabricPreviewTool, FabricDataAgentToolParameters, ToolProjectConnection,
        )
    except ImportError as e:
        die(f"Missing SDK ({e}). Install with: pip install azure-ai-projects azure-identity openai httpx")

    sub = args.subscription or az_subscription_id()
    if not sub:
        die("Could not resolve a subscription id. Run 'az login' or pass --subscription.")
    search_rg = args.search_resource_group or args.resource_group

    if not os.path.isfile(args.system_prompt):
        die(f"System prompt not found: {args.system_prompt}")
    with open(args.system_prompt, encoding="utf-8") as f:
        instructions = f.read()

    cred = DefaultAzureCredential(exclude_interactive_browser_credential=True)
    mgmt_token = cred.get_token(f"{ARM}/.default").token

    conn_base = (
        f"/subscriptions/{sub}/resourceGroups/{args.resource_group}"
        f"/providers/Microsoft.CognitiveServices/accounts/{args.foundry_resource}"
        f"/projects/{args.project}/connections"
    )
    search_conn_id = f"{conn_base}/{args.search_connection_name}"
    fabric_conn_id = f"{conn_base}/{args.fabric_connection_name}"

    # ── 1. Search admin key (server-side only; never printed) ────────────────
    step(f"Resolving admin key for search service '{args.search_service}'")
    keys_url = (
        f"{ARM}/subscriptions/{sub}/resourceGroups/{search_rg}"
        f"/providers/Microsoft.Search/searchServices/{args.search_service}"
        f"/listAdminKeys?api-version={SEARCH_KEYS_API}"
    )
    kstatus, kresp = arm_request("POST", keys_url, mgmt_token)
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
    })
    log("AI Search connection ready")

    # ── 3. Fabric Data Agent connection (CustomKeys) ─────────────────────────
    step(f"Connection: {args.fabric_connection_name} (Fabric Data Agent)")
    put_connection_with_retry(mgmt_token, fabric_conn_id, {
        "authType": "CustomKeys",
        "category": "CustomKeys",
        "target": "-",
        "isSharedToAll": True,
        "credentials": {"keys": {
            "workspace-id": args.fabric_workspace_id,
            "artifact-id": args.fabric_artifact_id,
        }},
        "metadata": {"type": "fabric_dataagent_preview"},
    })
    log("Fabric connection ready")

    # ── 4. Prompt agent with both tools ──────────────────────────────────────
    endpoint = f"https://{args.foundry_resource}.services.ai.azure.com/api/projects/{args.project}"
    project = AIProjectClient(endpoint=endpoint, credential=cred)

    if not args.replace:
        try:
            existing = list(project.agents.list_versions(args.agent_name))
        except Exception:
            existing = []
        if existing:
            latest = existing[-1]
            ver = getattr(latest, "version", "?")
            log(f"Agent '{args.agent_name}' already exists (version {ver}). "
                f"Use --replace to add a new version. Skipping creation.")
            _maybe_smoke(args, project)
            _summary(args, search_conn_id, fabric_conn_id, endpoint, ver)
            return

    step(f"Creating prompt agent: {args.agent_name} (model: {args.model})")
    definition = PromptAgentDefinition(
        model=args.model,
        instructions=instructions,
        temperature=0.2,
        top_p=1.0,
        tools=[
            AzureAISearchTool(azure_ai_search=AzureAISearchToolResource(indexes=[
                AISearchIndexResource(
                    project_connection_id=search_conn_id,
                    index_name=args.search_index,
                    query_type=getattr(AzureAISearchQueryType, QUERY_TYPES[args.search_query_type]),
                    top_k=args.search_top_k,
                )
            ])),
            MicrosoftFabricPreviewTool(fabric_dataagent_preview=FabricDataAgentToolParameters(
                project_connections=[ToolProjectConnection(project_connection_id=fabric_conn_id)]
            )),
        ],
    )
    agent = project.agents.create_version(
        agent_name=args.agent_name,
        definition=definition,
        description=(
            "Multi-persona OEE Factory IQ assistant. Routes between the Fabric Data Agent "
            "(live telemetry) and Azure AI Search (SOP corpus)."
        ),
    )
    log(f"Created agent '{agent.name}' version {agent.version}")
    _maybe_smoke(args, project)
    _summary(args, search_conn_id, fabric_conn_id, endpoint, agent.version)


def _maybe_smoke(args, project):
    if not args.smoke:
        return
    step("Smoke test")
    oa = project.get_openai_client()
    for label, q in [
        ("AI Search (SOP)", "What are the corrective actions for a Nozzle-Clog fault on an SMT-Placement station? Cite the SOP."),
        ("Fabric (live)", "Using the Fabric data agent, how many machine events are in the system right now?"),
    ]:
        try:
            resp = oa.responses.create(
                input=q,
                extra_body={"agent_reference": {"name": args.agent_name, "type": "agent_reference"}},
            )
            print(f"\n   [{label}]\n   {resp.output_text.strip()[:600]}", flush=True)
        except Exception as e:  # noqa: BLE001
            log(f"[{label}] smoke query failed: {e}")


def _summary(args, search_conn_id, fabric_conn_id, endpoint, version):
    step("Done")
    log(f"Project endpoint: {endpoint}")
    log(f"Agent:            {args.agent_name} (version {version}), model {args.model}")
    log(f"AI Search tool:   index '{args.search_index}' via connection {args.search_connection_name}")
    log(f"Fabric tool:      data agent via connection {args.fabric_connection_name}")
    log("Open it in the Foundry portal: https://ai.azure.com \u2192 project \u2192 Agents")


if __name__ == "__main__":
    main()
