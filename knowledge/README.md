# Knowledge corpus — SOPs and corporate documents

This folder is the source for the **Azure AI Search** corpus that backs the
Foundry agent. Its content is what the agent's AI Search knowledge tool
retrieves when an operator asks "how do I fix it?" or "what's the policy?".

## What's in here

| Count | What | Format |
|---|---|---|
| 30 | Per-station SOPs — one per machine type in the simulator | PDF |
| 6 | Cross-cutting / corporate documents (maintenance workflow, LOTO, quality, OEE targets, shift handover, lines reference) | PDF |
| **36** | **Total published documents** | **PDF** |

Plus:

- `source/` — 36 markdown sources (one per PDF, same base name) kept in the
  repo so reviewers can diff content changes line-by-line.
- `source/_template.md` — author template enforcing the same section
  structure across every SOP. Use this when adding a new station.

The PDFs (one per markdown source) are produced by
[`scripts/build-sops.sh`](../scripts/build-sops.sh) and **committed to the
repo** so demo users don't need pandoc or LaTeX installed to run the demo.

## File naming convention

Per-station documents:

```
Line-<X>_<NN>_<MachineType>_<Suffix>.pdf
```

where `X` is `A`/`B`/`C`/`D`/`E`, `NN` is the zero-padded station position
(`01`–`08`), `MachineType` matches the simulator's `machineType` string
exactly, and `Suffix` is one of `SOP`, `Maintenance_SOP`, `Calibration`,
`NDT`, or `Troubleshooting`.

Cross-cutting documents have no `Line-X_NN_` prefix:

```
Maintenance_Workflow_Overview.pdf
Safety_Lockout_Tagout_Procedure.pdf
Quality_Reject_Disposition_Policy.pdf
OEE_Targets_and_Escalation.pdf
Shift_Handover_Checklist.pdf
Production_Lines_Reference.pdf
```

The AI Search indexer uses a regex on `metadata_storage_name` to extract
`line_id` and `station_position` from the per-station files; cross-cutting
files leave those fields empty.

## Source-of-truth alignment

Each station SOP names every `faultType` from
[`simulator/FabricOEESimulator/simulator.yaml`](../simulator/FabricOEESimulator/simulator.yaml)
verbatim as a heading inside section 4. This is deliberate: the simulator
emits those exact strings in the `fault_type` telemetry field, and the
agent retrieves SOP chunks by matching them. If you add a new fault type to
the simulator, **add the matching section to the SOP and rebuild the PDF**
or the agent's recall on that fault will drop.

## Regenerating the PDFs

```bash
# Build all 36 PDFs from source/*.md → knowledge/*.pdf
bash scripts/build-sops.sh

# Build a single doc
bash scripts/build-sops.sh --file Line-B_02_Hydraulic-Press_Maintenance_SOP
```

The script uses `pandoc` + `wkhtmltopdf` by default (lightweight, HTML-styled,
looks like a real org-published checklist). It will also accept
`--engine xelatex` if you prefer a LaTeX-typeset output. See the script
header for prerequisites.

## Document list

### Line-A · Precision Machining (5)

| # | Source markdown | Published PDF |
|---|---|---|
| 1 | `source/Line-A_01_CNC-Lathe_SOP.md` | `Line-A_01_CNC-Lathe_SOP.pdf` |
| 2 | `source/Line-A_02_CNC-Mill_SOP.md` | `Line-A_02_CNC-Mill_SOP.pdf` |
| 3 | `source/Line-A_03_Surface-Grinder_SOP.md` | `Line-A_03_Surface-Grinder_SOP.pdf` |
| 4 | `source/Line-A_04_Deburring-Station_SOP.md` | `Line-A_04_Deburring-Station_SOP.pdf` |
| 5 | `source/Line-A_05_CMM-Inspection_Calibration.md` | `Line-A_05_CMM-Inspection_Calibration.pdf` |

### Line-B · Sheet Metal Forming (4)

| # | Source markdown | Published PDF |
|---|---|---|
| 1 | `source/Line-B_01_Blanking-Press_SOP.md` | `Line-B_01_Blanking-Press_SOP.pdf` |
| 2 | `source/Line-B_02_Hydraulic-Press_Maintenance_SOP.md` | `Line-B_02_Hydraulic-Press_Maintenance_SOP.pdf` |
| 3 | `source/Line-B_03_Trimming-Station_SOP.md` | `Line-B_03_Trimming-Station_SOP.pdf` |
| 4 | `source/Line-B_04_Quality-Inspection_SOP.md` | `Line-B_04_Quality-Inspection_SOP.pdf` |

