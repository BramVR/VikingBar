import { asset } from './site.js';
import { useEffect, useRef, useState } from 'react';
import { samples, formatData } from './demo-data.js';
import { HistoryDemo } from './HistoryDemo.jsx';
import { BillingDemo, DemoIcon } from './BillingDemo.jsx';

export function BalanceDemo({initialView = 'balance'}) {
  const [selection, setSelection] = useState({sim: 'personal', bundle: 0});
  const [view, setView] = useState(initialView);
  const [historyOpen, setHistoryOpen] = useState(initialView === 'balance');
  const [preferences, setPreferences] = useState({unit: 'GB', showGB: true, display: 'remaining', interval: '15 minutes', login: false});
  const [refreshing, setRefreshing] = useState(false);
  const [freshness, setFreshness] = useState('Updated just now');
  const timer = useRef(null);
  const navigationTarget = useRef(null);
  useEffect(() => () => clearTimeout(timer.current), []);
  const account = samples[selection.sim];
  const bundle = account.bundles[selection.bundle];
  const remainingFraction = bundle.remaining / bundle.total;
  const displayed = preferences.display === 'remaining' ? bundle.remaining : bundle.total - bundle.remaining;
  const fraction = displayed / bundle.total;
  const icon = remainingFraction === .72 ? asset('vikingbar-icon.png') : asset(`vikingbar-icon-${Math.round(remainingFraction * 100)}.png`);
  const format = value => formatData(value, preferences.unit, 1);
  const updatePreference = (key, value) => setPreferences(previous => ({...previous, [key]: value}));
  const navigate = destination => {setHistoryOpen(false); setView(destination); requestAnimationFrame(() => navigationTarget.current?.focus());};
  const select = next => {
    clearTimeout(timer.current);
    setRefreshing(false);
    setFreshness('Updated just now');
    setHistoryOpen(false);
    setSelection(next);
  };
  const refresh = () => {
    if (refreshing) return;
    setRefreshing(true);
    setFreshness('Refreshing sample…');
    timer.current = setTimeout(() => {setRefreshing(false); setFreshness('Sample refreshed just now');}, 650);
  };
  return <div data-nosnippet="" className={`demo-wrap native-demo ${historyOpen ? 'history-is-open' : ''}`}>
    <div className="sample-menubar" aria-hidden="true"><span>VikingBar</span><img className="menu-helmet" src={icon} alt=""/>{preferences.showGB && <span>{bundle.remaining} GB</span>}<span className="menubar-time">09:41</span></div>
    <section className="native-card" aria-label={initialView === 'bills' ? 'Interactive sample billing menu' : 'Interactive sample VikingBar menu'}>
      <header className="native-header"><img className="menu-helmet" src={icon} alt=""/><strong>VikingBar</strong><span>Demo</span></header>
      {view !== 'balance' && <button ref={navigationTarget} className="native-action native-back" onClick={() => navigate(view === 'account' ? 'settings' : 'balance')}><DemoIcon name="back"/>Back</button>}
      {view === 'balance' && <>
        <label className="native-selector"><span className="sr-only">Example SIM</span><select ref={navigationTarget} aria-label="Example SIM" value={selection.sim} onChange={event => select({sim:event.target.value, bundle:0})}>{Object.entries(samples).map(([key, value]) => <option key={key} value={key}>{value.name}</option>)}</select></label>
        <div className="native-bundle"><label><span className="sr-only">Example bundle</span><select aria-label="Example bundle" value={selection.bundle} onChange={event => select({...selection, bundle:Number(event.target.value)})}>{account.bundles.map((item, index) => <option key={item.name} value={index}>{item.name}</option>)}</select></label><span className="native-secondary">Selected bundle</span></div>
        <div className="native-allowance" aria-live="polite"><div><span className="native-number">{format(displayed).split(' ')[0]}</span><span className="native-unit">{preferences.unit}</span><span className="native-secondary">{preferences.display}</span></div><div className="native-total"><span>{format(bundle.total)}</span><span className="native-secondary">allowance</span></div></div>
        <div className="native-meter" role="meter" aria-label={`Example data ${preferences.display}`} aria-valuenow={Math.round(fraction * 100)} aria-valuemin={0} aria-valuemax={100} aria-valuetext={`${format(displayed)} ${preferences.display} of ${format(bundle.total)}`}><span style={{width:`${fraction * 100}%`}}/></div>
        <div className="native-values"><span>{format(bundle.total - displayed)} {preferences.display === 'remaining' ? 'used' : 'remaining'}</span><span>{Math.round(fraction * 100)}% {preferences.display === 'remaining' ? 'left' : 'used'}</span></div>
        <div className="native-expiry"><span>{bundle.days} days left</span><span>Expires {bundle.expiry}</span></div>
        <HistoryDemo key={`${selection.sim}-${selection.bundle}`} sim={selection.sim} name={account.name} bundle={bundle} unit={preferences.unit} open={historyOpen} setOpen={setHistoryOpen}/>
        <details className="native-details" key={`details-${selection.sim}-${selection.bundle}`}><summary><span>Bundle details</span><span className="native-charges">Extra charges <strong>{account.charges}</strong></span></summary><p>{bundle.detail} Expires {bundle.expiry} 2026. Allowances stay separate; extra charges apply to this SIM.</p></details>
        <div className="native-refresh-row"><button className="native-action" onClick={refresh} disabled={refreshing} aria-busy={refreshing}><DemoIcon name="refresh"/>{refreshing ? 'Refreshing…' : 'Refresh'}</button><a className="native-action" href="https://mobilevikings.be/en/my-viking/" target="_blank" rel="noreferrer">Open My Viking <span aria-hidden="true">↗</span></a></div>
        <p className="native-secondary demo-freshness" role="status">{freshness}</p>
        <nav className="native-footer" aria-label="Sample menu navigation"><button className="native-action" onClick={() => navigate('bills')}><DemoIcon name="pdf"/>Bills</button><button className="native-action" onClick={() => navigate('points')}><DemoIcon name="points"/>Points</button><button className="native-action" onClick={() => navigate('settings')}><DemoIcon name="settings"/>Settings</button></nav>
      </>}
      {view === 'bills' && <BillingDemo simName={account.name}/>}
      {view === 'settings' && <div className="demo-settings"><h3>Settings</h3>
        <label className="native-setting">Data display<select value={preferences.display} onChange={event => updatePreference('display', event.target.value)}><option value="remaining">Remaining</option><option value="used">Used</option></select></label>
        <label className="native-setting">Refresh<select value={preferences.interval} onChange={event => updatePreference('interval', event.target.value)}>{['5 minutes','15 minutes','30 minutes','1 hour'].map(value => <option key={value}>{value}</option>)}</select></label>
        <label className="native-setting">Launch at login<input type="checkbox" checked={preferences.login} onChange={event => updatePreference('login',event.target.checked)}/></label>
        <p>{preferences.login ? 'On' : 'Off'} in this demo. Your Mac settings are unchanged.</p>
        <label className="native-setting"><span>Show remaining GB in menu bar</span><input type="checkbox" checked={preferences.showGB} onChange={event => updatePreference('showGB',event.target.checked)}/></label>
        <label className="native-setting">Data units<select value={preferences.unit} onChange={event => updatePreference('unit',event.target.value)}><option>GB</option><option>GiB</option></select></label>
        <p>GB uses decimal units. GiB uses binary units. Preferences apply to this demo only.</p>
        <button className="native-action" onClick={() => navigate('account')}>Account…</button>
      </div>}
      {view === 'account' && <div className="demo-account"><h3>Account</h3><p>Connected · Demo account</p><p className="native-secondary">demo@example.invalid</p><p>This website uses sample data. Connect your account in the Mac app.</p></div>}
      {view === 'points' && <div className="demo-points"><h3>Viking Points</h3><p className="native-secondary">Shared across this customer's subscriptions.</p><strong>Available: 12.75</strong><p>Pending: 3.50</p><p>Blocked: 2.25</p><p className="native-secondary">Sample balances · Updated just now</p><details className="native-details"><summary>Recent transactions</summary><dl><div><dt>Shopping reward <span>Completed</span></dt><dd>+2.50</dd></div><div><dt>Partner purchase <span>Pending</span></dt><dd>+3.50</dd></div><div><dt>Invoice credit <span>Completed</span></dt><dd>−5.00</dd></div></dl></details></div>}
    </section>
  </div>;
}
