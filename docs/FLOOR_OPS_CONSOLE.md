# Floor Ops Console — design & setup

The **Floor Ops Console** is a Fabric App (Rayfin SDK) that captures what humans do on
the shop floor and blends it into the Power BI OEE model. It replaces the earlier
"Downtime Logbook" component and its telemetry read surface.

## Why the design changed (the key lesson)

A deployed Rayfin app has two hard constraints:

1. It authenticates with **Fabric SSO only**.
2. It can **only use its own managed SQL database** — not an external one.

The old Downtime Logbook tried to *read* the downtime queue from telemetry through a
standalone **API for GraphQL**. Per Microsoft's docs, calling that API from the app's
browser frontend requires a **separate Entra app registration** (SPA + PKCE +
`GraphQLApi.Execute.All`) — heavy ceremony for a same-workspace demo, and the source of a
persistent 401.

So the Floor Ops Console leans into what Fabric Apps do effortlessly: **write your own
data**. There are no outbound reads and no app registration. The app writes events; Fabric
handles the integration.

```
Operator/Supervisor ─► Floor Ops Console (Fabric SSO)
      │  writes FloorEvent (Andon issue / quality defect / shift event)
      ▼
  app's managed Fabric SQL DB ─► OneLake (auto-mirror) ─► OneLake shortcut
      ─► ManufacturingLH/dbo.FloorEvent ─► Direct Lake OEE model ─► Power BI
```

The app **also reads its own rows back** (same Fabric SSO path — supported, no
registration) to render the in-app **Insights** dashboard.

## The single entity: `FloorEvent`

Defined in [`app/rayfin/data/FloorEvent.ts`](../app/rayfin/data/FloorEvent.ts). One row per
floor event, carrying the full Andon lifecycle plus optional quality fields:

| group | fields |
| --- | --- |
| identity/join | `device_id` (→ StationDim), `line_id` (→ DimLine), `shift` (→ DimShift), `station_position` |
| classification | `category`, `priority`, `description` |
| workflow | `status`, `event_ts`, `acknowledged_at`, `resolved_at`, `root_cause_code`, `corrective_action` |
| quality blend | `defect_type`, `severity`, `scrap_qty` |
| identity | `raised_by`, `resolved_by`, `logged_at` |

The Rayfin `@entity` model `FloorEvent` generates a schema-qualified, pluralized table
`dbo.FloorEvents` in the managed DB. The lakehouse shortcut is named `FloorEvent`
(singular) so it surfaces as `dbo.FloorEvent` to match the Power BI model binding.

## How it joins the OEE model

FloorEvent joins the star schema on shared dimensions, so no fragile exact-timestamp
matching is needed — correlation is at the natural line / station / shift / day grain:

- `FloorEvent[device_id]  → StationDim[device_id]`
- `FloorEvent[line_id]    → DimLine[line_id]`
- `FloorEvent[shift]      → DimShift[shift]`

New DAX measures (in `_Measures`, folder **Floor Ops**): `Floor Events Logged`,
`Open Issues`, `Critical Open`, `Resolved Issues`, `Resolution Rate`,
`Human MTTA (min)`, `Human MTTR (min)`, `Scrap Qty`.

## App ↔ report tie-together

The point is that the floor and the boardroom see **the same numbers**:

- **Same KPIs both places** — Open Issues, MTTA/MTTR, Resolution Rate, Scrap render in the
  app's Insights tab *and* the Power BI **Floor Ops** page (the app reads live; the report
  reads the framed Direct Lake copy minutes later).
- **Shared taxonomy** — FloorEvent `category` values align with the OEE loss buckets so
  human cause cross-filters machine effect.
- **Shared visual language** — `app/src/theme.ts` palette mirrors the report theme.
- **Deep link** — the app header links to the OEE report; the report's Floor Ops page pairs
  human vs machine MTTR by line.

## Setup

### 1. Deploy the app
```bash
cd app
npm install
npx rayfin login            # if not already signed in
npm run rayfin:up           # app + managed SQL DB + Fabric SSO + static hosting
npm run rayfin:db           # apply the FloorEvent schema (use --force if replacing a prior entity)
```

### 2. Seed demo data (optional but recommended)
```bash
python scripts/3a-seed-floor-events.py --workspace-name "<WORKSPACE>" --count 80
```
Realistic events across lines/stations/shifts/categories/statuses, timestamped within the
telemetry window. Seeding also gives the OneLake mirror rows to export.

### 3. Wire the data into the OEE model
```bash
bash scripts/3-setup-floor-ops.sh --workspace-name "<WORKSPACE>"
```
Creates the `ManufacturingLH/Tables/dbo/FloorEvent` OneLake shortcut over the app's managed
SQL DB and refreshes the lakehouse SQL analytics endpoint for SQL consumers (the ontology and
the Data Agent). Then re-run `scripts/4-setup-powerbi.sh` (or refresh the `OEEAnalytics`
semantic model) so Direct Lake frames FloorEvent, and re-run `scripts/6-publish-ontology.py`
so the ontology adds its FloorIssue entity.

### 4. Use it
1. Open the app from the Fabric portal (auto Fabric SSO) or the hosting URL (**Sign in with
   Fabric**).
2. **Raise** issues; work them across the **Board**; watch the **Insights** charts update.
3. In Power BI, open the **Floor Ops** page — the same KPIs, joined to OEE by line and shift.

## Preview / gating caveats
- **Fabric Apps is preview**: a tenant admin must enable the workload; capacity + supported
  region required.
- Deployed-app auth is **Fabric SSO only**; local dev can use email/password.
- The lakehouse **must be schema-enabled** (`enableSchemas: true`) for the `dbo` shortcut to
  resolve in Direct Lake — see [`POWERBI_NOTES.md`](POWERBI_NOTES.md).
