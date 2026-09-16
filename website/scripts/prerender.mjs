import { readFile, writeFile, copyFile } from 'node:fs/promises';
import { render, questions, siteURL, title, description } from '../dist/prerender/entry-server.js';

const output = new URL('../dist/client/', import.meta.url);
const escape = value => value.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;');
const image = `${siteURL}assets/social-card.png`;
const schema = {
  '@context': 'https://schema.org',
  '@graph': [
    { '@type': 'WebSite', '@id': `${siteURL}#website`, name: 'VikingBar', url: siteURL, inLanguage: 'en', description },
    { '@type': 'SoftwareApplication', '@id': `${siteURL}#app`, name: 'VikingBar', url: siteURL, description,
      applicationCategory: 'UtilitiesApplication', operatingSystem: 'macOS 14 or later', processorRequirements: 'Apple Silicon',
      softwareRequirements: 'Mobile Vikings account with approved API access and public client ID; no client secret; 1Password optional',
      screenshot: image, installUrl: 'https://github.com/BramVR/VikingBar/blob/main/docs/RELEASING.md#download-a-development-build' },
    { '@type': 'FAQPage', '@id': `${siteURL}#questions`, mainEntity: questions.map(([name, text]) => ({
      '@type': 'Question', name, acceptedAnswer: { '@type': 'Answer', text },
    })) },
  ],
};
const meta = `
    <link rel="canonical" href="${siteURL}" />
    <meta name="robots" content="index, follow, max-image-preview:large" />
    <meta property="og:type" content="website" />
    <meta property="og:site_name" content="VikingBar" />
    <meta property="og:locale" content="en_US" />
    <meta property="og:title" content="${escape(title)}" />
    <meta property="og:description" content="${escape(description)}" />
    <meta property="og:url" content="${siteURL}" />
    <meta property="og:image" content="${image}" />
    <meta property="og:image:width" content="2172" />
    <meta property="og:image:height" content="724" />
    <meta property="og:image:alt" content="VikingBar: Mobile Vikings usage in your Mac menu bar" />
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:title" content="${escape(title)}" />
    <meta name="twitter:description" content="${escape(description)}" />
    <meta name="twitter:image" content="${image}" />
    <meta name="twitter:image:alt" content="VikingBar: Mobile Vikings usage in your Mac menu bar" />
    <link rel="sitemap" type="application/xml" href="${siteURL}sitemap.xml" />
    <script type="application/ld+json">${JSON.stringify(schema).replaceAll('<', '\\u003c')}</script>`;
let html = await readFile(new URL('index.html', output), 'utf8');
html = html.replace(/<title>.*?<\/title>/, `<title>${escape(title)}</title>`)
  .replace(/<meta name="description" content="[^"]*"\s*\/>/, `<meta name="description" content="${escape(description)}" />`)
  .replace('</head>', `${meta}\n  </head>`)
  .replace('<div id="root"></div>', `<div id="root">${render()}</div>`);
await writeFile(new URL('index.html', output), html);
await copyFile(new URL('../../docs/assets/vikingbar-header.png', import.meta.url), new URL('assets/social-card.png', output));
await writeFile(new URL('sitemap.xml', output), `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>${siteURL}</loc></url></urlset>\n`);
await writeFile(new URL('robots.txt', output), `User-agent: *\nAllow: /\nSitemap: ${siteURL}sitemap.xml\n`);
await writeFile(new URL('llms.txt', output), `# VikingBar\n\n> ${description}\n\nDevelopment build for Apple Silicon Macs running macOS 14+. Independent project, not an official Mobile Vikings app. The website preview uses synthetic balances.\n\n## Documentation\n- [Website](${siteURL})\n- [Source and README](https://github.com/BramVR/VikingBar)\n- [Account setup](https://github.com/BramVR/VikingBar/blob/main/docs/live-account.md)\n- [Development builds](https://github.com/BramVR/VikingBar/blob/main/docs/RELEASING.md#download-a-development-build)\n\n## Questions\n${questions.map(([q, a]) => `### ${q}\n${a}\n`).join('\n')}`);
await writeFile(new URL('.nojekyll', output), '');
await writeFile(new URL('404.html', output), `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><meta name="robots" content="noindex"><title>Page not found — VikingBar</title><body><h1>Page not found</h1><p><a href="${siteURL}">Return to VikingBar</a></p></body></html>`);
console.log('Pre-rendered product text, metadata, structured data, sitemap, and llms.txt.');
