# Fabric Activator alerts for the OEE demo

Fabric Activator (also called **Data Activator** or **Reflex** in older portal
surfaces) monitors live Fabric data for operational conditions and runs an
action when a condition is met. In this demo it sits beside the existing
real-time path:

```text
Simulator -> Eventstream -> ManufacturingEH KQL Silver tables -> Activator
                                                            -> Teams/email
```

Use Activator for proactive "detect -> act" notifications. It does not change
the simulator, write back to telemetry, or require the Rayfin or Power BI
extensions. Activator is still preview-ish in many tenants, so expect portal UI
labels to move. You need a Fabric capacity, Real-Time Intelligence enabled, and
tenant/admin enablement for Activator in a supported region.

## Recommended alert 1 — Station down too long

**Goal:** notify a supervisor when a station stays in `Fault`, `Idle`, or
`Maintenance` for longer than the demo threshold.

Recommended defaults:

| Setting | Value |
|---|---|
| Object / grouping key | `device_id` |
| Display fields | `line_id`, `station_position`, `machine_status` |
| Window | 10 minutes |
| Trigger condition | `(is_fault == 1 OR is_idle == 1 OR is_maintenance == 1)` remains true for the window |
| Action | Teams message first; email fallback |

If you configure this from a KQL-backed Reflex rule, use this logic:

```kql
let window = 10m;
MachineEvents
| where timestamp >= ago(window)
| summarize
    down_samples = countif(is_fault == 1 or is_idle == 1 or is_maintenance == 1),
    samples = count(),
    arg_max(timestamp, machine_status, line_id, station_position)
  by device_id
| extend down_ratio = todouble(down_samples) / todouble(samples)
| where samples > 0 and down_ratio >= 0.80
```

The `0.80` ratio makes the alert robust to a single recovery/noisy event. For a
stricter rule, use `down_ratio == 1.0`.

If you configure directly from the Eventstream canvas, the raw stream contains
`machine_status` rather than the Silver proxy columns. Use:

```text
Group by device_id
Condition: machine_status is Fault OR Idle OR Maintenance
Duration: 10 minutes
```

## Recommended alert 2 — Sustained low OEE on a line

**Goal:** notify when a line's OEE stays below target for N minutes.

This repo intentionally does **not** store a precomputed OEE table. OEE is
composed at query time:

| OEE component | Demo source |
|---|---|
| Availability | `avg(is_running)` from `MachineEvents` |
| Performance | `avg(performance_ratio)` from `MachineEventsEnriched()` over running rows; `performance_ratio = min(1.0, ideal_cycle_time / actual_cycle_time)` |
| Quality | `avg(is_pass)` from completed `PartEvents` where `is_completed == 1` |

Recommended defaults:

| Setting | Value |
|---|---|
| Object / grouping key | `line_id` |
| Window | 10 minutes |
| Target | `OEE < 0.60` for demo; tune to your audience |
| Action | Teams message first; email fallback |

KQL logic for the full rule:

```kql
let window = 10m;
let target_oee = 0.60;
let machine =
    MachineEventsEnriched()
    | where timestamp >= ago(window)
    | summarize
        availability = avg(todouble(is_running)),
        performance = avgif(performance_ratio, is_running == 1)
      by line_id;
let quality =
    PartEvents
    | where timestamp >= ago(window) and is_completed == 1
    | summarize quality = avg(todouble(is_pass)) by line_id;
machine
| join kind=leftouter quality on line_id
| extend
    performance = coalesce(performance, 1.0),
    quality = coalesce(quality, 1.0),
    oee = availability * performance * quality
| where oee < target_oee
```

Activator portal capabilities vary by tenant and item type. If the portal cannot
watch this full KQL expression directly, use an operational proxy that Activator
can express today:

```kql
let window = 10m;
MachineEvents
| where timestamp >= ago(window)
| summarize
    availability = avg(todouble(is_running)),
    fault_rate = avg(todouble(is_fault)),
    idle_rate = avg(todouble(is_idle))
  by line_id
| where availability < 0.75 or (fault_rate + idle_rate) > 0.25
```

