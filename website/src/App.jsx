import { asset } from './site.js';
import { useEffect, useRef, useState } from 'react';
import { HelmetScene } from './HelmetScene.jsx';
import { BalanceDemo } from './BalanceDemo.jsx';
import { InfoSections } from './InfoSections.jsx';

const REPO = 'https://github.com/BramVR/VikingBar';
const references = [
  { name: 'README.md', path: 'README.md', title: 'A native Mac app', description: 'SwiftUI and AppKit provide the menu bar and data card. A shared Swift core also powers the bundled CLI.', code: 'Swift 6.2\nmacOS 14+\nApple Silicon', label: 'Read the README' },
  { name: 'DataCard.swift', path: 'Sources/VikingBar/DataCard.swift', title: 'The balance card', description: 'The card displays the selected bundle, usage, expiry, and last successful refresh.', code: 'Text(menu.remainingText)\nText(menu.expiryText)\nText(menu.freshnessText)', label: 'Read DataCard.swift' },
  { name: 'HelmetRenderer.swift', path: 'Sources/VikingBar/HelmetRenderer.swift', title: 'The menu bar helmet', description: 'A native template image uses an inset bar for the remaining allowance. Unlimited and unavailable balances have distinct treatments.', code: 'static let size = NSSize(\n    width: 22, height: 18\n)', label: 'Read HelmetRenderer.swift' },
  { name: 'StatusPresentation.swift', path: 'Sources/VikingBarCore/StatusPresentation.swift', title: 'The optional GB label', description: 'A saved setting adds remaining decimal GB beside the helmet. It defaults to off.', code: 'self.title = showRemainingGB\n    ? amount : ""', label: 'Read StatusPresentation.swift' },
  { name: 'AppSession.swift', path: 'Sources/VikingBar/AppSession.swift', title: 'The selected account data', description: 'The app coordinates SIM and bundle selection, refresh activity, and display preferences.', code: null, label: 'Read AppSession.swift' },
];

function SourceContent({ selected, setSelected }) {
  const reference = references[selected];
  return <>
    <div className="source-heading"><span className="eyebrow">Behind the app</span><a href={REPO} target="_blank" rel="noreferrer">GitHub <span aria-hidden="true">↗</span></a></div>
    <p className="repo-name">BramVR<span>/</span><strong>VikingBar</strong></p>
    <nav aria-label="Code reference" className="source-files">
      {references.map((file, index) => <button key={file.name} aria-pressed={selected === index} onClick={() => setSelected(index)}><span className="file-mark" aria-hidden="true">{index === 0 ? 'MD' : 'SW'}</span>{file.name}</button>)}
    </nav>
    <section className="source-detail" aria-live="polite">
      <h2>{reference.title}</h2><p>{reference.description}</p>
      {reference.code && <pre><code>{reference.code}</code></pre>}
      <a className="text-link" href={`${REPO}/blob/main/${reference.path}`} target="_blank" rel="noreferrer">{reference.label} <span aria-hidden="true">↗</span></a>
    </section>
    <div className="source-bottom"><span className="eyebrow">Run it locally</span><pre><code>make package-app</code></pre><p>Sign in directly with your approved public client ID, or use the optional 1Password helper. No client secret is required. The CLI stores refresh tokens in macOS Keychain. Repository links require access to the private GitHub repository.</p><a href={`${REPO}/blob/main/docs/live-account.md`} target="_blank" rel="noreferrer">Account setup <span aria-hidden="true">↗</span></a></div>
  </>;
}

