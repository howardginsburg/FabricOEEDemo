---
title: "Assembly-Robot — Standard Operating Procedure"
doc_type: "Standard Operating Procedure"
line_id: "Line-C"
station_position: 5
station_type: "Assembly-Robot"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# Assembly-Robot — Standard Operating Procedure

> **Audience:** Maintenance Tech · Line Manager
> **Applies to:** Line-C, station 5, Assembly-Robot

## 1. Purpose

The Assembly-Robot performs the final robotic pick-and-place assembly
operations before Leak-Test verifies the sealed subassembly.

## 2. Normal operating envelope

- Ideal cycle time: **20 s**
- Max acceptable cycle time: **25 s**
- Expected reject rate: **≤ 2 %**
- Fault probability per cycle: **0.4 %**
- Input buffer capacity: **5 parts**

## 3. Idle reasons

| `idle_reason` | Meaning here | First check |
|---|---|---|
| `Starved` | Fastening-Station (station 4) is not feeding parts. | Verify Fastening state. |
| `Blocked` | Leak-Test (station 6) cannot accept the assembled part. | Verify Leak-Test state. |

## 4. Faults & corrective actions

### 4.1 `Joint-Calibration`

- **Symptoms in telemetry:** `fault_type = "Joint-Calibration"`.
  Misplacement rejects climb at Leak-Test.
- **Likely root cause:** robot joint encoder zero drifted, or a hard stop
  was disturbed.
- **Corrective action:**
  1. Run the robot zero-position calibration routine.
  2. Re-teach the pick and place positions against the master.
- **Restart criteria:** TCP position within ± 0.5 mm of master.

### 4.2 `Gripper-Fail`

- **Symptoms in telemetry:** `fault_type = "Gripper-Fail"`. Part dropped or
  mis-grasped; downstream Leak-Test reports missing components.
- **Likely root cause:** gripper jaws worn, vacuum loss, or finger
  positioning sensor failed.
- **Corrective action:**
  1. LOTO. Inspect gripper jaws; replace fingers as needed.
  2. Verify vacuum or pneumatic grip pressure.
  3. Test grip retention with a tare load.
- **Restart criteria:** 10 cycles without drop.

### 4.3 `Encoder-Fault`

- **Symptoms in telemetry:** `fault_type = "Encoder-Fault"`. Axis tracking
  error or robot halts to safe state.
- **Likely root cause:** encoder cable damaged or absolute encoder lost
  position.
- **Corrective action:**
  1. Check encoder cable and connectors; reseat or replace.
  2. Re-zero the affected axis.
  3. Run a full repeatability test.
- **Restart criteria:** repeatability within ± 0.05 mm at the TCP.

## 5. Preventive maintenance schedule

- **Daily:** visual check of cables and gripper.
- **Weekly:** TCP verification against master.
- **Monthly:** lubrication of harmonic drives per OEM schedule.
- **Quarterly:** full repeatability test.

## 6. References

- `Maintenance_Workflow_Overview.pdf`
- `Safety_Lockout_Tagout_Procedure.pdf`
- `Line-C_04_Fastening-Station_SOP.pdf`
- `Line-C_06_Leak-Test_SOP.pdf`
