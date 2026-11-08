# Prerequisites

## Fabric

- **A Fabric capacity, F2 or larger.** F8 is a comfortable size for the whole demo; see
  [Capacity and cost](../reference/capacity.md). Trial capacities don't support the operations agent.
- **A workspace on that capacity** where you're at least a Contributor. It can't be *My workspace*.
- **Tenant settings.** A Fabric administrator turns these on in the admin portal under **Tenant settings**.

| Tenant setting | Needed for | Details |
|---|---|---|
| Users can create Fabric items | Every step | [Fabric items](https://learn.microsoft.com/fabric/admin/fabric-switch) |
| Users can create Ontology (preview) items | Steps 1 and 7 | [Ontology tenant settings](https://learn.microsoft.com/fabric/iq/ontology/overview-tenant-settings) |
| Users can use Copilot and other features powered by Azure OpenAI | The data agent (step 1), the operations agent (step 8) | [Data agent tenant settings](https://learn.microsoft.com/fabric/data-science/data-agent-tenant-settings) |
| Data sent to Azure OpenAI can be processed (and stored) outside your capacity's geographic region | Only when the capacity is outside the US and the EU | [Data agent tenant settings](https://learn.microsoft.com/fabric/data-science/data-agent-tenant-settings) |
| Enable Event Schema Sets in Real-Time Hub (preview) | Step 1 (the event contracts; optional) | [Tenant settings index](https://learn.microsoft.com/fabric/admin/tenant-settings-index) |
| Enable Fabric App Items (preview) | Step 4 | [Tenant settings index](https://learn.microsoft.com/fabric/admin/tenant-settings-index) |

To get the operations agent's (step 8) alerts in Microsoft Teams, the person it messages needs a Teams account
with the **Fabric Operations Agent** app installed. In a tenant without Teams, the agent still runs, and its
alerts are in its activity log. See the
[operations agent prerequisites](https://learn.microsoft.com/fabric/real-time-intelligence/operations-agent#prerequisites).

## Azure (steps 9 and 10 only)

- A subscription where you can create a resource group, a Microsoft Foundry resource, Azure AI Search, and a
  storage account.
- Permission to assign roles (Owner, or User Access Administrator) in that resource group. The scripts give you,
  the search service, and the Foundry project the data roles they need on the storage account, the Foundry
  resource, and the search service.
- **Consumption model quota (GlobalStandard)** in your region for `gpt-5.5`, `text-embedding-3-large`, and
  `gpt-5.4-mini`. Step 9 checks your quota first and tells you how to choose another model if one is missing.

## Tools

On Windows, install the setup tools in **WSL** (Ubuntu) and run every script there. Under Git Bash, `az`
resolves to a wrapper that breaks the scripts' request bodies.

| Tool | Needed for | Notes |
|---|---|---|
| Azure CLI | Every step | 2.67 or later for step 9. Sign in from the same shell that runs the scripts. |
| `jq`, `curl` | Every step | `sudo apt install jq curl` |
| Python 3.10+ | Steps 1, 3, 4, 7, 8, 9, 10 | The Fabric scripts use only the standard library. |
| `azure-ai-projects` (2.2+), `azure-identity`, `openai`, `httpx` | Steps 9 and 10 | Install them in a virtual environment (below). |
| `pyodbc` and [ODBC Driver 18 for SQL Server](https://learn.microsoft.com/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server) | Steps 3 and 4 | Step 3 uses it only when `sqlcmd` isn't installed. |
| .NET 10 SDK | Step 2 | On Windows, outside WSL: the simulator is a Windows desktop app. |
| Node.js 18+ | Step 4 | The Fabric App's CLI is a project dependency. |

WSL's Python doesn't allow installing packages system-wide, so use a virtual environment and keep it
activated while you run the scripts:

```bash
python3 -m venv ~/.venvs/oee
source ~/.venvs/oee/bin/activate
pip install "azure-ai-projects>=2.2.0" azure-identity openai httpx pyodbc
```

## Get the code and sign in

```bash
git clone https://github.com/howardginsburg/FabricOEEDemo.git
cd FabricOEEDemo
az login                       # add --tenant <TENANT_ID> if your account has several tenants
az account set --subscription "<SUBSCRIPTION>"   # steps 9 and 10
```

Then check everything at once. The script changes nothing; it reports what's missing and how to fix it,
grouped by the step that needs it:

```bash
bash scripts/0-check-prereqs.sh
```

## Verify

- `bash scripts/0-check-prereqs.sh` reports no missing core prerequisites.
- `az account show` shows the account that has access to your Fabric workspace.
