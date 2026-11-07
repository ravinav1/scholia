import { installContentBootstrap } from './content-bootstrap.js';

const key = Symbol.for('scholia.content.bootstrap');
if (!globalThis[key]) globalThis[key] = installContentBootstrap();
