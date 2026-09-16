import { questions } from './questions.js';
import { asset } from './site.js';
const REPO = 'https://github.com/BramVR/VikingBar';
const SETUP = `${REPO}/blob/main/docs/live-account.md`;
const INSTALL = `${REPO}/blob/main/docs/local-install.md`;
const BUILD = `${REPO}/releases/tag/v0.1.0`;
const PREVIEW_INSTALL = `${REPO}/blob/main/docs/RELEASING.md#install-the-unsigned-preview`;

function StepIcon({ kind }) {
  const paths = {
    download: 'M24 5v27m-10-10 10 10 10-10M8 33v8h32v-8',
    key: 'M29 8a11 11 0 0 0-13 15L5 34v9h9v-6h6v-6l5-5A11 11 0 0 0 40 11L36 7l-7 1ZM32 13h.01',
    sim: 'M12 5h18l9 9v29H12V5ZM19 23h13v14H19V23Zm0 7h13m-7-7v14',
  };
  return <svg viewBox="0 0 48 48" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={paths[kind]}/></svg>;
}

export function InfoSections() {
  const steps = [
    { title: 'Download and install', icon: 'download', body: 'Download the free unsigned preview from GitHub without an account. Extract the app archive, then open VikingBar.app.', link: 'Download preview', href: BUILD },
    { title: 'Connect your account', icon: 'key', body: 'Click the menu-bar helmet and choose Connect account. Sign in directly with your public client ID, username, and password. You can also use the optional 1Password helper.', link: 'Account setup', href: SETUP },
    { title: 'Choose your balance', icon: 'sim', body: 'Choose a SIM and data bundle. The helmet shows the selected bundle balance.', link: 'Menu preview', href: '#your-balance' },
  ];

  return <div className="info-sections">
    <section className="info-section" id="setup" aria-labelledby="setup-heading">
      <h2 id="setup-heading">Setup</h2>
      <div className="setup-prerequisite">
        <h3>Request API access first</h3>
        <p>API access is not included automatically with your Mobile Vikings account. Email <a href="mailto:api@mobilevikings.be">api@mobilevikings.be</a> with your name, the brand (Mobile Vikings), the application (VikingBar), and its purpose (viewing your own balance). Ask support to approve VikingBar as a public client without a client secret. Wait for that confirmation and your public client ID before connecting. No client secret is required for the approved public-client setup.</p>
        <a href="https://docs.uwa.mobilevikings.be/" target="_blank" rel="noreferrer">Mobile Vikings API access instructions <span aria-hidden="true">↗</span></a>
      </div>
      <ol className="setup-steps">
        {steps.map((step, index) => <li key={step.title}>
          <div className="step-mark"><span aria-hidden="true">0{index + 1}</span><StepIcon kind={step.icon}/></div>
          <h3>{step.title}</h3><p>{step.body}</p>
          <a href={step.href} {...(step.href.startsWith('https:') ? { target: '_blank', rel: 'noreferrer' } : {})}>{step.link} <span aria-hidden="true">{index === 2 ? '→' : '↗'}</span></a>
        </li>)}
      </ol>
    </section>
    <section className="info-section" aria-labelledby="requirements-heading">
      <h2 id="requirements-heading">Requirements</h2>
      <dl className="requirements-list">
        <div><dt>System</dt><dd>macOS 14 or later</dd></div>
        <div><dt>Hardware</dt><dd>Apple Silicon</dd></div>
        <div><dt>Account</dt><dd>Mobile Vikings with approved API access</dd></div>
      </dl>
      <div data-nosnippet="" className="menubar-example" role="img" aria-label="Example Mac menu bar showing VikingBar with 36 GB remaining">
        <img src={asset("vikingbar-icon.png")} alt=""/><span>36 GB</span>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" aria-hidden="true"><path d="M3 9a14 14 0 0 1 18 0M6 12a9 9 0 0 1 12 0M9 15a4 4 0 0 1 6 0"/><circle cx="12" cy="18" r=".8" fill="currentColor"/></svg>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" aria-hidden="true"><circle cx="10" cy="10" r="6"/><path d="m15 15 5 5"/></svg>
        <span className="menubar-time" aria-hidden="true">9:41</span>
      </div>
    </section>
    <section className="info-section" aria-labelledby="questions-heading">
      <h2 id="questions-heading">Questions</h2>
      <div className="info-faq">{questions.map(([question, answer], index) => <details key={question} open={index < 2}>
        <summary>{question}</summary><p>{answer}</p>
      </details>)}</div>
    </section>
    <section className="info-section info-downloads" aria-labelledby="documentation-heading">
      <h2 id="documentation-heading">Downloads and documentation</h2>
      <p>Download the free unsigned preview from GitHub without an account. Source code and setup documentation are public.</p>
      <nav aria-label="Downloads and documentation">
        <a href={BUILD} target="_blank" rel="noreferrer">Unsigned preview <span aria-hidden="true">↗</span></a>
        <a href={PREVIEW_INSTALL} target="_blank" rel="noreferrer">Installation instructions <span aria-hidden="true">↗</span></a>
        <a href={SETUP} target="_blank" rel="noreferrer">Setup guide <span aria-hidden="true">↗</span></a>
        <a href={INSTALL} target="_blank" rel="noreferrer">Local installation <span aria-hidden="true">↗</span></a>
        <a href={REPO} target="_blank" rel="noreferrer">Source code <span aria-hidden="true">↗</span></a>
      </nav>
    </section>
  </div>;
}
