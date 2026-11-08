# 9. Foundry agent

This step builds **OEE Factory IQ**, a Microsoft Foundry agent that answers questions from the plant's six
personas. It combines two kinds of knowledge:

- **A Foundry IQ knowledge base**, `oee-factory-kb`, over two sources: an Azure AI Search index of the plant's
  36 SOP and policy PDFs, and the `OEEFactoryOntology` ontology.
- **The OEE Data Agent**, for numbers, rankings, trends, and recent events.

It takes three scripts. Run them after [step 7](fabric-iq.md).

## Create the Foundry resource and models

```bash
bash scripts/8-setup-foundry.sh \
  --foundry-resource <FOUNDRY_RESOURCE_NAME> \
  --project <FOUNDRY_PROJECT_NAME> \
  --resource-group <RESOURCE_GROUP> \
  --location <AZURE_REGION>
```

The script creates the resource group if it doesn't exist, the Foundry resource and project, and three model
deployments, all on the `GlobalStandard` (pay-as-you-go) SKU:

| Deployment | Used by |
|---|---|
| `gpt-5.5` | The agent and the knowledge base |
| `text-embedding-3-large` | The SOP index |
| `gpt-5.4-mini` | The evaluation judge in [step 10](evaluate.md) (`--no-judge-model` skips it) |

It checks your quota first. If a model has no pay-as-you-go quota in your region, it stops and prints the
options to choose another model or version (`--chat-model`, `--chat-model-version`, `--judge-model`). The
agent's chat model must support background mode (`gpt-5.5` or `gpt-5.4`), because data agent calls can run for
minutes.

At the end, the script prints the endpoint to use in the next command:
`https://<FOUNDRY_RESOURCE_NAME>.openai.azure.com`, unless you set `--custom-domain`.

## Index the SOPs

```bash
bash scripts/9-setup-aisearch.sh \
  --resource-group <RESOURCE_GROUP> \
  --location <AZURE_REGION> \
  --search-service <SEARCH_SERVICE_NAME> \
  --foundry-aoai-endpoint https://<FOUNDRY_RESOURCE_NAME>.openai.azure.com \
  --storage-account <STORAGE_ACCOUNT_NAME>
```

The script creates a storage account and uploads the SOP PDFs from `knowledge/`, then creates the Azure AI
Search service and the `oee-sops` index, skillset, and indexer, which chunk and embed the PDFs. Pass
`--storage-account` so that re-runs reuse one storage account instead of creating new ones. If AI Search has no
capacity in your region (`InsufficientResourcesAvailable`), add `--search-location <OTHER_REGION>`.

## Create the knowledge base and the agent

```bash
python3 scripts/10-setup-foundry-agent.py \
  --foundry-resource <FOUNDRY_RESOURCE_NAME> \
  --project <FOUNDRY_PROJECT_NAME> \
  --resource-group <RESOURCE_GROUP> \
  --search-service <SEARCH_SERVICE_NAME> \
  --fabric-workspace "<FABRIC_WORKSPACE>" \
  --smoke
```

It creates:

- the **`oee-factory-kb`** knowledge base, with two knowledge sources: `oee-sops-ks` over the `oee-sops` index,
  and `oee-ontology-ks` over the ontology;
- project connections to the ontology and the published OEE Data Agent;
- the **`oee-factory-iq`** prompt agent on `gpt-5.5`, with two tools: the knowledge base (`oee-knowledge`) and
  the data agent (`oee-data-agent`). Its instructions are
  [agent/system-prompt.md](https://github.com/howardginsburg/FabricOEEDemo/blob/main/agent/system-prompt.md).

`--smoke` asks one question per tool and knowledge source. After you change the system prompt, re-run the
script with `--replace` to create a new version of the agent.

!!! info "Every user needs access to the Fabric items"
    The data agent tool and the knowledge base's ontology source act as the signed-in user, so everyone who uses
    the agent needs read access to the ontology, the data agent, and the sources the ontology binds, including
    Read and Build permissions on the `OEEAnalytics` semantic model. The ontology doesn't accept service
    principals. The knowledge base reads the SOP index with the project's managed identity.

!!! note "The knowledge base starts on the free agentic retrieval plan"
    Agentic retrieval in Azure AI Search comes with a monthly free token allowance. Once it's used, the knowledge
    base's requests fail until the next month, and with them the agent's answers. Evaluation runs use the
    allowance fastest. To keep going, select **Enable standard plan** on the **Knowledge** page in the Foundry
    portal. The standard plan bills per use beyond the free allowance, and it needs the Basic search tier or
    higher, which script 9 creates. See
    [Enable or disable agentic retrieval billing](https://learn.microsoft.com/azure/search/agentic-retrieval-how-to-enable-disable).

## Verify

- `--smoke` prints an answer for each tool and knowledge source.
- In the [Foundry portal](https://ai.azure.com), turn on **New Foundry**, open the project, then **Agents** >
  **oee-factory-iq**, and ask a question in the playground.

To learn how the agent routes questions between its tools, see the
[agent README](https://github.com/howardginsburg/FabricOEEDemo/blob/main/agent/README.md).
