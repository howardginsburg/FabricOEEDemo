# Fabric Activator alerts for the OEE demo

Fabric Activator (also called **Data Activator** or **Reflex**) is a no-code
event-detection engine. It watches a live Fabric data source and runs an action
when a condition is met. In this demo it closes the "detect → act" loop on the
existing real-time path with **zero new infrastructure**:

```text
Simulator -> Eventstream (manufacturing-telemetry) -> Activator "Floor Ops Alerts"
                                                       -> email on machine outage
```

It does not change the simulator, write back to telemetry, or require the Rayfin
or Power BI extensions. You need a Fabric capacity with Real-Time Intelligence /
Activator enabled in a supported region.

## The rule this demo ships

| Setting | Value |
|---|---|
| Source | Eventstream `manufacturing-telemetry` (stream `manufacturing-telemetry-stream`) |
| Object | `Device`, identity = `device_id` |
| Object properties | `line_id`, `station_position`, `machine_type`, `machine_status` |
| Trigger | `machine_status` **becomes** `Fault` (one alert per Running→Fault transition) |
| Action | Email the ops recipient |
| Email subject | `⚠ Outage: {device_id} on {line_id}` |
| Email body | `{machine_type} at station {station_position} on {line_id} faulted (device {device_id}). Current status: {machine_status}.` |

"Becomes Fault" (rather than "any Fault event") means one clean email per outage,
even though a faulted station reports `Fault` for several telemetry cycles before
it transitions to `Maintenance`.

## Scripted setup

The rule is defined declaratively in
[`scripts/activator/ReflexEntities.template.json`](../scripts/activator/ReflexEntities.template.json)
(a Reflex item definition with `__EVENTSTREAM_ARTIFACT_ID__` and `__ALERT_EMAIL__`
placeholders) and deployed by
[`scripts/5-setup-activator-alerts.sh`](../scripts/5-setup-activator-alerts.sh).

```bash
# Uses the signed-in az user as the alert recipient by default:
bash scripts/5-setup-activator-alerts.sh --workspace-name "OEE Demo"

# Or set an explicit recipient:
bash scripts/5-setup-activator-alerts.sh --workspace-name "OEE Demo" \
     --alert-email ops@contoso.com
```

The script is idempotent. On each run it:

1. Resolves the workspace and the `manufacturing-telemetry` eventstream id.
2. **Resumes the eventstream** (see the ingestion gotcha below).
3. Creates the `Floor Ops Alerts` Activator item if it does not already exist
   (`POST /workspaces/{ws}/reflexes`).
4. Substitutes the template placeholders (eventstream id + recipient), then pushes
   the definition via `POST /workspaces/{ws}/items/{id}/updateDefinition`. The
   rule ships with `settings.shouldRun = true`, so it is active on deploy.

### Why the definition is scriptable

The public [Reflex item definition](https://learn.microsoft.com/rest/api/fabric/articles/item-management/definitions/reflex-definition)
supports streaming sources — `eventstreamSource-v1`, `kqlSource-v1`,
`realTimeHubSource-v1`. Because this demo alerts on an **eventstream**, the whole
Activator (source → object → attributes → rule → email action) can be captured as
`ReflexEntities.json` and redeployed as code. (A Power BI *report-measure* alert,
by contrast, is created through the report "Set alert" onramp and is not part of
the public definition surface.)

## Ingestion gotcha — paused eventstream destinations

An eventstream's **destinations can be left `Paused`** while its source and stream
still show `Running`. In that state the simulator's events reach the stream but
never ingest into the `ManufacturingEH` KQL tables — every downstream surface
(dashboard, Direct Lake report, and this Activator) silently goes stale.

The setup script proactively calls the resume API:

```text
POST /v1/workspaces/{ws}/eventstreams/{es}/resume   { "startType": "Now" }
```

If ingestion looks stale, check the topology and resume:

```bash
az rest --method GET \
  --uri "https://api.fabric.microsoft.com/v1/workspaces/{ws}/eventstreams/{es}/topology" \
  --resource "https://api.fabric.microsoft.com" \
  | jq '.destinations[] | {name, status}'
```

## Customizing

- **Recipient:** `--alert-email`, or edit the `sentTo` value in the template.
- **Message text:** edit the `subject` / `headline` / `optionalMessage` arrays in
  the template. Static text is a `{"name":"string","type":"string","value":"…"}`
  entry; a dynamic field token is
  `{"kind":"EventFieldReference","type":"complex","arguments":[{"name":"fieldName","type":"string","value":"<field>"}]}`.
- **Trigger:** the `EventDetectStep` uses `TextChanges` / `ChangesTo` / `Fault`.
  Change the value to alert on a different `machine_status`.

## Re-capturing after editing in the portal

If you tweak the rule in the Activator canvas, re-capture the definition back into
the template so the change is reproducible:

```bash
az rest --method POST \
  --uri "https://api.fabric.microsoft.com/v1/workspaces/{ws}/items/{reflexId}/getDefinition" \
  --resource "https://api.fabric.microsoft.com"
# decode the ReflexEntities.json part, re-insert the __EVENTSTREAM_ARTIFACT_ID__
# and __ALERT_EMAIL__ placeholders, and save over the template.
```

## Troubleshooting

- **No `Activator` / `Reflex` item type:** ask a Fabric admin to enable Activator
  for the tenant and confirm the workspace is on supported capacity.
- **Rule never fires:** confirm telemetry is live (resume the eventstream) and that
  faults are actually occurring — faults are probabilistic per station, so give the
  running simulator a few minutes.
- **No email:** confirm the recipient is a real mailbox in the tenant and that the
  rule shows `shouldRun = true` / is started.
