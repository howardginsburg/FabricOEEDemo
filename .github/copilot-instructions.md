# Copilot instructions — Fabric OEE Demo

Guidance for AI agents working in this repo. It captures hard‑won, non‑obvious lessons from
building and deploying this demo so you don't rediscover them. Read this before running any
`scripts/*` or touching `powerbi/`, `app/`, or the translytical function.

## What this repo is
A real‑time **OEE** (Overall Equipment Effectiveness) demo on Microsoft Fabric. A .NET 10 WPF
simulator streams factory telemetry → Fabric Eventstream → Eventhouse/KQL (Bronze→Silver) →
Real‑Time Dashboard + a Direct Lake Power BI model. Optional layers: Fabric IQ ontology + Data
Agent, a Foundry prompt agent over Azure AI Search SOPs, a translytical write‑back UDF, and a
Rayfin Fabric App. See `README.md` for the full architecture and the script reference table.

Deployment order: `scripts/1-setup-fabric.sh` (always first) → `2-setup-powerbi.sh` →
`3-setup-translytical.sh` → `4-setup-foundry.sh` → `5-setup-aisearch.sh` →
`6/7` (ontology + data agent, also auto‑run by script 1) → `8-setup-foundry-agent.py`.
All setup scripts are meant to be **idempotent** — re‑running is the normal recovery path.

---

## Environment & tooling (Windows) — read first

- **Run the bash scripts under WSL, not Git Bash.** The scripts detect the `az` binary and do
  Windows↔Linux temp‑path conversion (`wslpath`, `/mnt/c/...`). Under Git Bash, `az` resolves to
  a wrapper (`.../wbin/az`) that breaks the scripts' `@file` body handling. WSL Ubuntu has a
  native `/usr/bin/az` and works correctly. Typical invocation:
  `wsl.exe -d Ubuntu-24.04 -- bash -lc 'cd "/mnt/c/.../FabricOEEDemo" && bash scripts/1-setup-fabric.sh --workspace-name "OEE Demo"'`
- **`az` must be logged in in whichever shell runs the scripts** (WSL and Windows are separate
  logins). The Fabric scripts need `az login`; Foundry (script 4) needs **Azure CLI ≥ 2.67**.
- **`python3` on Windows** may resolve to the broken Microsoft Store stub while `python` works.
  In WSL, `python3` is fine but is externally managed (PEP 668 — use `--break-system-packages`
  or a venv). For script 8 deps install into the *Windows* Python you actually run it with:
  `pip install azure-ai-projects azure-identity openai httpx`.
- **Windows console is cp1252** — Python scripts that print box‑drawing chars (`──`) crash with
  `UnicodeEncodeError`. Run them with `PYTHONUTF8=1` (e.g. script `8-setup-foundry-agent.py`).
- **WSL `/tmp` is cleared between separate `wsl.exe` invocations.** Don't rely on a temp file
  written in one call being present in the next — do multi‑step work inside a single script, or
  write intermediates under the repo/session folder.
- The `.fabric-tmp/` dir is the scripts' scratch space and self‑cleans; it's git‑ignored.

## Fabric REST API patterns

- **Item create / `updateDefinition` are async (HTTP 202).** The response body is empty; the real
  result comes from polling the long‑running operation. **Never fire‑and‑forget** — poll
  `GET /v1/operations/{x-ms-operation-id}` until `status == Succeeded`/`Failed`, and read
  `/operations/{id}/result` for the error. Swallowing the 202 hides validation errors and makes a
  failed deploy look successful (this bit us in `3-setup-translytical.sh` — the UDF silently
  never created). `scripts/3` now has an `fabric_lro_post` helper; reuse that pattern.
- **`POST .../getDefinition` needs `Content-Length: 0`** or it returns `HTTP 411 Length Required`.
- Tokens: Fabric API resource is `https://api.fabric.microsoft.com`; Power BI API resource is
  `https://analysis.windows.net/powerbi/api`; a KQL cluster's resource is its own cluster URI.
- Resolve a **Fabric capacity id** from `GET /v1/capacities` by `displayName`; create a workspace
  with `POST /v1/workspaces {displayName, capacityId}` to bind it to that capacity.

## Azure region / quota gotchas (seen in Central US)

- **`gpt-4.1` has no GlobalStandard (consumption) quota in some regions** (incl. centralus) — only
  Batch. `4-setup-foundry.sh` runs a quota preflight; if it flags 0, pass the widely‑available
  fallback: `--chat-model gpt-4o --chat-model-version 2024-11-20`. `text-embedding-3-large` quota
  is usually fine. Check with `az cognitiveservices usage list -l <region>`.
- **Azure AI Search** can be capacity‑constrained in a region (`InsufficientResourcesAvailable`).
  `5-setup-aisearch.sh` supports `--search-location <other-region>` (it reads storage + calls AOAI
  cross‑region).
- **Storage `publicNetworkAccess`** may be force‑disabled by an org **Azure Policy** (a `modify`
  effect that reverts your update via ARM). Symptoms: blob container create / the AI Search indexer
  fail with 403 "blocked by network rules". Re‑enable with an ARM PATCH
  (`properties.publicNetworkAccess=Enabled`) and run the upload/index promptly. If the policy keeps
  reverting it, the human operator may need to enable it.
