import { readFileSync, readdirSync, statSync, lstatSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { builtinModules, createRequire } from 'node:module';
import { join, resolve, relative, sep, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';
const hash = value => createHash('sha256').update(value).digest('hex');
export function verifyArtifact(directory) {
  const root = resolve(directory), release = JSON.parse(readFileSync(join(root, 'shared/release-manifest.json'), 'utf8'));
  const { buildId, ...identity } = release;
  if (release.manifestVersion !== 1 || release.protocolVersion !== 'image-read-v1') throw new Error('Unsupported manifest protocol.');
  if (hash(JSON.stringify(identity)) !== buildId) throw new Error('Manifest identity mismatch.');
  function walk(directory, prefix = '') {
    return readdirSync(directory).sort().flatMap(name => {
      const path = join(directory, name), next = prefix ? prefix + '/' + name : name;
      if (lstatSync(path).isSymbolicLink()) throw new Error('Artifact symlink rejected.');
      return statSync(path).isDirectory() ? walk(path, next) : [next];
    });
  }
  const sourceRoot = resolve(fileURLToPath(new URL('..', import.meta.url)));
  for (const [file, digest] of Object.entries(release.sources)) if (hash(readFileSync(join(sourceRoot, file))) !== digest) throw new Error('Source changed since packaging: ' + file);
  if (hash(readFileSync(join(sourceRoot, 'AppScope/resources/rawfile/schema.json'))) !== release.schemaHash) throw new Error('Source schema changed since packaging.');
  const files = walk(root).filter(file => file !== 'shared/release-manifest.json');
  if (files.length !== Object.keys(release.files).length) throw new Error('Artifact contains unrecorded/missing files.');
  for (const file of files) if (hash(readFileSync(join(root, file))) !== release.files[file]) throw new Error('Artifact changed: ' + file);
  if (release.policyHash !== release.files['shared/content-policy.js']) throw new Error('Policy fingerprint mismatch.');
  const manifest = JSON.parse(readFileSync(join(root, 'package.json'))), lock = JSON.parse(readFileSync(join(root, 'package-lock.json')));
  if (manifest.name !== release.functionName || manifest.engines?.node !== '20.x' || JSON.stringify(manifest.dependencies || {}) !== JSON.stringify(lock.packages[''].dependencies || {})) throw new Error('Package/lock identity mismatch.');
  for (const [name, version] of Object.entries(manifest.dependencies)) {
    const installed = JSON.parse(readFileSync(join(root, 'node_modules', ...name.split('/'), 'package.json')));
    if (installed.version !== version || lock.packages['node_modules/' + name]?.version !== version) throw new Error('Dependency version mismatch: ' + name);
  }
  const config = JSON.parse(readFileSync(join(root, 'function-config.json'))), [entry, symbol] = config.handler.split('.');
  if (release.generatedHandlerHash !== release.files[entry + '.js']) throw new Error('Generated entry fingerprint mismatch.');
  if (!readFileSync(join(root, entry + '.js'), 'utf8').includes('exports.' + symbol)) throw new Error('Handler export missing.');
  const builtins = new Set(builtinModules.flatMap(name => [name, 'node:' + name]));
  for (const file of files.filter(file => file.endsWith('.js') && !file.startsWith('node_modules/'))) {
    const path = join(root, file), resolver = createRequire(path), code = readFileSync(path, 'utf8');
    for (const match of code.matchAll(/\brequire\(\s*(['"])([^'"]+)\1\s*\)/g)) {
      const request = match[2]; if (builtins.has(request)) continue;
      const modulePath = resolver.resolve(request), location = relative(root, modulePath);
      if (location === '..' || location.startsWith('..' + sep) || isAbsolute(location)) throw new Error('Dependency escapes artifact: ' + request);
      if (!request.startsWith('.')) {
        const parts = request.split('/'), name = request.startsWith('@') ? parts.slice(0, 2).join('/') : parts[0];
        if (!manifest.dependencies[name]) throw new Error('Undeclared runtime dependency: ' + name);
      }
    }
  }
  console.log('Artifact fingerprints and local dependency closure verified: ' + release.functionName + ' ' + buildId);
  return release;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { if (process.argv.length !== 3) throw new Error('Usage: node scripts/check-artifact.mjs <unpacked-artifact>'); verifyArtifact(process.argv[2]); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
