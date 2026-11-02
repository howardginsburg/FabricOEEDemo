import { CATEGORIES, LINES, STATIONS_PER_LINE, type Category, type Priority, type Status } from './theme';

/// A FloorEvent row as read back from the app's own managed DB.
export interface FloorEventRow {
  id: string;
  device_id: string;
  line_id: string;
  station_position: number;
  shift: string;
  event_ts: string | Date;
  category: Category;
  priority: Priority;
  description: string;
  status: Status;
  acknowledged_at?: string | Date | null;
  resolved_at?: string | Date | null;
  root_cause_code?: string | null;
  corrective_action?: string | null;
  defect_type?: string | null;
  severity?: string | null;
  scrap_qty?: number | null;
  raised_by: string;
  resolved_by?: string | null;
  logged_at: string | Date;
}

const OPEN_STATES: Status[] = ['Open', 'Acknowledged', 'In Progress'];

function minutesBetween(a?: string | Date | null, b?: string | Date | null): number | null {
  if (!a || !b) return null;
  const t0 = new Date(a).getTime();
  const t1 = new Date(b).getTime();
  if (Number.isNaN(t0) || Number.isNaN(t1) || t1 < t0) return null;
  return (t1 - t0) / 60000;
}

function avg(xs: number[]): number | null {
  if (xs.length === 0) return null;
  return xs.reduce((s, x) => s + x, 0) / xs.length;
}

export interface FloorKpis {
  total: number;
  open: number;
  criticalOpen: number;
  resolved: number;
  resolutionRate: number; // 0..1
  mttaMin: number | null; // event_ts → acknowledged_at
  mttrMin: number | null; // event_ts → resolved_at
  scrapQty: number;
}

export function computeKpis(rows: FloorEventRow[]): FloorKpis {
  const open = rows.filter((r) => OPEN_STATES.includes(r.status));
  const resolved = rows.filter((r) => r.status === 'Resolved');
  const mtta = rows
    .map((r) => minutesBetween(r.event_ts, r.acknowledged_at))
    .filter((x): x is number => x !== null);
  const mttr = rows
    .map((r) => minutesBetween(r.event_ts, r.resolved_at))
    .filter((x): x is number => x !== null);
  return {
    total: rows.length,
    open: open.length,
    criticalOpen: open.filter((r) => r.priority === 'Critical').length,
    resolved: resolved.length,
    resolutionRate: rows.length ? resolved.length / rows.length : 0,
    mttaMin: avg(mtta),
    mttrMin: avg(mttr),
    scrapQty: rows.reduce((s, r) => s + (r.scrap_qty ?? 0), 0)
  };
}

export interface ParetoDatum {
  category: Category;
  count: number;
  cumulativePct: number;
}

/// Category counts sorted desc with a cumulative % line (classic Pareto).
export function categoryPareto(rows: FloorEventRow[]): ParetoDatum[] {
  const counts = new Map<Category, number>();
  for (const c of CATEGORIES) counts.set(c, 0);
  for (const r of rows) counts.set(r.category, (counts.get(r.category) ?? 0) + 1);
  const sorted = [...counts.entries()]
    .filter(([, n]) => n > 0)
    .sort((a, b) => b[1] - a[1]);
  const total = sorted.reduce((s, [, n]) => s + n, 0) || 1;
  let running = 0;
  return sorted.map(([category, count]) => {
    running += count;
    return { category, count, cumulativePct: (running / total) * 100 };
  });
}

export interface StatusDatum {
  status: Status;
  count: number;
}

export function statusBreakdown(rows: FloorEventRow[]): StatusDatum[] {
  const order: Status[] = ['Open', 'Acknowledged', 'In Progress', 'Resolved'];
  return order.map((status) => ({ status, count: rows.filter((r) => r.status === status).length }));
}

export interface PriorityDatum {
  priority: Priority;
  count: number;
}

export function priorityBreakdown(rows: FloorEventRow[]): PriorityDatum[] {
  const order: Priority[] = ['Low', 'Medium', 'High', 'Critical'];
  return order.map((priority) => ({ priority, count: rows.filter((r) => r.priority === priority).length }));
}

export interface TrendDatum {
  day: string; // YYYY-MM-DD
  raised: number;
  resolved: number;
}

/// Events raised vs resolved per day — the momentum area chart.
export function dailyTrend(rows: FloorEventRow[]): TrendDatum[] {
  const byDay = new Map<string, { raised: number; resolved: number }>();
  const key = (d: string | Date) => new Date(d).toISOString().slice(0, 10);
  for (const r of rows) {
    const k = key(r.event_ts);
    if (!byDay.has(k)) byDay.set(k, { raised: 0, resolved: 0 });
    byDay.get(k)!.raised += 1;
    if (r.resolved_at) {
      const rk = key(r.resolved_at);
      if (!byDay.has(rk)) byDay.set(rk, { raised: 0, resolved: 0 });
      byDay.get(rk)!.resolved += 1;
    }
  }
  return [...byDay.entries()]
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([day, v]) => ({ day, ...v }));
}

export interface HeatCell {
  line_id: string;
  station_position: number;
  count: number;
}

/// Line × station issue density for the heatmap grid.
export function lineStationHeat(rows: FloorEventRow[]): HeatCell[] {
  const counts = new Map<string, number>();
  for (const r of rows) counts.set(`${r.line_id}|${r.station_position}`, (counts.get(`${r.line_id}|${r.station_position}`) ?? 0) + 1);
  const cells: HeatCell[] = [];
  for (const line_id of LINES) {
    for (let sp = 1; sp <= STATIONS_PER_LINE; sp++) {
      cells.push({ line_id, station_position: sp, count: counts.get(`${line_id}|${sp}`) ?? 0 });
    }
  }
  return cells;
}

export function fmtMin(x: number | null): string {
  if (x === null) return '—';
  if (x < 60) return `${x.toFixed(0)}m`;
  return `${(x / 60).toFixed(1)}h`;
}
