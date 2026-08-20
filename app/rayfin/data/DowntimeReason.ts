import { entity, uuid, text, date, set } from '@microsoft/rayfin-core';

/// Human-entered downtime reason code. This is the ONLY data the Rayfin app owns
/// and writes (to its own managed Fabric SQL database). Downtime FACTS come from
/// telemetry (read-only) — the operator attaches a reason to a downtime occurrence,
/// keyed by device_id + downtime_start so it joins back to MachineEvents /
/// MaintenanceEvents in the Power BI OEE model (ManufacturingLH/dbo.DowntimeReason).
@entity()
export class DowntimeReason {
  @uuid() id!: string;

  /// Station device id, e.g. "line-c-station-2" — matches MachineEvents.device_id.
  @text() device_id!: string;

  /// Start of the downtime occurrence being annotated (from telemetry).
  @date() downtime_start!: Date;

  /// Specific operator-entered reason.
  @text({ max: 120 }) reason_code!: string;

  /// Rollup category (aligns with IssueTypeMaster categories + operational reasons).
  @set(
    'Mechanical-Wear',
    'Jam-Feed',
    'Fluid-Pressure',
    'Thermal',
    'Sensor-Vision-Calibration',
    'Electrical-Other',
    'Material-Shortage',
    'Operator-Adjustment',
    'Planned-Maintenance',
    'Other'
  )
  category!:
    | 'Mechanical-Wear'
    | 'Jam-Feed'
    | 'Fluid-Pressure'
    | 'Thermal'
    | 'Sensor-Vision-Calibration'
    | 'Electrical-Other'
    | 'Material-Shortage'
    | 'Operator-Adjustment'
    | 'Planned-Maintenance'
    | 'Other';

  @text({ optional: true, max: 500 }) comment?: string;

  @text({ optional: true, max: 500 }) corrective_action?: string;

  /// Populated from auth claims (claims.sub) at submit time.
  @text() logged_by!: string;

  @date() logged_at!: Date;
}