The cleaner long-term option is to watch an OEE measure from the Power BI
semantic model after the Power BI component exists. That keeps the alert target
aligned with the executive report.

## Portal setup option A — Start from the Eventstream

Microsoft documents the Eventstream path as **Set alert**, which automatically
adds an Activator destination to the Eventstream.

1. Open Fabric and go to the workspace that contains `manufacturing-telemetry`.
2. Open the **manufacturing-telemetry** Eventstream.
3. If the Eventstream is in edit/draft mode, select **Publish** and confirm it
   is **Live** or **Running**.
4. Select **Set alert** from the Eventstream ribbon.
5. In the alert/rule pane:
   - Rule name: `Station down too long`.
   - Check: use a grouped event condition.
   - Group by: `device_id`.
   - Condition: `machine_status` is `Fault`, `Idle`, or `Maintenance`.
   - Duration/window: 10 minutes.
6. In **Action**, choose **Microsoft Teams** and send to the demo supervisor or
   operations channel. If Teams is unavailable in the tenant, choose email.
7. In **Save location**, save to an existing Activator item or create
   `OEE Activator Alerts`.
8. Select **Create**, then open the Activator item if you want to test or edit
   the rule. Start/activate the rule before demoing.

Use this path for the station alert because it is easy to explain live on the
Eventstream canvas. For the low-OEE alert, prefer the KQL-backed or Power BI
measure-backed path below unless the portal supports your desired expression.

## Portal setup option B — Create or edit a Reflex/Activator item

Use this path when you want the rule to read from `ManufacturingEH` or from a
Power BI measure.

1. In the Fabric workspace, create an **Activator** item named
   `OEE Activator Alerts` (older UI may say **Data Activator** or **Reflex**).
2. Add data from the existing Eventstream or KQL database:
   - Eventstream source: `manufacturing-telemetry`.
   - KQL source: `ManufacturingEH`.
3. Define the object:
   - Station rule: object key `device_id`.
   - Line rule: object key `line_id`.
4. Create the rule condition:
   - Station rule: down condition from the first section for 10 minutes.
   - Low-OEE rule: full OEE KQL condition, proxy condition, or Power BI OEE
     measure condition when available.
5. Configure the action:
   - Default: Teams message to an operations channel.
   - Fallback: email to the demo operator/supervisor.
6. Include enough context in the message: line, station/device, current status,
   breach duration, and current metric value.
7. Save, send a test notification if the UI offers it, then **Activate** or
   **Start** the rule.

## Message links and optional tie-ins

Keep alert actions lightweight. The recommended message body is:

```text
OEE demo alert: {ruleName}
Line: {line_id}
Station/device: {device_id}
Status/metric: {machine_status or oee}
Window: 10 minutes
Next step: open the dashboard or log downtime reason.
```

Optionally add a plain URL to either:

- the Rayfin Downtime Logbook app, so an operator can log a reason code; or
- the Power BI report, so a supervisor can inspect the OEE trend.

These are only deep links. Activator does not need the Rayfin or Power BI
components for the alerts to work.

## Troubleshooting and preview gates

- **No Activator/Data Activator/Reflex item type:** ask a Fabric admin to enable
  Activator for the tenant and confirm the workspace is on supported capacity.
- **Set alert button is missing:** publish the Eventstream and confirm it is
  live/running. Some tenants expose alert creation only from Real-Time hub or
  the Activator item.
- **Actions unavailable:** Teams/email actions can be tenant-policy gated. Use
  email as the fallback channel.
- **KQL rule cannot be attached:** use the Eventstream station rule or the
  fault/idle proxy query, then move to a Power BI OEE measure once the semantic
  model exists.
- **No notifications:** verify the rule is activated, the simulator is sending
  fresh events, and the Fabric capacity is not paused.

## How to demo it

1. Run the Fabric foundation and start the simulator.
2. Confirm `manufacturing-telemetry` is running and data lands in
   `ManufacturingEH`.
3. Activate the `Station down too long` Teams rule.
4. Cause or wait for a simulator station fault/idle/maintenance condition.
5. After the configured window, show the Teams/email alert and open the linked
   dashboard or logbook URL if configured.
