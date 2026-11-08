# Copilot instructions — Fabric OEE Demo

Guidance for AI agents working in this repo. It captures hard‑won, non‑obvious lessons from
building and deploying this demo so you don't rediscover them. Read this before running any
`scripts/*` or touching `powerbi/`, `ontology/`, `agent/`, `app/`, or the translytical function.

## What this repo is
A real‑time **OEE** (Overall Equipment Effectiveness) demo on Microsoft Fabric. A .NET 10 WPF
simulator streams factory telemetry → Fabric Eventstream → Eventhouse/KQL (Bronze→Silver) →
OneLake → Real‑Time Dashboard + a Direct Lake on OneLake Power BI model. A Fabric IQ ontology
(`OEEFactoryOntology`, TMDL) grounds the OEE Data Agent, a Foundry IQ knowledge base, the
`oee-factory-iq` Foundry agent, and an operations agent. Other optional layers: a translytical
write‑back UDF, a Rayfin Fabric App, an Activator alert, and an Event Schema Set. The documentation
site is built from `docs/` (see "Documentation site" below): `docs/setup/` has every setup step,
`docs/how-it-works.md` the architecture and design, and `docs/reference/scripts.md` the script
reference.

Deployment order: `scripts/1-setup-fabric.sh` (always first; it also runs `1a` (Event Schema Set),
`6` (ontology), and `7` (data agent)) → `2-setup-translytical.sh` → `3-setup-floor-ops.sh` →
`4-setup-powerbi.sh` → `5-setup-activator-alerts.sh` → re‑run `6` and `7` so they pick up the
tables from 2–4 → `8-setup-foundry.sh` → `9-setup-aisearch.sh` → `10-setup-foundry-agent.py` →
`11-setup-operations-agent.py` → `12-evaluate-agent.py` (after every agent change).
**Script 2 (translytical) runs before script 4 (Power BI) on purpose:** the semantic model's
`Target OEE` measure reads the `OeeTarget` OneLake shortcut that script 2 creates, and the report's
write‑back button is injected with the `OeeTargetFunctions` UDF id that script 2 creates. Script 4
degrades gracefully (drops the button, warns) if the UDF isn't there yet.
All setup scripts are meant to be **idempotent** — re‑running is the normal recovery path.

---

## Environment & tooling (Windows) — read first

- **Run the bash scripts under WSL, not Git Bash.** The scripts detect the `az` binary and do
  Windows↔Linux temp‑path conversion (`wslpath`, `/mnt/c/...`). Under Git Bash, `az` resolves to
  a wrapper (`.../wbin/az`) that breaks the scripts' `@file` body handling. WSL Ubuntu has a
  native `/usr/bin/az` and works correctly. Typical invocation:
  `wsl.exe -d Ubuntu-24.04 -- bash -lc 'cd "/mnt/c/.../FabricOEEDemo" && bash scripts/1-setup-fabric.sh --workspace-name "OEE Demo"'`
- **`az` must be logged in in whichever shell runs the scripts** (WSL and Windows are separate
  logins, and can be signed in to different tenants — use the one signed in to the demo tenant).
  The Fabric scripts need `az login`; Foundry (script 8) needs **Azure CLI ≥ 2.67**.
- **`python3` on Windows** may resolve to the broken Microsoft Store stub while `python` works.
  In WSL, `python3` is fine but is externally managed (PEP 668 — use `--break-system-packages`
  or a venv). Scripts 10 and 12 need `pip install "azure-ai-projects>=2.2.0" azure-identity openai
  httpx` in whichever Python runs them; the Fabric scripts (1a, 6, 7, 11) use only the standard
  library.
- **Windows console is cp1252** — Python scripts that print box‑drawing chars (`──`) crash with
  `UnicodeEncodeError`. Run them with `PYTHONUTF8=1` (e.g. scripts 10 and 12).
- **WSL `/tmp` is cleared between separate `wsl.exe` invocations.** Don't rely on a temp file
  written in one call being present in the next — do multi‑step work inside a single script, or
  write intermediates under the repo/session folder.
- The `.fabric-tmp/` dir is the scripts' scratch space and self‑cleans; it's git‑ignored.

## Fabric REST API patterns

