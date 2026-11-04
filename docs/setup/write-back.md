# 3. OEE target write-back

This step lets a manager set a line's OEE target from inside the Power BI report. A button on the report calls
a Fabric user data function, which writes the target to a Fabric SQL database. The database mirrors to
OneLake, and a lakehouse shortcut lets the report read the new target within minutes.

Run it **before** [step 5](power-bi.md): the report's write-back button needs the user data function, and the
semantic model's `Target OEE` measure needs the `OeeTarget` table.

## Run it

```bash
bash scripts/2-setup-translytical.sh --workspace-name "<FABRIC_WORKSPACE>"
```

It creates:

| Item | Type | What it holds |
|---|---|---|
| `OeeGovernance` | SQL database | `dbo.OeeTarget`, seeded with a target for each line |
| `OeeTargetFunctions` | User data functions | `set_oee_target(lineId, targetOee, setBy)`, which upserts a line's target |
| `OeeTarget` | Lakehouse shortcut | The mirrored `dbo.OeeTarget`, at `ManufacturingLH/Tables/dbo/OeeTarget` |

The script creates the table with `sqlcmd` when it's installed. Otherwise it runs
`scripts/2a-apply-oee-target-schema.py`, which needs `pyodbc` and ODBC Driver 18. You can also run that
script yourself:

```bash
python3 scripts/2a-apply-oee-target-schema.py --workspace-name "<FABRIC_WORKSPACE>"
```

The shortcut appears once the database's mirror has exported the table, usually a minute or two after the rows
are written; the script waits for it.

## Verify

- In the `OeeGovernance` SQL database, `SELECT * FROM dbo.OeeTarget` returns one row per line.
- The `OeeTargetFunctions` item shows `set_oee_target` as published.
- `ManufacturingLH` lists `OeeTarget` under **Tables > dbo**.

!!! warning "Preview features"
    User data functions, Fabric SQL databases, and the report's data function buttons (translytical task
    flows) can be gated by tenant settings, capacity region, and preview availability. If the script can't
    create an item, it prints the portal steps instead. The function reaches the database through a connection
    with the alias `OeeGovernance`. The deployed definition includes it, but a preview tenant can still ask you
    to set it up in the portal: open `OeeTargetFunctions`, select **Manage connections**, and make sure the
    `OeeGovernance` alias points to the `OeeGovernance` database.

## Learn more

- [User data functions programming model](https://learn.microsoft.com/fabric/data-engineering/user-data-functions/python-programming-model)
- [Create a data function button in Power BI](https://learn.microsoft.com/power-bi/create-reports/translytical-task-flow-button)
- [Connect user data functions to data sources](https://learn.microsoft.com/fabric/data-engineering/user-data-functions/connect-to-data-sources)
