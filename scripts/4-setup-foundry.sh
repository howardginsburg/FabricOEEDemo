#!/usr/bin/env bash
# =============================================================================
# 4-setup-foundry.sh — Provision the Microsoft Foundry resource, project, and
# chat + embedding model deployments.
#
# This is the FIRST script in the Fabric IQ + AI Search + Foundry agent chain.
# It must run before scripts/5-setup-aisearch.sh because the embedding-model
# deployment that AI Search uses is what this script provisions.
#
# Aligned with the current Microsoft Foundry resource model (AIServices kind
# with `--allow-project-management`), per:
#   https://learn.microsoft.com/azure/foundry/tutorials/quickstart-create-foundry-resources?tabs=azurecli
#
# IMPORTANT — Azure CLI version: `--allow-project-management` and the
# `az cognitiveservices account project` subcommands require Azure CLI 2.67.0
# or later. Older builds (e.g. 2.58) fail with "unrecognized arguments".
# Upgrade with `az upgrade` (or the MSI) before running this script.
#
# IMPORTANT — model SKU / quota (consumption, no PTU): deployments default to
# `GlobalStandard` (pay-as-you-go, token-based — NOT Provisioned/PTU). Some
# subscriptions have no consumption quota for `gpt-4.1` in a given region (only
# Batch); if the quota preflight below reports 0, either request quota or pass
# `--chat-model gpt-4o --chat-model-version 2024-11-20`, which is widely
# available on GlobalStandard.
#
# What is automated:
#   • Creates the resource group (if missing).
#   • Creates the Foundry resource (`az cognitiveservices account create
#     --kind AIServices --sku s0 --allow-project-management`).
#   • Assigns a custom subdomain — required for the OpenAI endpoint URL.
#   • Creates the Foundry project (`az cognitiveservices account project create`).
#   • Deploys the chat model       (default: gpt-4.1).
#   • Deploys the embedding model  (default: text-embedding-3-large).
#   • Prints the OpenAI endpoint, project ID, and all values needed for
#     scripts/5-setup-aisearch.sh and the README agent setup section.
#
# What stays manual today (Foundry portal, after script 5):
#   • Register both knowledge sources and create the prompt agent — covered in README.md.
#
# Prerequisites:
#   - Azure CLI (az) 2.67.0 or later with an active login (`az login`).
#   - jq, curl.
#
# Usage:
#   bash scripts/4-setup-foundry.sh \
#     --foundry-resource <FOUNDRY_RESOURCE_NAME> \
#     --project          <FOUNDRY_PROJECT_NAME> \
#     --resource-group   <RG> \
#     --location         <LOCATION>
#
# Optional flags:
#   --custom-domain <NAME>          Custom subdomain (must be globally unique;
#                                    default: same as --foundry-resource).
#   --chat-model <NAME>             Default: gpt-4.1.
#   --chat-model-version <VER>      Default: 2025-04-14.
#   --chat-deployment <NAME>        Default: same as --chat-model.
#   --chat-capacity <N>             TPM in thousands (default: 50).
#   --chat-sku <NAME>               Deployment SKU (default: GlobalStandard —
#                                    consumption/pay-as-you-go, no PTU).
#   --embedding-model <NAME>        Default: text-embedding-3-large.
#   --embedding-model-version <VER> Default: 1.
#   --embedding-deployment <NAME>   Default: same as --embedding-model.
#   --embedding-capacity <N>        TPM in thousands (default: 50).
#   --embedding-sku <NAME>          Deployment SKU (default: GlobalStandard).
#   --search-service <NAME>         If scripts/5-setup-aisearch.sh has already
#                                    run, supply the AI Search service name so
#                                    this script can pre-resolve endpoint + key.
#   --search-index <NAME>           Default: oee-sops.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_DIR="$REPO_ROOT/agent"

FOUNDRY_RESOURCE=""
PROJECT=""
RESOURCE_GROUP=""
LOCATION=""
CUSTOM_DOMAIN=""

