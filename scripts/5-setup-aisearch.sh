#!/usr/bin/env bash
# =============================================================================
# 5-setup-aisearch.sh — Provision Azure AI Search + index the SOP PDFs
#
# Runs AFTER scripts/4-setup-foundry.sh because it relies on the Foundry AOAI
# endpoint (with text-embedding-3-large deployed) to generate the chunk
# vectors. See README.md for the end-to-end flow.
#
# Builds the static knowledge layer of the Fabric IQ + AI Search demo:
#   • Resource group (reuse or create)
#   • Storage account + blob container "oee-sops" (shared-key access DISABLED;
#     blobs are uploaded with your AAD identity via --auth-mode login)
#   • Upload of all knowledge/*.pdf (36 documents)
#   • Embedding model deployment on the Foundry AOAI resource
#     (default: text-embedding-3-large)
#   • Azure AI Search service (default SKU: Basic — semantic ranker + vector search are supported and the 15 GB/5-index limits are far above what the 36 SOPs need; override with --sku standard if you outgrow it) with a SYSTEM-ASSIGNED managed identity
#   • RBAC role assignments — NO SECRETS LEAVE AZURE:
#       - You (current user)  → Storage Blob Data Contributor on the storage account (lets the script upload PDFs)
#       - Search service MI   → Storage Blob Data Reader     on the storage account (lets the indexer read PDFs)
#       - Search service MI   → Cognitive Services OpenAI User on the Foundry resource (lets the vectorizer + embedding skill call AOAI)
#   • Search data source, index, skillset, indexer
#     - DocumentExtractionSkill → SplitSkill → AzureOpenAIEmbeddingSkill (MI auth)
#     - Data source binds to storage via ResourceId (no connection string)
#     - Index "oee-sops" with regex-extracted line_id and station_position
#   • Runs the indexer once, prints document count and a sample hybrid query
#
# The script is idempotent — re-running it skips resources that already exist
# and updates index/skillset/indexer definitions in place where supported.
#
# Prerequisites:
#   - Azure CLI (az) 2.x with an active login (`az login`)
#   - jq, curl
#   - A Foundry AOAI resource (endpoint + key) capable of hosting embedding
#     model "text-embedding-3-large" (or override with --embedding-model)
#   - The PDFs have been generated under knowledge/*.pdf
#     (run `scripts/build-sops.sh` if not)
#
# Usage:
#   bash scripts/5-setup-aisearch.sh \
#     --resource-group <RG> \
#     --location <LOCATION> \
#     --search-service <NAME> \
#     --foundry-aoai-endpoint https://<your-aoai>.openai.azure.com
#
# Arguments:
#   --resource-group         (required)
#   --location               (required) Azure region for storage + (default) search
#   --search-service         (required) Search service name (global-unique)
#   --foundry-aoai-endpoint  (required) https URL of the AOAI/Foundry endpoint
#   --storage-account        (optional) Storage acct name; auto-named if blank.
#                             Tip: pass an explicit name so re-runs reuse it
#                             instead of creating a new (orphan) account.
#   --container-name         (optional) Blob container (default: oee-sops)
#   --index-name             (optional) Search index (default: oee-sops)
#   --sku                    (optional) Search SKU (default: basic)
#   --search-location        (optional) Region for the AI Search service only.
#                             Defaults to --location. Use a different region when
#                             --location is capacity-constrained for Search
#                             ("InsufficientResourcesAvailable"); the service can
#                             read storage and call AOAI cross-region.
#   --embedding-model        (optional) Default text-embedding-3-large
#   --embedding-deployment   (optional) Deployment name (default same as model)
#
# Notes learned in the field:
#   • Storage is created with public network access ENABLED. If an Azure Policy
#     later disables it, AAD data-plane calls (uploads, the indexer) fail with a
#     403 that the CLI mis-reports as "blocked by network rules". Re-enable via
#     'az storage account update -n <acct> -g <rg> --public-network-access Enabled'.
#   • Role assignments use the ARM REST API when the 'az role assignment' command
#     is unavailable in your environment (some tenants return MissingSubscription).
#   • RBAC on the Search managed identity can take >30s to reach the storage data
#     plane; the indexer run is retried to absorb that propagation delay.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KNOWLEDGE_DIR="$REPO_ROOT/knowledge"

