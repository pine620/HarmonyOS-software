import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { verifyArtifact } from './check-artifact.mjs';
import { functionDefinitions, localDependency, moduleDestination } from './function-layout.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const root = resolve(dirname(scriptPath), '..'), functions = join(root, 'cloudfunctions');
const definitions = functionDefinitions;
const hash = value => createHash('sha256').update(value).digest('hex');
function run(command, args, cwd, capture = false) {
  const result = spawnSync(command, args, { cwd, shell: false, encoding: 'utf8', stdio: capture ? 'pipe' : 'inherit',
    env: { ...process.env, PATH: dirname(process.execPath) + (process.platform === 'win32' ? ';' : ':') + (process.env.PATH || '') } });
  if (result.error || result.status !== 0) throw new Error(command + ' failed: ' + (result.error?.message || result.stderr || result.status));
  return result.stdout || '';
}
function npm(args, cwd) {
  const cli = process.env.npm_execpath;
  return cli && existsSync(cli) && cli.endsWith('.js') ? run(process.execPath, [cli, ...args], cwd) : run(process.platform === 'win32' ? 'npm.cmd' : 'npm', args, cwd);
}
function filesIn(directory, prefix = '') {
  return readdirSync(directory).sort().flatMap(name => {
    const path = join(directory, name), next = prefix ? prefix + '/' + name : name;
    return statSync(path).isDirectory() ? filesIn(path, next) : [next];
  });
}
export function packageFunction(name) {
  if (Number(process.versions.node.split('.')[0]) !== 20) throw new Error('Use Node.js 20.x.');
  const definition = definitions[name]; if (!definition) throw new Error('Unknown function: ' + name);
  const sourceRoot = join(functions, name), dependencyRoot = sourceRoot;
  const config = JSON.parse(readFileSync(join(sourceRoot, 'function-config.json'), 'utf8'));
  if (config.functionType !== (definition.className ? 1 : 0) || config.handler !== definition.entry + '.' + (definition.className || 'handler')) throw new Error('Handler/type mismatch.');
  // SDK-only image invocation must retain app authentication and must not expose anonymous HTTP.
  if (name === 'shike-image' && !config.triggers?.every(trigger => trigger.properties?.authFlag === 'true' && trigger.properties?.enableUrlDecode === false)) throw new Error('Image trigger must retain app authentication.');
  const manifest = JSON.parse(readFileSync(join(dependencyRoot, 'package.json'), 'utf8'));
  const lock = JSON.parse(readFileSync(join(dependencyRoot, 'package-lock.json'), 'utf8'));
  manifest.name = name; lock.name = name; lock.packages[''].name = name;
  if (manifest.engines?.node !== '20.x' || JSON.stringify(manifest.dependencies || {}) !== JSON.stringify(lock.packages[''].dependencies || {})) throw new Error('Package/lock dependency mismatch.');
  const parent = join(root, 'build', 'cloud'); mkdirSync(parent, { recursive: true });
  const target = mkdtempSync(join(parent, name + '-deployment-')), sources = {}, copied = new Set();
  const destination = source => join(target, moduleDestination(functions, name, source));
  function copyModule(source, suppliedCode) {
    if (copied.has(source)) return; copied.add(source);
    const original = readFileSync(source), output = destination(source);
    sources[relative(root, source).split(sep).join('/')] = hash(original);
    let code = suppliedCode === undefined ? original.toString('utf8') : suppliedCode;
    if (/\.[jt]s$/.test(source)) code = code.replace(/\brequire\(\s*(['"])([^'"]+)\1\s*\)/g, (whole, quote, request) => {
      if (!request.startsWith('.')) return whole;
      const dependency = localDependency(functions, source, request), path = destination(dependency);
      copyModule(dependency);
      let rebased = relative(dirname(output), path).split(sep).join('/'); if (!rebased.startsWith('.')) rebased = './' + rebased;
      return 'require(' + JSON.stringify(rebased) + ')';
    });
    mkdirSync(dirname(output), { recursive: true }); writeFileSync(output, code);
  }
  const entrySource = join(sourceRoot, definition.entry + (definition.className ? '.ts' : '.js'));
  if (definition.className) {
    npm(['ci', '--include=dev'], sourceRoot);
    const compiled = join(target, '.compiled');
    run(process.execPath, [join(sourceRoot, 'node_modules', 'typescript', 'bin', 'tsc'), '--project', join(sourceRoot, 'tsconfig.json'), '--outDir', compiled], sourceRoot);
    // Resolve emitted requires against the original TS location, then rebase into the independent artifact.
    copyModule(entrySource, readFileSync(join(compiled, definition.entry + '.js'), 'utf8').replace(/\n?\/\/# sourceMappingURL=.*$/m, ''));
    const temporaryEntry = destination(entrySource); copyFileSync(temporaryEntry, join(target, definition.entry + '.js')); rmSync(temporaryEntry);
    rmSync(compiled, { recursive: true });
    sources[relative(root, join(sourceRoot, 'tsconfig.json')).split(sep).join('/')] = hash(readFileSync(join(sourceRoot, 'tsconfig.json')));
  } else copyModule(entrySource);
  for (const extra of definition.extra || []) copyModule(join(sourceRoot, extra));
  if (definition.extraMedia) copyModule(join(functions, 'shike-media', 'cover-worker.js'));
  // Auth handlers also expose the exact shared policy hash, without importing the business runtime.
  copyModule(join(functions, 'shared', 'release-info.js'));
  copyModule(join(functions, 'shared', 'content-policy.js'));
  for (const file of ['function-config.json', 'timer-contract.json', 'gateway-contract.json']) if (existsSync(join(sourceRoot, file))) {
    copyFileSync(join(sourceRoot, file), join(target, file)); sources[relative(root, join(sourceRoot, file)).split(sep).join('/')] = hash(readFileSync(join(sourceRoot, file)));
  }
  for (const [file, value] of [['package.json', manifest], ['package-lock.json', lock]]) writeFileSync(join(target, file), JSON.stringify(value, null, 2) + '\n');
  sources[relative(root, join(dependencyRoot, 'package.json')).split(sep).join('/')] = hash(readFileSync(join(dependencyRoot, 'package.json')));
  sources[relative(root, join(dependencyRoot, 'package-lock.json')).split(sep).join('/')] = hash(readFileSync(join(dependencyRoot, 'package-lock.json')));
  npm(['ci', '--omit=dev'], target);
  rmSync(join(target, 'node_modules', '.bin'), { recursive: true, force: true });
  // Hash all shipped files, including exact installed dependencies. Manifest excludes only itself.
  for (const path of [scriptPath, join(root, 'scripts/function-layout.mjs'), join(root, 'scripts/check-artifact.mjs'), join(root, 'AppScope/resources/rawfile/schema.json'), ...filesIn(join(root, 'clouddb/objecttype')).map(file => join(root, 'clouddb/objecttype', file))]) sources[relative(root, path).split(sep).join('/')] = hash(readFileSync(path));
  const files = Object.fromEntries(filesIn(target).map(file => [file, hash(readFileSync(join(target, file)))]));
  const release = { manifestVersion: 1, functionName: name, protocolVersion: 'image-read-v1',
    policyHash: files['shared/content-policy.js'], schemaHash: hash(readFileSync(join(root, 'AppScope/resources/rawfile/schema.json'))),
    schemaVersion: JSON.parse(readFileSync(join(root, 'AppScope/resources/rawfile/schema.json'))).schemaVersion,
    generatedHandlerHash: files[definition.entry + '.js'], sources, files };
  release.buildId = hash(JSON.stringify(release));
  writeFileSync(join(target, 'shared', 'release-manifest.json'), JSON.stringify(release, null, 2) + '\n');
  verifyArtifact(target);
  const archive = target + '.zip';
  try {
    run('zip', ['-q', '-r', archive, ...readdirSync(target).sort()], target);
    const names = new Set(run('unzip', ['-Z1', archive], target, true).split(/\r?\n/));
    for (const file of [...Object.keys(files), 'shared/release-manifest.json']) if (!names.has(file)) throw new Error('Archive missing: ' + file);
  } catch (error) { rmSync(archive, { force: true }); throw error; }
  console.log(JSON.stringify({ functionName: name, artifact: target, zip: archive, buildId: release.buildId, policyHash: release.policyHash, schemaHash: release.schemaHash }));
  console.log('Upload this verified artifact ZIP. No source-directory generated handler is published; no deployment or handler execution performed.');
  return target;
}
if (process.argv[1] && resolve(process.argv[1]) === scriptPath) {
  try { if (process.argv.length !== 3) throw new Error('Usage: node scripts/package-functions.mjs <function-name>'); packageFunction(process.argv[2]); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