- **Item create / `updateDefinition` are async (HTTP 202).** The response body is empty; the real
  result comes from polling the long‑running operation. **Never fire‑and‑forget** — poll
  `GET /v1/operations/{x-ms-operation-id}` until `status == Succeeded`/`Failed`, and read
  `/operations/{id}/result` for the error. Swallowing the 202 hides validation errors and makes a
  failed deploy look successful (this bit us in `2-setup-translytical.sh` — the UDF silently
  never created). Reuse the existing helpers: `fabric_lro_post` in scripts 1, 2, and 4, and
  `post_lro` in the Python scripts (1a, 6, 7, 11).
- **`POST .../getDefinition` needs `Content-Length: 0`** or it returns `HTTP 411 Length Required`.
- Tokens: Fabric API resource is `https://api.fabric.microsoft.com`; Power BI API resource is
  `https://analysis.windows.net/powerbi/api`; a KQL cluster's resource is its own cluster URI.
- Resolve a **Fabric capacity id** from `GET /v1/capacities` by `displayName`; create a workspace
  with `POST /v1/workspaces {displayName, capacityId}` to bind it to that capacity.
- **The capacity may be paused** (automation can pause it outside working hours). Fabric calls then
  fail; resume it before running the scripts (Azure portal, or `az rest --method post --url
  "https://management.azure.com<capacity-resource-id>/resume?api-version=2023-11-01"`), and pause
  it (`/suspend`) after the demo.

## Capacity (F8) — what costs what

The live pipeline is cheap (about 92K CU-s over two weeks). The Fabric IQ items are billed per use
and were 96% of the usage while the demo was built (Capacity Metrics app → Compute → Items):

- **Data agent:** about 65K–100K uncached prompt tokens per question, about 7K–10K CU-s. A full script 12 run is
  30–40 of them, about a third of an F8 day. Run `--case`/`--persona` subsets; don't loop full runs.
- **Operations agent:** a playbook generation is a long reasoning run at four times Copilot token rates.
  The generations made while building it cost about 625K CU-s. Generate once, with nothing else running.
- **Ontology graph:** about 70 CU-s per second of graph compute (565K CU-s for about 2¼ hours). Every
  ontology publish re-ingests all bound data, and every GQL query wakes it. Script 6 skips unchanged
  publishes and re-validates GQL only when the queryset is stale or with `--refresh-graph`. Don't add
  `--refresh-graph` after a schema publish, which re-ingests on its own.
- **Ontology Discovery** (1,000 CU-s per definition read, including an open portal tab about every 20
  minutes) and **Ontology AI Reasoning** are non-billable in preview, so they don't count toward
  throttling yet.
- **Throttling** (`CapacityLimitExceeded`, HTTP 429 `RequestBlocked`) means billable usage ran ahead of
  the capacity. Suspend and resume clears it at once, but the pause bills the remaining smoothed usage
  immediately, so space heavy runs out instead. Throttling also takes the Eventstream's endpoint offline
  ("Namespace cannot be resolved") and pauses its destinations: resume them afterwards (`POST
  .../eventstreams/{id}/destinations/{destId}/resume`, `{"startType":"WhenLastStopped"}` backfills the gap).
  The simulator drops events it can't send and logs `send_error` / `send_recovered` in its telemetry log;
  before that fix, one failed send silently stalled the whole simulation.

## Azure region / quota gotchas (seen in Central US)

- **Model quota varies by region.** `8-setup-foundry.sh` deploys `gpt-5.5` (agent + knowledge
  base), `text-embedding-3-large` (SOP index), and `gpt-5.4-mini` (evaluation judge), all
  `GlobalStandard`, and runs a quota preflight. If a model shows 0 consumption quota (some regions
  expose only Batch — e.g. `gpt-4.1` in centralus), override with `--chat-model` /
  `--chat-model-version` / `--judge-model`. The agent needs a background‑capable chat model
  (`gpt-5.5` or `gpt-5.4`). Check quota with `az cognitiveservices usage list -l <region>`.
- **Azure AI Search** can be capacity‑constrained in a region (`InsufficientResourcesAvailable`).
  `9-setup-aisearch.sh` supports `--search-location <other-region>` (it reads storage + calls AOAI
  cross‑region).
