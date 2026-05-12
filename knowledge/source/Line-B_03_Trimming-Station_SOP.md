---
title: "Trimming-Station — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-B"
station_position: 3
station_type: "Trimming-Station"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# Trimming-Station — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager · Quality Worker
> **Applies to:** Line-B, station 3, Trimming-Station

## 1. Purpose

The Trimming-Station removes excess flash and flange material left after
the Hydraulic-Press deep-draw, leaving a clean periphery for the final
Quality-Inspection check.

## 2. Normal operating envelope

- Ideal cycle time: **10 s**
- Max acceptable cycle time: **14 s**
- Expected reject rate: **≤ 2 %**
- Fault probability per cycle: **0.4 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Hydraulic-Press (station 2) is not feeding parts. | Verify Hydraulic-Press state — most common cause of `Starved` on Line-B. |
| `Blocked` | Quality-Inspection (station 4) cannot accept the trimmed part. | Verify Quality-Inspection state. |

## 4. Faults & corrective actions

### 4.1 `Blade-Dull`

- **Symptoms in telemetry:** `fault_type = "Blade-Dull"`. Quality-Inspection
  flags edge-finish defects in the cycles leading up to the fault.
- **Likely root cause:** trimming blade has reached the end of resharpening
  service life.
- **Corrective action:**
  1. LOTO. Remove and inspect each blade segment.
  2. Send for resharpening or install a fresh blade set.
  3. Re-set cut depth against the master gauge.
- **Restart criteria:** burr height ≤ 0.05 mm on three test parts.

### 4.2 `Guard-Trip`

- **Symptoms in telemetry:** `fault_type = "Guard-Trip"`. Safety door or
  light-curtain interrupted mid-cycle.
- **Likely root cause:** light-curtain misalignment, door latch wear, or an
  operator reach-in during cycle.
- **Corrective action:**
  1. Reset the safety controller and acknowledge the fault per local EHS
     procedure.
  2. Verify the trigger source from the safety log (door, curtain, e-stop).
  3. If recurring on the same channel, inspect the sensor wiring.
- **Restart criteria:** safety system passes the daily verification cycle.

### 4.3 `Alignment-Shift`

- **Symptoms in telemetry:** `fault_type = "Alignment-Shift"`. Uneven trim
  geometry; sudden jump in reject rate.
- **Likely root cause:** part-locating fixture has shifted; clamp pressure
  drift.
- **Corrective action:**
  1. LOTO. Verify fixture pin location.
  2. Re-torque the fixture base bolts to spec.
  3. Validate trim contour against a CMM-checked master.
- **Restart criteria:** trim contour passes the master comparison check.

## 5. Preventive maintenance schedule

- **Daily:** blade visual check; clear scrap chute.
- **Weekly:** clamp-pressure verification; fixture pin gauge.
- **Monthly:** blade replacement / resharpening cycle.
- **Quarterly:** safety system function test.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Safety_Lockout_Tagout_Procedure.pdf`
- `Line-B_02_Hydraulic-Press_Maintenance_SOP.pdf`
- `Line-B_04_Quality-Inspection_SOP.pdf`
