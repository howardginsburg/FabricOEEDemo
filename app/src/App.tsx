import React, { useEffect, useMemo, useState } from 'react';
import { client, fabricAuthOptions } from './rayfinClient';
import { initEmbeddedAuth, ensureSignedInWithFabric } from '@microsoft/rayfin-auth-provider-fabric';
import Insights from './Insights';
import { computeKpis, fmtMin, type FloorEventRow } from './analytics';
import {
  COLORS, CATEGORIES, PRIORITIES, SHIFTS, STATUSES, SEVERITIES, LINES, STATIONS_PER_LINE,
  PRIORITY_COLOR, STATUS_COLOR, CATEGORY_COLOR, deviceId,
  type Category, type Priority, type Shift, type Status, type Severity
} from './theme';

// Deep link to the paired Power BI OEE report (same workspace) for the app↔report tie.
const OEE_REPORT_URL =
  'https://app.fabric.microsoft.com/groups/9e6b9cb3-59b6-40dc-81d3-12f94e17fc4e/reports/4f3213d5-c9fb-40dd-99ef-bee145222c0b';

type Tab = 'raise' | 'board' | 'insights';

interface RaiseForm {
  line_id: string;
  station_position: number;
  shift: Shift;
  category: Category;
  priority: Priority;
  description: string;
  defect_type: string;
  severity: Severity;
  scrap_qty: string;
}

const emptyForm: RaiseForm = {
  line_id: 'Line-A',
  station_position: 1,
  shift: 'Day',
  category: 'Mechanical-Wear',
  priority: 'Medium',
  description: '',
  defect_type: '',
  severity: 'Minor',
  scrap_qty: ''
};

const SELECT_FIELDS = [
  'id', 'device_id', 'line_id', 'station_position', 'shift', 'event_ts', 'category',
  'priority', 'description', 'status', 'acknowledged_at', 'resolved_at', 'root_cause_code',
  'corrective_action', 'defect_type', 'severity', 'scrap_qty', 'raised_by', 'resolved_by', 'logged_at'
] as const;

const NEXT_STATUS: Record<Status, Status | null> = {
  Open: 'Acknowledged',
  Acknowledged: 'In Progress',
  'In Progress': 'Resolved',
  Resolved: null
};

const input: React.CSSProperties = {
  background: COLORS.panelAlt, color: COLORS.text, border: `1px solid ${COLORS.border}`,
  borderRadius: 8, padding: '8px 10px', fontSize: 14, width: '100%'
};
const label: React.CSSProperties = { display: 'block', color: COLORS.textDim, fontSize: 12, marginBottom: 4 };

function Btn({ children, onClick, tone, disabled }: { children: React.ReactNode; onClick?: () => void; tone?: string; disabled?: boolean }) {
  return (
    <button onClick={onClick} disabled={disabled} style={{
      background: tone ?? COLORS.accent, color: '#0b0f18', border: 'none', borderRadius: 8,
      padding: '8px 14px', fontSize: 14, fontWeight: 600, cursor: disabled ? 'default' : 'pointer',
      opacity: disabled ? 0.5 : 1
    }}>{children}</button>
  );
}

