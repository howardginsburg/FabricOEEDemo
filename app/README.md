# OEE Downtime Logbook (Fabric App / Rayfin)

Component B of the OEE analytics extensions. A standalone Fabric App (Rayfin SDK) that
lets an operator attach a **structured downtime reason code** to each downtime
occurrence. It is deliberately decoupled from the simulator and the other components:

- **Reads** downtime FACTS (read-only) from a **standalone Fabric API for GraphQL** over
  `ManufacturingLH/dbo.RecentDowntime` — it never writes there.
- **Writes** only its OWN data (`DowntimeReason`) to its **own managed Fabric SQL
  database** via the Rayfin app GraphQL.
- The app's SQL DB mirrors to OneLake and is shortcut into
  `ManufacturingLH/dbo.DowntimeReason`, where the Power BI OEE model joins it on
  `device_id + downtime_start` for the **human-root-cause downtime Pareto**.

Why this shape: a deployed Rayfin app uses **Fabric SSO only** and **can't point at an
existing database**, so it owns its store and only reads telemetry through a separate
supported read endpoint. See `docs/DOWNTIME_LOGBOOK.md` for the full rationale and setup.

## Layout
```
app/
├── rayfin/
│   ├── data/DowntimeReason.ts   # the only entity the app owns/writes
│   ├── data/schema.ts           # entity registration
│   ├── rayfin.yml               # Fabric App config (auth=Fabric SSO, data=mssql, static hosting)
│   └── tsconfig.json
├── graphql/
│   ├── RecentDowntime.view.sql  # read surface: SQL view over MaintenanceEvents
│   └── recent-downtime.graphql  # query the frontend runs against the standalone GraphQL API
├── src/                         # React + Vite operator UI (reconciliation queue)
├── package.json / tsconfig.json / vite.config.ts / index.html
```

## Prerequisites
- Node.js 18+. The Rayfin CLI ships as a dev dependency here (`@microsoft/rayfin-cli`),
  so `npx rayfin ...` / the `npm run rayfin:*` scripts work after `npm install`. New apps
  are scaffolded with `npm create @microsoft/rayfin@latest`; this project is already scaffolded.
- A Fabric workspace on capacity with the **Fabric Apps (preview)** workload enabled by a
  tenant admin, in a supported region.
- The core foundation deployed (`scripts/1-setup-fabric.sh`) so `ManufacturingLH` and the
  Silver `MaintenanceEvents` table exist.

## Quick start
```bash
cd app
npm install
cp rayfin/.env.example rayfin/.env   # then set RAYFIN_PUBLIC_DOWNTIME_GRAPHQL_URL (after the read surface exists)
npm run rayfin:env                    # generate .env.local (VITE_* names) from rayfin/.env
npm run dev                           # local frontend dev server

# deploy to Fabric (Rayfin SDK / CLI):
npx rayfin login                      # interactive Entra sign-in (only if not already signed in)
npx rayfin up --dry-run               # preview the deploy without making changes (optional)
npm run rayfin:up                     # provision app + managed SQL DB + Fabric SSO + static hosting
npm run rayfin:db                     # apply the DowntimeReason schema  (rayfin up db apply)
npm run rayfin:static                 # redeploy only the frontend after UI changes (optional)
npm run rayfin:status                 # show the current deployment state
```
`rayfin up` retrieves the publishable key, writes the `RAYFIN_PUBLIC_*` deployment values
back into `rayfin/.env`, and (re)generates `.env.local`. Then follow
`docs/DOWNTIME_LOGBOOK.md` to (1) create the `dbo.RecentDowntime` view + standalone
Fabric API for GraphQL, (2) set `RAYFIN_PUBLIC_DOWNTIME_GRAPHQL_URL` in `rayfin/.env`
(re-run `npm run rayfin:env`), and (3) shortcut the app's `DowntimeReason` table into
`ManufacturingLH` for the analytics blend.

> Deployment requires the Fabric Apps preview workload and interactive (or service-principal)
> Fabric auth, so it is **not** run by the repo's `scripts/*` setup scripts — only the
> Fabric-side plumbing is (`scripts/setup-downtime-graphql.sh`). Dependency versions are
> pinned to the Rayfin `1.34.x` line; re-pin if your CLI scaffolds a newer major.