- **AI Search indexer 403 "credentials invalid or expired"** right after service creation is RBAC
  propagation lag for the search managed identity (Storage Blob Data Reader). Wait for the role to
  propagate, then re‑run `5-setup-aisearch.sh` (idempotent) to create + run the indexer.

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
  band‑aid (needs ~1–2 min to propagate and a failed enhanced‑refresh can undo it). `2-setup-powerbi.sh`
  keeps a rebind as a *safety net that runs last*, but the real fix is the format above.

## Direct Lake behavior

- **Direct Lake auto‑frames on query** — after new telemetry streams, on‑demand queries
  (`POST /datasets/{id}/executeQueries`, and report visuals) reflect the latest data without a
  successful reframe. Don't block on the reframe for data freshness.
- **Background reframe (`POST /datasets/{id}/refreshes`) fails for API‑deployed Direct Lake models**
  ("We cannot access the source Delta table …", rotating table names). This is a known limitation of
  the deployment path, not a data problem. `2-setup-powerbi.sh` polls/retries it best‑effort and, on
  failure, prints guidance; it does **not** gate anything. The portal's interactive "Refresh" (SSO)
  works where the background call doesn't.
- A **full** reframe also fails if the model contains tables bound to Delta sources that don't exist
  yet (see `OeeTarget` / `DowntimeReason` below). Those tables show `Invalid object name` until their
  OneLake shortcuts exist; they don't block the report from opening.

## Fabric User Data Functions (translytical `set_oee_target`)

- **UDF input parameter names cannot contain underscores.** Fabric validation rejects them
  (`MetadataValidationError: input parameter '<name>' cannot contain an underscore`). Use camelCase
  for the function signature (`lineId`, `targetOee`, `setBy`); SQL **column** names keep underscores.
- **The `@udf.connection(alias=…)` value must be an inline alphanumeric string literal.** The
  validator reads decorators statically, so a module constant (`alias=OEE_GOVERNANCE_ALIAS`) fails as
  "not a valid Alphanumeric string". Inline it: `alias="OeeGovernance"`.
- Deploying the UDF via the Items API is async — poll the LRO (see Fabric REST patterns) or the real
  validation errors above are silently swallowed.
- **Nothing auto‑invokes the UDF.** The trigger is a Power BI **data‑function button** — an
  interactive Desktop/service authoring element (its PBIR action binding isn't checked in). The read
  side is wired: `dbo.OeeTarget` → OneLake mirror → `ManufacturingLH/Tables/dbo/OeeTarget` shortcut →
  model measures `Target OEE` / `OEE vs Target` → the report's "OEE vs Target by Line" chart + "Target
  OEE" card. Only the write‑back button is manual.
- **Applying T‑SQL to a Fabric SQL database headlessly:** there's no need for `sqlcmd`. Use
  `pyodbc` + *ODBC Driver 18 for SQL Server* with an **Entra access token** for the SQL data plane
  (`az account get-access-token --resource https://database.windows.net/`), passed via
  `attrs_before={1256: <utf‑16‑le token struct>}`. `scripts/apply-oee-target-schema.py` implements this
  and `3-setup-translytical.sh` calls it as a fallback. Resolve the server FQDN + DB name from
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
  database** (that's where the app's `DowntimeReason` table lives) — you don't create a SQL DB for it.
- Deployed apps use **Fabric SSO only**; local dev uses email/password.

## Portal‑only manual steps (cannot be scripted)

- **Publish the Eventstream** after script 1 if it isn't already Running.
- **Attach the ontology to the Data Agent and Publish it** — the Fabric public REST API has no
  endpoint for these two actions. The published Data Agent URL
  (`.../groups/<workspace-id>/aiskills/<artifact-id>`) provides the GUIDs script 8 needs.
- **Start the WPF simulator** (`simulator/FabricOEESimulator.Wpf`, `dotnet run`, click **Start**) —
  it's a Windows GUI with no headless mode. Its Eventstream connection string comes from the
  `oee-simulator` custom endpoint (Fabric REST: `GET .../eventstreams/{id}/sources/{sourceId}/connection`
  returns `accessKeys.primaryConnectionString`) and goes in the git‑ignored `simulator.local.yaml`.
- **`OeeGovernance` schema + `OeeTarget` shortcut are now scripted** (`3-setup-translytical.sh` +
  `apply-oee-target-schema.py`), but the **translytical write‑back button** and the `DowntimeReason`
  shortcut (from the Rayfin app's managed SQL DB) remain manual. The report opens and shows the
  current target without the button; only interactive target‑setting and the downtime‑reason visuals
  need those.

## Conventions

- **Never commit secrets.** Connection strings/keys go only in git‑ignored files
  (`simulator.local.yaml`, `app/rayfin/.env`, `app/.env.local`). Verify with `git check-ignore`.
- Prefer **idempotent** REST calls and re‑running the relevant script over ad‑hoc fixes.
- **Clean up test artifacts** you create in Fabric (e.g. throwaway reports) when done.
- When validating end‑to‑end, check the KQL Silver tables directly
  (`.../v1/rest/query` against the Eventhouse cluster) and the model with `executeQueries`, rather
  than relying on the portal UI (which can be flaky in embedded browsers and cache stale item lists).
