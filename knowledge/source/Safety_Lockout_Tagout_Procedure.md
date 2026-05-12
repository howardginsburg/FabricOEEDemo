---
title: "Safety — Lockout / Tagout (LOTO) Procedure"
doc_type: "Policy"
version: "1.0"
owner: "Environment, Health & Safety"
last_reviewed: "2026-01-15"
---

# Safety — Lockout / Tagout (LOTO) Procedure

> **Audience:** Every technician, operator, and engineer who opens an
> enclosure, exposes hazardous energy, or services any of the 30 stations.
> **Applies to:** All 5 lines, all 30 stations.

## 1. Purpose

This procedure prevents injury from unexpected energization, start-up, or
release of stored energy during service, maintenance, or troubleshooting of
factory equipment. Every per-station SOP cross-references this document
under "Corrective action" steps that open an enclosure.

LOTO covers all hazardous energy sources present at this site:

- **Electrical** — line voltage at all CNC, robotic, and material-handling
  stations.
- **Hydraulic** — Line-B Hydraulic-Press, Line-D paint pumps.
- **Pneumatic** — every station with air-actuated clamps or gates.
- **Thermal** — Line-D Curing-Oven, Line-E Reflow-Oven, Line-E Wave-Solder
  pot. Thermal residue can remain hours after shutdown.
- **Chemical** — Line-D Chemical-Wash bath, paint solvents.
- **UV** — Line-E Conformal-Coat UV cure lamps.
- **Stored mechanical** — press rams (Line-B), spring-loaded clamps.

## 2. When LOTO is required

Apply LOTO before performing any of the following on any station:

1. Opening an enclosure to service a motor, drive, sensor, or control panel.
2. Replacing tools, blades, dies, nozzles, or other consumables.
3. Clearing a jam where a hand or tool will pass a guarded boundary.
4. Touching parts of the equipment that could become energized.
5. Performing PM tasks listed in section 5 of any station SOP.

LOTO is **not** required for purely external visual checks (e.g., reading a
machine status display from the operator side).

## 3. The 7-step LOTO sequence

The standard sequence every technician must follow:

1. **Prepare**: identify all energy sources on the machine. Use the
   station-specific energy chart posted at the machine.
2. **Notify**: tell affected operators that the machine is going out of
   service. Capture the work order ID.
3. **Shut down**: bring the machine to a normal stop via the operator
   controls.
4. **Isolate**: turn off the disconnect for every energy source. Close
   manual valves on air, hydraulic, and chemical lines.
5. **Lockout / tagout**: apply your personal padlock and tag to each
   disconnect. Tag must show technician ID, date, time, and work order ID.
6. **Release stored energy**: bleed residual pressure (hydraulic,
   pneumatic), wait for thermal cooldown, ground any capacitive circuits.
7. **Verify**: attempt to start the machine using the normal start
   controls. The machine must remain de-energized.

## 4. Station-specific notes

- **Line-B Hydraulic-Press** — main accumulator can hold ~3,000 psi after
  electrical disconnect. **Always bleed before opening the ram enclosure.**
  See `Line-B_02_Hydraulic-Press_Maintenance_SOP.pdf` section 4.2.
- **Line-D Curing-Oven** — surfaces stay > 60 °C for at least 60 minutes
  after power-off. Wait for the cool-down indicator before opening any
  panel. See `Line-D_05_Curing-Oven_SOP.pdf`.
- **Line-E Wave-Solder** — solder pot stays molten for ~3 hours after
  power-off. Replace UV lamps on the Conformal-Coat station only when the
  driver disconnect is locked out (UV radiation hazard even at off-cycle
  start). See `Line-E_06_Wave-Solder_Troubleshooting.pdf`.
- **Robotic cells (Welding-Robot, Assembly-Robot)** — robot teach-pendant
  enable is *not* a substitute for LOTO. Always isolate at the drive
  cabinet before entering the cell envelope.

## 5. Group lockout

When more than one technician services the same machine:

- Each technician applies their own padlock to a multi-lock hasp.
- The machine cannot be returned to service until **every** padlock is
  removed by the technician who applied it.

## 6. Removing LOTO

- Only the technician who applied the lock may remove it (except in
  documented emergency-override situations approved by EHS).
- Sequence: verify work is complete → remove tools and personnel from
  machine → re-install all guards → notify operators → remove locks in
  reverse order of application → restore energy → run a verification cycle.

## 7. References

- `Maintenance_Workflow_Overview.pdf`
- Every per-station SOP under section 4 (Faults & corrective actions).
- Local EHS site procedure (binder at the supervisor station).
