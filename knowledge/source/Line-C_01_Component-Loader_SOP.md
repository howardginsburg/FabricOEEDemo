---
title: "Component-Loader — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-C"
station_position: 1
station_type: "Component-Loader"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# Component-Loader — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager
> **Applies to:** Line-C, station 1, Component-Loader

## 1. Purpose

The Component-Loader is the entry point of Line-C (Welding & Assembly). It
feeds raw components from a vibratory bowl / hopper onto the line for the
Welding-Robot. As station 1, every downstream station starves when this
loader stops.

## 2. Normal operating envelope

- Ideal cycle time: **10 s**
- Max acceptable cycle time: **13 s**
- Expected reject rate: **0 %**
- Fault probability per cycle: **0.1 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Hopper is empty or operator has not staged components. | Refill component magazine; check Production Schedule. |
| `Blocked` | Welding-Robot (station 2) output buffer is full. | Verify Welding-Robot state. |

## 4. Faults & corrective actions

### 4.1 `Feed-Jam`

- **Symptoms in telemetry:** `fault_type = "Feed-Jam"`. Loader stops feeding;
  downstream Welding-Robot reports `Starved`.
- **Likely root cause:** component bridged in the feeder track, or a
  misshapen part lodged at the pickoff.
- **Corrective action:**
  1. LOTO. Clear the jammed component from the track.
  2. Inspect the track for wear; smooth any galled surfaces.
  3. Verify bowl amplitude per recipe.
- **Restart criteria:** 20 cleanly delivered components.

### 4.2 `Sensor-Block`

- **Symptoms in telemetry:** `fault_type = "Sensor-Block"`. The pick-position
  detector is reporting "part present" continuously even when empty.
- **Likely root cause:** photo-eye is fouled with dust or has misaligned.
- **Corrective action:**
  1. Clean the sensor face.
  2. Realign the sensor against the reflector / target.
  3. Verify trigger margin in the diagnostic.
- **Restart criteria:** sensor reads clean transitions on 10 cycles.

### 4.3 `Hopper-Empty`

- **Symptoms in telemetry:** `fault_type = "Hopper-Empty"`. The bowl level
  switch tripped; this is operationally distinct from `idle_reason =
  Starved` only because the simulator raised it as a fault.
- **Likely root cause:** kit shortage; missed material request; bulk run
  longer than planned.
- **Corrective action:**
  1. Refill the hopper to the upper level mark.
  2. Confirm operator has the component lot number captured for
     traceability.
  3. Reset the level fault.
- **Restart criteria:** continuous feed for 5 cycles.

## 5. Preventive maintenance schedule

- **Daily:** clean photo-eye lenses; check hopper level.
- **Weekly:** lubricate feeder track guides.
- **Monthly:** replace track liner if grooved.
- **Quarterly:** vibratory bowl spring set inspection.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Line-C_02_Welding-Robot_SOP.pdf`
- `Production_Lines_Reference.pdf`
