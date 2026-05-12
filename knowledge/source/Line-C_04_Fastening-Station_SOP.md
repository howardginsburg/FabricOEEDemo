---
title: "Fastening-Station — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-C"
station_position: 4
station_type: "Fastening-Station"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# Fastening-Station — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager · Quality Worker
> **Applies to:** Line-C, station 4, Fastening-Station

## 1. Purpose

The Fastening-Station inserts torque-controlled fasteners (bolts and
screws) into the inspected weld assembly before Assembly-Robot (station 5)
completes the subassembly.

## 2. Normal operating envelope

- Ideal cycle time: **15 s**
- Max acceptable cycle time: **19 s**
- Expected reject rate: **≤ 1 %**
- Fault probability per cycle: **0.3 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Weld-Inspection (station 3) is not feeding parts. | Verify Weld-Inspection state. |
| `Blocked` | Assembly-Robot (station 5) cannot accept the part. | Verify Assembly-Robot state. |

## 4. Faults & corrective actions

### 4.1 `Torque-Drift`

- **Symptoms in telemetry:** `fault_type = "Torque-Drift"`. Reject codes
  from downstream show under-torqued or over-torqued joints.
- **Likely root cause:** torque transducer drift, or air supply pressure
  variation on pneumatic models.
- **Corrective action:**
  1. Run the torque calibration routine against a known torque check
     fixture.
  2. If drift exceeds ± 5 %, replace the transducer or recalibrate.
  3. Verify air pressure regulator setpoint.
- **Restart criteria:** calibration value within ± 2 % across three
  setpoints.

### 4.2 `Bit-Break`

- **Symptoms in telemetry:** `fault_type = "Bit-Break"`. The spindle stalls;
  cycle aborts.
- **Likely root cause:** worn or fatigued driver bit, or off-axis approach.
- **Corrective action:**
  1. LOTO. Remove the broken bit.
  2. Inspect the bit holder; replace if galled.
  3. Verify spindle approach centering against the master fixture.
- **Restart criteria:** five clean drives in a row.

### 4.3 `Feeder-Jam`

- **Symptoms in telemetry:** `fault_type = "Feeder-Jam"`. Fastener-feed
  pickoff fails.
- **Likely root cause:** fastener bridged in the supply tube, or pickoff
  sensor fouled.
- **Corrective action:**
  1. LOTO. Clear the supply tube.
  2. Clean the pickoff sensor face.
  3. Verify the fastener bowl amplitude per recipe.
- **Restart criteria:** 20 fasteners delivered without alarm.

## 5. Preventive maintenance schedule

- **Daily:** torque verification against the check fixture.
- **Weekly:** bit holder inspection; supply-tube cleaning.
- **Monthly:** transducer calibration check.
- **Quarterly:** full pneumatic system service.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Quality_Reject_Disposition_Policy.pdf`
- `Line-C_03_Weld-Inspection_NDT.pdf`
- `Line-C_05_Assembly-Robot_SOP.pdf`
