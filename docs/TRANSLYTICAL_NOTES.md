# Translytical OEE target write-back

Component C lets a manager set a per-line OEE target from inside the Power BI report. The button invokes the Fabric User Data Function `set_oee_target`, which upserts a row in `OeeGovernance.dbo.OeeTarget`. Fabric SQL database mirroring exposes that table in OneLake, and `scripts/3-setup-translytical.sh` shortcuts it into `ManufacturingLH/Tables/dbo/OeeTarget` so the existing Direct Lake semantic model can evaluate `Target OEE` and `OEE vs Target`.

## Flow

1. Manager opens `OEEAnalytics` and filters the Executive page (`page-exec`) to a line.
2. Manager enters an OEE target as a fraction, for example `0.82`.
3. A Power BI **data function** button calls `set_oee_target(lineId, targetOee, setBy)`.
4. The UDF uses the `OeeGovernance` Fabric SQL connection alias and parameterized SQL to upsert `dbo.OeeTarget`.
5. The mirrored table is read through the OneLake shortcut at `ManufacturingLH/Tables/dbo/OeeTarget`.
6. Direct Lake visuals show actual OEE against the latest target.

## Setup

Run after the Fabric foundation and Power BI deployment:

```bash
bash scripts/3-setup-translytical.sh --workspace-name "<FABRIC_WORKSPACE>"
```

The script is safe to re-run. It creates or finds:

- Fabric SQL database item `OeeGovernance`.
- Table `dbo.OeeTarget` with seed targets for `Line-A` through `Line-E`.
- User Data Functions item `OeeTargetFunctions` with function `set_oee_target`.
- OneLake shortcut `ManufacturingLH/Tables/dbo/OeeTarget`.

If REST deployment is blocked by tenant, capacity, or preview availability, the script prints portal fallback steps. Automatic `dbo.OeeTarget` creation uses `sqlcmd` if present and otherwise falls back to `scripts/apply-oee-target-schema.py` (pyodbc + Entra token — needs the *ODBC Driver 18 for SQL Server*); if neither is available, run `powerbi/translytical/OeeTarget.schema.sql` from the Fabric SQL database T-SQL editor, or:

```bash
python scripts/apply-oee-target-schema.py --workspace-name "<FABRIC_WORKSPACE>"
```

The OneLake shortcut step retries while the Fabric SQL DB mirror materializes (a minute or two after the rows are written) and then refreshes the lakehouse SQL analytics endpoint so Direct Lake sees `dbo.OeeTarget`.

## Report integration (already checked in)

The `OEEAnalytics` report's Executive page already visualizes the target once `dbo.OeeTarget` exists
and is shortcut into the lakehouse:

- **OEE vs Target by Line** — the `OEE by Line` column chart carries both `[OEE]` and `[Target OEE]` series.
- **Target OEE** card — shows `[Target OEE]` for the current line/shift selection.

These use the model measures `Target OEE = AVERAGE(OeeTarget[target_oee])` and
`OEE vs Target = [OEE] - [Target OEE]`. They read the *current* target; the interactive **write‑back
button** below is what lets a manager change it.

## Power BI Desktop / service wiring (the write‑back button)

The data‑function button is the one piece that must be authored interactively (Power BI Desktop **or**
the Power BI service report editor) — its report‑definition (PBIR) action binding isn't part of the
checked‑in report. Everything it needs is already provisioned: the `OeeTargetFunctions` UDF, the
`dbo.OeeTarget` table, the OneLake shortcut, and the target visuals.


1. Open `powerbi/OEEAnalytics.pbip` in Power BI Desktop.
2. Open the Executive page (`page-exec`).
3. Add or reuse a line selector:
   - Use the existing line slicer or a small line table visual.
   - Bind the selected line to the UDF parameter `lineId`.
4. Add a target input:
   - Use a numeric what-if parameter or numeric slicer named like **New target OEE**.
   - Configure values from `0.00` to `1.00`, step `0.01`, formatted as a percentage if desired.
   - Bind it to `targetOee`.