export default function App(): React.ReactElement {
  const [rows, setRows] = useState<FloorEventRow[]>([]);
  const [tab, setTab] = useState<Tab>('board');
  const [form, setForm] = useState<RaiseForm>(emptyForm);
  const [status, setStatus] = useState<string>('');
  const [loading, setLoading] = useState<boolean>(false);
  const [authed, setAuthed] = useState<boolean>(false);
  const [authing, setAuthing] = useState<boolean>(true);
  const [user, setUser] = useState<string>('operator');

  async function refresh(): Promise<void> {
    setLoading(true);
    try {
      const data = await client.data.FloorEvent
        .select([...SELECT_FIELDS] as never)
        .orderBy({ logged_at: 'desc' } as never)
        .execute();
      setRows((data ?? []) as unknown as FloorEventRow[]);
      setStatus('');
    } catch (err) {
      setStatus(`Load error: ${(err as Error).message}`);
    } finally {
      setLoading(false);
    }
  }

  function onSession(session: { isAuthenticated?: boolean; user?: { email?: string; id?: string } } | null): boolean {
    if (session?.isAuthenticated) {
      setAuthed(true);
      setUser(session.user?.email ?? session.user?.id ?? 'operator');
      return true;
    }
    return false;
  }

  async function signIn(): Promise<void> {
    setAuthing(true); setStatus('');
    try {
      const session = await ensureSignedInWithFabric(client.auth, fabricAuthOptions);
      if (onSession(session as never)) await refresh();
    } catch (err) {
      setStatus(`Sign-in failed: ${(err as Error).message}`);
    } finally {
      setAuthing(false);
    }
  }

  useEffect(() => {
    void (async () => {
      try {
        const session = await initEmbeddedAuth(client.auth, fabricAuthOptions);
        if (onSession(session as never)) await refresh();
      } catch (err) {
        setStatus(`Auth error: ${(err as Error).message}`);
      } finally {
        setAuthing(false);
      }
    })();
  }, []);

  const kpis = useMemo(() => computeKpis(rows), [rows]);

  async function submitRaise(): Promise<void> {
    if (!form.description.trim()) { setStatus('Enter a description.'); return; }
    try {
      const now = new Date();
      await client.data.FloorEvent.create({
        device_id: deviceId(form.line_id, form.station_position),
        line_id: form.line_id,
        station_position: form.station_position,
        shift: form.shift,
        event_ts: now,
        category: form.category,
        priority: form.priority,
        description: form.description.trim(),
        status: 'Open',
        raised_by: user,
        logged_at: now,
        ...(form.category === 'Quality-Defect'
          ? {
              defect_type: form.defect_type.trim() || undefined,
              severity: form.severity,
              scrap_qty: form.scrap_qty ? Number(form.scrap_qty) : undefined
            }
          : {})
      } as never);
      setStatus(`Raised ${form.priority} issue on ${form.line_id} S${form.station_position}.`);
      setForm(emptyForm);
      await refresh();
      setTab('board');
    } catch (err) {
      setStatus(`Save error: ${(err as Error).message}`);
    }
  }

  async function advance(row: FloorEventRow): Promise<void> {
    const next = NEXT_STATUS[row.status];
    if (!next) return;
    try {
      const patch: Record<string, unknown> = { status: next };
      const now = new Date();
      if (next === 'Acknowledged') patch.acknowledged_at = now;
      if (next === 'Resolved') {
        patch.resolved_at = now;
        patch.resolved_by = user;
        const rc = window.prompt('Root cause code (optional):', row.root_cause_code ?? '') ?? '';
        const ca = window.prompt('Corrective action (optional):', row.corrective_action ?? '') ?? '';
        if (rc.trim()) patch.root_cause_code = rc.trim();
        if (ca.trim()) patch.corrective_action = ca.trim();
      }
      await client.data.FloorEvent.update({ id: row.id } as never, patch as never);
      await refresh();
    } catch (err) {
      setStatus(`Update error: ${(err as Error).message}`);
    }
  }

  return (
    <div style={{
      background: COLORS.bg, color: COLORS.text, minHeight: '100vh',
      fontFamily: 'Segoe UI, system-ui, sans-serif', padding: 24
    }}>
      <div style={{ maxWidth: 1180, margin: '0 auto' }}>
        {/* Header */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 16, flexWrap: 'wrap', marginBottom: 4 }}>
          <h1 style={{ margin: 0, fontSize: 26 }}>🏭 Floor Ops Console</h1>
          <a href={OEE_REPORT_URL} target="_blank" rel="noreferrer" style={{
            marginLeft: 'auto', color: COLORS.accent, fontSize: 13, textDecoration: 'none',
            border: `1px solid ${COLORS.border}`, borderRadius: 8, padding: '6px 12px'
          }}>Open OEE report in Power BI →</a>
        </div>
        <p style={{ color: COLORS.textDim, marginTop: 4 }}>
          Raise and resolve floor issues. Every event flows into the Power BI OEE model (Direct Lake)
          and joins machine telemetry by station, line, and shift — human context beside machine signal.
        </p>

        {/* Header KPI strip */}
        <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', margin: '12px 0 18px' }}>
          <HeaderStat label="Open" value={String(kpis.open)} tone={COLORS.warn} />
          <HeaderStat label="Critical open" value={String(kpis.criticalOpen)} tone={kpis.criticalOpen ? COLORS.bad : COLORS.good} />
          <HeaderStat label="Avg response" value={fmtMin(kpis.mttaMin)} tone={COLORS.accent} />
          <HeaderStat label="Resolution rate" value={`${(kpis.resolutionRate * 100).toFixed(0)}%`} tone={COLORS.good} />
          <HeaderStat label="Scrap qty" value={String(kpis.scrapQty)} tone={kpis.scrapQty ? COLORS.bad : COLORS.text} />
        </div>

        {/* Tabs + actions */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 16, borderBottom: `1px solid ${COLORS.border}`, paddingBottom: 12 }}>
          {(['board', 'raise', 'insights'] as Tab[]).map((t) => (
            <button key={t} onClick={() => setTab(t)} style={{
              background: tab === t ? COLORS.accent : 'transparent',
              color: tab === t ? '#0b0f18' : COLORS.textDim,
              border: `1px solid ${tab === t ? COLORS.accent : COLORS.border}`,
              borderRadius: 8, padding: '8px 16px', fontSize: 14, fontWeight: 600, cursor: 'pointer', textTransform: 'capitalize'
            }}>{t}</button>
          ))}
          <div style={{ marginLeft: 'auto', display: 'flex', gap: 8, alignItems: 'center' }}>
            {authed && <Btn onClick={() => void refresh()} tone={COLORS.panelAlt} disabled={loading}>{loading ? 'Loading…' : '↻ Refresh'}</Btn>}
            {!authed && <Btn onClick={() => void signIn()} disabled={authing}>{authing ? 'Signing in…' : 'Sign in with Fabric'}</Btn>}
          </div>
        </div>

        {status && <p style={{ color: /error|failed/i.test(status) ? COLORS.bad : COLORS.good }}>{status}</p>}

        {!authed && !authing && (
          <div style={{ color: COLORS.textDim, padding: 40, textAlign: 'center' }}>
            Sign in with Fabric to load the floor board.
          </div>
        )}

        {authed && tab === 'board' && <Board rows={rows} onAdvance={advance} loading={loading} />}
        {authed && tab === 'raise' && <RaiseView form={form} setForm={setForm} onSubmit={submitRaise} />}
        {authed && tab === 'insights' && <Insights rows={rows} />}
      </div>
    </div>
  );
}

