import { entity, uuid, text, date, int, set } from '@microsoft/rayfin-core';

/// A single floor operations event — the one entity behind the "Floor Ops Console".
/// It blends three shop-floor workflows into one lifecycle:
///   • Andon    — an operator raises an issue at a station; a supervisor works it
///                through Open → Acknowledged → In Progress → Resolved.
///   • Quality  — when category is a quality issue, defect_type / severity / scrap_qty
///                capture the scrap detail.
///   • Shift    — line_id + shift + event_ts roll every event up to a shift scorecard.
///
/// This is the ONLY data the Fabric app owns and writes (to its own managed Fabric SQL
/// database via Fabric SSO — no external reads, no Entra app registration). The app also
/// READS ITS OWN rows back for the in-app Insights dashboard. The table mirrors to OneLake
/// and is surfaced at ManufacturingLH/dbo.FloorEvent via a shortcut, where the Direct Lake
/// OEE model joins it on device_id → StationDim (and through the model to line / shift /
/// machine type) for the human-context-meets-machine-telemetry story.
@entity()
export class FloorEvent {
  @uuid() id!: string;

  /// Station device id, e.g. "line-c-station-2" — matches StationDim.device_id /
  /// MachineEvents.device_id. Built in the app from line_id + station_position.
  @text() device_id!: string;

  /// Production line, e.g. "Line-C" — matches DimLine.line_id.
  @text() line_id!: string;

  /// Station position within the line (1-based).
  @int() station_position!: number;

  /// Shift the event was raised on — matches DimShift.shift.
  @set('Day', 'Night')
  shift!: 'Day' | 'Night';

  /// When the issue was raised (aligns to the OEE telemetry window for correlation).
  @date() event_ts!: Date;

  /// Issue category. Values align with IssueTypeMaster / OEE loss buckets so app issues
  /// cross-filter machine telemetry (human cause ↔ machine effect). "Quality-Defect"
  /// unlocks the quality fields below.
  @set(
    'Mechanical-Wear',
    'Jam-Feed',
    'Fluid-Pressure',
    'Thermal',
    'Sensor-Vision-Calibration',
    'Electrical-Other',
    'Material-Shortage',
    'Quality-Defect',
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
    | 'Quality-Defect'
    | 'Operator-Adjustment'
    | 'Planned-Maintenance'
    | 'Other';

  /// Andon priority — drives board color + "Critical Open" KPI.
  @set('Low', 'Medium', 'High', 'Critical')
  priority!: 'Low' | 'Medium' | 'High' | 'Critical';

  /// Free-text description of what the operator saw.
  @text({ max: 500 }) description!: string;

  /// Workflow state. Supervisors advance this on the board.
  @set('Open', 'Acknowledged', 'In Progress', 'Resolved')
  status!: 'Open' | 'Acknowledged' | 'In Progress' | 'Resolved';

  /// Timestamps set as the event moves through the workflow — power human MTTA / MTTR.
  @date({ optional: true }) acknowledged_at?: Date;
  @date({ optional: true }) resolved_at?: Date;

  /// Resolution detail (supervisor-entered on close).
  @text({ optional: true, max: 120 }) root_cause_code?: string;
  @text({ optional: true, max: 500 }) corrective_action?: string;

  /// Quality blend — only meaningful when category === 'Quality-Defect'.
  @text({ optional: true, max: 80 }) defect_type?: string;
  @set({ enum: ['Minor', 'Major', 'Critical'], optional: true })
  severity?: 'Minor' | 'Major' | 'Critical';
  @int({ optional: true }) scrap_qty?: number;

  /// Identity from Fabric SSO auth claims (claims.sub) at raise / resolve time.
  @text() raised_by!: string;
  @text({ optional: true }) resolved_by?: string;

  @date() logged_at!: Date;
}
