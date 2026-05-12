---
title: "CNC-Lathe — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-A"
station_position: 1
station_type: "CNC-Lathe"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# CNC-Lathe — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager · Quality Worker
> **Applies to:** Line-A, station 1, CNC-Lathe

## 1. Purpose

The CNC-Lathe is the entry point of Line-A (Precision Machining). It accepts
raw bar stock and produces a rough turned shaft profile for the downstream
CNC-Mill. As the first station, an outage on this lathe starves every
downstream station on the line within minutes.

## 2. Normal operating envelope

- Ideal cycle time: **40 s** (`idealCycleTimeSeconds`)
- Max acceptable cycle time: **48 s** (`maxCycleTimeSeconds`)
- Expected reject rate: **≤ 2 %**
- Fault probability per cycle: **0.5 %**
- Input buffer capacity: **5 parts**
- Telemetry interval: **10 s**

## 3. Idle reasons

| `idle_reason` | Meaning on the CNC-Lathe | First check |
|---|---|---|
| `Starved` | Raw bar stock feed empty. As station 1 this means the upstream feeder ran out — refill bar stock magazine. | Verify bar feeder + check the Production Schedule for an unscheduled gap. |
| `Blocked` | Downstream CNC-Mill cannot accept the next part — output buffer full. | Check CNC-Mill status; resolve its `Fault` or `Maintenance` first. |

## 4. Faults & corrective actions

### 4.1 `Chuck-Jam`

- **Symptoms in telemetry:** `machine_status` flips to `Fault`,
  `fault_type = "Chuck-Jam"`. Actual cycle time on the prior cycle often
  exceeded 48 s as the chuck struggled. CNC-Mill (station 2) reports
  `idle_reason = "Starved"` within one telemetry interval.
- **Likely root cause:** A chip or fragment of bar stock has lodged between
  the chuck jaws, or the chuck pressure regulator has drifted.
- **Corrective action:**
  1. Apply LOTO per `Safety_Lockout_Tagout_Procedure.pdf`.
  2. Open the chuck, remove the bar stock remnant and any chips.
  3. Inspect each jaw for galling; replace the jaw set if scoring is visible.
  4. Verify chuck pressure at the regulator (target: 60 psi ± 5).
  5. Bump-cycle three test parts before releasing to production.
- **Restart criteria:** three consecutive parts complete within
  `idealCycleTimeSeconds` × 1.10 and no reject is raised.

### 4.2 `Bearing-Wear`

- **Symptoms in telemetry:** `fault_type = "Bearing-Wear"`; if not yet
  faulted, watch for rising actual cycle time (still under 48 s) and a slow
  uptick in reject rate above 2 %.
- **Likely root cause:** Spindle bearing has accumulated radial play beyond
  the 0.005 mm tolerance.
- **Corrective action:**
  1. LOTO. Open the spindle housing.
  2. Measure radial play with a dial indicator. If > 0.005 mm, replace the
     bearing pack as a matched set.
  3. Re-pack with the lathe OEM's grease specification only.
  4. Run the 60-second warm-up cycle before resuming production.
- **Restart criteria:** spindle runout ≤ 0.005 mm verified post-repair.

### 4.3 `Tool-Break`

- **Symptoms in telemetry:** `fault_type = "Tool-Break"`. The reject before
  the fault will almost always be flagged in the Quality dashboard.
- **Likely root cause:** Tool insert exceeded service life or struck an
  inclusion in the bar stock.
- **Corrective action:**
  1. LOTO. Index the turret to the broken tool position.
  2. Replace the insert (or full holder if the holder shank is damaged).
  3. Re-set tool length offset against the master probe.
  4. Inspect the next 5 parts on the CMM (station 5) at 100 %.
- **Restart criteria:** post-repair tool length within 0.01 mm of master,
  no scrap on the next 5 parts at CMM-Inspection.

## 5. Preventive maintenance schedule

- **Daily:** check coolant level, blow off chip tray, verify bar feeder
  supply.
- **Weekly:** inspect chuck jaws, lube turret indexer.
- **Monthly:** spindle vibration analysis; replace coolant filter.
- **Quarterly:** spindle bearing endplay measurement; recalibrate tool
  length probe.

Missed PMs escalate per `Maintenance_Workflow_Overview.pdf`.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Safety_Lockout_Tagout_Procedure.pdf`
- `Quality_Reject_Disposition_Policy.pdf`
- `Production_Lines_Reference.pdf` (Line-A part flow)
- `Line-A_02_CNC-Mill_SOP.pdf` (downstream peer)
- `Line-A_05_CMM-Inspection_Calibration.pdf` (quality gate)