export function App() {
  const [selected, setSelected] = useState(0);
  const [motion, setMotion] = useState(false);
  const [phase, setPhase] = useState(null);
  const getDialog = useRef(null);
  const sourceDialog = useRef(null);
  useEffect(() => {
    const preference = matchMedia('(prefers-reduced-motion: reduce)');
    setMotion(!preference.matches);
    const update = () => setMotion(!preference.matches);
    preference.addEventListener('change', update);
    return () => preference.removeEventListener('change', update);
  }, []);
  const openGet = () => getDialog.current.showModal();
  return <div className={motion ? 'site motion-on' : 'site'}>
    <a href="#main" className="skip-link">Skip to content</a>
    <div className="front-page">
      <header className="header"><a href="#" className="wordmark" aria-label="VikingBar home"><img src={asset("vikingbar-icon.png")} alt=""/>Viking<span>Bar</span></a><nav className="header-right" aria-label="Main navigation"><a href="#features">Features</a><a href="#setup">Setup</a><a href="#your-balance">Preview</a><button className="source-trigger" onClick={() => sourceDialog.current.showModal()}>Source</button><a className="header-cta" href="#get-vikingbar" onClick={e => {e.preventDefault(); openGet();}}>Get VikingBar <span aria-hidden="true">↗</span></a></nav></header>
      <main id="main">
        <section className="hero" aria-labelledby="hero-heading">
          <div className="hero-copy"><h1 id="hero-heading"><span>Your data.</span><span>One glance.</span></h1><p className="hero-description">Your Mobile Vikings balance. In your Mac's menu bar.</p><a className="primary" href="#your-balance">Explore VikingBar <span aria-hidden="true">→</span></a></div>
          <HelmetScene motion={motion} phase={phase}/>
          <a href="#your-balance" className="scroll-cue"><span className="scroll-line" aria-hidden="true"/>A closer look</a>
        </section>
        <section className="allowance-story section" id="allowance-motion" aria-label="Allowance animation demo">
          <div className="story-heading"><span className="eyebrow">The allowance, at a glance</span><button className="motion-toggle" aria-pressed={motion} onClick={() => setMotion(!motion)}>{motion ? 'Pause motion' : 'Enable motion'}</button></div>
          <div className="story-stages">{['Full', 'Empty', 'Refill'].map((label, index) => <button key={label} className="story-stage" onClick={() => { setPhase({index, nonce:Date.now()}); window.scrollTo({top:0, behavior:motion ? 'smooth' : 'instant'}); }} aria-label={`Show ${label.toLowerCase()} allowance animation`}>
            <span className={`story-helmet story-helmet-${index}`} aria-hidden="true"/>
            <span className="story-label"><strong>{['100%', '0%', 'Reset'][index]}</strong><span>{label}</span></span>
          </button>)}</div>
        </section>
        <section className="balance-section section" id="your-balance" aria-labelledby="balance-heading"><BalanceDemo/><div className="section-copy"><span className="eyebrow">Less checking</span><h2 id="balance-heading">Skip the<br/>account page.</h2><p>Open VikingBar to see what's left, what you've used, and when your bundle expires. Your balance is one click away.</p><p className="quiet">Want the number at a glance? Show your remaining GB beside the helmet.</p></div></section>
        <section className="details-section section" id="features" aria-label="What VikingBar shows">
          <article><h2>Each SIM. Its own balance.</h2><p>Switch between your personal and work SIMs. Each allowance stays separate.</p></article>
          <article><h2>Extra charges in view.</h2><p>See charges outside your bundle alongside your data.</p></article>
        </section>
        <InfoSections/>
      </main>
      <footer><span>VikingBar<span className="footer-separator">·</span>Independent project for Mobile Vikings users.</span><button className="motion-toggle" aria-pressed={motion} onClick={() => setMotion(!motion)}>{motion ? 'Pause motion' : 'Enable motion'}</button></footer>
    </div>
    <aside className="source-sidebar" aria-label="Readme and code"><SourceContent selected={selected} setSelected={setSelected}/></aside>
    <dialog className="get-dialog" aria-labelledby="download-title" ref={getDialog} onClick={e => {if (e.target === e.currentTarget) e.currentTarget.close();}}><button className="close-dialog" onClick={() => getDialog.current.close()} aria-label="Close download details">Close <span aria-hidden="true">×</span></button><span className="eyebrow">VikingBar for Mac</span><h2 id="download-title">Try the<br/>development build.</h2><p>VikingBar is currently available as a development build for Macs with Apple Silicon, running macOS 14 or later. Downloads and documentation require access to the private GitHub repository.</p><p>First request API access by emailing <a href="mailto:api@mobilevikings.be">api@mobilevikings.be</a>. Wait for approval and your public client ID. Sign in directly in VikingBar, or use the optional configured 1Password helper. No client secret is required.</p><a className="primary" href={`${REPO}/actions/workflows/checks.yml`} target="_blank" rel="noreferrer">Find a build on GitHub <span aria-hidden="true">↗</span></a><a className="setup-link" href={`${REPO}/blob/main/docs/RELEASING.md#download-a-development-build`} target="_blank" rel="noreferrer">Download instructions <span aria-hidden="true">↗</span></a><a className="setup-link" href={`${REPO}/blob/main/docs/live-account.md`} target="_blank" rel="noreferrer">Account setup <span aria-hidden="true">↗</span></a></dialog>
    <dialog className="source-dialog" aria-label="Readme and code" ref={sourceDialog}><button className="close-dialog" onClick={() => sourceDialog.current.close()} aria-label="Close code reference">Close <span aria-hidden="true">×</span></button><SourceContent selected={selected} setSelected={setSelected}/></dialog>
  </div>;
}
