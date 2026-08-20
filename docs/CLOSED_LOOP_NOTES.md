# Analytics & Act extensions — component map

These extensions add an **analyze** layer and a human **act / write-back** layer on top of
the existing real-time OEE stack. They are deliberately **decoupled**: each is independently
valuable and demoable, the **simulator is untouched**, and everything converges in the
Power BI OEE model via OneLake — not in a fragile real-time control loop.

```
   Simulator (unchanged) ──► Eventhouse/KQL ─┐
   Data Activator (A)      ──► Teams/email ────┤  (alerts; no store change)
   Rayfin Downtime app (B) ──► reason codes ───┼──► OneLake ──► Power BI OEE model (0)
   Translytical (C)        ──► OEE targets ─────┘                (everything converges here)
```

## Components

| # | Component | Shows | Store it writes | Reads |
| --- | --- | --- | --- | --- |
| 0 | Power BI semantic model + report | Direct Lake OEE analytics (foundation) | — | ManufacturingLH/dbo (Direct Lake) |
| A | Data Activator alerts | proactive event-driven alerting | — (alerts only) | Eventstream / KQL |
| B | Rayfin Downtime Logbook | full-stack app on Fabric (models→GraphQL+SQL+SSO) | its own managed SQL DB (`DowntimeReason`) | standalone GraphQL over `dbo.RecentDowntime` |
| C | Translytical OEE targets | write-back from inside a report | `OeeGovernance` Fabric SQL DB (`OeeTarget`) | the report's filter context |

- **0 — Power BI:** [`powerbi/`](../powerbi), [`scripts/2-setup-powerbi.sh`](../scripts/2-setup-powerbi.sh),
  [`docs/POWERBI_NOTES.md`](POWERBI_NOTES.md).
- **A — Activator:** [`docs/ACTIVATOR_ALERTS.md`](ACTIVATOR_ALERTS.md),
  [`scripts/setup-activator-alerts.sh`](../scripts/setup-activator-alerts.sh).
- **B — Rayfin app:** [`app/`](../app), [`docs/DOWNTIME_LOGBOOK.md`](DOWNTIME_LOGBOOK.md),
  [`scripts/setup-downtime-graphql.sh`](../scripts/setup-downtime-graphql.sh).
- **C — Translytical:** [`powerbi/translytical/`](../powerbi/translytical),
  [`scripts/3-setup-translytical.sh`](../scripts/3-setup-translytical.sh),
  [`docs/TRANSLYTICAL_NOTES.md`](TRANSLYTICAL_NOTES.md).

## The constraints that shaped the design
- **Rayfin app GraphQL = Fabric SSO (Entra user) only** — no service principal after deploy.
- **Rayfin can't use an existing/external database** — it only uses its own managed SQL DB.
  → Component B **writes only its own reason codes** and **reads** downtime from a separate
  standalone Fabric API for GraphQL. It never gates the simulator and needs no return channel.
- **Two stores, one model:** the Rayfin app owns its DB; translytical uses a separate
  `OeeGovernance` Fabric SQL DB. Both mirror to OneLake and are shortcut into
  `ManufacturingLH/dbo` so the **semantic model is the single place they converge**.

## How they converge in analytics
- **B → 0:** `DowntimeReason` (human reason codes) joins telemetry downtime on
  `device_id + downtime_start` → human-root-cause downtime Pareto on the Availability page.
- **C → 0:** `OeeTarget` relates to `DimLine` → `Target OEE` / `OEE vs Target` on the
  Executive page.

## Optional natural tie-ins (never required)
- **A → B:** an Activator alert message links to the Downtime Logbook app (just a URL).
- **C → A:** Activator watches OEE vs the translytical-set `OeeTarget` → escalation on breach.

## Preview / capacity gating
All three act-layer capabilities are preview and require tenant enablement + capacity +
a supported region: **Translytical task flows**, **Fabric User Data Functions**, **Fabric
SQL database**, **Fabric Apps (Rayfin)**, and Data Activator maturity. Component 0 (Power BI
Direct Lake) is fully functional on its own without any of them.

## Suggested order
1. Component 0 (foundation; unlocks C) → 2. Component A → 3. Component B → 4. Component C.
Each is shippable before the next.
