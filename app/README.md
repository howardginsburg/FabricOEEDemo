# Floor Ops Console (Fabric App / Rayfin)

A standalone **Fabric App** (Rayfin SDK) that is the operator/supervisor cockpit for the
shop floor. It blends three workflows into one event lifecycle:

- **Andon** — an operator raises an issue at a station; a supervisor works it through
  **Open → Acknowledged → In Progress → Resolved** with response timestamps.
- **Quality** — when the category is `Quality-Defect`, defect type / severity / scrap
  quantity are captured too.
- **Shift** — line + shift + timestamp roll every event up to a shift scorecard.

## Why this shape (the important architecture point)

A deployed Rayfin app authenticates with **Fabric SSO only** and can **only use its own
managed SQL database** — it can't reach out to arbitrary external endpoints without a
separate Entra app registration. So this app is deliberately **write-only to its own
store**, and lets Fabric do the integration:

```
Operator/Supervisor ─► Floor Ops Console (Fabric SSO)
      │  writes FloorEvent
      ▼
  app's managed Fabric SQL DB ─► OneLake (auto-mirror) ─► shortcut
      ─► ManufacturingLH/dbo.FloorEvent ─► Direct Lake OEE model
```

No telemetry reads, no ETL, no registration. The app **also reads its OWN rows back**
(same Fabric SSO path) to render the in-app **Insights** dashboard — that's fully
supported because it's the app's own managed database, not an external data source.

The FloorEvent table joins the OEE star schema on shared dimensions
(`device_id → StationDim`, `line_id → DimLine`, `shift → DimShift`), so human floor
context sits **beside** machine telemetry in Power BI — same KPIs on the floor and in
leadership's report, minutes apart.

See [`docs/FLOOR_OPS_CONSOLE.md`](../docs/FLOOR_OPS_CONSOLE.md) for the full flow.

## Layout
```
app/
├── rayfin/
│   ├── data/FloorEvent.ts       # the only entity the app owns/writes
│   ├── data/schema.ts           # entity registration
│   ├── rayfin.yml               # Fabric App config (auth=Fabric SSO, data=mssql, static hosting)
│   └── .env / .env.example      # deployment + runtime values
├── src/
│   ├── App.tsx                  # 3-tab console: Board (Kanban) · Raise · Insights
│   ├── Insights.tsx             # in-app charts (Recharts) from the app's own data
│   ├── analytics.ts             # KPI / chart derivations
│   ├── theme.ts                 # shared palette + taxonomy (aligned with the PBIR theme)
│   └── rayfinClient.ts          # Rayfin client + Fabric SSO options
├── package.json / tsconfig.json / vite.config.ts / index.html
```

## Prerequisites
- Node.js 18+. The Rayfin CLI ships as a dev dependency (`@microsoft/rayfin-cli`), so
  `npx rayfin ...` / the `npm run rayfin:*` scripts work after `npm install`.
- A Fabric workspace on capacity with the **Fabric Apps (preview)** workload enabled by a
  tenant admin, in a supported region.
- The core foundation deployed (`scripts/1-setup-fabric.sh`) so the schema-enabled
  `ManufacturingLH` lakehouse exists.

## Quick start
```bash
cd app
npm install
cp rayfin/.env.example rayfin/.env    # first deploy fills the RAYFIN_PUBLIC_* values

# deploy to Fabric (Rayfin SDK / CLI):
npx rayfin login                      # interactive Entra sign-in (only if not already signed in)
npm run rayfin:up                     # provision app + managed SQL DB + Fabric SSO + static hosting
npm run rayfin:db                     # apply the FloorEvent schema  (rayfin up db apply)
npm run rayfin:static                 # redeploy only the frontend after UI changes
npm run rayfin:status                 # show the current deployment state
```

Then wire the data into the OEE model (from the repo root):
```bash
python scripts/3a-seed-floor-events.py --workspace-name "<WORKSPACE>"   # optional demo data
bash   scripts/3-setup-floor-ops.sh   --workspace-name "<WORKSPACE>"   # OneLake shortcut + endpoint refresh
```
Finally refresh the `OEEAnalytics` semantic model and open the **Floor Ops** report page.

## Auth
Auth is **Fabric SSO** via `@microsoft/rayfin-auth-provider-fabric`. When the app is
launched embedded in the Fabric portal it signs in automatically (postMessage handoff);
opened standalone it shows a **Sign in with Fabric** button. No Entra app registration is
required — the app only talks to its own managed backend.

> Deployment requires the Fabric Apps preview workload and interactive (or service-principal)
> Fabric auth, so it is **not** run by the repo's numbered `scripts/*`. Dependency versions
> are pinned to the Rayfin `1.34.x` line; re-pin if your CLI scaffolds a newer major.
