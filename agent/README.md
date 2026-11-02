# OEE Factory IQ agent

`oee-factory-iq` is a Microsoft Foundry prompt agent that answers questions from the six
personas in the demo (Corp Exec, Plant Manager, Line Manager, Maintenance Tech, Quality
Worker, Reliability Engineer). [scripts/10-setup-foundry-agent.py](../scripts/10-setup-foundry-agent.py) creates it,
with its connections and knowledge base; each run with `--replace` adds a new agent version.

| File | What it is |
|---|---|
| [system-prompt.md](system-prompt.md) | The agent's instructions. Script 10 keeps the `<!-- mode: … -->` blocks for the knowledge mode it deploys and drops the rest. |
| [knowledge/aisearch_sops.md](knowledge/aisearch_sops.md) | The `oee-sops` index over the 36 SOP and policy PDFs. |
| [evals/](evals/) | The persona question set and how the agent is evaluated. |
| [samples/queries.md](samples/queries.md) | Demo questions by persona, generated from `evals/cases.json`. |

## Tools

Two knowledge modes (`--knowledge`):

| Mode | Tools |
|---|---|
| `knowledge-base` (default) | **`oee-knowledge`**: the Foundry IQ knowledge base `oee-factory-kb` in Azure AI Search, reached as an MCP tool. Two knowledge sources: `oee-sops-ks` (the `oee-sops` index) and `oee-ontology-ks` (the `OEEFactoryOntology` ontology). It plans subqueries across both and synthesizes a cited answer.<br>**`oee-data-agent`**: the OEE Data Agent through the Fabric IQ tool. |
| `tools` | **AI Search** on `oee-sops`, **`oee-ontology`** (the ontology through Fabric IQ), and **`oee-data-agent`**. |

The OEE Data Agent ([scripts/7-setup-data-agent.py](../scripts/7-setup-data-agent.py), which
holds its instructions and example queries) has three sources: the ontology, the
`OEEAnalytics` Direct Lake semantic model, and the `ManufacturingEH` Eventhouse.

Routing in short: numbers, rankings, trends, and recent events go to the data agent; meaning,
rules, procedures, and plant design facts (bottlenecks, targets, thresholds) go to the knowledge
base; combined questions call both, each with only its part. Whether an escalation rule has
fired (OEE below 60% for more than 15 minutes or an hour) is its own data agent question, asked
separately from KPIs and targets, because OEE over the full history can't show how long a line
has been below 60%.

Inside the knowledge base, the ontology source answers with a live query over the ontology's
data, which can take up to 100 seconds. The knowledge base's retrieval instructions keep
procedure, condition, and KPI questions on the SOP source, and it stores a 150-second retrieve
budget so a slow ontology query degrades to an SOP-only answer instead of failing the response.

## Identity

The Fabric IQ tools and the knowledge base's ontology source act on behalf of the signed-in
user (Agent Service passes the user's token), so every user needs read access to the ontology,
the data agent, and their sources. The ontology endpoint doesn't accept service principals. The
knowledge base reads the SOP index with the project's managed identity.

## Try it

- `python scripts/10-setup-foundry-agent.py … --smoke` asks one question per tool.
- In the Foundry portal: project → Agents → `oee-factory-iq` → playground.
- `python scripts/12-evaluate-agent.py …` runs the full persona question set and adds a run to
  the agent's Foundry evaluation (see [evals/README.md](evals/README.md)).
