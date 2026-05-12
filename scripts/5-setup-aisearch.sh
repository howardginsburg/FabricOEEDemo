#!/usr/bin/env bash
# =============================================================================
# 5-setup-aisearch.sh — Provision Azure AI Search + index the SOP PDFs
#
# Runs AFTER scripts/4-setup-foundry.sh because it relies on the Foundry AOAI
# endpoint (with text-embedding-3-large deployed) to generate the chunk
# vectors. See FABRIC_OEE_TUTORIAL.md Step 10 for the end-to-end flow.
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
#   --location               (required) Azure region
#   --search-service         (required) Search service name (global-unique)
#   --foundry-aoai-endpoint  (required) https URL of the AOAI/Foundry endpoint
#   --storage-account        (optional) Storage acct name; auto-named if blank
#   --container-name         (optional) Blob container (default: oee-sops)
#   --index-name             (optional) Search index (default: oee-sops)
#   --sku                    (optional) Search SKU (default: basic)
#   --embedding-model        (optional) Default text-embedding-3-large
#   --embedding-deployment   (optional) Deployment name (default same as model)
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

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in az jq curl; do
  command -v "$cmd" &>/dev/null || die "'$cmd' is required but not installed."
done

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
    --allow-shared-key-access false -o none
  ok "Created (shared key auth disabled)"
fi

STORAGE_ID=$(az storage account show -n "$STORAGE_ACCOUNT" -g "$RESOURCE_GROUP" --query id -o tsv)

# Grant the current user Storage Blob Data Contributor so we can upload via --auth-mode login
step "Granting current user Storage Blob Data Contributor on $STORAGE_ACCOUNT"
CURRENT_USER_OID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
if [[ -z "$CURRENT_USER_OID" ]]; then
  warn "Could not resolve signed-in user object id — you may need to assign Storage Blob Data Contributor manually."
else
  if az role assignment list \
       --assignee "$CURRENT_USER_OID" \
       --scope "$STORAGE_ID" \
       --role "Storage Blob Data Contributor" \
       --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
    ok "Role already assigned"
  else
    az role assignment create \
      --assignee-object-id "$CURRENT_USER_OID" \
      --assignee-principal-type User \
      --role "Storage Blob Data Contributor" \
      --scope "$STORAGE_ID" -o none
    ok "Role assigned — sleeping 30s for AAD propagation"
    sleep 30
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
    --sku-capacity 50 --sku-name "Standard" -o none
  ok "Deployment created"
fi

# ── 6. Search service ────────────────────────────────────────────────────────
step "AI Search service: $SEARCH_SERVICE (SKU: $SKU)"
if az search service show -n "$SEARCH_SERVICE" -g "$RESOURCE_GROUP" &>/dev/null; then
  ok "Already exists"
else
  az search service create \
    -n "$SEARCH_SERVICE" -g "$RESOURCE_GROUP" -l "$LOCATION" \
    --sku "$SKU" --partition-count 1 --replica-count 1 \
    --identity-type SystemAssigned \
    --auth-options aadOrApiKey \
    --aad-auth-failure-mode http403 -o none
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
  if az role assignment list \
       --assignee "$SEARCH_MI_OID" \
       --scope "$SCOPE" \
       --role "$ROLE" \
       --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
    ok "$ROLE already assigned on $(basename "$SCOPE")"
  else
    az role assignment create \
      --assignee-object-id "$SEARCH_MI_OID" \
      --assignee-principal-type ServicePrincipal \
      --role "$ROLE" \
      --scope "$SCOPE" -o none
    ok "$ROLE assigned on $(basename "$SCOPE")"
  fi
done
ok "Sleeping 30s for RBAC propagation"
sleep 30

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
step "Running indexer (initial run)"
curl -sS -X POST \
  -H "api-key: $SEARCH_ADMIN_KEY" \
  "${SEARCH_ENDPOINT}/indexers/${IDX_NAME}/run?api-version=${SEARCH_API}" >/dev/null
ok "Indexer run started"

elapsed=0
while (( elapsed < 600 )); do
  status_json=$(curl -sS -H "api-key: $SEARCH_ADMIN_KEY" \
    "${SEARCH_ENDPOINT}/indexers/${IDX_NAME}/status?api-version=${SEARCH_API}")
  status=$(echo "$status_json" | jq -r '.lastResult.status // .status // "unknown"')
  case "$status" in
    success)         ok "Indexer succeeded"; break ;;
    transientFailure|persistentFailure|error)
      err_msg=$(echo "$status_json" | jq -r '.lastResult.errorMessage // "see status"')
      die "Indexer failed: $err_msg" ;;
    inProgress|reset|*)
      printf "   indexer status: %s …\n" "$status"
      sleep 15; elapsed=$((elapsed + 15)) ;;
  esac
done

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
manual "Use these values in the Foundry portal (FABRIC_OEE_TUTORIAL.md Step 11.2):"
manual "  Endpoint:        https://${SEARCH_SERVICE}.search.windows.net"
manual "  Index:           $INDEX_NAME"
manual "  Query key:       $SEARCH_QUERY_KEY"
manual "  Embedding model: text-embedding-3-large"
manual "  Semantic config: oee-semantic"
