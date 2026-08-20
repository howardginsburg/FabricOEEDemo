import React, { useEffect, useMemo, useState } from 'react';
import { client } from './rayfinClient';
import { fetchRecentDowntime, occurrenceKey, type DowntimeOccurrence } from './downtimeApi';

const CATEGORIES = [
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
] as const;
type Category = (typeof CATEGORIES)[number];

interface FormState {
  reason_code: string;
  category: Category;
  comment: string;
  corrective_action: string;
}

const emptyForm: FormState = {
  reason_code: '',
  category: 'Mechanical-Wear',
  comment: '',
  corrective_action: ''
};

export default function App(): React.ReactElement {
  const [occurrences, setOccurrences] = useState<DowntimeOccurrence[]>([]);
  const [loggedKeys, setLoggedKeys] = useState<Set<string>>(new Set());
  const [selected, setSelected] = useState<DowntimeOccurrence | null>(null);
  const [form, setForm] = useState<FormState>(emptyForm);
  const [status, setStatus] = useState<string>('');
  const [loading, setLoading] = useState<boolean>(true);

  async function refresh(): Promise<void> {
    setLoading(true);
    try {
      const [recent, logged] = await Promise.all([
        fetchRecentDowntime(),
        client.data.DowntimeReason.select(['device_id', 'downtime_start']).execute()
      ]);
      const keys = new Set<string>(
        (logged ?? []).map((r: { device_id: string; downtime_start: string | Date }) =>
          occurrenceKey(r.device_id, String(r.downtime_start))
        )
      );
      setOccurrences(recent);
      setLoggedKeys(keys);
      setStatus('');
    } catch (err) {
      setStatus(`Load error: ${(err as Error).message}`);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void refresh();
  }, []);

  // "Open" queue = telemetry downtime not yet annotated in the app's own store.
  const openQueue = useMemo(
    () => occurrences.filter((o) => !loggedKeys.has(occurrenceKey(o.device_id, o.downtime_start))),
    [occurrences, loggedKeys]
  );

  async function submit(): Promise<void> {
    if (!selected) return;
    if (!form.reason_code.trim()) {
      setStatus('Enter a reason code.');
      return;
    }
    try {
      await client.data.DowntimeReason.create({
        device_id: selected.device_id,
        downtime_start: new Date(selected.downtime_start),
        reason_code: form.reason_code.trim(),
        category: form.category,
        comment: form.comment.trim() || undefined,
        corrective_action: form.corrective_action.trim() || undefined,
        logged_by: 'operator',
        logged_at: new Date()
      });
      setStatus(`Logged reason for ${selected.device_id}.`);
      setSelected(null);
      setForm(emptyForm);
      await refresh();
    } catch (err) {
      setStatus(`Save error: ${(err as Error).message}`);
    }
  }

  return (
    <div style={{ fontFamily: 'Segoe UI, system-ui, sans-serif', maxWidth: 980, margin: '0 auto', padding: 24 }}>
      <h1>OEE Downtime Logbook</h1>
      <p style={{ color: '#555' }}>
        Attach a reason code to each downtime occurrence. Reasons are stored by this app and flow
        into the Power BI OEE model for the human-root-cause downtime Pareto.
      </p>
      <button onClick={() => void refresh()} disabled={loading}>
        {loading ? 'Loading…' : 'Refresh'}
      </button>
      {status && <p style={{ color: status.includes('error') ? '#b00' : '#070' }}>{status}</p>}

      <h2>Open downtime ({openQueue.length})</h2>
      <table style={{ width: '100%', borderCollapse: 'collapse' }}>
        <thead>
          <tr style={{ textAlign: 'left', borderBottom: '2px solid #ddd' }}>
            <th>Line</th>
            <th>Station</th>
            <th>Machine</th>
            <th>Fault</th>
            <th>Start</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {openQueue.map((o) => (
            <tr key={o.work_order_id} style={{ borderBottom: '1px solid #eee' }}>
              <td>{o.line_id}</td>
              <td>{o.station_position}</td>
              <td>{o.machine_type}</td>
              <td>{o.issue_type}</td>
              <td>{new Date(o.downtime_start).toLocaleString()}</td>
              <td>
                <button onClick={() => { setSelected(o); setForm(emptyForm); }}>Log reason</button>
              </td>
            </tr>
          ))}
          {openQueue.length === 0 && !loading && (
            <tr><td colSpan={6} style={{ padding: 12, color: '#777' }}>Queue clear — no unreconciled downtime.</td></tr>
          )}
        </tbody>
      </table>

      {selected && (
        <div style={{ marginTop: 24, padding: 16, border: '1px solid #ccc', borderRadius: 8 }}>
          <h3>Log reason — {selected.device_id}</h3>
          <p style={{ color: '#555' }}>
            {selected.machine_type} · {selected.issue_type} · {new Date(selected.downtime_start).toLocaleString()}
          </p>
          <label style={{ display: 'block', marginBottom: 8 }}>
            Reason&nbsp;
            <input
              value={form.reason_code}
              onChange={(e) => setForm({ ...form, reason_code: e.target.value })}
              placeholder="e.g. Coolant line clogged"
              style={{ width: 360 }}
            />
          </label>
          <label style={{ display: 'block', marginBottom: 8 }}>
            Category&nbsp;
            <select
              value={form.category}
              onChange={(e) => setForm({ ...form, category: e.target.value as Category })}
            >
              {CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
            </select>
          </label>
          <label style={{ display: 'block', marginBottom: 8 }}>
            Comment&nbsp;
            <input value={form.comment} onChange={(e) => setForm({ ...form, comment: e.target.value })} style={{ width: 360 }} />
          </label>
          <label style={{ display: 'block', marginBottom: 12 }}>
            Corrective action&nbsp;
            <input value={form.corrective_action} onChange={(e) => setForm({ ...form, corrective_action: e.target.value })} style={{ width: 360 }} />
          </label>
          <button onClick={() => void submit()}>Submit</button>{' '}
          <button onClick={() => { setSelected(null); setForm(emptyForm); }}>Cancel</button>
        </div>
      )}
    </div>
  );
}
