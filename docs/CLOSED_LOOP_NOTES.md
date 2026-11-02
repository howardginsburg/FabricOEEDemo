# Analytics & Act extensions — component map

These extensions add an **analyze** layer and a human **act / write-back** layer on top of
the existing real-time OEE stack. They are deliberately **decoupled**: each is independently
valuable and demoable, the **simulator is untouched**, and everything converges in the
Power BI OEE model via OneLake — not in a fragile real-time control loop.

```
   Simulator (unchanged) ──► Eventhouse/KQL ─┐
   Data Activator (A)      ──► email ──────────┤  (alerts; no store change)
   Floor Ops Console (B)   ──► floor events ───┼──► OneLake ──► Power BI OEE model (0)
   Translytical (C)        ──► OEE targets ─────┘                (everything converges here)
```

## Components

| # | Component | Shows | Store it writes | Reads |
| --- | --- | --- | --- | --- |
| 0 | Power BI semantic model + report | Direct Lake OEE analytics (foundation) | — | ManufacturingLH/dbo (Direct Lake) |
| A | Data Activator alerts | proactive event-driven alerting | — (alerts only) | Eventstream / KQL |
| B | Floor Ops Console | full-stack Fabric App (models→SQL+SSO) with in-app Recharts insights | its own managed Fabric SQL DB (`FloorEvent`) | its own managed DB (Fabric SSO) |
| C | Translytical OEE targets | write-back from inside a report | `OeeGovernance` Fabric SQL DB (`OeeTarget`) | the report's filter context |

- **0 — Power BI:** [`powerbi/`](../powerbi), [`scripts/4-setup-powerbi.sh`](../scripts/4-setup-powerbi.sh),
  [`docs/POWERBI_NOTES.md`](POWERBI_NOTES.md).
- **A — Activator:** [`docs/ACTIVATOR_ALERTS.md`](ACTIVATOR_ALERTS.md),
  [`scripts/5-setup-activator-alerts.sh`](../scripts/5-setup-activator-alerts.sh).
- **B — Floor Ops Console:** [`app/`](../app), [`docs/FLOOR_OPS_CONSOLE.md`](FLOOR_OPS_CONSOLE.md),
  [`scripts/3-setup-floor-ops.sh`](../scripts/3-setup-floor-ops.sh).
- **C — Translytical:** [`powerbi/translytical/`](../powerbi/translytical),
  [`scripts/2-setup-translytical.sh`](../scripts/2-setup-translytical.sh),
  [`docs/TRANSLYTICAL_NOTES.md`](TRANSLYTICAL_NOTES.md).

## The constraints that shaped the design
- **Floor Ops Console = Fabric SSO (Entra user) only** — the app reads/writes its own managed
  Fabric SQL database as the signed-in user; no service principal, no external database.
- **Write-only by design:** component B **writes floor events** to its own DB and visualizes
  them in-app (Recharts). It does not read telemetry back through a standalone API — that avoids
  the extra Entra app registration a separate Fabric API for GraphQL would require, and needs no
  return channel to the simulator.
- **Two stores, one model:** the app owns its DB; translytical uses a separate
  `OeeGovernance` Fabric SQL DB. Both mirror to OneLake and are shortcut into
  `ManufacturingLH/dbo` so the **semantic model is the single place they converge**.

## How they converge in analytics
- **B → 0:** `FloorEvent` (operator-logged events) joins the OEE star on line / station / shift
  → open issues, resolution rate, and human-vs-machine MTTR on the **Floor Ops** report page.
- **C → 0:** `OeeTarget` relates to `DimLine` → `Target OEE` / `OEE vs Target` on the
  Executive page.

## Optional natural tie-ins (never required)
- **A → B:** an Activator outage email can link operators straight to the Floor Ops Console app (just a URL).
- **C → A:** Activator watches OEE vs the translytical-set `OeeTarget` → escalation on breach.

## Preview / capacity gating
All three act-layer capabilities are preview and require tenant enablement + capacity +
a supported region: **Translytical task flows**, **Fabric User Data Functions**, **Fabric
SQL database**, **Fabric Apps (Rayfin)**, and Data Activator maturity. Component 0 (Power BI
Direct Lake) is fully functional on its own without any of them.

## Suggested order
1. Component 0 (foundation; unlocks C) → 2. Component A → 3. Component B → 4. Component C.
Each is shippable before the next.
