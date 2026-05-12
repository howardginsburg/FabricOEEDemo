---
title: "Surface-Grinder — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-A"
station_position: 3
station_type: "Surface-Grinder"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# Surface-Grinder — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager · Quality Worker
> **Applies to:** Line-A, station 3, Surface-Grinder

## 1. Purpose

The Surface-Grinder is station 3 of Line-A. It removes the last few
hundredths of a millimetre from the milled shaft to bring critical bearing
surfaces into final tolerance before deburring and CMM inspection.

## 2. Normal operating envelope

- Ideal cycle time: **35 s**
- Max acceptable cycle time: **42 s**
- Expected reject rate: **≤ 2 %**
- Fault probability per cycle: **0.3 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning on the Surface-Grinder | First check |
|---|---|---|
| `Starved` | CNC-Mill (station 2) is not feeding parts. | Verify mill state. |
| `Blocked` | Deburring-Station (station 4) cannot accept the part. | Verify deburring state. |

## 4. Faults & corrective actions

### 4.1 `Wheel-Wear`

- **Symptoms in telemetry:** `fault_type = "Wheel-Wear"`; surface-finish
  rejects rise at CMM-Inspection in the preceding cycles.
- **Likely root cause:** grinding wheel diameter has fallen below the
  minimum usable size or has glazed.
- **Corrective action:**
  1. LOTO. Measure wheel diameter; replace if below the manufacturer's
     minimum.
  2. Dress the wheel using the diamond dresser; record new size.
  3. Re-zero the wheel head offset against the master.
- **Restart criteria:** surface roughness Ra ≤ 0.4 μm on three test parts.

### 4.2 `Coolant-Clog`

- **Symptoms in telemetry:** `fault_type = "Coolant-Clog"`. May follow a
  period of elevated grinding sparks reported by the operator.
- **Likely root cause:** swarf and grinding sludge have plugged the coolant
  delivery line or the through-spindle filter.
- **Corrective action:**
  1. LOTO. Drain and flush the coolant manifold.
  2. Replace the inline filter cartridge.
  3. Verify coolant pressure at the wheel ≥ 30 psi.
- **Restart criteria:** stable coolant pressure with no sparks at first
  contact.

### 4.3 `Alignment-Drift`

- **Symptoms in telemetry:** `fault_type = "Alignment-Drift"`. CMM begins
  flagging parallelism or perpendicularity rejects shortly before the fault.
- **Likely root cause:** column lock-up shifted; thermal growth from a long
  uninterrupted run.
- **Corrective action:**
  1. LOTO. Let the grinder cool for 15 minutes.
  2. Re-square the wheel head to the table with a master square.
  3. Run a one-pass test on a calibration block.
- **Restart criteria:** test block within ±0.005 mm of nominal.

## 5. Preventive maintenance schedule

- **Daily:** check coolant level and pressure.
- **Weekly:** wheel dress; clean magnetic chuck.
- **Monthly:** column lubricant level; replace coolant filter.
- **Quarterly:** table alignment check; bearing greasing.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Safety_Lockout_Tagout_Procedure.pdf`
- `Line-A_02_CNC-Mill_SOP.pdf`
- `Line-A_04_Deburring-Station_SOP.pdf`
- `Line-A_05_CMM-Inspection_Calibration.pdf`