- **Storage `publicNetworkAccess`** may be force‑disabled by an org **Azure Policy** (a `modify`
  effect). Symptoms: blob container create / the AI Search indexer fail with 403 "blocked by network
  rules". The policy rewrites both `az storage account update` and a direct ARM PATCH back to
  `Disabled` while the call still succeeds, so always read the value back (`9-setup-aisearch.sh` does,
  and stops with guidance). Only the human operator can open it (policy exemption or admin change);
  then upload + index promptly. Once the indexer finishes it can be closed again — the index holds the
  chunks and vectors, so the agent never reads storage.
- **AI Search indexer 403 "credentials invalid or expired"** right after service creation is RBAC
  propagation lag for the search managed identity (Storage Blob Data Reader). Wait for the role to
  propagate, then re‑run `9-setup-aisearch.sh` (idempotent) to create + run the indexer.

## Power BI report definition — the big one

**Reports MUST be authored in the current PBIR schema versions or the portal can't open them.**

Symptom: opening the report shows **"Something went wrong — Failed to get access request info for
this artifact"**. The failing call is `GET .../metadata/accessrequest/2/undefined` (405) — the
shell couldn't resolve the report's dataset object id (it's literally `undefined`). This is NOT a
permissions, model, or data problem (the model queries fine on demand; a natively‑created report
over the same model opens).

Root cause: a legacy PBIR format. Use the **modern** schema versions everywhere under
`powerbi/OEEAnalytics.Report/`:

| File | Required schema / value |
| --- | --- |
| `definition/version.json` | `"version": "2.0.0"` (NOT 4.0.0) |
| `definition/report.json` | `report/3.3.0` schema, with the base theme as a **StaticResources resourcePackage** |
| `definition/pages/pages.json` | `pagesMetadata/1.1.0` |
| `definition/pages/*/page.json` | `page/2.1.0` |
| `definition/pages/**/visual.json` | `visualContainer/2.12.0` |
| `StaticResources/SharedResources/BaseThemes/<Theme>.json` | actual theme file must exist and be referenced by `report.json` |

- Do **not** reference a base theme by name only (e.g. `CY24SU10` as `SharedResources` with no file)
  — include the theme JSON as a part.
- The report→dataset binding (`definition.pbir`) uses `byConnection` with **only** a
  `connectionString` under the `definitionProperties/2.0.0` schema. Extra fields
  (`pbiModelDatabaseName`, `pbiModelVirtualServerName`, `name`, `connectionType`, …) are rejected by
  the 2.0.0 schema. Connection string shape:
  `Data Source="powerbi://api.powerbi.com/v1.0/myorg/<Workspace>";initial catalog=<Model>;integrated security=ClaimsToken;semanticmodelid=<GUID>`
- **Debugging tip that works:** create a throwaway report natively in Fabric ("QuickCreate") bound
  to the same model — it opens reliably. Pull its definition via `getDefinition` and diff the schema
  versions / theme handling against the repo's report to find format drift.
- A Power BI REST **Rebind** (`POST /groups/{ws}/reports/{id}/Rebind {datasetId}`) is only a fragile
  band‑aid (needs ~1–2 min to propagate and a failed enhanced‑refresh can undo it). `4-setup-powerbi.sh`
  keeps a rebind as a *safety net that runs last*, but the real fix is the format above.

## Direct Lake behavior

- **The model is Direct Lake on OneLake.** Every table binds to `ManufacturingLH/Tables/dbo/*`
  through one shared `AzureStorage.DataLake` expression; `4-setup-powerbi.sh` injects
  `__WORKSPACE_ID__` / `__LAKEHOUSE_ID__`. No SQL endpoint in the query path, no DirectQuery fallback.
- **Background reframes (`POST /datasets/{id}/refreshes`) succeed in this mode.** They failed
  ("We cannot access the source Delta table …", rotating table names) only while the model was
  Direct Lake on the SQL endpoint — don't switch it back.
- **Direct Lake auto‑frames on query** — after new telemetry streams, on‑demand queries
  (`POST /datasets/{id}/executeQueries`, and report visuals) reflect the latest data. Don't block on
  a reframe for data freshness.
- A **full** reframe fails if the model contains tables bound to Delta sources that don't exist
  yet (`OeeTarget` / `FloorEvent` before scripts 2 and 3); they don't block the report from opening.
- The lakehouse **SQL analytics endpoint** still matters to other consumers: the ontology binds
  through it, so scripts that add shortcuts (2, 3, 4, 6) refresh its metadata.

## Fabric User Data Functions (translytical `set_oee_target`)

- **UDF input parameter names cannot contain underscores.** Fabric validation rejects them
  (`MetadataValidationError: input parameter '<name>' cannot contain an underscore`). Use camelCase
  for the function signature (`lineId`, `targetOee`, `setBy`); SQL **column** names keep underscores.
- **The `@udf.connection(alias=…)` value must be an inline alphanumeric string literal.** The
  validator reads decorators statically, so a module constant (`alias=OEE_GOVERNANCE_ALIAS`) fails as
  "not a valid Alphanumeric string". Inline it: `alias="OeeGovernance"`.
- Deploying the UDF via the Items API is async — poll the LRO (see Fabric REST patterns) or the real
  validation errors above are silently swallowed.
- **The UDF is invoked by a Power BI data‑function button that is now checked in and deployed.** It
  lives on the Executive page as `vis-exec-slicer-target` (a `textSlicer` numeric input, "New Target
  OEE (0-1)") + `vis-exec-btn-set-target` (an `actionButton` whose `visualLink` is a `DataFunction`
  action). Param bindings are baked in: `lineId` → `ValueParameter` on the `_Measures[Selected Line
  ID]` measure (`SELECTEDVALUE(DimLine[line_id])`); `targetOee` → `SlicerParameter` on
  `vis-exec-slicer-target`; `setBy` → `SlicerParameter`, `isOptional:true`, `defaultValue:"report"`
  (unmapped). The button JSON stores the UDF by **workspace id + item id**, so it uses
  `__WORKSPACE_ID__` / `__UDF_ITEM_ID__` placeholders and `4-setup-powerbi.sh` resolves
  `OeeTargetFunctions` by name and injects them at deploy (dropping the button via `BUILD_EXCLUDE`
  if the UDF is absent). Read side: `dbo.OeeTarget` → OneLake mirror → shortcut → measures `Target
  OEE` / `OEE vs Target` → the "OEE vs Target by Line" chart + "Target OEE" card.
- **Report parts exceed Linux `MAX_ARG_STRLEN` (~128 KB/arg)** once the ~95 KB base64 theme is
  included, so `deploy_item` builds the request body with `jq --slurpfile` from a temp file, never
  `--argjson parts "$parts"`. `build_parts` supports multiple override pairs + a `BUILD_EXCLUDE` skip
  list for the optional button visuals.
- **Making a UDF parameter optional** is done purely in the Python signature (`setBy: str = "report"`).
  The `resources/functions.json` `fabricFunctionParameters` schema has only `name`/`dataType` — no
  optional/default field — so don't try to encode optionality there.
- **Applying T‑SQL to a Fabric SQL database headlessly:** there's no need for `sqlcmd`. Use
  `pyodbc` + *ODBC Driver 18 for SQL Server* with an **Entra access token** for the SQL data plane
  (`az account get-access-token --resource https://database.windows.net/`), passed via
  `attrs_before={1256: <utf‑16‑le token struct>}`. `scripts/2a-apply-oee-target-schema.py` implements this
  and `2-setup-translytical.sh` calls it as a fallback. Resolve the server FQDN + DB name from
  `GET /v1/workspaces/{ws}/sqlDatabases/{id}` → `properties.serverFqdn` / `properties.databaseName`.

## Rayfin Fabric App (`app/`)

- The app deploys with the **Rayfin CLI**, not `azd`/Bicep: `npx rayfin up` → `npx rayfin up db apply`.
  There is **no `rayfin dev`** command in CLI 1.34 — use `npm run dev` (Vite) for local UI. Valid npm
  scripts: `rayfin:up`, `rayfin:db` (`up db apply`), `rayfin:static` (`up staticapp deploy`),
  `rayfin:status`, `rayfin:env`.
- **`app/rayfin/tsconfig.json` must emit to `.temp/compiled`** (`"outDir": ".temp/compiled"`). The CLI
  looks for compiled data models at `rayfin/.temp/compiled/data/*.js`; an outDir like `.temp/build`
  makes `rayfin up db apply` fail with "No … compiled/data/*.js files found".
- Env model: public vars live in `rayfin/.env` as `RAYFIN_PUBLIC_*`; `rayfin env` (auto‑run by
  `rayfin up`) emits `.env.local` with framework names — for Vite `RAYFIN_PUBLIC_FOO` → `VITE_RAYFIN_FOO`.
  Don't hand‑edit `.env.local`. `rayfin up` deploys the AppBackend **and its own managed Fabric SQL
  database** (that's where the app's `FloorEvent` table lives) — you don't create a SQL DB for it.
- Deployed apps use **Fabric SSO only**; local dev uses email/password.

## Fabric IQ — ontology, data agents, knowledge base

- **The ontology is the new TMDL experience** (`ontology/OEEFactoryOntology.Ontology/`, `.platform`
  `config.version` 2.0), published by `6-publish-ontology.py`. The old JSON entity‑type experience
  retires 2027‑01‑31 — don't author JSON parts.
- **Bindings (four sources, recognized by script 6 from each table's partition):**
  - lakehouse: `Sql.Database("<sql-endpoint>", "ManufacturingLH")` expression + directLake partition + the 8
    `ONT_*` annotations script 6 adds (with `AzureStorage.DataLake` the service strips 7 of them and the graph
    and the agents can't resolve the source);
  - Eventhouse (`MachineTelemetry`, `MaintenanceEvents`, `PartPassResults`): `= m` directQuery partition with
    `AzureDataExplorer.Contents(<query URI>, <db>, <table>)`, 6 `ONT_*` partition annotations
    (`ONT_ItemKind = KQLDatabase`, `ONT_ItemId` = the KQL database id) and a table-level `ONT_SourceSchema`;
    the lakehouse key column it joins to gets `isKey`;
  - SQL database (`OeeTarget` on `OeeGovernance`): the lakehouse shape on the database's SQL analytics
    endpoint, with `ONT_ItemKind = SQLDatabase`;
  - semantic model (`_Measures`): an expression named `DirectQuery to AS - <ws id>/<model id>`
    (`AnalysisServices.Database(...)` + cube navigation), an `entity` directQuery partition, 6 annotations
    with `ONT_ItemKind = Dataset`, and `measure 'X' = EXTERNALMEASURE("X", DOUBLE|INTEGER, "<expression>")`.
    Script 6 copies each measure's description, format, and `sourceLineageTag` from the model's TMDL and
    stops if the deployed model lacks one (needs Read and Build on the model). One `additionalBackingTable`
    per entity.
- **`OeeScorecard` must keep its `Value` property** (bound to `_Measures.Value`): a data agent attaches a
  source only through entity properties bound to it. The service accepts a property-less entity, but then the
  data agent never reaches the model (run step `ontology.context.datasources_attached` lists only
  LakehouseTables and Kusto).
- **Modeling limits:** one `keyProperty` per entity (no composite keys — derive a single key column).
  Inheritance: `baseEntityType: ns#Base`; `redefines: ns#Base.prop` on the property line;
  `overriddenMetadataField description` after the scalar properties. A derived entity that sets
  synonyms needs `overriddenMetadataField synonyms`.
- **Graph:** materialize it with the portal's **Manage graph**; it doesn't pick up new properties
  until you do that again (the ontology definition has no projection setting, and the graph item
  itself is read-only). Then `6-publish-ontology.py --refresh-graph`. The graph keeps the data
  sources it was materialized with (OneLake Delta paths in the GraphModel's `dataSources.json`) until the
  next Manage graph, so a binding change doesn't reach it before then. Entities bound to the
  Eventhouse or the semantic model aren't graph‑eligible (Microsoft documents lakehouse and
  mirrored-database Delta tables as the graph's sources), so `Machine` (telemetry), `PartPass`,
  `MaintenanceEvent`, `OeeScorecard`, and the abstract `Document` are left out. The current graph
  (materialized Nov 3) still loads `OeeTarget` from the lakehouse's `OeeTarget` shortcut; whether
  Manage graph keeps it now that it's bound to the `OeeGovernance` SQL database is unverified (no
  saved query uses it). GQL labels are
  `<ns>_<Entity>`; edges are `<ns>_<ns>_<Relationship>`. GQL status `02000` right after a refresh
  is transient.
- **Identity:** the ontology MCP endpoint and the ontology knowledge source accept user identities
  only (no service principals).
- **Data agent (script 7) — ontology as context:** the ontology is the agent's only source
  (`ontologies/<name>/ontology.json`; a `datasource.json` of type `ontology` is rejected). The agent writes
  KQL, SQL, or DAX against the item each entity is bound to. Script 7 mounts the Eventhouse and the
  lakehouse under the ontology (`ontologies/<name>/ontologydatasources/<item id>/datasource.json`, type
  `Eventhouse`/`Lakehouse`, with `fewshots.json` beside it), taking the item ids from the deployed ontology's
  `ONT_*` annotations, and publishes on the preview runtime (`stage_config.experimental.enableExperimentalFeatures`;
  `--runtime standard` for the GA runtime) — no portal step. A mounted Eventhouse exposes the whole KQL
  database, not just the bound tables. Semantic models take no data-agent context, so the model guidance
  (group by `DimLine[line_id]`/`StationDim[device_id]` and label from each row) is in the agent instructions.
  Data agents don't query SQL database-bound entities and the service rejects mounting one
  (updateDefinition "unknown error"), so OEE targets come from the model's `Target OEE` measure. Never write
  values into a query as data: without a reachable source the preview runtime once emitted
  `project target_OEE = 0.85`. NL2KQL can't see stored functions, so script 7 inlines
  `OeeFacts`/`OeeKpis` as `let` statements in its example queries and runs each example against the
  Eventhouse before publishing. "Latest hour of data" windows end
  at `max(timestamp)` (or `max(passed_at)` for `PartPasses`) because `ago()` windows are empty when
  the simulator isn't streaming. The agent's ontology context carries entities, properties, relationships,
  and bindings but not rules, so script 7 renders the ontology's rules, metric names, and time-series
  properties into the agent's instructions at publish time (the readback TMDL is CRLF: normalize before
  regex parsing, or the lists come out empty). The data agent refreshes the ontology context every 10 minutes.
  The orchestrator rewrites each question for the source it picks; when it prescribes a method
  ("four consecutive buckets in the latest hour"), the generator improvises and gets duration rules
  wrong. So the instructions route every duration or rolling-window rule check to the Eventhouse
  in the user's words, and its example query measures minutes since the last 5-minute bucket at or
  above 60%. Time in a state is samples × 10 s, never timestamp differences (telemetry has gaps).
  Debug a wrong answer with `--ask "<question>" --show-queries` (attached sources, example queries loaded, and
  the KQL/SQL/DAX it ran; DAX is in the `askPBI.tool.execute` call's `code` argument).
- **Foundry IQ knowledge base (script 10, api‑version `2026-08-01-preview`):** the `fabricOntology`
  source runs a live NL query over the ontology's data per request and gives up after its own 100 s
  timeout. The agent's MCP retrieve sets no runtime, so the 90 s service default failed whole agent
  responses: script 10 stores `retrieveDefaults.maxRuntimeInSeconds` (150), and its retrieval
  instructions keep procedure and KPI questions off the ontology source. `minimal` retrieval effort
  isn't supported with an ontology source.
- **Foundry agent (script 10):** the Fabric IQ tool (`azure-ai-projects>=2.2.0`) reaches the ontology
  and the data agent through RemoteTool connections with `UserEntraToken` auth (audience
  `https://analysis.windows.net/powerbi/api`). Background mode needs `gpt-5.4`/`gpt-5.5`, and gpt‑5.x
  deployments reject `temperature`/`top_p`. After editing `agent/system-prompt.md`, re‑run with
  `--replace` (new agent version) and then script 12.
- **Operations agent (script 11):** the definition part is `Configurations.json` with exactly one
  data source, keyed by the source item's GUID (an alias key fails playbook generation with "must be
  a canonical GUID"). The source is the `ManufacturingEH` KQL database, not the ontology: an
  ontology source can evaluate only a property's latest value (no aggregations), and every alert
  rule here counts events or computes a rate over a window. **Each alert rule is checked by a
  stored function `Rule<RuleName>()` in the Eventhouse's `Rules` folder** (script 1; script 11 exits
  if one is missing). Each returns one row per reporting station or line (LineOeeEscalation: one per
  line and escalation tier), keyed by `alert_id`, with `fired` true where the rule fires and every
  message field; the agent alerts when `fired` becomes true, once per episode, instead of at every
  5-minute check (each alert is an LLM call of about 7,600 tokens). Without them, the playbook generator built its
  own windowed queries, dropped joins, and failed different rules on every attempt, even with the
  logic spelled out. The generator still fails one to six rules per attempt unless each rule's entry
  in the instructions names its condition column and message columns: every function returns
  `fired` and `alert_id`, and script 11 renders each rule's columns from the function's live output schema
  (`Rule<Name>() | getschema`), after which all six bind. Script 11 retries a failed generation up to
  three times, then checks that every rule's query calls its function as of the current time (no
  argument, `datetime(null)`, or `endTime`); as of `startTime`, the agent's long check window misses
  new events. Generation fails for every rule while the capacity is throttled, because it can't read
  the functions. Script 11 generates the
  playbook through the agent's MCP endpoint (`/v1/mcp/workspaces/{ws}/operationsAgents/{id}/configure`:
  `generate_playbook`, then poll `get_generate_playbook_status` until `Completed`; 2–15 minutes).
  A generation orphaned by a capacity pause stays `InProgress` and makes `generate_playbook` fail
  with an internal error; writing the configuration again clears it (script 11 does this
  automatically). Never send `playbook` back from a readback (item references come back as the
  zero GUID; `{}` is rejected): even the readback playbook with one rule's query fixed failed with
  HTTP 500 and cleared the playbook, so a bad rule means generating again. For "fired becomes true"
  the generator emits the transition condition `propertychangechangestotrue` (one alert per
  episode); it once called a function with a fixed `datetime(...)` it had evaluated, which the
  instructions now forbid and script 11's check rejects. Start and stop with MCP `start_agent` / `stop_agent`
  (`--start` / `--stop`); it's left stopped so it doesn't use capacity.
