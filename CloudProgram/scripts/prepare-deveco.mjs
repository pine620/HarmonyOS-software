import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { builtinModules } from 'node:module';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { functionDefinitions, generatedDirectories, localDependency, moduleDestination } from './function-layout.mjs';

// User-run source synchronization only: no npm install, compilation, ZIP,
// handler execution, credentials, network or deployment.
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const functions = join(root, 'cloudfunctions');
const hash = value => createHash('sha256').update(value).digest('hex');
const builtins = new Set(builtinModules.flatMap(name => [name, 'node:' + name]));
const requires = /\brequire\(\s*(['"])([^'"]+)\1\s*\)/g;
const manifestName = 'shared/deveco-source-manifest.json';

function planFunction(name) {
  const definition = functionDefinitions[name], sourceRoot = join(functions, name);
  const files = new Map(), generated = new Map(), sources = {};
  const record = path => {
    const bytes = readFileSync(path);
    sources[relative(root, path).split(sep).join('/')] = hash(bytes);
    return bytes;
  };
  function visit(source) {
    const destination = moduleDestination(functions, name, source);
    if (files.has(destination)) return;
    const original = record(source).toString('utf8');
    files.set(destination, original);
    let code = original;
    if (/\.[jt]s$/.test(source)) code = original.replace(requires, (whole, quote, request) => {
      if (!request.startsWith('.')) return whole;
      const dependency = localDependency(functions, source, request);
      visit(dependency);
      // Maintained files already use function-owned paths. Only derived copies
      // (service/media/shared subtrees) need their relative imports rebased.
      if (source.startsWith(sourceRoot + sep)) return whole;
      let rebased = relative(dirname(destination), moduleDestination(functions, name, dependency)).split(sep).join('/');
      if (!rebased.startsWith('.')) rebased = './' + rebased;
      return 'require(' + JSON.stringify(rebased) + ')';
    });
    files.set(destination, code);
    if (!source.startsWith(sourceRoot + sep)) generated.set(destination, code);
  }
  const entry = definition.entry + (definition.className ? '.ts' : '.js');
  visit(join(sourceRoot, entry));
  for (const extra of definition.extra || []) visit(join(sourceRoot, extra));
  if (definition.extraMedia) visit(join(functions, 'shike-media', 'cover-worker.js'));
  // release-info reads content-policy through fs rather than a literal require.
  visit(join(functions, 'shared', 'release-info.js'));
  visit(join(functions, 'shared', 'content-policy.js'));
  for (const file of ['package.json', 'package-lock.json', 'function-config.json', 'tsconfig.json', 'timer-contract.json', 'gateway-contract.json']) {
    if (existsSync(join(sourceRoot, file))) files.set(file, record(join(sourceRoot, file)).toString('utf8'));
  }
  const config = JSON.parse(files.get('function-config.json'));
  if (config.handler !== definition.entry + '.' + (definition.className || 'handler') ||
    config.functionType !== (definition.className ? 1 : 0)) throw new Error(name + ': handler/type mismatch');
  const manifest = JSON.parse(files.get('package.json')), lock = JSON.parse(files.get('package-lock.json'));
  if (manifest.name !== name || lock.name !== name || manifest.engines?.node !== '20.x' ||
    JSON.stringify(manifest.dependencies || {}) !== JSON.stringify(lock.packages[''].dependencies || {})) {
    throw new Error(name + ': package/lock mismatch');
  }
  for (const [file, code] of files) {
    if (!/\.[jt]s$/.test(file)) continue;
    for (const match of code.matchAll(requires)) {
      const request = match[2];
      if (builtins.has(request)) continue;
      if (request.startsWith('.')) {
        const base = relative(sourceRoot, resolve(sourceRoot, dirname(file), request)).split(sep).join('/');
        if (![base, base + '.js', base + '.json', base + '/index.js'].some(path => files.has(path))) {
          throw new Error(name + ': dependency missing/escaping function: ' + file + ' -> ' + request);
        }
      } else {
        const parts = request.split('/'), dependency = request.startsWith('@') ? parts.slice(0, 2).join('/') : parts[0];
        const version = manifest.dependencies?.[dependency];
        if (!version || lock.packages['node_modules/' + dependency]?.version !== version) {
          throw new Error(name + ': undeclared/unlocked dependency: ' + dependency);
        }
      }
    }
  }
  const schema = record(join(root, 'AppScope/resources/rawfile/schema.json'));
  record(fileURLToPath(import.meta.url));
  record(join(root, 'scripts/function-layout.mjs'));
  const identity = {
    manifestVersion: 1, deploymentMode: 'deveco-source', functionName: name,
    protocolVersion: 'image-read-v1', policyHash: hash(files.get('shared/content-policy.js')),
    schemaHash: hash(schema), schemaVersion: JSON.parse(schema).schemaVersion, entrySource: entry,
    sources: Object.fromEntries(Object.entries(sources).sort(([a], [b]) => a.localeCompare(b))),
    files: Object.fromEntries([...files].sort(([a], [b]) => a.localeCompare(b)).map(([file, code]) => [file, hash(code)]))
  };
  const release = { ...identity, buildId: 'image-read-v1-deveco-' + hash(JSON.stringify(identity)) };
  generated.set(manifestName, JSON.stringify(release, null, 2) + '\n');
  return { name, sourceRoot, generated, release };
}

function walk(directory, prefix) {
  return readdirSync(directory).sort().flatMap(name => {
    const path = join(directory, name), next = prefix + '/' + name;
    return statSync(path).isDirectory() ? walk(path, next) : [next];
  });
}
function checkPlan(plan) {
  for (const folder of generatedDirectories(plan.name)) {
    const path = join(plan.sourceRoot, folder);
    if (!existsSync(path)) throw new Error(plan.name + ': run npm run prepare:deveco first');
    for (const file of walk(path, folder)) if (!plan.generated.has(file)) throw new Error(plan.name + ': stale generated file: ' + file);
  }
  for (const [file, code] of plan.generated) {
    const path = join(plan.sourceRoot, file);
    if (!existsSync(path) || readFileSync(path, 'utf8') !== code) throw new Error(plan.name + ': missing/stale generated file: ' + file);
  }
}

try {
  if (process.argv.length > 3 || (process.argv[2] && process.argv[2] !== '--check')) throw new Error('Usage: node scripts/prepare-deveco.mjs [--check]');
  const plans = Object.keys(functionDefinitions).map(planFunction);
  for (const plan of plans) {
    if (process.argv[2] !== '--check') {
      for (const folder of generatedDirectories(plan.name)) rmSync(join(plan.sourceRoot, folder), { recursive: true, force: true });
      for (const [file, code] of plan.generated) {
        const path = join(plan.sourceRoot, file);
        mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, code);
      }
    }
    checkPlan(plan);
    console.log(JSON.stringify({ functionName: plan.name, generatedFiles: plan.generated.size, buildId: plan.release.buildId, policyHash: plan.release.policyHash }));
  }
  console.log('DevEco source dependency closure ready for 7 functions. No compilation, handler execution or deployment performed.');
} catch (error) { console.error(error.message); process.exitCode = 1; }