RESOURCE_GROUP=""
LOCATION=""
SEARCH_SERVICE=""
FOUNDRY_AOAI_ENDPOINT=""
STORAGE_ACCOUNT=""
CONTAINER_NAME="oee-sops"
INDEX_NAME="oee-sops"
SKU="basic"
SEARCH_LOCATION=""
EMBED_MODEL="text-embedding-3-large"
EMBED_DEPLOYMENT=""

SEARCH_API="2024-07-01"

if [[ -t 1 ]]; then
  GREEN='\033[92m'; YELLOW='\033[93m'; RED='\033[91m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; RESET=''
fi
ok()     { printf "   ${GREEN}✓${RESET} %s\n" "$*"; }
warn()   { printf "   ${YELLOW}!${RESET} %s\n" "$*"; }
die()    { printf "   ${RED}✗ ERROR:${RESET} %s\n" "$*" >&2; exit 1; }
step()   { printf "\n── %s\n" "$*"; }
manual() { printf "   ${YELLOW}→${RESET} %s\n" "$*"; }

# ── Args ──────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --resource-group)        RESOURCE_GROUP="$2"; shift 2 ;;
    --location)              LOCATION="$2"; shift 2 ;;
    --search-service)        SEARCH_SERVICE="$2"; shift 2 ;;
    --foundry-aoai-endpoint) FOUNDRY_AOAI_ENDPOINT="$2"; shift 2 ;;
    --storage-account)       STORAGE_ACCOUNT="$2"; shift 2 ;;
    --container-name)        CONTAINER_NAME="$2"; shift 2 ;;
    --index-name)            INDEX_NAME="$2"; shift 2 ;;
    --sku)                   SKU="$2"; shift 2 ;;
    --search-location)       SEARCH_LOCATION="$2"; shift 2 ;;
    --embedding-model)       EMBED_MODEL="$2"; shift 2 ;;
    --embedding-deployment)  EMBED_DEPLOYMENT="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,/^# =\{20,\}$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -z "$RESOURCE_GROUP"        ]] && die "--resource-group is required"
[[ -z "$LOCATION"              ]] && die "--location is required"
[[ -z "$SEARCH_SERVICE"        ]] && die "--search-service is required"
[[ -z "$FOUNDRY_AOAI_ENDPOINT" ]] && die "--foundry-aoai-endpoint is required"

[[ -z "$EMBED_DEPLOYMENT" ]] && EMBED_DEPLOYMENT="$EMBED_MODEL"
[[ -z "$SEARCH_LOCATION"  ]] && SEARCH_LOCATION="$LOCATION"

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in az jq curl; do
  command -v "$cmd" &>/dev/null || die "'$cmd' is required but not installed."
done

