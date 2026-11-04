# 6. Activator alert

This step adds the **Floor Ops Alerts** Activator. It watches the telemetry stream and emails ops the moment a
machine faults: one email per outage, when a station's status *becomes* `Fault`.

## Run it

```bash
bash scripts/5-setup-activator-alerts.sh --workspace-name "<FABRIC_WORKSPACE>" \
  --alert-email ops@contoso.com
```

Without `--alert-email`, the alert goes to the account you're signed in with. The script resumes the
Eventstream (see [step 1](fabric-foundation.md#check-the-eventstream)), creates the Activator, and deploys the
rule from `scripts/activator/ReflexEntities.template.json`. The rule starts running immediately.

| Setting | Value |
|---|---|
| Source | The `manufacturing-telemetry` Eventstream |
| Object | One per station (`device_id`) |
| Trigger | `machine_status` changes to `Fault` |
| Email | Subject `⚠ Outage: {device_id} on {line_id}`, with the machine type, station, and line |

## Verify

1. With the simulator running, select a station and choose **Fault now** in the **Demo Scenarios** panel.
2. Within a few minutes, the recipient gets the outage email.

## Change the rule

Edit `scripts/activator/ReflexEntities.template.json` and re-run the script: change the trigger value to alert
on another status, or edit the subject and message text. If you change the rule in the Activator itself, export
it with `getDefinition` and copy the `ReflexEntities.json` part back into the template, keeping its
`__EVENTSTREAM_ARTIFACT_ID__` and `__ALERT_EMAIL__` placeholders, so the next deployment keeps your change. The
[Reflex item definition](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/reflex-definition)
describes the format.
