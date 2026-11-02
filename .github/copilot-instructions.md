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
write‑back UDF, a Rayfin Fabric App, an Activator alert, and an Event Schema Set. See `README.md`
for the architecture and the script reference table, and `docs/FABRIC_IQ_DESIGN.md` for the
Fabric IQ design.

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

- **Data agent:** about 66K uncached prompt tokens per question, about 7K CU-s. A full script 12 run is
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
  immediately, so space heavy runs out instead.

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
  effect that reverts your update via ARM). Symptoms: blob container create / the AI Search indexer
  fail with 403 "blocked by network rules". Re‑enable with an ARM PATCH
  (`properties.publicNetworkAccess=Enabled`) and run the upload/index promptly. If the policy keeps
  reverting it, the human operator may need to enable it.
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
- **Bindings:** each table partition uses a `Sql.Database("<sql-endpoint>", "ManufacturingLH")`
  expression plus the 8 `ONT_*` annotations script 6 adds. With `AzureStorage.DataLake` the service
  strips 7 of them and the graph and the data agent can't resolve the source. One
  `additionalBackingTable` per entity.
- **Modeling limits:** one `keyProperty` per entity (no composite keys — derive a single key column).
  Inheritance: `baseEntityType: ns#Base`; `redefines: ns#Base.prop` on the property line;
  `overriddenMetadataField description` after the scalar properties. A derived entity that sets
  synonyms needs `overriddenMetadataField synonyms`.
- **Graph:** materialize it with the portal's **Manage graph**; it doesn't pick up new properties
  until you do that again (the ontology definition has no projection setting, and the graph item
  itself is read-only). Then `6-publish-ontology.py --refresh-graph`. Only keyed entities with
  one backing table are graph‑eligible: keyless `PartPass`/`MaintenanceEvent`, the abstract
  `Document`, and `Machine` (its telemetry is a second backing table) are left out. GQL labels are
  `<ns>_<Entity>`; edges are `<ns>_<ns>_<Relationship>`. GQL status `02000` right after a refresh
  is transient.
- **Identity:** the ontology MCP endpoint and the ontology knowledge source accept user identities
  only (no service principals).
- **Data agent (script 7):** NL2KQL can't see stored functions, so script 7 inlines
  `OeeFacts`/`OeeKpis` as `let` statements in its example queries. "Latest hour of data" windows end
  at `max(timestamp)` (or `max(passed_at)` for `PartPasses`) because `ago()` windows are empty when
  the simulator isn't streaming. Script 7 attaches the ontology (an `ontologies/<name>/ontology.json`
  part; a `datasource.json` of type `ontology` is rejected) and publishes — no portal step. The
  ontology source exposes entity data but not rules, so script 7 renders the ontology's rules,
  metric names, and time-series properties into the agent's instructions at publish time.
  The orchestrator rewrites each question for the source it picks; when it prescribes a method
  ("four consecutive buckets in the latest hour"), the generator improvises and gets duration rules
  wrong. So the instructions route every duration or rolling-window rule check to the Eventhouse
  in the user's words, and its example query measures minutes since the last 5-minute bucket at or
  above 60%. Time in a state is samples × 10 s, never timestamp differences (telemetry has gaps).
  Debug a wrong answer from the run steps' tool calls (`analyze.database.nl2code` holds the generated
  query); a newly published ontology property can take a few minutes to reach the agent's context.
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
  if one is missing). Each returns one row per firing station or line with every message field, and
  counts only stations or lines that are reporting. Without them, the playbook generator built its
  own windowed queries, dropped joins, and failed different rules on every attempt, even with the
  logic spelled out. With them, all six rules bound on the first attempt. Script 11 generates the
  playbook through the agent's MCP endpoint (`/v1/mcp/workspaces/{ws}/operationsAgents/{id}/configure`:
  `generate_playbook`, then poll `get_generate_playbook_status` until `Completed`; 2–15 minutes).
  A generation orphaned by a capacity pause stays `InProgress` and makes `generate_playbook` fail
  with an internal error; writing the configuration again clears it (script 11 does this
  automatically). Never send `playbook` back from a readback (item references come back as the
  zero GUID; `{}` is rejected). Start and stop with MCP `start_agent` / `stop_agent`
  (`--start` / `--stop`); it's left stopped so it doesn't use capacity.
- **Eventhouse streaming ingestion is on**, so update policies can't look up or join other tables —
  enrich per row from the payload (script 1).
- **OneLake mirror reseed gap:** each script 1 run reseeds the reference tables; their OneLake
  copies are empty for about 7 minutes, so the ontology and the model briefly show no reference data.

## Agent evaluation (`12-evaluate-agent.py`)

- Responses are generated locally as the signed‑in user (the Fabric IQ tools need the user's
  identity, which a server‑side agent‑target evaluation can't provide), then judged in the Foundry
  evaluation "oee-factory-iq persona set" by `gpt-5.4-mini` — a different model from the agent's.
- `agent/evals/cases.json` is the single source for the questions and `agent/samples/queries.md`
  (`--write-samples`). Data facts come from `facts_kql` at run time — never copy seed values into it.
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

## Conventions

- **Never commit secrets.** Connection strings/keys go only in git‑ignored files
  (`simulator.local.yaml`, `app/rayfin/.env`, `app/.env.local`). Verify with `git check-ignore`.
- Prefer **idempotent** REST calls and re‑running the relevant script over ad‑hoc fixes.
- **Clean up test artifacts** you create in Fabric (e.g. throwaway reports) when done.
- When validating end‑to‑end, check the KQL Silver tables directly
  (`.../v1/rest/query` against the Eventhouse cluster) and the model with `executeQueries`, rather
  than relying on the portal UI (which can be flaky in embedded browsers and cache stale item lists).
