# Downtime Logbook (Component B) — design & setup

The Rayfin "OEE Downtime Logbook" lets an operator attach a **structured reason code** to
each downtime occurrence. Those human reasons blend into the Power BI OEE model to produce
a **human-root-cause downtime Pareto** — something machine telemetry alone can't give.

## Why this shape (the constraints that drive it)
Two verified Fabric Apps constraints shape the whole design:
1. A **deployed Rayfin app authenticates with Fabric SSO (Entra) only** — there is no
   service-principal path into its GraphQL.
2. A Rayfin app **can't use an existing/external database** — it only uses its own managed
   SQL database (schema generated from the TypeScript `@entity` models).

So the app **owns and writes only its own data** (`DowntimeReason`) and **reads downtime
facts from a separate, supported read endpoint**. Nothing gates the simulator; there is no
return channel; there are no cross-auth writes.

```
Simulator (unchanged) ─► MaintenanceEvents (telemetry) ─► ManufacturingLH/dbo.RecentDowntime (view)
                                                                    │  (standalone Fabric API for GraphQL, read-only)
                                                                    ▼
Operator ─► Rayfin Downtime Logbook (Fabric SSO) ─ reads queue ────┘
        └─ writes DowntimeReason ─► app managed SQL DB ─► OneLake ─► ManufacturingLH/dbo.DowntimeReason
                                                                     │
                                       Power BI OEE model JOIN on device_id + downtime_start
```

## What counts as "downtime"
Downtime already exists in telemetry — every fault that stops a station creates a
maintenance work order, so the `Created` action on `MaintenanceEvents` is a clean per-episode
downtime start (`device_id` + `timestamp`) with the machine-side `issue_type` attached. The
`dbo.RecentDowntime` view (`app/graphql/RecentDowntime.view.sql`) exposes the last 24h of
those. An occurrence is **"open"** (needs a reason) when no `DowntimeReason` row exists for
its `device_id + downtime_start`; the app computes that diff client-side.

## Setup

### 1. Create the read surface (standalone Fabric API for GraphQL)
1. Apply the view to the **ManufacturingLH SQL analytics endpoint**:
   run `app/graphql/RecentDowntime.view.sql` in the lakehouse SQL endpoint query editor
   (or via `scripts/setup-downtime-graphql.sh`, which prints/applies it).
2. In the workspace, **+ New → API for GraphQL**, name it `oee-downtime-read`.
3. **Add data → ManufacturingLH (SQL analytics endpoint)**, select the `dbo.RecentDowntime`
   view, and expose the auto-generated `recentDowntimes` query.
4. Configure access for the operators who will use the app (user/SSO passthrough). This
   endpoint is **read-only** and separate from the Rayfin app's own GraphQL.
5. Set the endpoint URL in `app/rayfin/.env` as `RAYFIN_PUBLIC_DOWNTIME_GRAPHQL_URL`,
   then run `npm run rayfin:env` (it emits `VITE_RAYFIN_DOWNTIME_GRAPHQL_URL` into
   `.env.local`, which `app/src/downtimeApi.ts` reads).

> The generated query/field names may differ slightly from `app/graphql/recent-downtime.graphql`
> — adjust the query in `app/src/downtimeApi.ts` to match your generated schema.

### 2. Deploy the Rayfin app
The app is a Fabric app built on the **Rayfin SDK**; it deploys with the Rayfin CLI
(`rayfin up`) — there is no `azd`/Bicep path for Fabric apps.
```bash
cd app
npm install
npx rayfin login            # interactive Entra sign-in (skip if already signed in)
npx rayfin up --dry-run     # optional: preview the deploy
npm run rayfin:up           # app + managed SQL DB + Fabric SSO + static hosting  (rayfin up)
npm run rayfin:db           # apply the DowntimeReason schema                      (rayfin up db apply)
npm run rayfin:status       # confirm the deployment state
```
`rayfin up` retrieves the publishable key and writes the `RAYFIN_PUBLIC_*` deployment
values (`RAYFIN_PUBLIC_PUBLISHABLE_KEY`, `RAYFIN_PUBLIC_ITEM_ID`,
`RAYFIN_PUBLIC_WORKSPACE_ID`, …) back into `rayfin/.env`, then regenerates `.env.local`
for the Vite frontend (`VITE_RAYFIN_*` / `VITE_FABRIC_*`). After UI-only changes, redeploy
static content quickly with `npm run rayfin:static` (`rayfin up staticapp deploy`).

### 3. Blend reason codes into the OEE model
The app's managed SQL database mirrors to OneLake. Create a OneLake shortcut so its
`DowntimeReason` table appears at `ManufacturingLH/Tables/dbo/DowntimeReason` (same pattern
`scripts/2-setup-powerbi.sh` uses for `StationDim`). The semantic model already has a
Direct Lake `DowntimeReason` table bound to `ManufacturingLH/dbo.DowntimeReason` and a
`Downtime Reasons Logged` measure; once the shortcut exists, add an
`Availability & Downtime` visual grouped by `DowntimeReason[category]` for the
human-root-cause Pareto.

## Demo it
1. Run the simulator so faults create work orders (downtime occurrences).
2. Open the Downtime Logbook → the **Open downtime** queue fills from telemetry.
3. Log a reason + category on one → it writes to the app DB.
4. In Power BI, refresh → the reason appears in the human-root-cause downtime Pareto.

## Preview / gating caveats
- **Fabric Apps is preview**: tenant admin must enable the workload; capacity + supported
  region required.
- Deployed-app auth is **Fabric SSO only**; local dev uses email/password.
- The read-surface GraphQL and the app are **separate items**; the app never writes to the
  lakehouse/telemetry.
