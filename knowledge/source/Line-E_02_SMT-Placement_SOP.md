---
title: "SMT-Placement — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-E"
station_position: 2
station_type: "SMT-Placement"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# SMT-Placement — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager · Quality Worker
> **Applies to:** Line-E, station 2, SMT-Placement

## 1. Purpose

SMT-Placement uses pick-and-place heads to mount surface-mount components
onto the PCB before the Reflow-Oven solders them. It is the second-highest
fault contributor on Line-E (after Wave-Solder).

## 2. Normal operating envelope

- Ideal cycle time: **15 s**
- Max acceptable cycle time: **20 s**
- Expected reject rate: **≤ 3 %**
- Fault probability per cycle: **0.6 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | PCB-Loader (station 1) is not feeding boards. | Verify PCB-Loader state. |
| `Blocked` | Reflow-Oven (station 3) buffer full. | Verify Reflow-Oven state. |

## 4. Faults & corrective actions

### 4.1 `Nozzle-Clog`

- **Symptoms in telemetry:** `fault_type = "Nozzle-Clog"`. Components
  mis-picked; AOI rejects (downstream) climb.
- **Likely root cause:** debris in pick nozzle, or vacuum line leak.
- **Corrective action:**
  1. Clean the nozzle in ultrasonic.
  2. Verify vacuum at the head.
- **Restart criteria:** 20 successful picks.

### 4.2 `Feeder-Jam`

- **Symptoms in telemetry:** `fault_type = "Feeder-Jam"`. Component feeder
  fails to present the next part.
- **Likely root cause:** carrier tape mis-fed; sprocket worn.
- **Corrective action:**
  1. LOTO. Clear the feeder.
  2. Inspect sprocket; replace if worn.
- **Restart criteria:** stable feed for 10 cycles.

### 4.3 `Vision-Fail`

- **Symptoms in telemetry:** `fault_type = "Vision-Fail"`. Placement
  accuracy errors; rotation offsets exceed spec.
- **Likely root cause:** upward-look camera lens fouled, focus drifted.
- **Corrective action:**
  1. Clean camera lens.
  2. Re-run vision calibration.
- **Restart criteria:** placement accuracy within ± 0.05 mm.

## 5. Preventive maintenance schedule

- **Daily:** clean nozzles; check vacuum.
- **Weekly:** inspect feeders.
- **Monthly:** camera calibration.
- **Quarterly:** head accuracy verification.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Line-E_01_PCB-Loader_SOP.pdf`
- `Line-E_03_Reflow-Oven_SOP.pdf`
- `Line-E_04_AOI-Inspection_SOP.pdf`