CHAT_MODEL="gpt-4.1"
CHAT_MODEL_VERSION="2025-04-14"
CHAT_DEPLOYMENT=""
CHAT_CAPACITY="50"
CHAT_SKU="GlobalStandard"

EMBED_MODEL="text-embedding-3-large"
EMBED_MODEL_VERSION="1"
EMBED_DEPLOYMENT=""
EMBED_CAPACITY="50"
EMBED_SKU="GlobalStandard"

# Minimum Azure CLI for --allow-project-management + project subcommands
MIN_AZ_VERSION="2.67.0"

SEARCH_SERVICE=""
SEARCH_INDEX="oee-sops"

if [[ -t 1 ]]; then
  GREEN='\033[92m'; YELLOW='\033[93m'; RED='\033[91m'; CYAN='\033[96m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; CYAN=''; RESET=''
fi
ok()     { printf "   ${GREEN}✓${RESET} %s\n" "$*"; }
warn()   { printf "   ${YELLOW}!${RESET} %s\n" "$*"; }
die()    { printf "   ${RED}✗ ERROR:${RESET} %s\n" "$*" >&2; exit 1; }
step()   { printf "\n── %s\n" "$*"; }
manual() { printf "   ${CYAN}→${RESET} %s\n" "$*"; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --foundry-resource)        FOUNDRY_RESOURCE="$2"; shift 2 ;;
    --workspace-name)          FOUNDRY_RESOURCE="$2"; shift 2 ;;  # back-compat alias
    --project)                 PROJECT="$2"; shift 2 ;;
    --resource-group)          RESOURCE_GROUP="$2"; shift 2 ;;
    --location)                LOCATION="$2"; shift 2 ;;
    --custom-domain)           CUSTOM_DOMAIN="$2"; shift 2 ;;
    --chat-model)              CHAT_MODEL="$2"; shift 2 ;;
    --chat-model-version)      CHAT_MODEL_VERSION="$2"; shift 2 ;;
    --chat-deployment)         CHAT_DEPLOYMENT="$2"; shift 2 ;;
    --chat-capacity)           CHAT_CAPACITY="$2"; shift 2 ;;
    --chat-sku)                CHAT_SKU="$2"; shift 2 ;;
    --embedding-model)         EMBED_MODEL="$2"; shift 2 ;;
    --embedding-model-version) EMBED_MODEL_VERSION="$2"; shift 2 ;;
    --embedding-deployment)    EMBED_DEPLOYMENT="$2"; shift 2 ;;
    --embedding-capacity)      EMBED_CAPACITY="$2"; shift 2 ;;
    --embedding-sku)           EMBED_SKU="$2"; shift 2 ;;
    --search-service)          SEARCH_SERVICE="$2"; shift 2 ;;
    --search-index)            SEARCH_INDEX="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,/^# =\{20,\}$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -z "$FOUNDRY_RESOURCE" ]] && die "--foundry-resource is required"
[[ -z "$PROJECT"          ]] && die "--project is required (Foundry project name)"
[[ -z "$RESOURCE_GROUP"   ]] && die "--resource-group is required"
[[ -z "$LOCATION"         ]] && die "--location is required"

[[ -z "$CUSTOM_DOMAIN"    ]] && CUSTOM_DOMAIN="$FOUNDRY_RESOURCE"
[[ -z "$CHAT_DEPLOYMENT"  ]] && CHAT_DEPLOYMENT="$CHAT_MODEL"
[[ -z "$EMBED_DEPLOYMENT" ]] && EMBED_DEPLOYMENT="$EMBED_MODEL"

for cmd in az jq; do
  command -v "$cmd" &>/dev/null || die "'$cmd' is required but not installed."
done

