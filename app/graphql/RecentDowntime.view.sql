-- RecentDowntime read surface for the Rayfin Downtime Logbook.
-- Create this VIEW in the ManufacturingLH SQL analytics endpoint (dbo schema), then
-- build a standalone "Fabric API for GraphQL" over it (see docs/DOWNTIME_LOGBOOK.md).
-- The view exposes one row per downtime occurrence (a maintenance work order Created
-- event) in the last 24h — the queue the operator annotates with a reason code.
--
-- Why MaintenanceEvents: each fault that stops a station creates a work order, so the
-- 'Created' action is a clean per-episode downtime start (device_id + timestamp) with
-- the machine-side issue_type already attached. The app treats an occurrence as "open"
-- when no DowntimeReason row exists for that device_id + downtime_start.
CREATE OR ALTER VIEW dbo.RecentDowntime AS
SELECT
    m.work_order_id,
    m.device_id,
    m.line_id,
    m.station_position,
    m.machine_type,
    m.issue_type,
    m.timestamp        AS downtime_start
FROM dbo.MaintenanceEvents AS m
WHERE m.action = 'Created'
  AND m.timestamp >= DATEADD(HOUR, -24, SYSUTCDATETIME());
GO
