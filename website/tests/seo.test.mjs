import assert from 'node:assert/strict';
import { readFile, access } from 'node:fs/promises';
import test from 'node:test';
import { questions } from '../src/questions.js';

const output = new URL('../dist/client/', import.meta.url);
const html = await readFile(new URL('index.html', output), 'utf8');
const canonical = 'https://vikingbar.bramvanrompuy.be/';

test('product and setup information are readable before JavaScript executes', () => {
  assert.match(html, /<div id="root"><[\s\S]+<main/);
  for (const text of ['Your data.', 'Mobile Vikings', 'Request API access first', 'Sign in directly', '1Password', 'No client secret is required', 'macOS 14 or later']) assert.ok(html.includes(text), text);
  assert.doesNotMatch(html, /Manual sign-in is not implemented|manual sign-in is not available|requires a configured 1Password helper/);
  assert.doesNotMatch(html, /private GitHub repository|Repository access required/);
  assert.match(html, /Downloading GitHub Actions artifacts requires a GitHub account/);
  assert.equal((html.match(/<h1[ >]/g) || []).length, 1);
  assert.match(html, /data-nosnippet/);
});

test('canonical, social metadata, and FAQ structured data match visible content', () => {
  assert.ok(html.includes(`<link rel="canonical" href="${canonical}"`));
  assert.ok(html.includes(`property="og:url" content="${canonical}"`));
  assert.match(html, /name="twitter:card" content="summary_large_image"/);
  const schema = JSON.parse(html.match(/<script type="application\/ld\+json">(.*?)<\/script>/s)[1]);
  const faq = schema['@graph'].find(item => item['@type'] === 'FAQPage');
  assert.deepEqual(faq.mainEntity.map(item => [item.name, item.acceptedAnswer.text]), questions);
  for (const [question, answer] of questions) {
    const escaped = answer.replaceAll('&', '&amp;').replaceAll("'", '&#x27;');
    assert.ok(html.includes(`<summary>${question}</summary>`));
    assert.ok(html.includes(`<p>${escaped}</p>`));
  }
});

test('all local HTML and CSS assets exist below the configured base', async () => {
  const script = html.match(/<script type="module"[^>]*src="([^"]+)"/)[1];
  const base = script.slice(0, script.indexOf('assets/'));
  assert.equal(base, '/');
  const urls = [...html.matchAll(/(?:src|href)="([^"]+)"/g)].map(match => match[1]).filter(url => url.startsWith('/'));
  for (const url of urls) {
    assert.ok(url.startsWith(base), url);
    await access(new URL(url.slice(base.length), output));
  }
  const cssURL = urls.find(url => url.endsWith('.css'));
  const css = await readFile(new URL(cssURL.slice(base.length), output), 'utf8');
  for (const [, raw] of css.matchAll(/url\(([^)]+)\)/g)) {
    const url = raw.replaceAll('"', '').replaceAll("'", '');
    if (url.startsWith('data:')) continue;
    assert.ok(url.startsWith(base), url);
    await access(new URL(url.slice(base.length), output));
  }
});

test('discovery files use the production URL and missing pages are not indexed', async () => {
  assert.ok((await readFile(new URL('sitemap.xml', output), 'utf8')).includes(`<loc>${canonical}</loc>`));
  assert.ok((await readFile(new URL('llms.txt', output), 'utf8')).includes('synthetic balances'));
  assert.match(await readFile(new URL('404.html', output), 'utf8'), /name="robots" content="noindex"/);
  await access(new URL('assets/social-card.png', output));
});