function HeaderStat({ label, value, tone }: { label: string; value: string; tone: string }) {
  return (
    <div style={{ background: COLORS.panel, border: `1px solid ${COLORS.border}`, borderRadius: 10, padding: '8px 14px' }}>
      <span style={{ color: COLORS.textDim, fontSize: 12, marginRight: 8 }}>{label}</span>
      <span style={{ color: tone, fontSize: 18, fontWeight: 700 }}>{value}</span>
    </div>
  );
}

function RaiseView({ form, setForm, onSubmit }: { form: RaiseForm; setForm: (f: RaiseForm) => void; onSubmit: () => void }) {
  const isQuality = form.category === 'Quality-Defect';
  return (
    <div style={{ background: COLORS.panel, border: `1px solid ${COLORS.border}`, borderRadius: 12, padding: 20, maxWidth: 680 }}>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
        <div>
          <label style={label}>Line</label>
          <select style={input} value={form.line_id} onChange={(e) => setForm({ ...form, line_id: e.target.value })}>
            {LINES.map((l) => <option key={l} value={l}>{l}</option>)}
          </select>
        </div>
        <div>
          <label style={label}>Station</label>
          <select style={input} value={form.station_position} onChange={(e) => setForm({ ...form, station_position: Number(e.target.value) })}>
            {Array.from({ length: STATIONS_PER_LINE }, (_, i) => <option key={i} value={i + 1}>Station {i + 1}</option>)}
          </select>
        </div>
        <div>
          <label style={label}>Shift</label>
          <select style={input} value={form.shift} onChange={(e) => setForm({ ...form, shift: e.target.value as Shift })}>
            {SHIFTS.map((s) => <option key={s} value={s}>{s}</option>)}
          </select>
        </div>
        <div>
          <label style={label}>Priority</label>
          <select style={input} value={form.priority} onChange={(e) => setForm({ ...form, priority: e.target.value as Priority })}>
            {PRIORITIES.map((p) => <option key={p} value={p}>{p}</option>)}
          </select>
        </div>
        <div style={{ gridColumn: 'span 2' }}>
          <label style={label}>Category</label>
          <select style={input} value={form.category} onChange={(e) => setForm({ ...form, category: e.target.value as Category })}>
            {CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
          </select>
        </div>
        <div style={{ gridColumn: 'span 2' }}>
          <label style={label}>Description</label>
          <textarea style={{ ...input, minHeight: 70, resize: 'vertical' }} value={form.description}
            onChange={(e) => setForm({ ...form, description: e.target.value })} placeholder="What happened at the station?" />
        </div>
        {isQuality && (
          <>
            <div>
              <label style={label}>Defect type</label>
              <input style={input} value={form.defect_type} onChange={(e) => setForm({ ...form, defect_type: e.target.value })} placeholder="e.g. Solder bridge" />
            </div>
            <div>
              <label style={label}>Severity</label>
              <select style={input} value={form.severity} onChange={(e) => setForm({ ...form, severity: e.target.value as Severity })}>
                {SEVERITIES.map((s) => <option key={s} value={s}>{s}</option>)}
              </select>
            </div>
            <div>
              <label style={label}>Scrap qty</label>
              <input style={input} type="number" min={0} value={form.scrap_qty} onChange={(e) => setForm({ ...form, scrap_qty: e.target.value })} />
            </div>
          </>
        )}
      </div>
      <div style={{ marginTop: 18 }}>
        <Btn onClick={onSubmit} tone={PRIORITY_COLOR[form.priority]}>Raise issue</Btn>
      </div>
    </div>
  );
}

function Board({ rows, onAdvance, loading }: { rows: FloorEventRow[]; onAdvance: (r: FloorEventRow) => void; loading: boolean }) {
  return (
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 12 }}>
      {STATUSES.map((col) => {
        const items = rows.filter((r) => r.status === col);
        return (
          <div key={col} style={{ background: COLORS.panel, border: `1px solid ${COLORS.border}`, borderRadius: 12, padding: 12, minHeight: 200 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 10 }}>
              <span style={{ width: 10, height: 10, borderRadius: '50%', background: STATUS_COLOR[col] }} />
              <span style={{ fontWeight: 600 }}>{col}</span>
              <span style={{ marginLeft: 'auto', color: COLORS.textDim, fontSize: 13 }}>{items.length}</span>
            </div>
            {items.length === 0 && !loading && <div style={{ color: COLORS.textDim, fontSize: 12, padding: 8 }}>—</div>}
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              {items.map((r) => (
                <div key={r.id} style={{
                  background: COLORS.panelAlt, border: `1px solid ${COLORS.border}`,
                  borderLeft: `4px solid ${PRIORITY_COLOR[r.priority]}`, borderRadius: 8, padding: 10
                }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 4 }}>
                    <span style={{ fontSize: 12, fontWeight: 700, color: PRIORITY_COLOR[r.priority] }}>{r.priority}</span>
                    <span style={{ fontSize: 12, color: COLORS.textDim }}>{r.line_id} · S{r.station_position}</span>
                  </div>
                  <div style={{ fontSize: 13, marginBottom: 6 }}>{r.description}</div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
                    <span style={{ fontSize: 11, background: CATEGORY_COLOR[r.category], color: '#0b0f18', borderRadius: 6, padding: '1px 6px', fontWeight: 600 }}>{r.category}</span>
                    <span style={{ fontSize: 11, color: COLORS.textDim }}>{r.shift}</span>
                    {NEXT_STATUS[r.status] && (
                      <button onClick={() => onAdvance(r)} style={{
                        marginLeft: 'auto', background: 'transparent', color: COLORS.accent,
                        border: `1px solid ${COLORS.border}`, borderRadius: 6, padding: '3px 8px', fontSize: 12, cursor: 'pointer'
                      }}>→ {NEXT_STATUS[r.status]}</button>
                    )}
                  </div>
                </div>
              ))}
            </div>
          </div>
        );
      })}
    </div>
  );
}
