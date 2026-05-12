---
title: "PCB-Loader — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-E"
station_position: 1
station_type: "PCB-Loader"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# PCB-Loader — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager
> **Applies to:** Line-E, station 1, PCB-Loader

## 1. Purpose

The PCB-Loader is the entry point of Line-E (Electronics Assembly). It
feeds bare PCBs from magazine racks onto the conveyor for SMT-Placement.
A stoppage starves the entire 8-station line.

## 2. Normal operating envelope

- Ideal cycle time: **5 s** — fastest station in the factory
- Max acceptable cycle time: **7 s**
- Expected reject rate: **0 %**
- Fault probability per cycle: **0.1 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Magazine racks empty. | Refill magazine; check Production Schedule. |
| `Blocked` | SMT-Placement (station 2) buffer full. | Verify SMT-Placement state. |

## 4. Faults & corrective actions

### 4.1 `Feed-Jam`

- **Symptoms in telemetry:** `fault_type = "Feed-Jam"`. Loader stops; all
  downstream Line-E stations report `Starved`.
- **Likely root cause:** PCB stuck in feeder gate; magazine misaligned.
- **Corrective action:**
  1. LOTO. Clear the jammed PCB.
  2. Verify magazine alignment.
- **Restart criteria:** 10 PCBs feed cleanly.

### 4.2 `Magazine-Empty`

- **Symptoms in telemetry:** `fault_type = "Magazine-Empty"`. Although it
  reads as a fault, this is essentially a refill condition.
- **Likely root cause:** kit consumed faster than expected.
- **Corrective action:**
  1. Refill the magazine.
  2. Confirm lot traceability captured.
- **Restart criteria:** continuous feed for 5 cycles.

### 4.3 `Sensor-Block`

- **Symptoms in telemetry:** `fault_type = "Sensor-Block"`. Pickoff sensor
  reads "present" when no PCB is at the gate.
- **Likely root cause:** sensor fouled, dust accumulation, or misalignment.
- **Corrective action:**
  1. Clean and realign the sensor.
  2. Verify trigger margin.
- **Restart criteria:** clean transitions on 10 cycles.

## 5. Preventive maintenance schedule

- **Daily:** check magazine; clean sensors.
- **Weekly:** lubricate feed mechanism.
- **Monthly:** alignment verification.
- **Quarterly:** mechanical overhaul.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Line-E_02_SMT-Placement_SOP.pdf`
- `Production_Lines_Reference.pdf`