# ── Azure CLI version guard ───────────────────────────────────────────────────
# --allow-project-management and `az cognitiveservices account project` need 2.67+.
ver_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }
AZ_VER="$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo 0)"
if ! ver_ge "$AZ_VER" "$MIN_AZ_VERSION"; then
  die "Azure CLI $AZ_VER is too old — this script needs >= $MIN_AZ_VERSION for '--allow-project-management' and 'az cognitiveservices account project'. Upgrade with 'az upgrade' (or reinstall the MSI) and retry."
fi

# ── 0. Subscription ──────────────────────────────────────────────────────────
step "Verifying Azure login"
SUB_ID=$(az account show --query id -o tsv 2>/dev/null || true)
[[ -z "$SUB_ID" ]] && die "Not logged in. Run 'az login' first."
ok "Subscription: $SUB_ID"

# ── 1. Resource group ────────────────────────────────────────────────────────
step "Resource group: $RESOURCE_GROUP"
if az group show -n "$RESOURCE_GROUP" &>/dev/null; then
  ok "Already exists"
else
  az group create -n "$RESOURCE_GROUP" -l "$LOCATION" -o none
  ok "Created"
fi

# ── 2. Foundry resource (AIServices) ─────────────────────────────────────────
step "Foundry resource: $FOUNDRY_RESOURCE"
if az cognitiveservices account show -n "$FOUNDRY_RESOURCE" -g "$RESOURCE_GROUP" &>/dev/null; then
  ok "Already exists"
else
  az cognitiveservices account create \
    --name "$FOUNDRY_RESOURCE" \
    --resource-group "$RESOURCE_GROUP" \
    --kind AIServices \
    --sku s0 \
    --location "$LOCATION" \
    --custom-domain "$CUSTOM_DOMAIN" \
    --allow-project-management true \
    --yes \
    -o none
  ok "Created"
fi

# Ensure custom domain is set (idempotent on existing resource)
CURRENT_DOMAIN=$(az cognitiveservices account show \
  -n "$FOUNDRY_RESOURCE" -g "$RESOURCE_GROUP" \
  --query properties.customSubDomainName -o tsv 2>/dev/null || echo "")
if [[ -z "$CURRENT_DOMAIN" ]]; then
  step "Assigning custom domain: $CUSTOM_DOMAIN"
  az cognitiveservices account update \
    --name "$FOUNDRY_RESOURCE" \
    --resource-group "$RESOURCE_GROUP" \
    --custom-domain "$CUSTOM_DOMAIN" \
    -o none
  ok "Custom domain set"
else
  ok "Custom domain: $CURRENT_DOMAIN"
  CUSTOM_DOMAIN="$CURRENT_DOMAIN"
fi

OPENAI_ENDPOINT="https://${CUSTOM_DOMAIN}.openai.azure.com"
SERVICES_ENDPOINT=$(az cognitiveservices account show \
  -n "$FOUNDRY_RESOURCE" -g "$RESOURCE_GROUP" \
  --query properties.endpoint -o tsv)

# ── 3. Foundry project ───────────────────────────────────────────────────────
step "Foundry project: $PROJECT"
if az cognitiveservices account project show \
     --name "$FOUNDRY_RESOURCE" \
     --resource-group "$RESOURCE_GROUP" \
     --project-name "$PROJECT" &>/dev/null; then
  ok "Already exists"
else
  az cognitiveservices account project create \
    --name "$FOUNDRY_RESOURCE" \
    --resource-group "$RESOURCE_GROUP" \
    --project-name "$PROJECT" \
    --location "$LOCATION" \
    -o none
  ok "Created"
fi

PROJECT_ID=$(az cognitiveservices account project show \
  --name "$FOUNDRY_RESOURCE" \
  --resource-group "$RESOURCE_GROUP" \
  --project-name "$PROJECT" \
  --query id -o tsv)

