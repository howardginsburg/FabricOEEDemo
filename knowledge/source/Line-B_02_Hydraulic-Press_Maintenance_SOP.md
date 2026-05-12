---
title: "Hydraulic-Press — Maintenance SOP (Faultiest Station on Line-B)"
doc_type: "Maintenance SOP"
line_id: "Line-B"
station_position: 2
station_type: "Hydraulic-Press"
version: "1.0"
owner: "Maintenance Engineering"
last_reviewed: "2026-01-15"
---

# Hydraulic-Press — Maintenance SOP

> **Audience:** Maintenance Tech (primary) · Line Manager
> **Applies to:** Line-B, station 2, Hydraulic-Press

## 1. Purpose

The Hydraulic-Press deep-draws the blank from station 1 into the 3-D
housing shape. With a 1.5 % per-cycle fault probability — the **highest on
Line-B** — this press is the single most common source of downtime on the
sheet-metal line. This SOP exists to give maintenance technicians a fast,
predictable path from a `Fault` telemetry event back to `Running`.

## 2. Normal operating envelope

- Ideal cycle time: **12 s**
- Max acceptable cycle time: **18 s**
- Expected reject rate: **≤ 4 %**
- Fault probability per cycle: **1.5 %** (line max)
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Blanking-Press (station 1) is not feeding blanks. | Verify Blanking-Press state. |
| `Blocked` | Trimming-Station (station 3) cannot accept the formed part. | Verify Trimming state. |

Because of this press's high fault rate, **most downstream `Starved`
events on Line-B trace back to this station**. When triaging starvation on
stations 3 or 4, check this press first.

## 4. Faults & corrective actions

### 4.1 `Pressure-Loss`

- **Symptoms in telemetry:** `fault_type = "Pressure-Loss"`. The press
  cannot complete the down stroke; cycle time often spikes to the 18 s max
  on the last successful cycle.
- **Likely root cause:** internal pump leak; relief valve drift; hose
  burst.
- **Corrective action:**
  1. LOTO and bleed stored pressure per `Safety_Lockout_Tagout_Procedure.pdf`.
  2. Check fluid level in the reservoir; top off only with the OEM-spec
     hydraulic fluid.
  3. Inspect hoses and fittings for visible leaks; replace as needed.
  4. Pressure-test to system rating (typ. 3,000 psi); verify hold for
     5 minutes with the press at top of stroke.
- **Restart criteria:** rated pressure held for 5 minutes, no leaks.

### 4.2 `Seal-Failure`

- **Symptoms in telemetry:** `fault_type = "Seal-Failure"`. Often follows a
  period of slow pressure decay and visible weeping around the main ram.
- **Likely root cause:** main ram seal has hardened or cut. End of service
  life is typically 18–24 months under normal duty.
- **Corrective action:**
  1. LOTO. Drop the ram with overhead crane onto blocks.
  2. Replace the main ram seal kit (rod seal + wiper + back-up ring).
  3. Re-flush the line with fresh hydraulic fluid.
  4. Cycle the press 20 times at half-rated pressure before resuming
     production.
- **Restart criteria:** no weep across a 30-minute observation window.

### 4.3 `Valve-Fault`

- **Symptoms in telemetry:** `fault_type = "Valve-Fault"`. Erratic stroke
  timing, or the press fails to return.
- **Likely root cause:** directional control valve solenoid burned out, or
  spool stuck from contamination.
- **Corrective action:**
  1. LOTO.
  2. Inspect the directional valve solenoid for continuity; replace coil.
  3. If the spool is stuck, replace the valve cartridge.
  4. Sample-test the hydraulic fluid for ISO 18/16/13 cleanliness; flush if
     out of spec.
- **Restart criteria:** ten consecutive cycles within ideal cycle time
  window.

## 5. Preventive maintenance schedule

- **Daily:** fluid level check; visual leak walk-around.
- **Weekly:** filter element delta-pressure check.
- **Monthly:** sample hydraulic fluid for particulate count.
- **Quarterly:** main ram seal inspection (record service hours).
- **Annually:** full pump and motor service.

A missed quarterly seal inspection escalates to the Plant Manager per
`OEE_Targets_and_Escalation.pdf` because of this press's outsized impact
on line OEE.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Safety_Lockout_Tagout_Procedure.pdf`
- `OEE_Targets_and_Escalation.pdf`
- `Line-B_01_Blanking-Press_SOP.pdf`
- `Line-B_03_Trimming-Station_SOP.pdf`
