---
title: "Blanking-Press — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-B"
station_position: 1
station_type: "Blanking-Press"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# Blanking-Press — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager · Quality Worker
> **Applies to:** Line-B, station 1, Blanking-Press

## 1. Purpose

The Blanking-Press is the entry point of Line-B (Sheet Metal Forming). It
punches flat blanks from coil or sheet stock that the downstream
Hydraulic-Press will draw into the housing's 3-D form. A stoppage here
starves the entire line within 1–2 buffer fills (≈ 1 minute given an 8 s
ideal cycle and 5-part buffers).

## 2. Normal operating envelope

- Ideal cycle time: **8 s** — Line-B is the fastest line in the factory
- Max acceptable cycle time: **11 s**
- Expected reject rate: **≤ 2 %**
- Fault probability per cycle: **0.6 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Coil feed is empty or upstream loader has stopped. | Check coil supply and feeder. |
| `Blocked` | Hydraulic-Press (station 2) cannot accept the next blank. | Check Hydraulic-Press state. |

## 4. Faults & corrective actions

### 4.1 `Die-Wear`

- **Symptoms in telemetry:** `fault_type = "Die-Wear"`. Reject rate climbs
  past 2 % with burr / edge-finish issues called out at Quality-Inspection.
- **Likely root cause:** punch and die clearance has opened beyond service
  limit.
- **Corrective action:**
  1. LOTO. Remove the die set.
  2. Inspect punch and die edges; resharpen or replace per the tool log.
  3. Re-shim to nominal clearance for the stock thickness.
- **Restart criteria:** 10 trial blanks with burr height ≤ 0.05 mm.

### 4.2 `Alignment-Fault`

- **Symptoms in telemetry:** `fault_type = "Alignment-Fault"`. May follow a
  hard hit or a misfed blank.
- **Likely root cause:** die-set guide pins shifted, or feed rails
  misaligned to the blanking centerline.
- **Corrective action:**
  1. LOTO.
  2. Verify pin engagement; replace bent or galled guide pins.
  3. Re-align the feeder rails to the die centerline with a dial indicator.
- **Restart criteria:** three blanks land in the die pocket without contact.

### 4.3 `Feed-Jam`

- **Symptoms in telemetry:** `fault_type = "Feed-Jam"`.
- **Likely root cause:** coil snagged at the feed rolls, or a previously
  blanked sliver wedged in the strip pilot hole.
- **Corrective action:**
  1. LOTO.
  2. Reverse the feeder, clear the jammed strip; remove sliver scrap.
  3. Inspect feed roll urethane for grooving.
- **Restart criteria:** ten parts feed cleanly with no slip alarms.

## 5. Preventive maintenance schedule

- **Daily:** lube ram guides; clear scrap chute.
- **Weekly:** die-set inspection; feeder roll cleaning.
- **Monthly:** crown calibration check.
- **Quarterly:** ram tonnage verification.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Safety_Lockout_Tagout_Procedure.pdf`
- `Line-B_02_Hydraulic-Press_Maintenance_SOP.pdf`
- `Line-B_04_Quality-Inspection_SOP.pdf`
