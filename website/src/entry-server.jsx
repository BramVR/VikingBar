import React from 'react';
import { renderToString } from 'react-dom/server';
import { App } from './App.jsx';
export { questions } from './questions.js';
export { siteURL, title, description } from './site.js';
export const render = () => renderToString(<React.StrictMode><App/></React.StrictMode>);