5. Add a `setBy` input:
   - Use a text parameter if available, or a hidden/default value such as the manager UPN for demos.
   - Bind it to `setBy`.
6. Insert **Buttons → Data function**.
7. Choose workspace `<FABRIC_WORKSPACE>`, function set `OeeTargetFunctions`, and data function `set_oee_target`.
8. Map:
   - `lineId` → selected line (`DimLine[line_id]` / slicer selection)
   - `targetOee` → numeric target input
   - `setBy` → user/default text input
9. Publish the report and test in the Power BI service. Desktop can configure the button, but execution is service-side after publish.

## Preview and gating caveats

- Fabric User Data Functions require a Fabric capacity in a supported region and a workspace assigned to that capacity.
- The UDF item must be published before Power BI can call it.
- The UDF `OeeGovernance` connection alias must point to the `OeeGovernance` Fabric SQL database. The source definition includes this alias, but portal connection management might still be required in preview tenants.
- Power BI data function buttons require the referenced UDF to return `str`; `set_oee_target` returns a friendly success string.
- Translytical task flows and Fabric User Data Functions are tenant/capacity gated preview features in many environments. If the button or UDF tile is missing, check tenant settings, capacity region, and preview feature availability.
- Data function buttons store an explicit reference to a workspace, function set, and data function. After moving or redeploying the report, rebind the button to the target workspace's UDF item.

## Source files

- `powerbi/translytical/OeeTarget.schema.sql` creates and seeds `dbo.OeeTarget`.
- `powerbi/translytical/functions/set_oee_target/functions.py` contains the decorated UDF.
  Its **input parameter names are camelCase** (`lineId`, `targetOee`, `setBy`) because Fabric
  User Data Functions reject underscores in parameter names — deployment fails validation with
  `MetadataValidationError: input parameter '<name>' cannot contain an underscore`. The SQL
  **column** names (`line_id`, `target_oee`, `set_by`) keep underscores; only the function
  parameters are constrained.
- `powerbi/translytical/functions/set_oee_target/definition.json` and `resources/functions.json` follow the Fabric User Data Function item definition shape. The setup script injects the resolved workspace and SQL database item IDs before deployment.
- `scripts/3-setup-translytical.sh` provisions the SQL database, publishes the UDF best-effort, and creates the OneLake shortcut.

## Microsoft documentation grounding

- Fabric User Data Functions use `fabric.functions`, `fn.UserDataFunctions()`, and `@udf.function()`; functions used by Power BI data function buttons must return a string. See [Fabric user data function programming model overview](https://learn.microsoft.com/fabric/data-engineering/user-data-functions/python-programming-model) and [Create a data function button in Power BI](https://learn.microsoft.com/power-bi/create-reports/translytical-task-flow-button).
- Fabric UDF data connections use `@udf.connection(argName="...", alias="...")` and support Fabric SQL databases for read/write operations. See [Connect to data sources from your Fabric User data functions item](https://learn.microsoft.com/fabric/data-engineering/user-data-functions/connect-to-data-sources).
- The UDF item definition parts include `definition.json`, `resources/functions.json`, and `function_app.py`. See [User Data Function definition](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/user-data-function-definition).
- SQL database creation is exposed as `POST /v1/workspaces/{workspaceId}/sqlDatabases`, with item type `SQLDatabase`. See [Items - Create SQL Database](https://learn.microsoft.com/rest/api/fabric/sqldatabase/items/create-sql-database).
- Shortcuts and mirroring can be combined so mirrored database tables are consumed from a lakehouse without another copy; shortcuts to mirrored tables are read-only and writes go to the source database. See [Unify data with OneLake shortcuts and mirroring](https://learn.microsoft.com/fabric/onelake/unify-data) and [Explore data in your mirrored database with notebooks](https://learn.microsoft.com/fabric/mirroring/explore-onelake-shortcut).
