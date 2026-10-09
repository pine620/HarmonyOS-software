import { packageFunction } from './package-functions.mjs';
try { packageFunction('shike-maintenance'); } catch (error) { console.error(error.message); process.exitCode = 1; }
