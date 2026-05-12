---
title: "<Document Title>"
doc_type: "Standard Operating Procedure"   # or "Maintenance SOP", "Policy", "Reference"
line_id: "Line-X"                          # omit for cross-cutting docs
station_position: 0                        # omit for cross-cutting docs
station_type: "<Machine-Type>"             # omit for cross-cutting docs
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# <Document Title>

> **Audience:** Maintenance Tech · Line Manager · Quality Worker
> **Applies to:** <Line-X, station N, machine-type> (or "All lines" for cross-cutting)

## 1. Purpose

One short paragraph (2–3 sentences) describing what the station does in the
production flow, what part it produces or inspects, and why this SOP exists.
For cross-cutting docs, describe the policy / process and who it governs.

## 2. Normal operating envelope

Bullet list of the steady-state operating parameters a healthy run produces.
Include the simulator's `idealCycleTimeSeconds` and `maxCycleTimeSeconds` so
the agent can quote them when answering "is this station running normally?".

- Ideal cycle time: **<X> s** (simulator `idealCycleTimeSeconds`)
- Max acceptable cycle time: **<Y> s** (simulator `maxCycleTimeSeconds`)
- Expected reject rate: **≤ <Z> %** (simulator `rejectProbability`)
- Input buffer capacity: **5 parts**
- Telemetry interval: **10 s** (`telemetryIntervalSeconds`)

## 3. Idle reasons

The simulator emits `idle_reason` only when `machine_status = "Idle"`. The
two valid values are **`Starved`** and **`Blocked`**. Both apply to every
station — diagnose by looking at adjacent stations:

| `idle_reason` | What it means | First check |
|---|---|---|
| `Starved` | Input buffer is empty — the upstream station is not feeding parts. | Look upstream: is the previous station in `Fault`, `Maintenance`, or also `Idle`? |
| `Blocked` | Output buffer is full — the downstream station can't accept parts. | Look downstream: is the next station in `Fault`, `Maintenance`, or running below cycle? |

Document any station-specific notes here (e.g., for `PCB-Loader`, `Starved`
also fires when `Magazine-Empty` triggers and no `Fault` is raised).

## 4. Faults & corrective actions

One subsection per `faultType` declared in `simulator.yaml` for this
station. Use the **exact** simulator string as the heading — those strings
are what the agent must match against AI Search retrieval.

### 4.1 `<FaultType-1>`

- **Symptoms in telemetry:** machine_status flips to `Fault`; fault_type =
  `<FaultType-1>`; downstream stations soon report `idle_reason = Starved`.
- **Likely root cause:** 1–2 sentences.
- **Corrective action:** numbered steps. Reference LOTO when energy isolation
  is required (`Safety_Lockout_Tagout_Procedure.pdf`).
- **Restart criteria:** when the technician can close the maintenance work
  order and bring the machine back to `Running`.

### 4.2 `<FaultType-2>`

…

### 4.3 `<FaultType-3>`

…

## 5. Preventive maintenance schedule

Bullet list of PM intervals. Tie to the `Maintenance_Workflow_Overview.pdf`
escalation matrix for missed PMs.

- Daily: …
- Weekly: …
- Monthly: …
- Quarterly: …

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Safety_Lockout_Tagout_Procedure.pdf`
- `Quality_Reject_Disposition_Policy.pdf`
- `Production_Lines_Reference.pdf`
- Any peer-station SOPs that share a buffer with this station.
