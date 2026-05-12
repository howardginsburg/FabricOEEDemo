# Knowledge Source #2 — Azure AI Search `oee-sops`

## Identity

- **Type:** Azure AI Search index
- **Role:** Static SOP corpus
- **Endpoint:** `https://<search-service>.search.windows.net`
- **Index name:** `oee-sops`
- **Embedding model:** `text-embedding-3-large` (dim 3072)
- **Semantic configuration:** `oee-semantic`

## Corpus

36 PDFs indexed:

- **30 per-station SOPs** — one per simulator station, filename:
  `Line-<X>_<NN>_<StationType>_<Suffix>.pdf`. Each SOP has a fixed
  section structure: (1) Purpose, (2) Normal operating envelope,
  (3) Idle reasons, (4) Faults & corrective actions, (5) PM schedule,
  (6) References. Section 4 headings use the simulator's `fault_type`
  strings **verbatim** so retrieval matches the telemetry event.
- **6 cross-cutting documents** — `Maintenance_Workflow_Overview.pdf`,
  `Safety_Lockout_Tagout_Procedure.pdf`,
  `Quality_Reject_Disposition_Policy.pdf`,
  `OEE_Targets_and_Escalation.pdf`, `Shift_Handover_Checklist.pdf`,
  `Production_Lines_Reference.pdf`.

## Fields

| Field | Type | Purpose |
|---|---|---|
| `id` | string | Document chunk key. |
| `parent_id` | string | Parent PDF chunk owner. |
| `metadata_storage_name` | string | PDF filename — used in citations. |
| `metadata_storage_path` | string | Blob URL. |
| `metadata_content_type` | string | `application/pdf`. |
| `line_id` | string | `Line-A` … `Line-E` for station SOPs; empty for cross-cutting docs. |
| `station_position` | string | `01` … `08` for station SOPs; empty for cross-cutting docs. |
| `page_number` | int32 | Page within the PDF. |
| `chunk` | string | Text chunk used for keyword/semantic search. |
| `vector` | Collection(Single) | Embedding for vector search. |

## Retrieval modes

- **Semantic** (default for natural-language questions): keyword +
  re-ranker. Use `queryType=semantic`, `semanticConfiguration=oee-semantic`.
- **Hybrid** (recommended): keyword + vector. Add a `vectorQueries`
  block with the user query embedded by the same model.
- **Filtered**: when the user names a station, add
  `filter=line_id eq '<X>' and station_position eq '<NN>'` to ground
  the answer in the right SOP.
- **Cross-cutting**: when the user asks a factory-wide question, filter
  with `line_id eq '' and station_position eq ''` (or drop the filter
  entirely).

## When to use

- "How do I clear a Nozzle-Clog on the SMT-Placement?"
- "What's the preventive-maintenance schedule for the Curing-Oven?"
- "What is the LOTO procedure for the Hydraulic-Press?"
- "When do I escalate a Quality reject?"
- "What is the bottleneck on Line-E?"

## What it will NOT answer well

- "Is the Curing-Oven running right now?" — live state; use Fabric Data
  Agent.
- "How many open work orders on Line-C?" — live state; use Fabric Data
  Agent.

## Citation format

Cite by filename, e.g.:

> *Source: Line-D_05_Curing-Oven_SOP.pdf*

If multiple PDFs contributed, list them in retrieval-order under the
answer.
