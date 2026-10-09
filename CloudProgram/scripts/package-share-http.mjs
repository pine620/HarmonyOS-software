import { packageFunction } from './package-functions.mjs';
try { packageFunction('shike-share'); } catch (error) { console.error(error.message); process.exitCode = 1; }