# ── Robust role assignment (ARM REST fallback) ───────────────────────────────
# Some environments/tenants return "MissingSubscription" from the
# 'az role assignment' command. This helper tries that command first and falls
# back to a direct ARM REST PUT, which works regardless of that CLI quirk.
_role_def_id() { # <role display name> -> built-in role definition GUID
  case "$1" in
    "Storage Blob Data Contributor")  echo "ba92f5b4-2d11-453d-a403-e96b0029c9fe" ;;
    "Storage Blob Data Reader")       echo "2a2b9908-6ea1-4ae2-8e65-a410df84e7d1" ;;
    "Cognitive Services OpenAI User") echo "5e0bd9bd-7b93-4f28-af87-19fc36ad61bd" ;;
    *) return 1 ;;
  esac
}
# ensure_role <principalId> <User|ServicePrincipal> <role name> <scope resourceId>
ensure_role() {
  local principal="$1" ptype="$2" role="$3" scope="$4"
  # Fast path: az role assignment (skip if it already exists)
  if az role assignment list --assignee "$principal" --scope "$scope" --role "$role" \
       --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
    return 0
  fi
  if az role assignment create --assignee-object-id "$principal" \
       --assignee-principal-type "$ptype" --role "$role" --scope "$scope" -o none 2>/dev/null; then
    return 0
  fi
  # Fallback: ARM REST PUT
  local sub defguid roledef guid
  sub=$(az account show --query id -o tsv)
  defguid=$(_role_def_id "$role") || { warn "unknown role '$role'"; return 1; }
  roledef="/subscriptions/${sub}/providers/Microsoft.Authorization/roleDefinitions/${defguid}"
  local existing
  existing=$(az rest --method get \
    --url "https://management.azure.com${scope}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&\$filter=principalId+eq+'${principal}'" \
    --query "value[?properties.roleDefinitionId=='${roledef}'] | [0].id" -o tsv 2>/dev/null || true)
  [[ -n "$existing" && "$existing" != "null" ]] && return 0
  guid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python -c "import uuid;print(uuid.uuid4())")
  az rest --method put \
    --url "https://management.azure.com${scope}/providers/Microsoft.Authorization/roleAssignments/${guid}?api-version=2022-04-01" \
    --headers "Content-Type=application/json" \
    --body "{\"properties\":{\"roleDefinitionId\":\"${roledef}\",\"principalId\":\"${principal}\",\"principalType\":\"${ptype}\"}}" \
    -o none
}

