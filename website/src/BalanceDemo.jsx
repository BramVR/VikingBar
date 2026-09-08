import { asset } from './site.js';
import { useEffect, useRef, useState } from 'react';

const samples = {
  personal: { name: 'Personal SIM', bundles: [
    { name: 'Monthly data', remaining: 36, total: 50, days: 13, expiry: '21 Sep', fullExpiry: '21 September 2026', charges: '€0.00', detail: 'Monthly data for your personal SIM.' },
    { name: 'Extra data', remaining: 2.5, total: 5, days: 7, expiry: '15 Sep', fullExpiry: '15 September 2026', charges: '€0.00', detail: 'A separate extra-data bundle with its own expiry.' },
  ] },
  work: { name: 'Work SIM', bundles: [
    { name: 'Monthly data', remaining: 8, total: 20, days: 22, expiry: '30 Sep', fullExpiry: '30 September 2026', charges: '€1.20', detail: 'Monthly data for your work SIM.' },
    { name: 'Extra data', remaining: 1.5, total: 3, days: 17, expiry: '25 Sep', fullExpiry: '25 September 2026', charges: '€1.20', detail: 'An extra-data bundle belonging only to your work SIM.' },
  ] },
};

export function BalanceDemo() {
  const [selection, setSelection] = useState({sim: 'personal', bundle: 0});
  const [settings, setSettings] = useState(false);
  const [units, setUnits] = useState('GB');
  const [showGB, setShowGB] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [freshness, setFreshness] = useState('Updated just now');
  const timer = useRef(null);
  useEffect(() => () => clearTimeout(timer.current), []);
  const account = samples[selection.sim];
  const bundle = account.bundles[selection.bundle];
  const fraction = bundle.remaining / bundle.total;
  const menuIcon = fraction === .72 ? asset('vikingbar-icon.png') : asset(`vikingbar-icon-${Math.round(fraction * 100)}.png`);
  const format = value => new Intl.NumberFormat('en', {maximumFractionDigits: 1}).format(units === 'GiB' ? value / 1.073741824 : value);
  const select = next => {
    clearTimeout(timer.current);
    setRefreshing(false);
    setFreshness('Updated just now');
    setSelection(next);
  };
  const refresh = () => {
    if (refreshing) return;
    setRefreshing(true);
    setFreshness('Refreshing sample…');
    timer.current = setTimeout(() => {
      setRefreshing(false);
      setFreshness('Sample refreshed just now');
    }, 650);
  };
  return <div data-nosnippet="" className="demo-wrap native-demo">
    <div className="sample-menubar" aria-hidden="true">
      <span>VikingBar</span><img className="menu-helmet" src={menuIcon} alt=""/>
      {showGB && <span>{bundle.remaining} GB</span>}<span className="menubar-time">09:41</span>
    </div>
    <section className="native-card" aria-label="Interactive sample VikingBar menu">
      <header className="native-header"><img className="menu-helmet" src={asset("vikingbar-icon.png")} alt=""/><strong>VikingBar</strong><span>Demo</span></header>
      {settings ? <div className="demo-settings">
        <button className="native-action" onClick={() => setSettings(false)}>Back to balance</button>
        <h3>Settings</h3>
        <label className="native-setting">Data units<select value={units} onChange={event => setUnits(event.target.value)}><option>GB</option><option>GiB</option></select></label>
        <p>GB uses decimal units. GiB uses binary units. The menu bar always shows GB.</p>
        <label className="native-setting"><span>Show remaining GB in menu bar</span><input type="checkbox" checked={showGB} onChange={event => setShowGB(event.target.checked)}/></label>
        <p>These preferences apply to this website demo.</p>
      </div> : <>
        <label className="native-selector"><span className="sr-only">Example SIM</span>
          <select aria-label="Example SIM" value={selection.sim} onChange={event => select({sim:event.target.value, bundle:0})}>
            {Object.entries(samples).map(([key, value]) => <option key={key} value={key}>{value.name}</option>)}
          </select>
        </label>
        <div className="native-bundle">
          <label><span className="sr-only">Example bundle</span><select aria-label="Example bundle" value={selection.bundle} onChange={event => select({...selection, bundle:Number(event.target.value)})}>
            {account.bundles.map((item, index) => <option key={item.name} value={index}>{item.name}</option>)}
          </select></label>
          <span className="native-secondary">Selected bundle</span>
        </div>
        <div className="native-allowance" aria-live="polite">
          <div><span className="native-number">{format(bundle.remaining)}</span> <span className="native-unit">{units}</span><span className="native-secondary">remaining</span></div>
          <div className="native-total"><span>{format(bundle.total)} {units}</span><span className="native-secondary">allowance</span></div>
        </div>
        <div className="native-meter" role="meter" aria-label="Example data remaining" aria-valuenow={Math.round(fraction * 100)} aria-valuemin={0} aria-valuemax={100} aria-valuetext={`${format(bundle.remaining)} ${units} remaining of ${format(bundle.total)} ${units}`}><span style={{width:`${fraction * 100}%`}}/></div>
        <div className="native-values"><span>{format(bundle.total - bundle.remaining)} {units} used</span><span>{Math.round(fraction * 100)}% left</span></div>
        <div className="native-expiry"><span>{bundle.days} days left</span><time dateTime={`2026-09-${bundle.fullExpiry.split(' ')[0]}`} title={bundle.fullExpiry}>Expires {bundle.expiry}</time></div>
        <details className="native-details" key={`${selection.sim}-${selection.bundle}`}>
          <summary><span>Bundle details</span><span className="native-charges">Extra charges <strong>{bundle.charges}</strong></span></summary>
          <p>{bundle.detail} Expires {bundle.fullExpiry}. Allowances stay separate; extra charges apply to this SIM.</p>
        </details>
        <button className="native-action refresh-action" onClick={refresh} disabled={refreshing} aria-busy={refreshing}>
          <span>{refreshing ? 'Refreshing…' : 'Refresh'}</span><span className="native-secondary" role="status">{freshness}</span>
        </button>
        <a className="native-action native-external" href="https://mobilevikings.be/nl/my-viking/" target="_blank" rel="noreferrer"><span>Open My Viking</span><span className="native-secondary">Demo data</span></a>
        <button className="native-action settings-action" onClick={() => setSettings(true)}>Settings…</button>
      </>}
    </section>
  </div>;
}
