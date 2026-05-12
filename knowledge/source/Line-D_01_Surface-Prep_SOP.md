---
title: "Surface-Prep — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-D"
station_position: 1
station_type: "Surface-Prep"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# Surface-Prep — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager
> **Applies to:** Line-D, station 1, Surface-Prep

## 1. Purpose

Surface-Prep is the entry of Line-D (Surface Treatment). It uses abrasive
blasting / sanding to remove oxide, scale, and contaminants before the part
goes into chemical wash and paint. A stoppage here starves every station
downstream including the long-cycle Curing-Oven.

## 2. Normal operating envelope

- Ideal cycle time: **20 s**
- Max acceptable cycle time: **26 s**
- Expected reject rate: **≤ 1 %**
- Fault probability per cycle: **0.3 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Raw part feed empty. | Refill or restart upstream feeder. |
| `Blocked` | Chemical-Wash (station 2) buffer full. | Verify Chemical-Wash state. |

## 4. Faults & corrective actions

### 4.1 `Abrasive-Wear`

- **Symptoms in telemetry:** `fault_type = "Abrasive-Wear"`. Surface finish
  rejects rise at Coating-Inspection.
- **Likely root cause:** blast media degraded; bulk size distribution
  shifted fine.
- **Corrective action:**
  1. Sieve and replenish media to spec.
  2. Verify air pressure at the nozzle (target: 90 psi).
- **Restart criteria:** surface roughness matches recipe.

### 4.2 `Motor-Fault`

- **Symptoms in telemetry:** `fault_type = "Motor-Fault"`. Cell drive motor
  trips or overheats.
- **Likely root cause:** dust ingress into motor enclosure, bearing wear,
  or VFD fault.
- **Corrective action:**
  1. LOTO. Inspect motor; clean dust accumulation.
  2. Check VFD fault code; replace fan or motor as indicated.
- **Restart criteria:** stable motor temp / current draw across 10 minutes.

### 4.3 `Dust-Overload`

- **Symptoms in telemetry:** `fault_type = "Dust-Overload"`. Cell exhaust
  flow drops; environmental alarms may trip.
- **Likely root cause:** dust collector cartridge plugged.
- **Corrective action:**
  1. LOTO. Pulse-clean or replace the cartridge.
  2. Empty the dust hopper.
  3. Verify exhaust flow against spec.
- **Restart criteria:** static pressure within range.

## 5. Preventive maintenance schedule

- **Daily:** empty dust collector hopper.
- **Weekly:** check media level and sieve fines.
- **Monthly:** replace dust cartridge.
- **Quarterly:** motor and VFD service.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Safety_Lockout_Tagout_Procedure.pdf`
- `Line-D_02_Chemical-Wash_SOP.pdf`
- `Production_Lines_Reference.pdf`
