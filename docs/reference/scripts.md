# Scripts

Every script is in `scripts/` and is safe to re-run. The Fabric scripts take `--workspace-name`, and most of the
bash scripts also take `--use-device-code` to sign in with a device code. Each script's header comment lists all
of its options.

| Script | What it does | Setup step |
|---|---|---|
| `0-check-prereqs.sh` | Checks every prerequisite, grouped by the step that needs it, and prints how to fix anything missing. It changes nothing. | [Prerequisites](../setup/prerequisites.md) |
| `1-setup-fabric.sh` | Builds the real-time foundation: the Eventhouse tables, update policies, OEE and rule functions, and mirroring; the Eventstream; the lakehouse shortcuts; and the Real-Time Dashboard. Then runs scripts 1a, 6, and 7. `--skip-fabric-iq` leaves out the ontology and the data agent. | [1](../setup/fabric-foundation.md) |
| `1a-publish-event-schemas.py` | Publishes the event contracts in `eventschemas/` as the OEE Telemetry Events Event Schema Set, after checking them against the Bronze tables. `--skip-drift-check`, `--dry-run`. | [1](../setup/fabric-foundation.md) |
| `2-setup-translytical.sh` | Creates the `OeeGovernance` SQL database, the `OeeTargetFunctions` user data function, and the `OeeTarget` shortcut. | [3](../setup/write-back.md) |
| `2a-apply-oee-target-schema.py` | Creates `dbo.OeeTarget` with `pyodbc` when `sqlcmd` isn't installed. Script 2 runs it. | [3](../setup/write-back.md) |
| `3a-seed-floor-events.py` | Seeds demo floor events into the Floor Ops Console's database. `--count`, `--window-hours`, `--reset`. | [4](../setup/floor-ops-console.md) |
| `3-setup-floor-ops.sh` | Creates the `FloorEvent` shortcut over the app's mirrored table. `--app-sqldb-name`. | [4](../setup/floor-ops-console.md) |
| `4-setup-powerbi.sh` | Deploys the `OEEAnalytics` semantic model and report, wires the **Update OEE** button, and reframes the model. | [5](../setup/power-bi.md) |
| `5-setup-activator-alerts.sh` | Resumes the Eventstream and deploys the Floor Ops Alerts Activator rule. `--alert-email`. | [6](../setup/activator.md) |
| `6-publish-ontology.py` | Publishes the ontology from TMDL, binding the lakehouse, the Eventhouse, the `OeeGovernance` SQL database, and the `OEEAnalytics` semantic model; leaves out entities whose source doesn't exist yet; checks the model measures it references; and saves the GQL queryset once the graph has data. `--refresh-graph`, `--recreate`, `--dry-run --out <dir>`, `--export-ttl <file>`. | [7](../setup/fabric-iq.md) |
| `7-setup-data-agent.py` | Configures and publishes the OEE Data Agent with the ontology as its context: mounts the Eventhouse and the lakehouse the ontology binds, with their instructions and example queries, and checks that each example runs. `--smoke`, `--ask "<question>"`, `--show-queries`, `--runtime preview\|standard`, `--graph`, `--draft-only`, `--recreate`. | [7](../setup/fabric-iq.md) |
| `11-setup-operations-agent.py` | Creates the OEE Operations Agent and generates its playbook. `--recipient`, `--start`, `--stop`, `--generate-playbook`. | [8](../setup/operations-agent.md) |
| `8-setup-foundry.sh` | Creates the Foundry resource and project, and deploys the chat, embedding, and judge models after a quota check. | [9](../setup/foundry-agent.md) |
| `9-setup-aisearch.sh` | Creates the storage account and the AI Search service, uploads the SOP PDFs, and builds the `oee-sops` index. `--storage-account`, `--search-location`. | [9](../setup/foundry-agent.md) |
| `10-setup-foundry-agent.py` | Creates the knowledge base, the Fabric IQ connections, and the `oee-factory-iq` agent. `--smoke`, `--replace`, `--knowledge tools`. | [9](../setup/foundry-agent.md) |
| `12-evaluate-agent.py` | Evaluates the Foundry agent on the persona question set. `--case`, `--persona`, `--resubmit`, `--skip-foundry`, `--write-samples`. | [10](../setup/evaluate.md) |
| `dev-build-sops.sh` | Regenerates the SOP PDFs from `knowledge/source/*.md`. For development only; the PDFs are committed. | — |
