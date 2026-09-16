import { useId, useRef, useState } from 'react';
import { cycleSummary, formatData, historyDays } from './demo-data.js';

function DayBars({days, selected, onSelect, onActivate, boundary, unit, detailed = false}) {
  const buttons = useRef([]);
  const max = Math.max(...days.map(day => day.gb ?? 0));
  const move = (event, index) => {
    const next = {ArrowLeft: Math.max(0, index - 1), ArrowRight: Math.min(days.length - 1, index + 1), Home: 0, End: days.length - 1}[event.key];
    if (next === undefined) return;
    event.preventDefault();
    onSelect(next);
    buttons.current[next]?.focus();
  };
  return <div className={`daily-chart ${detailed ? 'daily-chart-large' : ''}`}>
    <div className="daily-bars" role="group" aria-label={detailed ? 'Detailed daily SIM usage' : 'Last 30 days plot'}>
      <span className="cycle-marker" style={{left: `${boundary / days.length * 100}%`}} aria-hidden="true"/>
      {days.map((day, index) => <button key={day.date} ref={node => {buttons.current[index] = node;}}
        className={`day-bar ${selected === index ? 'selected' : ''} ${day.gb === null ? 'missing' : ''} ${day.status === 'Partial today' ? 'partial' : ''}`}
        tabIndex={selected === index ? 0 : -1}
        aria-label={`${day.fullDate}, ${formatData(day.gb, unit)}, ${day.status}`}
        aria-pressed={selected === index}
        onPointerEnter={() => onSelect(index)} onFocus={() => onSelect(index)}
        onClick={() => {onSelect(index); onActivate?.();}} onKeyDown={event => move(event, index)}>
        <span style={{height: `${day.gb === null ? 0 : day.gb / max * 100}%`}}/>
        {day.gb === null && <span className="missing-mark" aria-hidden="true">×</span>}
      </button>)}
    </div>
    <div className="chart-axis"><span>{days[0].label}</span><span>{days.at(-1).label}</span></div>
  </div>;
}

export function HistoryDemo({sim, bundle, unit, name, open, setOpen}) {
  const [selected, setSelected] = useState(29);
  const opener = useRef(null);
  const panelId = useId();
  const days = historyDays(sim);
  const day = days[selected];
  const cycle = cycleSummary(days, bundle);
  const close = () => {setOpen(false); opener.current?.focus();};
  return <div className="history-demo" onKeyDown={event => {if (event.key === 'Escape' && open) {event.stopPropagation(); close();}}}>
    <button ref={opener} className="native-action history-trigger" aria-expanded={open} aria-controls={panelId} onClick={() => setOpen(!open)}>Last 30 days <span aria-hidden="true">›</span></button>
    <div className="history-metrics">
      <div><span>{selected === 29 ? 'Today' : day.label}</span><strong>{formatData(day.gb, unit)} <small>{day.status}</small></strong></div>
      <div><span>Cycle so far</span><strong>{formatData(cycle.observed, unit)}</strong></div>
    </div>
    <DayBars days={days} selected={selected} onSelect={setSelected} onActivate={() => setOpen(true)} boundary={bundle.cycleStart} unit={unit}/>
    {open && <section className="history-companion" id={panelId} aria-label={`Daily SIM data details for ${name}`}>
      <header><div><h3>Daily SIM data</h3><p>{name}</p></div><button aria-label="Close history details" onClick={close}>×</button></header>
      <p className="native-secondary">{days[0].label} – {days.at(-1).fullDate}</p>
      <p className="history-status">Sample history · Today is partial</p>
      <DayBars days={days} selected={selected} onSelect={setSelected} boundary={bundle.cycleStart} unit={unit} detailed/>
      <p className="cycle-label">Cycle started · {days[bundle.cycleStart].label}</p>
      <div className="history-day"><span>{day.fullDate}</span><strong>{formatData(day.gb, unit)}</strong></div>
      <p className="native-secondary">{day.status}{selected !== 29 && ` · Today ${formatData(days.at(-1).gb, unit)}`}</p>
      <div className="history-group"><h4>Current cycle</h4><dl><div><dt>Observed so far</dt><dd>{formatData(cycle.observed, unit)}</dd></div><div><dt>Estimated at renewal</dt><dd>{formatData(cycle.estimate, unit)}</dd></div></dl></div>
      <div className="history-group"><h4>About this data</h4><p>SIM data across regions and bundles. Provider updates may lag. The estimate excludes today.</p><dl><div><dt>Selected bundle reported</dt><dd>{formatData(bundle.total - bundle.remaining, unit)}</dd></div></dl></div>
    </section>}
  </div>;
}