- **The operations agent samples each rule every 5 minutes**, so a condition must hold for well over
  5 minutes to be caught: the simulator's scenario durations (`simulator.yaml` `scenarios:`) are
  sized for that. Its query keeps a rule's rows whose `checked_at` is between `startTime` and
  `endTime`, and runs just after `endTime`, so a row stamped with the query's own `now()` is dropped:
  that's why RejectRateQuarantine, RepeatFaults, and ConcurrentOpenWorkOrders never alerted until the
  rule functions defaulted to evaluating as of `now() - 1m`. Check alert noise by replaying the checks (`Rule<Name>(asOf)` at 5‑minute steps)
  before demoing. Two fixes came from that: `RuleStationOeeEscalation` uses the policy's
  Availability (`samples - idle`, from `OeeFacts().idle`), because starved/blocked time counts
  against the station that caused it — with measured Availability about half the stations escalated
  at any moment; and `RuleRejectRateQuarantine` needs at least 3 rejects, since one random reject at
  a ~20 parts/hour station exceeds twice its target. The data agent's station and reject examples
  (script 7) match these. A third came from replaying episodes (`fired` per `alert_id` across checks):
  the OEE rules evaluate complete 5‑minute buckets only, and count a bucket with Availability 0 or no
  finished or rejected part as OEE 0 (a station's wholly idle bucket is left out). Before that, the
  in-progress bucket and null-Quality buckets flipped `fired` off and back on within one episode, so
  the agent alerted on it again. Changing a function body needs no playbook regeneration if its name and
  output columns stay the same; changing an alert rule's statement in the ontology does.
- **Eventhouse streaming ingestion is on**, so update policies can't look up or join other tables —
  enrich per row from the payload (script 1).
- **OneLake mirror reseed gap:** each script 1 run reseeds the reference tables; their OneLake
  copies are empty for about 7 minutes, so the ontology and the model briefly show no reference data.
- **The ontology reads its lakehouse-bound entities through the lakehouse SQL analytics endpoint**
  (`Sql.Database` binding), so the plant's records trail the Eventhouse by the OneLake export
  (`TargetLatencyInMinutes` 5) plus the endpoint's metadata sync; telemetry, work order steps, and part
  passes are Eventhouse-bound and live. The legacy sync stops after 15 minutes without queries; the next
  query reads tables as of the last sync (hours old was seen for `MaintenanceEvents`/`PartEvents`) while it
  catches up over about a minute. `POST .../sqlEndpoints/{id}/refreshMetadata?preview=true` or the portal's
  **Refresh** wakes it. `WorkOrder` (lakehouse) records only how a work order was raised; "is it open"
  comes from its latest `MaintenanceEvent` step, which the instructions route to ManufacturingEH.
- **OEEAnalytics can stop framing after throttling.** Direct Lake auto-framing failed during a throttled
  window and didn't retry, so the report and the model's KPIs went stale for days. Script 4 reframes;
  check the model's row counts against KQL when KPIs look old.

## Agent evaluation (`12-evaluate-agent.py`)

- Responses are generated locally as the signed‑in user (the Fabric IQ tools need the user's
  identity, which a server‑side agent‑target evaluation can't provide), then judged in the Foundry
  evaluation "oee-factory-iq persona set" by `gpt-5.4-mini` — a different model from the agent's.
- `agent/evals/cases.json` is the single source for the questions and `docs/demo/sample-questions.md`
  (`--write-samples`; don't edit the page by hand). Data facts come from `facts_kql` at run time —
  never copy seed values into it.
- Bump `CRITERIA_VERSION` in script 12 when the item schema or the criteria change, so runs judged
  differently don't share an evaluation.
- Map every field an evaluator supports when the items carry it, or the run fails with
  `MissingRequiredDataMapping` (e.g. groundedness needs `tool_definitions` mapped).
- `responses.retrieve` can return 404 right after a background `responses.create` — retry.
- Results land in `agent/evals/results/` (git‑ignored). See `agent/evals/README.md`.

## Portal‑only manual steps (cannot be scripted)

- **Publish the Eventstream** after script 1 if it isn't already Running.
- **Ontology → Manage graph** to materialize the graph (and again after adding properties).
- **Install the Fabric Operations Agent Teams app** for the operations agent's recipient.
- **Start the WPF simulator** (`simulator/FabricOEESimulator.Wpf`, `dotnet run`, click **Start**) —
  it's a Windows GUI with no headless mode. Its Eventstream connection string comes from the
  `oee-simulator` custom endpoint (Fabric REST: `GET .../eventstreams/{id}/sources/{sourceId}/connection`
  returns `accessKeys.primaryConnectionString`) and goes in the git‑ignored `simulator.local.yaml`.
- **`OeeGovernance` schema, `OeeTarget` shortcut, and the write‑back button are all scripted now**
  (`2-setup-translytical.sh` + `2a-apply-oee-target-schema.py` for the SQL/shortcut;
  `4-setup-powerbi.sh` bakes the button into the report — run script 2 *before* script 4). The Floor
  Ops Console's `FloorEvent` shortcut (from the app's managed SQL DB) is likewise scripted via
  `3-setup-floor-ops.sh`. The report opens and shows the current target regardless.

## Documentation site (`docs/`)

- Built with **Zensical** from `docs/` and `mkdocs.yml` (Material for MkDocs config format, so
  Material stays a fallback); `.github/workflows/docs.yml` publishes it to GitHub Pages on pushes to
  `main` that touch the site. Local build: `pip install -r docs/requirements.txt`, then
  `zensical build --clean` (or `zensical serve`). Keep the build free of warnings.
- Every page must be in the `nav` in `mkdocs.yml`. **Link to repo files outside `docs/` with full
  GitHub URLs** (`https://github.com/howardginsburg/FabricOEEDemo/blob/main/<path>`); relative links
  outside `docs/` break the build.
- Each fact lives on one page: the setup steps own the commands, `demo/factory-floor.md` owns the
  scenario table, `demo/operations-agent.md` owns the rule table; other pages link to them.
- Screenshots live in `docs/assets/screenshots/{setup,demo}/`. The repo is public: blur account
  names, emails, and tenant identifiers, and never show keys.

## Conventions

- **Never commit secrets.** Connection strings/keys go only in git‑ignored files
  (`simulator.local.yaml`, `app/rayfin/.env`, `app/.env.local`). Verify with `git check-ignore`.
- Prefer **idempotent** REST calls and re‑running the relevant script over ad‑hoc fixes.
- **Clean up test artifacts** you create in Fabric (e.g. throwaway reports) when done.
- When validating end‑to‑end, check the KQL Silver tables directly
  (`.../v1/rest/query` against the Eventhouse cluster) and the model with `executeQueries`, rather
  than relying on the portal UI (which can be flaky in embedded browsers and cache stale item lists).
