# 5. Power BI report

This step deploys the `OEEAnalytics` semantic model and its report. The model uses **Direct Lake on OneLake**:
it reads the lakehouse's Delta tables directly, with no import and no scheduled refresh, so the report follows
the live stream within minutes.

## Run it

```bash
bash scripts/4-setup-powerbi.sh --workspace-name "<FABRIC_WORKSPACE>"
```

The script:

1. Adds the `device_id` station key to the `StationMaster` reference table, if it's missing, and syncs the
   lakehouse's SQL analytics endpoint.
2. Deploys the semantic model from `powerbi/OEEAnalytics.SemanticModel`, pointed at your lakehouse.
3. Deploys the report from `powerbi/OEEAnalytics.Report`. When the `OeeTargetFunctions` user data function from
   [step 3](write-back.md) exists, it wires the report's **Update OEE** button to it. Without it, the script
   leaves the button out and tells you to run step 3 first.
4. Reframes the model so it loads the newest data.

## The report

[Analytics and write-back](../demo/analytics.md) describes the report's pages and what to show on each.

## Verify

- The `OEEAnalytics` report opens and its Executive page shows OEE for all five lines.
- The **Target OEE** card shows a value (from step 3).
- The **Floor Ops** page shows the seeded events (from step 4).

!!! tip
    Re-run this script after steps 3 or 4 if you ran them later; it's safe to repeat. Direct Lake picks up new
    rows on its own, so you don't need to refresh the model for new telemetry. If the reframe at the end of
    the script fails, the report still works; see [Troubleshooting](troubleshooting.md).