### Line-C · Welding & Assembly (6)

| # | Source markdown | Published PDF |
|---|---|---|
| 1 | `source/Line-C_01_Component-Loader_SOP.md` | `Line-C_01_Component-Loader_SOP.pdf` |
| 2 | `source/Line-C_02_Welding-Robot_SOP.md` | `Line-C_02_Welding-Robot_SOP.pdf` |
| 3 | `source/Line-C_03_Weld-Inspection_NDT.md` | `Line-C_03_Weld-Inspection_NDT.pdf` |
| 4 | `source/Line-C_04_Fastening-Station_SOP.md` | `Line-C_04_Fastening-Station_SOP.pdf` |
| 5 | `source/Line-C_05_Assembly-Robot_SOP.md` | `Line-C_05_Assembly-Robot_SOP.pdf` |
| 6 | `source/Line-C_06_Leak-Test_SOP.md` | `Line-C_06_Leak-Test_SOP.pdf` |

### Line-D · Surface Treatment (7)

| # | Source markdown | Published PDF |
|---|---|---|
| 1 | `source/Line-D_01_Surface-Prep_SOP.md` | `Line-D_01_Surface-Prep_SOP.pdf` |
| 2 | `source/Line-D_02_Chemical-Wash_SOP.md` | `Line-D_02_Chemical-Wash_SOP.pdf` |
| 3 | `source/Line-D_03_Primer-Application_SOP.md` | `Line-D_03_Primer-Application_SOP.pdf` |
| 4 | `source/Line-D_04_Paint-Booth_SOP.md` | `Line-D_04_Paint-Booth_SOP.pdf` |
| 5 | `source/Line-D_05_Curing-Oven_SOP.md` | `Line-D_05_Curing-Oven_SOP.pdf` |
| 6 | `source/Line-D_06_Coating-Inspection_SOP.md` | `Line-D_06_Coating-Inspection_SOP.pdf` |
| 7 | `source/Line-D_07_Final-Packaging_SOP.md` | `Line-D_07_Final-Packaging_SOP.pdf` |

### Line-E · Electronics Assembly (8)

| # | Source markdown | Published PDF |
|---|---|---|
| 1 | `source/Line-E_01_PCB-Loader_SOP.md` | `Line-E_01_PCB-Loader_SOP.pdf` |
| 2 | `source/Line-E_02_SMT-Placement_SOP.md` | `Line-E_02_SMT-Placement_SOP.pdf` |
| 3 | `source/Line-E_03_Reflow-Oven_SOP.md` | `Line-E_03_Reflow-Oven_SOP.pdf` |
| 4 | `source/Line-E_04_AOI-Inspection_SOP.md` | `Line-E_04_AOI-Inspection_SOP.pdf` |
| 5 | `source/Line-E_05_Through-Hole-Insert_SOP.md` | `Line-E_05_Through-Hole-Insert_SOP.pdf` |
| 6 | `source/Line-E_06_Wave-Solder_Troubleshooting.md` | `Line-E_06_Wave-Solder_Troubleshooting.pdf` |
| 7 | `source/Line-E_07_Functional-Test_SOP.md` | `Line-E_07_Functional-Test_SOP.pdf` |
| 8 | `source/Line-E_08_Conformal-Coat_SOP.md` | `Line-E_08_Conformal-Coat_SOP.pdf` |

### Cross-cutting / corporate documents (6)

| Source markdown | Published PDF |
|---|---|
| `source/Maintenance_Workflow_Overview.md` | `Maintenance_Workflow_Overview.pdf` |
| `source/Safety_Lockout_Tagout_Procedure.md` | `Safety_Lockout_Tagout_Procedure.pdf` |
| `source/Quality_Reject_Disposition_Policy.md` | `Quality_Reject_Disposition_Policy.pdf` |
| `source/OEE_Targets_and_Escalation.md` | `OEE_Targets_and_Escalation.pdf` |
| `source/Shift_Handover_Checklist.md` | `Shift_Handover_Checklist.pdf` |
| `source/Production_Lines_Reference.md` | `Production_Lines_Reference.pdf` |

## Adding a new SOP

1. Copy `source/_template.md` to a new file using the naming convention above.
2. Fill in the front matter (`title`, `line_id`, `station_position`,
   `station_type`).
3. Section 4 — one heading per `faultType` from `simulator.yaml`, **verbatim
   string match**.
4. `bash scripts/build-sops.sh` to produce the PDF.
5. Re-run `bash scripts/5-setup-aisearch.sh` to re-index, or wait for the
   indexer's scheduled run.
