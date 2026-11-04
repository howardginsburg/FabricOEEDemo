# 4. Floor Ops Console

The Floor Ops Console is a Fabric App where operators raise floor issues (Andon calls, quality defects, shift
events) and supervisors work them to resolution. The app writes to its own Fabric SQL database, which mirrors to
OneLake, and a lakehouse shortcut brings the events into the Power BI report next to the machine data.

Run it **before** [step 5](power-bi.md), so the semantic model includes the `FloorEvent` table.

## Deploy the app

From the repository, with Node.js 18 or later:

```bash
cd app
npm install
cp rayfin/.env.example rayfin/.env
npx rayfin login        # only if you aren't signed in yet
npm run rayfin:up       # creates the app, its SQL database, and its hosting
npm run rayfin:db       # applies the FloorEvent table
cd ..
```

`rayfin:up` fills in the `RAYFIN_PUBLIC_*` values in `rayfin/.env`. The app signs users in with their Fabric
account; there's no app registration.

## Add demo data and connect it

```bash
python3 scripts/3a-seed-floor-events.py --workspace-name "<FABRIC_WORKSPACE>" --count 80
bash scripts/3-setup-floor-ops.sh --workspace-name "<FABRIC_WORKSPACE>"
```

- Script `3a` seeds realistic events across lines, stations, shifts, and statuses over the last 48 hours
  (`--window-hours`), so the app's charts and the report page aren't empty. It needs `pyodbc` and ODBC
  Driver 18.
- Script `3` creates the `FloorEvent` shortcut in `ManufacturingLH` over the app's mirrored table. If your
  app's database isn't named `oee-downtime-logbook`, pass `--app-sqldb-name`.

## Verify

- The workspace has the `oee-downtime-logbook` app backend and its `oee-downtime-logbook` SQL database.
- The app opens at its hosting URL, which `npm run rayfin:up` saves as `hostingUrl` in
  `app/rayfin/.deployments.json`. **Sign in with Fabric** opens a sign-in pop-up, so allow pop-ups for the
  site. The **Board** and **Insights** tabs then show the seeded events.
- `ManufacturingLH` lists `FloorEvent` under **Tables > dbo**.

!!! warning "Preview"
    Fabric Apps is in preview. The **Enable Fabric App Items (preview)** tenant setting must be on; see
    [Prerequisites](prerequisites.md).
