import { useEffect, useRef, useState } from 'react';
import { asset } from './site.js';
import { paymentFields } from './demo-data.js';

export function DemoIcon({name}) {
  const paths = {
    back: 'm14 5-7 7 7 7', refresh: 'M20 7v5h-5M4 17v-5h5M5 8a8 8 0 0 1 13-3l2 3M4 16l2 3a8 8 0 0 0 13-3',
    copy: 'M8 8h12v13H8zM16 5V2H3v15h2', pdf: 'M6 2h8l5 5v15H6zM14 2v6h5M9 13h7M9 17h7',
    qr: 'M3 3h6v6H3zM15 3h6v6h-6zM3 15h6v6H3zM15 15h2v2h-2zM20 15v3h-3v3M12 3v3M12 10v3H3M12 17v4M21 11h-4',
    check: 'm4 12 5 5L20 6', points: 'm12 2 3 6.5 7 .8-5.2 5 1.4 7-6.2-3.4-6.2 3.4 1.4-7L2 9.3l7-.8z',
    settings: 'M9 3h6l1 4 4 2v6l-4 2-1 4H9l-1-4-4-2V9l4-2zM15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0',
  };
  return <svg className="demo-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={paths[name]}/></svg>;
}

export function BillingDemo({simName}) {
  const [invoice, setInvoice] = useState('issued');
  const [expanded, setExpanded] = useState(true);
  const [copied, setCopied] = useState(null);
  const [copyError, setCopyError] = useState('');
  const [loading, setLoading] = useState(false);
  const [updated, setUpdated] = useState('11:03');
  const feedbackTimer = useRef(null);
  const refreshTimer = useRef(null);
  const copyRequest = useRef(0);
  useEffect(() => () => {
    clearTimeout(feedbackTimer.current);
    clearTimeout(refreshTimer.current);
    copyRequest.current++;
  }, []);
  const paid = invoice === 'paid';
  const refresh = () => {
    setLoading(true);
    setCopied(null);
    refreshTimer.current = setTimeout(() => {setLoading(false); setUpdated('just now');}, 650);
  };
  const copy = async field => {
    const request = ++copyRequest.current;
    setCopyError('');
    clearTimeout(feedbackTimer.current);
    try {
      await navigator.clipboard.writeText(field.copy ?? field.value);
      if (request !== copyRequest.current) return;
      setCopied(field.label);
      feedbackTimer.current = setTimeout(() => setCopied(null), 1800);
    } catch {
      if (request === copyRequest.current) {setCopied(null); setCopyError('Copy unavailable. Select the field to copy it.');}
    }
  };
  return <div className="billing-demo">
    <div className="bill-heading"><div><h3>Bills</h3><p className="native-secondary" role="status">{loading ? 'Refreshing sample…' : `Updated ${updated}`}</p></div><button className="bill-refresh" aria-label="Refresh sample bills" disabled={loading} onClick={refresh}><DemoIcon name="refresh"/></button></div>
    <div className="bill-selection"><select aria-label="Sample invoice" value={invoice} onChange={event => {setInvoice(event.target.value); setCopied(null);}}><option value="issued">SAMPLE-2026-001</option><option value="paid">SAMPLE-2026-002</option></select><span className={`bill-status ${paid ? 'paid' : ''}`}>{paid ? 'Paid' : 'Issued'}</span></div>
    <p className="bill-scope">{paid ? '7 Aug' : '7 Sep'} 2026 · {simName}<br/><span>Grouped invoice · Includes both sample SIMs</span></p>
    <dl className="bill-amounts"><div><dt>Total</dt><dd>€15.00</dd></div><div><dt>Amount due</dt><dd className="bill-due">{paid ? '€0.00' : '€10.00'}</dd></div><div><dt>Reduction</dt><dd>€5.00</dd></div><div><dt>Viking Points used</dt><dd>5</dd></div></dl>
    <button className="native-action bill-pdf" type="button" disabled><DemoIcon name="pdf"/>Open PDF<span className="native-secondary">Sample</span></button>
    <details className="bank-transfer" open={expanded} onToggle={event => setExpanded(event.currentTarget.open)}>
      <summary><DemoIcon name="qr"/><strong>Bank transfer QR</strong><span className="disclosure-chevron" aria-hidden="true"/></summary>
      {paid ? <p className="payment-unavailable">This invoice is paid. No bank transfer is needed.</p> : loading ? <p className="payment-unavailable" role="status">Checking the sample invoice…</p> : <>
        <div className="qr-summary"><img src={asset('demo-transfer-qr.png')} width="136" height="136" alt="Illustrative QR containing demo text, not payment instructions"/><div><strong>€10.00</strong><span className="native-secondary">Sample details · {updated}</span><p>Review in your banking app.</p><span className="qr-demo-note">Demo QR · not for payment</span></div></div>
        <dl className="payment-fields">{paymentFields.map(field => <div key={field.label}><dt>{field.label}</dt><dd>{field.value}</dd><button className={copied === field.label ? 'copied' : ''} onClick={() => copy(field)} aria-label={`Copy ${field.label}`} title={`Copy ${field.label}`}><DemoIcon name={copied === field.label ? 'check' : 'copy'}/><span>{copied === field.label ? 'Copied' : ''}</span></button></div>)}</dl>
        <span className="sr-only" role="status">{copied ? `Copied ${copied}` : ''}</span>
        {copyError && <p className="copy-error" role="status">{copyError}</p>}
      </>}
    </details>
  </div>;
}
