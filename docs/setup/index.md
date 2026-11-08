# Setup

Setup deploys the demo into one Fabric workspace, and optionally an Azure resource group for the Foundry
agent. Every step is a script you run from the repository. Re-running a script is safe, and it's the normal
way to recover from a failed run.

## What you'll deploy

| Step | What it adds | Needed for |
|---|---|---|
| [Prerequisites](prerequisites.md) | Tools, sign-in, tenant settings | Everything |
| [1. Fabric foundation](fabric-foundation.md) | Eventstream, Eventhouse, lakehouse, Real-Time Dashboard, the ontology, and the OEE Data Agent | **Required** |
| [2. Connect the simulator](simulator.md) | Live telemetry from the factory simulator | **Required** |
| [3. OEE target write-back](write-back.md) | A Fabric SQL database and a user data function that the report calls | Optional (preview) |
| [4. Floor Ops Console](floor-ops-console.md) | A Fabric App where operators log floor issues | Optional (preview) |
| [5. Power BI report](power-bi.md) | The Direct Lake semantic model and 5-page report | Optional |
| [6. Activator alert](activator.md) | An email when a machine faults | Optional |
| [7. Fabric IQ](fabric-iq.md) | The ontology's entities from the SQL database, the Floor Ops Console, and the semantic model; its graph; and the data agent | Optional (preview) |
| [8. Operations agent](operations-agent.md) | Alerts when an ontology rule fires | Optional (preview) |
| [9. Foundry agent](foundry-agent.md) | SOP search, a Foundry IQ knowledge base, and the OEE Factory IQ agent | Optional (Azure) |
| [10. Evaluate the agent](evaluate.md) | Persona evaluations of the agent in Foundry | Optional (Azure) |

Run the steps in order. A few dependencies make the order matter:

- Steps 3 and 4 run **before** step 5, so the semantic model finds the `OeeTarget` and `FloorEvent` tables
  and the report gets its write-back button.
- Step 7 runs **after** steps 3 to 5, so the ontology adds the entities those steps create and the data
  agent adds the semantic model.
- Steps 9 and 10 need step 7, because the Foundry agent uses the ontology and the data agent.

You can stop after any step. The [Demo](../demo/index.md) pages note which steps each part needs.

## Before you start

- **Use WSL on Windows.** The setup scripts are bash and Python. Run them from WSL (Ubuntu), Linux, or macOS.
  The simulator itself is a Windows app, so on Windows you run it outside WSL.
- **Size the capacity for what you'll run.** An F8 runs the demo comfortably. The agents are billed per use,
  and repeated evaluation runs can throttle a small capacity. See [Capacity and cost](../reference/capacity.md).
- **Know your names.** The commands use these placeholders:

| Placeholder | Example | Used by |
|---|---|---|
| `<FABRIC_WORKSPACE>` | `OEE Demo` | Every Fabric step |
| `<RESOURCE_GROUP>` | `OEEDemo` | Steps 9 and 10 |
| `<AZURE_REGION>` | `centralus` | Step 9 |
| `<FOUNDRY_RESOURCE_NAME>` | `oeedemofoundry` | Steps 9 and 10 |
| `<FOUNDRY_PROJECT_NAME>` | `oee-project` | Steps 9 and 10 |
| `<SEARCH_SERVICE_NAME>` | `oeedemosearch` (globally unique) | Step 9 |
| `<STORAGE_ACCOUNT_NAME>` | `oeedemosops` (globally unique, 3–24 lowercase letters and digits) | Step 9 |
| `<CAPACITY_NAME>`, `<CAPACITY_RESOURCE_GROUP>` | `oeedemocapacity`, `Fabric` | Clean up (pausing the capacity) |

When you're done presenting, [clean up](clean-up.md) so the demo stops using capacity. If a step fails, see
[Troubleshooting](troubleshooting.md).
