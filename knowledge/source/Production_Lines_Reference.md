---
title: "Production Lines — Reference Map"
doc_type: "Reference"
version: "1.0"
owner: "Operations Engineering"
last_reviewed: "2026-01-15"
---

# Production Lines — Reference Map

> **Audience:** All personas. Used by the agent to orient any answer about
> "which line", "which station", or "which bottleneck".
> **Applies to:** All 5 production lines (30 stations total).

## 1. Purpose

This is the canonical map of the factory. Every other document — station
SOPs, the maintenance overview, the OEE escalation matrix — refers back to
this document for **line topology, part flow, canonical station ordering,
and bottleneck identification**.

## 2. Lines at a glance

| Line | Domain | Stations | Bottleneck | Target OEE |
|---|---|---|---|---|
| Line-A | Precision Machining | 5 | CMM-Inspection (60 s cycle) | 78 % |
| Line-B | Sheet Metal Forming | 4 | Hydraulic-Press (1.5 % fault rate) | 72 % |
| Line-C | Welding & Assembly | 6 | Welding-Robot + Leak-Test | 75 % |
| Line-D | Surface Treatment | 7 | Curing-Oven (90 s cycle) | 70 % |
| Line-E | Electronics Assembly | 8 | Wave-Solder (0.7 % fault rate) | 73 % |

## 3. Canonical station ordering

The simulator processes parts in strict left-to-right order on each line.
Buffer capacity between adjacent stations is **5 parts**.

### Line-A · Precision Machining

```
01 CNC-Lathe → 02 CNC-Mill → 03 Surface-Grinder → 04 Deburring-Station → 05 CMM-Inspection
```

- Part type produced: precision machined components.
- Bottleneck: **CMM-Inspection** at 60 s ideal cycle. Any outage here
  starves nothing downstream (final station) but **blocks** Deburring.
- See SOPs: `Line-A_01_CNC-Lathe_SOP.pdf` through
  `Line-A_05_CMM-Inspection_Calibration.pdf`.

### Line-B · Sheet Metal Forming

```
01 Blanking-Press → 02 Hydraulic-Press → 03 Trimming-Station → 04 Quality-Inspection
```

- Part type produced: sheet metal panels.
- Bottleneck: **Hydraulic-Press** by fault-rate (1.5 % — the highest on
  this line). Watch closely per
  `Line-B_02_Hydraulic-Press_Maintenance_SOP.pdf`.
- See SOPs: `Line-B_01_Blanking-Press_SOP.pdf` through
  `Line-B_04_Quality-Inspection_SOP.pdf`.

### Line-C · Welding & Assembly

```
01 Component-Loader → 02 Welding-Robot → 03 Weld-Inspection → 04 Fastening-Station → 05 Assembly-Robot → 06 Leak-Test
```

- Part type produced: welded sub-assemblies.
- Bottleneck: **Welding-Robot** for performance, **Leak-Test** for quality
  (3 % reject target).
- See SOPs: `Line-C_01_Component-Loader_SOP.pdf` through
  `Line-C_06_Leak-Test_SOP.pdf`.

### Line-D · Surface Treatment

```
01 Surface-Prep → 02 Chemical-Wash → 03 Primer-Application → 04 Paint-Booth → 05 Curing-Oven → 06 Coating-Inspection → 07 Final-Packaging
```

- Part type produced: coated parts ready for ship.
- Bottleneck: **Curing-Oven** at 90 s ideal cycle. **Curing-Oven outage
  cascades within 1 cycle** — it starves Coating-Inspection and Packaging,
  and blocks Paint-Booth.
- Note: Curing-Oven stays > 60 °C for ~60 min after shutdown. See
  `Line-D_05_Curing-Oven_SOP.pdf`.

### Line-E · Electronics Assembly

```
01 PCB-Loader → 02 SMT-Placement → 03 Reflow-Oven → 04 AOI-Inspection → 05 Through-Hole-Insert → 06 Wave-Solder → 07 Functional-Test → 08 Conformal-Coat
```

- Part type produced: electronics modules.
- Bottleneck: **Wave-Solder** by fault-rate (0.7 %). Solder pot stays
  molten ~3 hours after power-off. See
  `Line-E_06_Wave-Solder_Troubleshooting.pdf`.
- AOI-Inspection has a 4 % reject-rate target — the highest on this line.

## 4. Cross-line dependencies

The 5 lines run independently — there is no inter-line part flow in this
factory. **A fault on Line-A does not affect Line-D.** However:

- **Maintenance technicians are shared** across all lines. A surge of work
  orders on one line can delay response on another. See
  `Maintenance_Workflow_Overview.pdf` §4.
- **The Plant Manager dashboard** aggregates OEE across all 5 lines and is
  the place to detect cross-line patterns (e.g., shift-change quality
  dips).

## 5. Telemetry hierarchy

Telemetry events from the simulator carry these identifiers:

- `line_id` ∈ { `Line-A`, `Line-B`, `Line-C`, `Line-D`, `Line-E` }
- `station_position` ∈ { `01`, `02`, … } — 1-indexed position on the line.
- `station_type` — e.g., `CNC-Lathe`. The same `station_type` can appear
  on different lines (e.g., `Nozzle-Clog` appears on Line-D Primer,
  Line-D Paint-Booth, Line-E SMT-Placement, and Line-E Conformal-Coat).

When the agent answers, **always disambiguate by `line_id` + `station_position`**
so the user knows exactly which station is being discussed.

## 6. References

- All 30 per-station SOPs.
- `Maintenance_Workflow_Overview.pdf` — fault-type table by station.
- `OEE_Targets_and_Escalation.pdf` — KPI targets and escalation matrix.
- `Quality_Reject_Disposition_Policy.pdf` — reject-rate targets and
  pause thresholds by station.
- `Shift_Handover_Checklist.pdf` — bottleneck-station status review.