step "Checking knowledge/*.pdf"
shopt -s nullglob
PDFS=( "$KNOWLEDGE_DIR"/*.pdf )
shopt -u nullglob
if [[ ${#PDFS[@]} -eq 0 ]]; then
  die "No PDFs found under $KNOWLEDGE_DIR. Run scripts/build-sops.sh first."
fi
ok "Found ${#PDFS[@]} PDF(s) to upload"

# ── 0. Subscription / login ──────────────────────────────────────────────────
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
  ok "Created in $LOCATION"
fi

# ── 2. Storage account ───────────────────────────────────────────────────────
if [[ -z "$STORAGE_ACCOUNT" ]]; then
  STORAGE_ACCOUNT="oeesops$(echo "$RESOURCE_GROUP" | tr -dc 'a-z0-9' | cut -c1-12)$(date +%s | tail -c 4)"
  STORAGE_ACCOUNT="${STORAGE_ACCOUNT:0:24}"
fi

step "Storage account: $STORAGE_ACCOUNT"
if az storage account show -n "$STORAGE_ACCOUNT" -g "$RESOURCE_GROUP" &>/dev/null; then
  ok "Already exists"
else
  az storage account create \
    -n "$STORAGE_ACCOUNT" -g "$RESOURCE_GROUP" -l "$LOCATION" \
    --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --public-network-access Enabled \
    --allow-shared-key-access false -o none
  ok "Created (shared key auth disabled; public network access enabled)"
fi

# Reconcile: an Azure Policy may disable public network access after creation,
# which breaks AAD uploads and the indexer (403 mis-reported as "network rules").
PNA=$(az storage account show -n "$STORAGE_ACCOUNT" -g "$RESOURCE_GROUP" \
  --query publicNetworkAccess -o tsv 2>/dev/null || echo "")
if [[ "$PNA" == "Disabled" ]]; then
  warn "Public network access is Disabled — attempting to re-enable"
  if az storage account update -n "$STORAGE_ACCOUNT" -g "$RESOURCE_GROUP" \
       --public-network-access Enabled -o none 2>/dev/null; then
    ok "Public network access re-enabled"
  else
    warn "Could not re-enable public network access (Azure Policy may enforce Disabled)."
    warn "  Ask an admin to allow it, or add your client IP to the storage firewall, then re-run."
  fi
fi

STORAGE_ID=$(az storage account show -n "$STORAGE_ACCOUNT" -g "$RESOURCE_GROUP" --query id -o tsv)

# Grant the current user Storage Blob Data Contributor so we can upload via --auth-mode login
step "Granting current user Storage Blob Data Contributor on $STORAGE_ACCOUNT"
CURRENT_USER_OID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
if [[ -z "$CURRENT_USER_OID" ]]; then
  warn "Could not resolve signed-in user object id — you may need to assign Storage Blob Data Contributor manually."
else
  if ensure_role "$CURRENT_USER_OID" User "Storage Blob Data Contributor" "$STORAGE_ID"; then
    ok "Role assigned (or already present) — sleeping 45s for AAD propagation"
    sleep 45
  else
    die "Failed to assign Storage Blob Data Contributor to the current user."
  fi
fi

# ── 3. Blob container ────────────────────────────────────────────────────────
step "Blob container: $CONTAINER_NAME"
if az storage container show \
  --name "$CONTAINER_NAME" --account-name "$STORAGE_ACCOUNT" --auth-mode login &>/dev/null; then
  ok "Already exists"
else
  az storage container create \
    --name "$CONTAINER_NAME" --account-name "$STORAGE_ACCOUNT" --auth-mode login -o none
  ok "Created"
fi

# ── 4. Upload PDFs (with blob metadata derived from filename) ────────────────
# Files like 'Line-D_05_Curing-Oven_SOP.pdf' get blob metadata
#   line_id=Line-D, station_position=05
# Cross-cutting docs (no Line-X_NN_ prefix) are uploaded without those keys,
# leaving the corresponding index fields null.
step "Uploading ${#PDFS[@]} PDF(s) with metadata"
for pdf in "${PDFS[@]}"; do
  fname=$(basename "$pdf")
  md_args=()
  if [[ "$fname" =~ ^(Line-[A-E])_([0-9]+)_ ]]; then
    md_args=(--metadata "line_id=${BASH_REMATCH[1]}" "station_position=${BASH_REMATCH[2]}")
  fi
  az storage blob upload \
    --container-name "$CONTAINER_NAME" \
    --account-name "$STORAGE_ACCOUNT" \
    --auth-mode login \
    --file "$pdf" \
    --name "$fname" \
    --content-type "application/pdf" \
    --overwrite true \
    "${md_args[@]}" \
    -o none
done
UPLOADED=$(az storage blob list \
  --container-name "$CONTAINER_NAME" \
  --account-name "$STORAGE_ACCOUNT" \
  --auth-mode login \
  --query "length([?ends_with(name,'.pdf')])" -o tsv)
ok "$UPLOADED PDF(s) in container"

# ── 5. AOAI embedding deployment ─────────────────────────────────────────────
step "Embedding model: $EMBED_MODEL (deployment: $EMBED_DEPLOYMENT)"

AOAI_HOST="${FOUNDRY_AOAI_ENDPOINT#https://}"
AOAI_HOST="${AOAI_HOST%%/*}"
AOAI_NAME="${AOAI_HOST%%.*}"

AOAI_RG=$(az cognitiveservices account list \
  --query "[?name=='$AOAI_NAME'].resourceGroup | [0]" -o tsv 2>/dev/null || true)

if [[ -z "$AOAI_RG" || "$AOAI_RG" == "null" ]]; then
  die "Could not locate Foundry/AOAI resource '$AOAI_NAME'. Run scripts/4-setup-foundry.sh first or pass the correct --foundry-aoai-endpoint."
fi

AOAI_ID=$(az cognitiveservices account show -n "$AOAI_NAME" -g "$AOAI_RG" --query id -o tsv)

if az cognitiveservices account deployment show \
     -n "$AOAI_NAME" -g "$AOAI_RG" --deployment-name "$EMBED_DEPLOYMENT" &>/dev/null; then
  ok "Deployment '$EMBED_DEPLOYMENT' already exists"
else
  az cognitiveservices account deployment create \
    -n "$AOAI_NAME" -g "$AOAI_RG" \
    --deployment-name "$EMBED_DEPLOYMENT" \
    --model-name "$EMBED_MODEL" \
    --model-version "1" \
    --model-format "OpenAI" \
    --sku-capacity 50 --sku-name "GlobalStandard" -o none
  ok "Deployment created"
fi

# ── 6. Search service ────────────────────────────────────────────────────────
step "AI Search service: $SEARCH_SERVICE (SKU: $SKU, region: $SEARCH_LOCATION)"
if az search service show -n "$SEARCH_SERVICE" -g "$RESOURCE_GROUP" &>/dev/null; then
  ok "Already exists"
else
  if ! az search service create \
    -n "$SEARCH_SERVICE" -g "$RESOURCE_GROUP" -l "$SEARCH_LOCATION" \
    --sku "$SKU" --partition-count 1 --replica-count 1 \
    --identity-type SystemAssigned \
    --auth-options aadOrApiKey \
    --aad-auth-failure-mode http403 -o none 2>/tmp/search_create_err; then
    ERR="$(cat /tmp/search_create_err 2>/dev/null)"
    if echo "$ERR" | grep -qi "InsufficientResourcesAvailable"; then
      die "Region '$SEARCH_LOCATION' is out of AI Search capacity. Re-run with --search-location <other region> (the service can read storage and call AOAI cross-region)."
    fi
    # 'az search service create' has been observed to crash with a Python import
    # deadlock (_ModuleLock('requests.models')) on some CLI builds. It is safe to
    # simply re-run this idempotent script; the service create will retry.
    die "AI Search service create failed: ${ERR:0:400}"
  fi
  ok "Created (system-assigned MI + Entra-or-key data-plane auth)"
fi

# Ensure auth-options is aadOrApiKey on existing services (idempotent)
CURRENT_AUTH=$(az search service show -n "$SEARCH_SERVICE" -g "$RESOURCE_GROUP" \
  --query "authOptions" -o json 2>/dev/null || echo "{}")
if ! echo "$CURRENT_AUTH" | grep -q "aadOrApiKey"; then
  step "Enabling Entra (RBAC) data-plane auth on existing service"
  az search service update -n "$SEARCH_SERVICE" -g "$RESOURCE_GROUP" \
    --auth-options aadOrApiKey \
    --aad-auth-failure-mode http403 -o none
  ok "Switched authOptions to aadOrApiKey"
fi

# Ensure system-assigned MI is enabled (idempotent for existing services)
SEARCH_MI_OID=$(az search service show -n "$SEARCH_SERVICE" -g "$RESOURCE_GROUP" \
  --query identity.principalId -o tsv 2>/dev/null || true)
if [[ -z "$SEARCH_MI_OID" || "$SEARCH_MI_OID" == "null" ]]; then
  az search service update -n "$SEARCH_SERVICE" -g "$RESOURCE_GROUP" \
    --identity-type SystemAssigned -o none
  SEARCH_MI_OID=$(az search service show -n "$SEARCH_SERVICE" -g "$RESOURCE_GROUP" \
    --query identity.principalId -o tsv)
  ok "Enabled system-assigned identity on existing service"
fi
ok "Search managed identity principalId: $SEARCH_MI_OID"

# Grant Search MI the data-plane roles it needs on storage + Foundry
step "Assigning RBAC roles to Search managed identity"
for role_scope in \
  "Storage Blob Data Reader|$STORAGE_ID" \
  "Cognitive Services OpenAI User|$AOAI_ID"; do
  ROLE="${role_scope%%|*}"
  SCOPE="${role_scope##*|}"
  if ensure_role "$SEARCH_MI_OID" ServicePrincipal "$ROLE" "$SCOPE"; then
    ok "$ROLE assigned (or already present) on $(basename "$SCOPE")"
  else
    die "$ROLE assignment failed on $(basename "$SCOPE")"
  fi
done
ok "Sleeping 60s for RBAC propagation"
sleep 60

SEARCH_ADMIN_KEY=$(az search admin-key show \
  --service-name "$SEARCH_SERVICE" -g "$RESOURCE_GROUP" \
  --query primaryKey -o tsv)
SEARCH_QUERY_KEY=$(az search query-key list \
  --service-name "$SEARCH_SERVICE" -g "$RESOURCE_GROUP" \
  --query "[0].key" -o tsv)
SEARCH_ENDPOINT="https://${SEARCH_SERVICE}.search.windows.net"

search_put() {
  local path="$1" body="$2"
  curl -sS -X PUT \
    -H "Content-Type: application/json" \
    -H "api-key: $SEARCH_ADMIN_KEY" \
    --data "$body" \
    "${SEARCH_ENDPOINT}${path}?api-version=${SEARCH_API}" \
    -w "\n__HTTP_STATUS__:%{http_code}"
}

search_post() {
  local path="$1" body="$2"
  curl -sS -X POST \
    -H "Content-Type: application/json" \
    -H "api-key: $SEARCH_ADMIN_KEY" \
    --data "$body" \
    "${SEARCH_ENDPOINT}${path}?api-version=${SEARCH_API}"
}

check_http() {
  local resp="$1" name="$2"
  local code; code=$(echo "$resp" | sed -n 's/.*__HTTP_STATUS__://p')
  case "$code" in
    200|201|204) ok "$name (HTTP $code)" ;;
    *)
      err_body=$(echo "$resp" | sed '/__HTTP_STATUS__:/d')
      die "$name failed (HTTP $code): ${err_body:0:400}"
      ;;
  esac
}

# ── 7. Data source (managed-identity bound to storage) ────────────────────
step "Search data source"
DS_NAME="${INDEX_NAME}-ds"
DS_BODY=$(jq -n \
  --arg name "$DS_NAME" \
  --arg conn "ResourceId=${STORAGE_ID};" \
  --arg container "$CONTAINER_NAME" \
  '{
    name: $name,
    type: "azureblob",
    credentials: { connectionString: $conn },
    container: { name: $container }
  }')
check_http "$(search_put "/datasources/$DS_NAME" "$DS_BODY")" "Data source: $DS_NAME"

# ── 8. Index ─────────────────────────────────────────────────────────────────
step "Search index: $INDEX_NAME"
INDEX_BODY=$(jq -n --arg name "$INDEX_NAME" --arg deploy "$EMBED_DEPLOYMENT" \
  --arg aoai "$FOUNDRY_AOAI_ENDPOINT" '
{
  name: $name,
  fields: [
    { name: "id",                   type: "Edm.String", key: true, filterable: true, analyzer: "keyword" },
    { name: "parent_id",            type: "Edm.String", filterable: true },
    { name: "metadata_storage_name", type: "Edm.String", filterable: true, facetable: true, searchable: true },
    { name: "metadata_storage_path", type: "Edm.String", filterable: true },
    { name: "metadata_content_type", type: "Edm.String", filterable: true },
    { name: "line_id",              type: "Edm.String", filterable: true, facetable: true },
    { name: "station_position",     type: "Edm.String", filterable: true, facetable: true },
    { name: "chunk",                type: "Edm.String", searchable: true, analyzer: "en.microsoft" },
    {
      name: "vector",
      type: "Collection(Edm.Single)",
      searchable: true,
      dimensions: 3072,
      vectorSearchProfile: "oee-vec-profile"
    }
  ],
  vectorSearch: {
    algorithms: [
      { name: "oee-hnsw", kind: "hnsw",
        hnswParameters: { m: 4, efConstruction: 400, efSearch: 500, metric: "cosine" } }
    ],
    vectorizers: [
      {
        name: "oee-aoai-vectorizer",
        kind: "azureOpenAI",
        azureOpenAIParameters: {
          resourceUri: $aoai,
          deploymentId: $deploy,
          modelName: "text-embedding-3-large"
        }
      }
    ],
    profiles: [
      { name: "oee-vec-profile", algorithm: "oee-hnsw", vectorizer: "oee-aoai-vectorizer" }
    ]
  },
  semantic: {
    configurations: [
      {
        name: "oee-semantic",
        prioritizedFields: {
          titleField: { fieldName: "metadata_storage_name" },
          prioritizedContentFields: [ { fieldName: "chunk" } ],
          prioritizedKeywordsFields: [ { fieldName: "line_id" }, { fieldName: "station_position" } ]
        }
      }
    ]
  }
}')
check_http "$(search_put "/indexes/$INDEX_NAME" "$INDEX_BODY")" "Index: $INDEX_NAME"

# ── 9. Skillset ──────────────────────────────────────────────────────────────
step "Skillset"
SK_NAME="${INDEX_NAME}-skillset"
SK_BODY=$(jq -n --arg name "$SK_NAME" --arg deploy "$EMBED_DEPLOYMENT" \
  --arg aoai "$FOUNDRY_AOAI_ENDPOINT" '
{
  name: $name,
  description: "Extract → split → embed SOP PDFs",
  skills: [
    {
      "@odata.type": "#Microsoft.Skills.Util.DocumentExtractionSkill",
      name: "extract",
      context: "/document",
      parsingMode: "default",
      dataToExtract: "contentAndMetadata",
      inputs: [ { name: "file_data", source: "/document/file_data" } ],
      outputs: [
        { name: "content",         targetName: "extracted_content" },
        { name: "normalized_images", targetName: "normalized_images" }
      ]
    },
    {
      "@odata.type": "#Microsoft.Skills.Text.SplitSkill",
      name: "split",
      context: "/document",
      textSplitMode: "pages",
      maximumPageLength: 2000,
      pageOverlapLength: 200,
      inputs: [ { name: "text", source: "/document/extracted_content" } ],
      outputs: [ { name: "textItems", targetName: "pages" } ]
    },
    {
      "@odata.type": "#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill",
      name: "embed",
      context: "/document/pages/*",
      resourceUri: $aoai,
      deploymentId: $deploy,
      modelName: "text-embedding-3-large",
      inputs: [ { name: "text", source: "/document/pages/*" } ],
      outputs: [ { name: "embedding", targetName: "vector" } ]
    }
  ],
  indexProjections: {
    selectors: [
      {
        targetIndexName: "'$INDEX_NAME'",
        parentKeyFieldName: "parent_id",
        sourceContext: "/document/pages/*",
        mappings: [
          { name: "chunk",  source: "/document/pages/*" },
          { name: "vector", source: "/document/pages/*/vector" },
          { name: "metadata_storage_name", source: "/document/metadata_storage_name" },
          { name: "metadata_storage_path", source: "/document/metadata_storage_path" },
          { name: "metadata_content_type", source: "/document/metadata_content_type" },
          { name: "line_id",          source: "/document/line_id" },
          { name: "station_position", source: "/document/station_position" }
        ]
      }
    ],
    parameters: { projectionMode: "skipIndexingParentDocuments" }
  }
}')
check_http "$(search_put "/skillsets/$SK_NAME" "$SK_BODY")" "Skillset: $SK_NAME"

