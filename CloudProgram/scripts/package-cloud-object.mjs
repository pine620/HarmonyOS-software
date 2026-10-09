import { packageFunction } from './package-functions.mjs';
const names = ['shike-auth', 'shike-media', 'shike-service', 'shike-location'];
try {
  const name = process.argv[2];
  if (process.argv.length !== 3 || name !== '--all' && !names.includes(name)) throw new Error('Usage: npm run package:cloud:all, or npm run package:cloud -- <cloud-object-name>');
  for (const item of name === '--all' ? names : [name]) packageFunction(item);
} catch (error) { console.error(error.message); process.exitCode = 1; }
