import React from 'react';
import {
  BarChart, Bar, Line, ComposedChart, PieChart, Pie, Cell,
  AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, Legend
} from 'recharts';
import {
  computeKpis, categoryPareto, statusBreakdown, priorityBreakdown, dailyTrend,
  lineStationHeat, fmtMin, type FloorEventRow
} from './analytics';
import {
  COLORS, CATEGORY_COLOR, STATUS_COLOR, PRIORITY_COLOR, LINES, STATIONS_PER_LINE
} from './theme';

function Panel({ title, children, span = 1 }: { title: string; children: React.ReactNode; span?: number }) {
  return (
    <div style={{
      background: COLORS.panel, border: `1px solid ${COLORS.border}`, borderRadius: 12,
      padding: 16, gridColumn: `span ${span}`, minWidth: 0
    }}>
      <div style={{ color: COLORS.textDim, fontSize: 12, fontWeight: 600, textTransform: 'uppercase', letterSpacing: 0.5, marginBottom: 12 }}>{title}</div>
      {children}
    </div>
  );
}

function Kpi({ label, value, tone }: { label: string; value: string; tone?: string }) {
  return (
    <div style={{
      background: COLORS.panelAlt, border: `1px solid ${COLORS.border}`, borderRadius: 12,
      padding: '14px 16px', flex: 1, minWidth: 120
    }}>
      <div style={{ color: COLORS.textDim, fontSize: 12, marginBottom: 6 }}>{label}</div>
      <div style={{ color: tone ?? COLORS.text, fontSize: 28, fontWeight: 700, lineHeight: 1 }}>{value}</div>
    </div>
  );
}

const tooltipStyle = {
  background: COLORS.panelAlt, border: `1px solid ${COLORS.border}`, borderRadius: 8, color: COLORS.text
};

function heatColor(count: number, max: number): string {
  if (count === 0) return COLORS.panelAlt;
  const t = max ? count / max : 0;
  // interpolate blue -> red
  const r = Math.round(76 + t * (248 - 76));
  const g = Math.round(194 - t * (194 - 81));
  const b = Math.round(255 - t * (255 - 73));
  return `rgb(${r},${g},${b})`;
}