# ── 10. Indexer ──────────────────────────────────────────────────────────────
step "Indexer"
IDX_NAME="${INDEX_NAME}-indexer"
IDX_BODY=$(jq -n --arg name "$IDX_NAME" --arg ds "$DS_NAME" \
  --arg idx "$INDEX_NAME" --arg sk "$SK_NAME" '
{
  name: $name,
  dataSourceName: $ds,
  targetIndexName: $idx,
  skillsetName: $sk,
  parameters: {
    batchSize: 1,
    configuration: {
      dataToExtract: "contentAndMetadata",
      parsingMode: "default",
      allowSkillsetToReadFileData: true
    }
  },
  fieldMappings: [
    {
      sourceFieldName: "metadata_storage_path",
      targetFieldName: "id",
      mappingFunction: { name: "base64Encode" }
    }
  ]
}')
check_http "$(search_put "/indexers/$IDX_NAME" "$IDX_BODY")" "Indexer: $IDX_NAME"

# ── 11. Run the indexer ──────────────────────────────────────────────────────
# The Search MI's Storage Blob Data Reader role can take a couple of minutes to
# reach the storage data plane; the first run may 403. Retry a few times.
step "Running indexer (initial run)"
run_indexer() {
  curl -sS -X POST -H "api-key: $SEARCH_ADMIN_KEY" \
    "${SEARCH_ENDPOINT}/indexers/${IDX_NAME}/run?api-version=${SEARCH_API}" >/dev/null
}

INDEXER_OK=0
for attempt in 1 2 3 4; do
  run_indexer
  ok "Indexer run started (attempt $attempt)"
  elapsed=0
  while (( elapsed < 600 )); do
    status_json=$(curl -sS -H "api-key: $SEARCH_ADMIN_KEY" \
      "${SEARCH_ENDPOINT}/indexers/${IDX_NAME}/status?api-version=${SEARCH_API}")
    status=$(echo "$status_json" | jq -r '.lastResult.status // .status // "unknown"')
    case "$status" in
      success)         ok "Indexer succeeded"; INDEXER_OK=1; break ;;
      transientFailure|persistentFailure|error)
        err_msg=$(echo "$status_json" | jq -r '.lastResult.errorMessage // "see status"')
        warn "Indexer failed (attempt $attempt): $err_msg"
        break ;;
      inProgress|reset|*)
        printf "   indexer status: %s …\n" "$status"
        sleep 15; elapsed=$((elapsed + 15)) ;;
    esac
  done
  (( INDEXER_OK == 1 )) && break
  if (( attempt < 4 )); then
    warn "Retrying indexer in 45s (RBAC propagation to the storage data plane can lag)…"
    sleep 45
  fi