# ── 4. Deploy chat model ─────────────────────────────────────────────────────
# Quota preflight (consumption): warn early if the target model+SKU has no quota
# in this region so you can switch model/SKU instead of failing mid-deploy.
quota_for() { # <sku> <model>
  az cognitiveservices usage list -l "$LOCATION" -o json 2>/dev/null \
    | jq -r --arg n "OpenAI.$1.$2" \
        '[.[] | select(.name.value==$n)][0] | if . == null then "MISSING" else "\(.limit-.currentValue)/\(.limit)" end'
}
step "Quota preflight (region: $LOCATION)"
CHAT_QUOTA="$(quota_for "$CHAT_SKU" "$CHAT_MODEL")"
if [[ "$CHAT_QUOTA" == "MISSING" || "$CHAT_QUOTA" == 0/* ]]; then
  warn "No '$CHAT_SKU' consumption quota for '$CHAT_MODEL' in $LOCATION (available: $CHAT_QUOTA)."
  warn "  → Request quota, choose another region, or use a model that has quota, e.g.:"
  warn "      --chat-model gpt-4o --chat-model-version 2024-11-20   (GlobalStandard, widely available)"
else
  ok "Chat quota ($CHAT_SKU $CHAT_MODEL): $CHAT_QUOTA TPM (k) available"
fi

step "Chat model deployment: $CHAT_DEPLOYMENT ($CHAT_MODEL v$CHAT_MODEL_VERSION, $CHAT_SKU)"
if az cognitiveservices account deployment show \
     --name "$FOUNDRY_RESOURCE" \
     --resource-group "$RESOURCE_GROUP" \
     --deployment-name "$CHAT_DEPLOYMENT" &>/dev/null; then
  ok "Already exists"
else
  az cognitiveservices account deployment create \
    --name "$FOUNDRY_RESOURCE" \
    --resource-group "$RESOURCE_GROUP" \
    --deployment-name "$CHAT_DEPLOYMENT" \
    --model-name "$CHAT_MODEL" \
    --model-version "$CHAT_MODEL_VERSION" \
    --model-format OpenAI \
    --sku-name "$CHAT_SKU" \
    --sku-capacity "$CHAT_CAPACITY" \
    -o none
  ok "Created"
fi

# ── 5. Deploy embedding model ────────────────────────────────────────────────
EMBED_QUOTA="$(quota_for "$EMBED_SKU" "$EMBED_MODEL")"
if [[ "$EMBED_QUOTA" == "MISSING" || "$EMBED_QUOTA" == 0/* ]]; then
  warn "No '$EMBED_SKU' consumption quota for '$EMBED_MODEL' in $LOCATION (available: $EMBED_QUOTA). Request quota or pick another region/SKU."
else
  ok "Embedding quota ($EMBED_SKU $EMBED_MODEL): $EMBED_QUOTA TPM (k) available"
fi

step "Embedding model deployment: $EMBED_DEPLOYMENT ($EMBED_MODEL v$EMBED_MODEL_VERSION, $EMBED_SKU)"
if az cognitiveservices account deployment show \
     --name "$FOUNDRY_RESOURCE" \
     --resource-group "$RESOURCE_GROUP" \
     --deployment-name "$EMBED_DEPLOYMENT" &>/dev/null; then
  ok "Already exists"
else
  az cognitiveservices account deployment create \
    --name "$FOUNDRY_RESOURCE" \
    --resource-group "$RESOURCE_GROUP" \
    --deployment-name "$EMBED_DEPLOYMENT" \
    --model-name "$EMBED_MODEL" \
    --model-version "$EMBED_MODEL_VERSION" \
    --model-format OpenAI \
    --sku-name "$EMBED_SKU" \
    --sku-capacity "$EMBED_CAPACITY" \
    -o none
  ok "Created"
fi

# ── 6. Resolve AI Search metadata (if it already exists) ─────────────────────
step "Resolving downstream connection metadata"

SEARCH_QUERY_KEY=""
SEARCH_ENDPOINT=""
if [[ -n "$SEARCH_SERVICE" ]]; then
  SEARCH_RG=$(az search service list --query "[?name=='$SEARCH_SERVICE'].resourceGroup | [0]" -o tsv 2>/dev/null || true)
  if [[ -n "$SEARCH_RG" && "$SEARCH_RG" != "null" ]]; then
    SEARCH_ENDPOINT="https://${SEARCH_SERVICE}.search.windows.net"
    SEARCH_QUERY_KEY=$(az search query-key list \
      --service-name "$SEARCH_SERVICE" -g "$SEARCH_RG" \
      --query "[0].key" -o tsv 2>/dev/null || true)
    ok "AI Search endpoint:  $SEARCH_ENDPOINT"
    ok "AI Search index:     $SEARCH_INDEX"
  else
    warn "AI Search '$SEARCH_SERVICE' not found yet — expected if scripts/5-setup-aisearch.sh has not run."
  fi
else
  warn "--search-service not provided. Run scripts/5-setup-aisearch.sh next, then collect its output for the README agent setup."
fi

# ── 7. Summary + next steps ──────────────────────────────────────────────────
step "Summary"

cat <<EOF

  Foundry resource:        $FOUNDRY_RESOURCE
  Project:                 $PROJECT
  Project ID:              $PROJECT_ID
  Resource group:          $RESOURCE_GROUP
  Location:                $LOCATION
  Custom domain:           $CUSTOM_DOMAIN

  AI Services endpoint:    $SERVICES_ENDPOINT
  OpenAI endpoint (AOAI):  $OPENAI_ENDPOINT
    → pass this URL to scripts/5-setup-aisearch.sh as --foundry-aoai-endpoint

  Chat deployment:         $CHAT_DEPLOYMENT  (model: $CHAT_MODEL, version: $CHAT_MODEL_VERSION)
  Embedding deployment:    $EMBED_DEPLOYMENT  (model: $EMBED_MODEL, version: $EMBED_MODEL_VERSION)

  Azure AI Search (KS #2):
    Endpoint:              ${SEARCH_ENDPOINT:-<run scripts/5-setup-aisearch.sh and use its output>}
    Index:                 $SEARCH_INDEX
    Query key:             ${SEARCH_QUERY_KEY:-<run scripts/5-setup-aisearch.sh and use its output>}

EOF

manual "Step A — Run scripts/5-setup-aisearch.sh next:"
manual "    bash scripts/5-setup-aisearch.sh \\"
manual "      --resource-group $RESOURCE_GROUP \\"
manual "      --location $LOCATION \\"
manual "      --search-service <UNIQUE_SEARCH_NAME> \\"
manual "      --foundry-aoai-endpoint $OPENAI_ENDPOINT"
manual ""
manual "Step B — Build the prompt agent + knowledge-source connections. This is now"
manual "scripted (formerly manual portal steps). After scripts/5-setup-aisearch.sh:"
manual "    python scripts/8-setup-foundry-agent.py \\"
manual "      --foundry-resource $FOUNDRY_RESOURCE \\"
manual "      --project $PROJECT \\"
manual "      --resource-group $RESOURCE_GROUP \\"
manual "      --search-service <UNIQUE_SEARCH_NAME> \\"
manual "      --fabric-workspace-id <WORKSPACE_GUID> \\"
manual "      --fabric-artifact-id <DATA_AGENT_GUID>"
manual ""
manual "  (workspace/artifact GUIDs come from the published Fabric data agent URL:"
manual "   https://<env>.fabric.microsoft.com/groups/<workspace-id>/aiskills/<artifact-id>)"
manual ""
manual "  Prefer the portal instead? https://ai.azure.com → project → Agents:"
manual "  attach an Azure AI Search knowledge source (index $SEARCH_INDEX, semantic"
manual "  config oee-semantic) and a Microsoft Fabric connection (workspace + artifact),"
manual "  then paste agent/system-prompt.md as the system message on model $CHAT_DEPLOYMENT."

step "Done"
ok "Foundry resource, project, and model deployments are ready."
ok "Next: bash scripts/5-setup-aisearch.sh ... --foundry-aoai-endpoint $OPENAI_ENDPOINT"