export default function Insights({ rows }: { rows: FloorEventRow[] }): React.ReactElement {
  const k = computeKpis(rows);
  const pareto = categoryPareto(rows);
  const status = statusBreakdown(rows);
  const priority = priorityBreakdown(rows);
  const trend = dailyTrend(rows);
  const heat = lineStationHeat(rows);
  const heatMax = Math.max(1, ...heat.map((c) => c.count));

  if (rows.length === 0) {
    return (
      <div style={{ color: COLORS.textDim, padding: 40, textAlign: 'center' }}>
        No floor events yet — raise one on the <strong>Raise</strong> tab and the dashboards light up here.
      </div>
    );
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
      {/* KPI row */}
      <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
        <Kpi label="Total events" value={String(k.total)} />
        <Kpi label="Open" value={String(k.open)} tone={COLORS.warn} />
        <Kpi label="Critical open" value={String(k.criticalOpen)} tone={k.criticalOpen ? COLORS.bad : COLORS.good} />
        <Kpi label="Avg response (MTTA)" value={fmtMin(k.mttaMin)} tone={COLORS.accent} />
        <Kpi label="Avg resolve (MTTR)" value={fmtMin(k.mttrMin)} tone={COLORS.accent} />
        <Kpi label="Resolution rate" value={`${(k.resolutionRate * 100).toFixed(0)}%`} tone={COLORS.good} />
        <Kpi label="Scrap qty" value={String(k.scrapQty)} tone={k.scrapQty ? COLORS.bad : COLORS.text} />
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 16 }}>
        {/* Category Pareto */}
        <Panel title="Issue Pareto — top drivers" span={2}>
          <ResponsiveContainer width="100%" height={260}>
            <ComposedChart data={pareto} margin={{ top: 10, right: 20, bottom: 40, left: 0 }}>
              <CartesianGrid stroke={COLORS.border} strokeDasharray="3 3" />
              <XAxis dataKey="category" tick={{ fill: COLORS.textDim, fontSize: 11 }} angle={-25} textAnchor="end" interval={0} height={60} />
              <YAxis yAxisId="l" tick={{ fill: COLORS.textDim, fontSize: 11 }} allowDecimals={false} />
              <YAxis yAxisId="r" orientation="right" domain={[0, 100]} tick={{ fill: COLORS.textDim, fontSize: 11 }} unit="%" />
              <Tooltip contentStyle={tooltipStyle} />
              <Bar yAxisId="l" dataKey="count" radius={[4, 4, 0, 0]}>
                {pareto.map((d) => <Cell key={d.category} fill={CATEGORY_COLOR[d.category]} />)}
              </Bar>
              <Line yAxisId="r" type="monotone" dataKey="cumulativePct" stroke={COLORS.accent} strokeWidth={2} dot={{ r: 3 }} />
            </ComposedChart>
          </ResponsiveContainer>
        </Panel>

        {/* Status donut */}
        <Panel title="Workflow status">
          <ResponsiveContainer width="100%" height={240}>
            <PieChart>
              <Pie data={status} dataKey="count" nameKey="status" innerRadius={55} outerRadius={90} paddingAngle={2}>
                {status.map((d) => <Cell key={d.status} fill={STATUS_COLOR[d.status]} />)}
              </Pie>
              <Legend wrapperStyle={{ color: COLORS.textDim, fontSize: 12 }} />
              <Tooltip contentStyle={tooltipStyle} />
            </PieChart>
          </ResponsiveContainer>
        </Panel>

        {/* Priority bar */}
        <Panel title="By priority">
          <ResponsiveContainer width="100%" height={240}>
            <BarChart data={priority} margin={{ top: 10, right: 10, bottom: 0, left: 0 }}>
              <CartesianGrid stroke={COLORS.border} strokeDasharray="3 3" />
              <XAxis dataKey="priority" tick={{ fill: COLORS.textDim, fontSize: 12 }} />
              <YAxis tick={{ fill: COLORS.textDim, fontSize: 11 }} allowDecimals={false} />
              <Tooltip contentStyle={tooltipStyle} />
              <Bar dataKey="count" radius={[4, 4, 0, 0]}>
                {priority.map((d) => <Cell key={d.priority} fill={PRIORITY_COLOR[d.priority]} />)}
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        </Panel>

        {/* Daily trend */}
        <Panel title="Raised vs resolved (daily)" span={2}>
          <ResponsiveContainer width="100%" height={220}>
            <AreaChart data={trend} margin={{ top: 10, right: 20, bottom: 0, left: 0 }}>
              <defs>
                <linearGradient id="gRaised" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="0%" stopColor={COLORS.bad} stopOpacity={0.5} />
                  <stop offset="100%" stopColor={COLORS.bad} stopOpacity={0} />
                </linearGradient>
                <linearGradient id="gResolved" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="0%" stopColor={COLORS.good} stopOpacity={0.5} />
                  <stop offset="100%" stopColor={COLORS.good} stopOpacity={0} />
                </linearGradient>
              </defs>
              <CartesianGrid stroke={COLORS.border} strokeDasharray="3 3" />
              <XAxis dataKey="day" tick={{ fill: COLORS.textDim, fontSize: 11 }} />
              <YAxis tick={{ fill: COLORS.textDim, fontSize: 11 }} allowDecimals={false} />
              <Tooltip contentStyle={tooltipStyle} />
              <Legend wrapperStyle={{ color: COLORS.textDim, fontSize: 12 }} />
              <Area type="monotone" dataKey="raised" stroke={COLORS.bad} fill="url(#gRaised)" strokeWidth={2} />
              <Area type="monotone" dataKey="resolved" stroke={COLORS.good} fill="url(#gResolved)" strokeWidth={2} />
            </AreaChart>
          </ResponsiveContainer>
        </Panel>

        {/* Line x station heatmap */}
        <Panel title="Issue density — line × station" span={2}>
          <div style={{ overflowX: 'auto' }}>
            <table style={{ borderCollapse: 'separate', borderSpacing: 4 }}>
              <thead>
                <tr>
                  <th />
                  {Array.from({ length: STATIONS_PER_LINE }, (_, i) => (
                    <th key={i} style={{ color: COLORS.textDim, fontSize: 11, fontWeight: 500, padding: 2 }}>S{i + 1}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {LINES.map((line) => (
                  <tr key={line}>
                    <td style={{ color: COLORS.textDim, fontSize: 12, paddingRight: 8, whiteSpace: 'nowrap' }}>{line}</td>
                    {Array.from({ length: STATIONS_PER_LINE }, (_, i) => {
                      const cell = heat.find((c) => c.line_id === line && c.station_position === i + 1)!;
                      return (
                        <td key={i} title={`${line} S${i + 1}: ${cell.count}`} style={{
                          width: 40, height: 34, textAlign: 'center', borderRadius: 6,
                          background: heatColor(cell.count, heatMax),
                          color: cell.count ? '#0b0f18' : COLORS.textDim, fontWeight: 700, fontSize: 12
                        }}>{cell.count || ''}</td>
                      );
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Panel>
      </div>
    </div>
  );
}