done
(( INDEXER_OK == 1 )) || die "Indexer did not succeed after retries. Confirm the Search MI has 'Storage Blob Data Reader' on $STORAGE_ACCOUNT and that storage public network access is Enabled, then re-run."

DOC_COUNT=$(curl -sS -H "api-key: $SEARCH_ADMIN_KEY" \
  "${SEARCH_ENDPOINT}/indexes/${INDEX_NAME}/stats?api-version=${SEARCH_API}" \
  | jq -r '.documentCount')
ok "Index '$INDEX_NAME' now has $DOC_COUNT chunks"

# ── 12. Smoke query ──────────────────────────────────────────────────────────
step "Smoke query"
SMOKE_BODY='{
  "search": "Curing-Oven temperature drift",
  "select": "metadata_storage_name,line_id,station_position,chunk",
  "queryType": "semantic",
  "semanticConfiguration": "oee-semantic",
  "top": 3
}'
search_post "/indexes/$INDEX_NAME/docs/search" "$SMOKE_BODY" \
  | jq '.value[] | { doc: .metadata_storage_name, line: .line_id, station: .station_position }'

# ── Summary ──────────────────────────────────────────────────────────────────
step "Done"
ok "Resource group:   $RESOURCE_GROUP"
ok "Storage account:  $STORAGE_ACCOUNT  (container: $CONTAINER_NAME)"
ok "Search service:   $SEARCH_SERVICE   (endpoint: $SEARCH_ENDPOINT)"
ok "Index:            $INDEX_NAME       (chunks: $DOC_COUNT)"

echo
manual "Next — create the prompt agent + knowledge-source connections (scripted):"
manual "    python scripts/8-setup-foundry-agent.py \\"
manual "      --foundry-resource <FOUNDRY_RESOURCE> --project <PROJECT> \\"
manual "      --resource-group $RESOURCE_GROUP \\"
manual "      --search-service $SEARCH_SERVICE --search-index $INDEX_NAME \\"
manual "      --fabric-workspace-id <WORKSPACE_GUID> --fabric-artifact-id <DATA_AGENT_GUID>"
manual ""
manual "Or attach in the Foundry portal manually with these values:"
manual "  Endpoint:        https://${SEARCH_SERVICE}.search.windows.net"
manual "  Index:           $INDEX_NAME"
manual "  Query key:       $SEARCH_QUERY_KEY"
manual "  Embedding model: text-embedding-3-large"
manual "  Semantic config: oee-semantic"
