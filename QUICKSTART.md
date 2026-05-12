# Quickstart — Scripted End-to-End Setup

This is the **fast path**. It uses the provisioner scripts in `scripts/` and the ontology notebook to stand up the entire demo — Fabric RTI, optional AIO ingestion, Fabric IQ Data Agent, Azure AI Search, and the Foundry agent — in roughly 30 minutes of attended runtime.

If you would rather learn the platform by clicking through each portal step, follow [FABRIC_OEE_TUTORIAL.md](FABRIC_OEE_TUTORIAL.md) (and optionally [AIO_OEE_TUTORIAL.md](AIO_OEE_TUTORIAL.md)) instead. The two paths land in the same place.

---

## Prerequisites

**Required for any path:**
- Microsoft Fabric capacity (F2 or higher) with Real-Time Intelligence enabled.
- A Fabric workspace where you have contributor access.
- [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) or [Docker](https://docs.docker.com/get-docker/) for the simulator.
- Azure CLI 2.x logged in (`az login`) with permission to create resource groups.
- `bash`, `jq`, and `curl` available in your shell (Git Bash, WSL, or Linux/macOS terminals all work).

**Azure IoT Operations path only:**
- Azure IoT Operations deployed ([Quickstart](https://github.com/howardginsburg/IoT-Operations-Quickstart)).
- Azure CLI 2.67.0+ with the `azure-iot-ops` extension.

**AI Search + Foundry agent steps only:**
- Permission to create a Microsoft Foundry resource + project and to deploy models (`gpt-4.1`, `text-embedding-3-large`) in your chosen region.
- Quota for at least 50K TPM on each model.

---

## 1. Clone

```bash
git clone https://github.com/howardginsburg/FabricOEEDemo.git
cd FabricOEEDemo
```

---

## 2. Provision Fabric (required)

Creates the Eventhouse, KQL Database, tables, reference data, materialized OEE view, Eventstream with routing, and imports the Real-Time Dashboard:

```bash
bash scripts/1-setup-fabric.sh --workspace-name "My Workspace"
# Or, with device-code auth:
bash scripts/1-setup-fabric.sh --workspace-name "My Workspace" --use-device-code
```

> **After the script completes**, open the Eventstream in the Fabric UI and verify it shows **Running**. If it is stopped or in draft state, click **Publish** — data will not flow until the Eventstream is running.

---

## 3. (Optional) Route ingestion through Azure IoT Operations

Skip this section if you want the simulator to publish directly to Fabric.

### 3a. Deploy the MQTT connector into AIO (manual, one-time)

Follow the [Microsoft Learn instructions](https://learn.microsoft.com/azure/iot-operations/discover-manage-assets/howto-use-mqtt-connector) to deploy the MQTT connector template into your AIO instance.

### 3b. Create the device, wait for topic discovery, and promote assets

```bash
bash scripts/2-setup-iotops.sh \
  --instance <your-aio-instance> \
  --resource-group <your-resource-group> \
  --workspace-name <fabric-workspace> \
  --eventhub-namespace <host> \
  --eventhub-name <es_xxx>
```

### 3c. Re-promote assets later if needed

```bash
bash scripts/3-setup-iotops-assets.sh \
  --instance <your-aio-instance> \
  --resource-group <your-resource-group>
```

---

## 4. Run the simulator

```bash
cd simulator/FabricOEESimulator
cp simulator.sample.yaml simulator.yaml
# Edit simulator.yaml — paste your Eventstream connection string (direct path)
# or MQTT broker address (AIO path).
dotnet run
```

Or with Docker:

```bash
cd simulator
docker build -t oee-simulator .
docker run -it --rm -v "$(pwd)/FabricOEESimulator/simulator.yaml:/app/simulator.yaml" oee-simulator
```

Within a few minutes the KQL tables should populate and the Real-Time Dashboard should light up.

---

## 5. (Optional) Create the Fabric Ontology + Data Agent

Enables natural-language querying of the live telemetry via Fabric IQ.

1. Download the `fabriciq_ontology_accelerator` wheel from the [FabricIQ Accelerator releases](https://github.com/microsoft/fabriciq-accelerator/releases) and upload it to your lakehouse.
2. Open `notebooks/create_ontology.ipynb` in Fabric and run all cells.
3. In the Fabric portal, open the **Data Agent** that the notebook creates and confirm it can answer:
   *"What's the current OEE for Line-A?"*

Note the Data Agent's **identifier** (display name or ID) — you pass it to Step 6.

---

## 6. (Optional) Provision the Foundry resource and deploy models

```bash
bash scripts/4-setup-foundry.sh \
  --foundry-resource <FOUNDRY_RESOURCE_NAME> \
  --project          <FOUNDRY_PROJECT_NAME> \
  --resource-group   <RG> \
  --location         <LOCATION>
```

The script provisions the Microsoft Foundry resource (`AIServices` kind with `--allow-project-management`), assigns a custom subdomain, creates the project, and deploys both models in one pass:

- **Chat model:** `gpt-4.1` (deployment name `gpt-4.1`, 50K TPM, version `2025-04-14`).
- **Embedding model:** `text-embedding-3-large` (deployment name `text-embedding-3-large`, 50K TPM, version `1`).

Override any of those with `--chat-model`, `--chat-model-version`, `--chat-deployment`, `--chat-capacity`, `--embedding-model`, `--embedding-model-version`, `--embedding-deployment`, `--embedding-capacity`. The custom subdomain defaults to the resource name; override with `--custom-domain` if it is taken.

The script prints the **OpenAI endpoint URL** (`https://<custom-domain>.openai.azure.com`) at the end — you pass that value to Step 7.

---

## 7. (Optional) Index the SOP corpus in Azure AI Search

```bash
bash scripts/5-setup-aisearch.sh \
  --resource-group <RG> \
  --location <LOCATION> \
  --search-service <UNIQUE_SEARCH_NAME> \
  --foundry-aoai-endpoint https://<your-foundry-aoai>.openai.azure.com
```

The script provisions the storage account, blob container `oee-sops`, uploads all 36 SOP PDFs from `knowledge/`, creates the AI Search service (Basic SKU — sufficient for the 36 SOPs; override with `--sku standard` if needed), wires the embedding deployment, and creates the data source, skillset, index, and indexer. It runs the indexer once and prints a smoke query.

Save the final **endpoint, query key, index name, embedding model, and semantic configuration** — you paste them into the Foundry portal in Step 8.

> **Regenerating PDFs (developer-only):** the 36 PDFs are already committed under `knowledge/*.pdf`. If you author a new SOP in `knowledge/source/`, rebuild with `bash scripts/build-sops.sh` (requires `pandoc` + `wkhtmltopdf` or `xelatex`).

---

## 8. (Optional) Build the agent and attach knowledge tools

This step is portal-only — there is no script. Knowledge sources are attached **per agent** in the current Foundry Agent Service (the legacy global *Foundry IQ → Knowledge* registry was replaced). Classic agents retire **March 31, 2027**.

> See [FABRIC_OEE_TUTORIAL.md §11](FABRIC_OEE_TUTORIAL.md#step-11--build-the-agent-and-attach-knowledge-tools-optional) for the full version (with RBAC steps and screenshot-level detail). The summary below is the fast path.

### 8a. Grant the Foundry project access to AI Search

Assign the Foundry account's managed identity `Search Index Data Reader` + `Search Service Contributor` on the AI Search service (CLI snippet in FABRIC_OEE_TUTORIAL.md §11.1). Required because Step 7 turned off shared-key auth on the index.

### 8b. Create the agent

Foundry portal → left pane **Build and customize** → **Agents** → **+ New agent**:

- Name: `OEE Factory IQ`.
- Model deployment: the `gpt-4.1` deployment from Step 6.
- Instructions: paste [agent/system-prompt.md](agent/system-prompt.md) verbatim.
- **Save** before attaching tools.

### 8c. Attach Knowledge tool #1 — Fabric Data Agent

Setup pane → **Knowledge** → **Add** → **Microsoft Fabric** → **New connection**:

- Open the published Fabric Data Agent from Step 5; copy `workspace-id` and `artifact-id` out of its URL (`https://<env>.fabric.microsoft.com/groups/<workspace-id>/aiskills/<artifact-id>`).
- Paste both into the connection dialog and check **Is secret** for each.
- Description: paste [agent/knowledge/fabric_data_agent.md](agent/knowledge/fabric_data_agent.md).

(The Fabric Data Agent must be **published** in Fabric, in the same tenant.)

### 8d. Attach Knowledge tool #2 — Azure AI Search

Same **Knowledge** panel → **Add** → **Azure AI Search**:

- **Connect to an index** → *Indexes that are not part of this project*.
- **New connection** → pick the AI Search service from Step 7, **Microsoft Entra ID (managed identity)** auth.
- **Index:** `oee-sops`. **Search type:** *Hybrid + semantic*. **Semantic configuration:** `oee-semantic`.
- Description: paste [agent/knowledge/aisearch_sops.md](agent/knowledge/aisearch_sops.md).

### 8e. Run the sample queries

Open **Try in playground** and exercise the persona prompts in [agent/samples/queries.md](agent/samples/queries.md). Expect responses that fuse live state with cited SOP excerpts.

---

## What you have at the end

| Pillar | Resource | Provisioned by |
|---|---|---|
| **Fabric RTI** | Eventhouse, KQL DB, OEE_5min view, Real-Time Dashboard, Activator | `scripts/1-setup-fabric.sh` |
| **Edge ingestion** (optional) | AIO device, dataflow, promoted assets | `scripts/2-setup-iotops.sh`, `scripts/3-setup-iotops-assets.sh` |
| **Fabric IQ** | Fabric Ontology + Data Agent | `notebooks/create_ontology.ipynb` |
| **Foundry runtime** | Foundry resource + project, chat + embedding deployments | `scripts/4-setup-foundry.sh` |
| **Static knowledge** | Blob storage, 36 SOP PDFs, AI Search index `oee-sops` | `scripts/5-setup-aisearch.sh` |
| **Agent** | Foundry agent `OEE Factory IQ` with Fabric + AI Search knowledge tools | Portal (Step 8) |

---

## When something does not work

- The Eventstream sometimes lands in draft state — open it in the Fabric UI and **Publish**.
- All five `scripts/*-setup-*.sh` are idempotent — re-running them is the recommended way to retry after a transient failure.
- For step-by-step diagnosis, the manual tutorials ([FABRIC_OEE_TUTORIAL.md](FABRIC_OEE_TUTORIAL.md), [AIO_OEE_TUTORIAL.md](AIO_OEE_TUTORIAL.md)) show what each script is doing under the hood and surface the right portal pages.
- The full troubleshooting matrix lives in the Appendix of [FABRIC_OEE_TUTORIAL.md](FABRIC_OEE_TUTORIAL.md#appendix--troubleshooting).
