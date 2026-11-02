/// Shared visual language for the Floor Ops Console. The category + priority palette
/// mirrors the Power BI report theme so the app and the report read as one product.

export const CATEGORIES = [
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
] as const;
export type Category = (typeof CATEGORIES)[number];

export const PRIORITIES = ['Low', 'Medium', 'High', 'Critical'] as const;
export type Priority = (typeof PRIORITIES)[number];

export const STATUSES = ['Open', 'Acknowledged', 'In Progress', 'Resolved'] as const;
export type Status = (typeof STATUSES)[number];

export const SHIFTS = ['Day', 'Night'] as const;
export type Shift = (typeof SHIFTS)[number];

export const SEVERITIES = ['Minor', 'Major', 'Critical'] as const;
export type Severity = (typeof SEVERITIES)[number];

/// Fixed line taxonomy — matches the simulator / DimLine (Line-A … Line-E), each with
/// a set number of stations. The operator picks from these; device_id is derived so it
/// joins to StationDim.device_id in the OEE model.
export const LINES = ['Line-A', 'Line-B', 'Line-C', 'Line-D', 'Line-E'] as const;
export const STATIONS_PER_LINE = 6;

/// device_id convention shared with scripts/1-setup-fabric.sh StationMaster:
///   strcat(tolower(line_id), '-station-', station_position)
export function deviceId(lineId: string, stationPosition: number): string {
  return `${lineId.toLowerCase()}-station-${stationPosition}`;
}

// ── Palette ────────────────────────────────────────────────────────────────
export const COLORS = {
  bg: '#0f1420',
  panel: '#171d2b',
  panelAlt: '#1e2536',
  border: '#2a3346',
  text: '#e7ecf5',
  textDim: '#9aa7bd',
  accent: '#4cc2ff',
  good: '#3fb950',
  warn: '#d29922',
  bad: '#f85149'
} as const;

export const PRIORITY_COLOR: Record<Priority, string> = {
  Low: '#3fb950',
  Medium: '#d29922',
  High: '#fb8500',
  Critical: '#f85149'
};

export const STATUS_COLOR: Record<Status, string> = {
  Open: '#f85149',
  Acknowledged: '#d29922',
  'In Progress': '#4cc2ff',
  Resolved: '#3fb950'
};

/// Stable, distinct colors per category (shared with the PBIR theme ordering).
export const CATEGORY_COLOR: Record<Category, string> = {
  'Mechanical-Wear': '#4cc2ff',
  'Jam-Feed': '#7ee787',
  'Fluid-Pressure': '#79c0ff',
  Thermal: '#ff7b72',
  'Sensor-Vision-Calibration': '#d2a8ff',
  'Electrical-Other': '#ffa657',
  'Material-Shortage': '#f2cc60',
  'Quality-Defect': '#ff6ac1',
  'Operator-Adjustment': '#56d4dd',
  'Planned-Maintenance': '#8b949e',
  Other: '#6e7681'
};
