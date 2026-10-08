import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { builtinModules, createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

// Run explicitly before uploading a deployment ZIP. This prepares local
// artifacts and the compiled source-directory entry only. It never calls the
// cloud or executes handlers, and keeps the TypeScript implementation intact.
const cloudRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const definitions = {
  'shike-auth': { entry: 'shikeAuth', className: 'ShikeAuth', modules: ['runtime.js'] },
  'shike-media': { entry: 'shikeMedia', className: 'ShikeMedia', modules: ['runtime.js', 'read-errors.js', 'content-policy.js'] },
  'shike-service': { entry: 'shikeService', className: 'ShikeService',
    modules: ['runtime.js', 'read-errors.js', 'content-policy.js', 'stage1-services.js', 'stage2-services.js', 'stage3-services.js', 'stages47-common.js', 'stage4-services.js', 'stage5-services.js', 'stage6-services.js', 'stage7-services.js', 'personal-collections.js', 'moderation-services.js', 'lifecycle-services.js', 'authentication-cleanup.js'] },
  'shike-location': { entry: 'shikeLocation', className: 'ShikeLocation', modules: ['runtime.js', 'read-errors.js', 'content-policy.js'] }
};

function requireFile(path) {
  if (!existsSync(path) || !statSync(path).isFile()) throw new Error('Required file is missing: ' + path);
  return path;
}

function readJson(path) {
  return JSON.parse(readFileSync(requireFile(path), 'utf8'));
}

function run(command, args, cwd, capture = false) {
  const result = spawnSync(command, args, {
    cwd, shell: false, encoding: 'utf8', stdio: capture ? 'pipe' : 'inherit',
    env: { ...process.env, PATH: dirname(process.execPath) + sepForPath() + (process.env.PATH || '') }
  });
  if (result.error) throw new Error(command + ' could not start: ' + result.error.message);
  if (result.status !== 0) {
    if (capture && result.stderr) console.error(result.stderr.trim());
    throw new Error(command + ' failed (exit ' + result.status + '). No deployable ZIP was produced.');
  }
  return result.stdout || '';
}

function sepForPath() {
  return process.platform === 'win32' ? ';' : ':';
}

function npm(args, cwd) {
  const cli = process.env.npm_execpath;
  if (cli && existsSync(cli) && cli.endsWith('.js')) run(process.execPath, [cli, ...args], cwd);
  else run(process.platform === 'win32' ? 'npm.cmd' : 'npm', args, cwd);
}

function requestsIn(path) {
  return [...readFileSync(path, 'utf8').matchAll(/\brequire\(\s*(['"])([^'"]+)\1\s*\)/g)]
    .map((match) => match[2]);
}

function resolveLocal(source, request, sourceRoot) {
  const base = resolve(dirname(source), request);
  const candidates = [base, base + '.js', base + '.json', join(base, 'index.js')];
  const found = candidates.find((path) => existsSync(path) && statSync(path).isFile());
  if (!found) throw new Error('Required local module is missing: ' + request + ' in ' + source);
  const location = relative(sourceRoot, found);
  if (location === '..' || location.startsWith('..' + sep) || isAbsolute(location)) {
    throw new Error('Local module is outside this independent function package: ' + request);
  }
  return found;
}

function copyLocalModules(source, sourceRoot, artifactRoot, copied) {
  for (const request of requestsIn(source)) {
    if (!request.startsWith('.')) continue;
    const dependency = resolveLocal(source, request, sourceRoot);
    if (copied.has(dependency)) continue;
    copied.add(dependency);
    const destination = join(artifactRoot, relative(sourceRoot, dependency));
    mkdirSync(dirname(destination), { recursive: true });
    copyFileSync(dependency, destination);
    if (dependency.endsWith('.js')) copyLocalModules(dependency, sourceRoot, artifactRoot, copied);
  }
}

function verifyArtifact(artifactRoot, definition, sourceManifest, sourceLock) {
  const entryName = definition.entry + '.js';
  const required = [entryName, ...definition.modules, 'function-config.json', 'package.json', 'package-lock.json'];
  const rootEntries = readdirSync(artifactRoot);
  for (const name of required) {
    if (!rootEntries.includes(name)) throw new Error('Required root file is missing or has the wrong case: ' + name);
    requireFile(join(artifactRoot, name));
  }
  const artifactManifest = readJson(join(artifactRoot, 'package.json'));
  if (!artifactManifest || Array.isArray(artifactManifest) ||
    artifactManifest.name !== sourceManifest.name || artifactManifest.version !== sourceManifest.version ||
    artifactManifest.engines?.node !== '20.x' ||
    (artifactManifest.type !== undefined && artifactManifest.type !== 'commonjs')) {
    throw new Error('Deployment package.json must be valid JSON for this Node.js 20 CommonJS object.');
  }
  const entry = readFileSync(join(artifactRoot, entryName), 'utf8');
  if (!entry.includes('exports.' + definition.className + ' =')) {
    throw new Error(entryName + ' does not contain the expected CommonJS class export.');
  }
  const config = readJson(join(artifactRoot, 'function-config.json'));
  if (config.handler !== definition.entry + '.' + definition.className || config.functionType !== 1) {
    throw new Error('Deployment handler or Cloud Object functionType does not match the source.');
  }
  const resolver = createRequire(join(artifactRoot, entryName));
  const builtins = new Set(builtinModules.flatMap((name) => [name, 'node:' + name]));
  const files = [join(artifactRoot, entryName), ...definition.modules.map((name) => join(artifactRoot, name))];
  const visited = new Set();
  while (files.length > 0) {
    const file = files.pop();
    if (visited.has(file)) continue;
    visited.add(file);
    for (const request of requestsIn(file)) {
      if (builtins.has(request)) continue;
      if (isAbsolute(request)) throw new Error('Absolute require is not portable: ' + request);
      const localResolver = createRequire(file);
      const modulePath = localResolver.resolve(request);
      if (request.startsWith('.')) {
        const location = relative(artifactRoot, modulePath);
        if (location === '..' || location.startsWith('..' + sep) || isAbsolute(location)) {
          throw new Error('Local module resolves outside the deployment package: ' + request);
        }
        if (modulePath.endsWith('.js')) files.push(modulePath);
      } else {
        const parts = request.split('/');
        const packageName = request.startsWith('@') ? parts.slice(0, 2).join('/') : parts[0];
        const location = relative(join(artifactRoot, 'node_modules'), modulePath);
        if (!sourceManifest.dependencies?.[packageName] || location === '..' ||
          location.startsWith('..' + sep) || isAbsolute(location)) {
          throw new Error('Runtime package must be declared and installed inside this artifact: ' + packageName);
        }
      }
    }
  }
  for (const [name, version] of Object.entries(sourceManifest.dependencies || {})) {
    const locked = sourceLock.packages['node_modules/' + name];
    const installed = readJson(join(artifactRoot, 'node_modules', ...name.split('/'), 'package.json'));
    if (!locked || locked.version !== version || installed.version !== version) {
      throw new Error('Production dependency does not match its locked version: ' + name);
    }
    resolver.resolve(name);
  }
  return required;
}

function publishSourceEntry(sourceRoot, artifactRoot, definition) {
  const entryName = definition.entry + '.js';
  const mapName = entryName + '.map';
  const artifactMap = join(artifactRoot, mapName);
  if (existsSync(artifactMap)) {
    const sourceMap = readJson(artifactMap);
    // The artifact's relative source paths must be rebased when its map is
    // placed beside the original TS file for source-directory deployment.
    sourceMap.sources = sourceMap.sources.map((source) => relative(sourceRoot,
      resolve(artifactRoot, sourceMap.sourceRoot || '', source)).split(sep).join('/'));
    sourceMap.sourceRoot = '';
    writeFileSync(join(sourceRoot, mapName), JSON.stringify(sourceMap) + '\n');
  }
  const destination = join(sourceRoot, entryName);
  copyFileSync(requireFile(join(artifactRoot, entryName)), destination);
  return destination;
}

function verifyArchive(archive, artifactRoot, required) {
  const names = new Set(run('unzip', ['-Z1', archive], artifactRoot, true).split(/\r?\n/).filter(Boolean));
  for (const name of required) {
    if (!names.has(name)) throw new Error('ZIP root file is missing: ' + name);
    const archived = run('unzip', ['-p', archive, name], artifactRoot, true);
    if (archived !== readFileSync(join(artifactRoot, name), 'utf8')) {
      throw new Error('ZIP content does not match the verified deployment file: ' + name);
    }
  }
  const manifestText = run('unzip', ['-p', archive, 'package.json'], artifactRoot, true);
  JSON.parse(manifestText);
  return createHash('sha256').update(manifestText, 'utf8').digest('hex');
}

function prepareObject(name) {
  const definition = definitions[name];
  const sourceRoot = join(cloudRoot, 'cloudfunctions', name);
  const config = readJson(join(sourceRoot, 'function-config.json'));
  const manifest = readJson(join(sourceRoot, 'package.json'));
  const lock = readJson(join(sourceRoot, 'package-lock.json'));
  if (config.handler !== definition.entry + '.' + definition.className || config.functionType !== 1) {
    throw new Error('Keep the existing Cloud Object handler and functionType=1.');
  }
  const declaredDependencies = manifest.dependencies || {};
  const lockedDependencies = lock.packages?.['']?.dependencies || {};
  if (manifest.engines?.node !== '20.x' || lock.packages?.['']?.name !== manifest.name ||
    lock.packages[''].version !== manifest.version ||
    Object.keys(declaredDependencies).length !== Object.keys(lockedDependencies).length ||
    Object.entries(declaredDependencies).some(([name, version]) => lockedDependencies[name] !== version)) {
    throw new Error('The package identity, Node engine or dependencies do not match the lockfile.');
  }
  const sourceEntry = requireFile(join(sourceRoot, definition.entry + '.ts'));
  for (const module of definition.modules) requireFile(join(sourceRoot, module));
  console.log('[' + name + '] Installing locked compiler dependencies.');
  npm(['ci', '--include=dev'], sourceRoot);
  const compiler = requireFile(join(sourceRoot, 'node_modules', 'typescript', 'bin', 'tsc'));
  // A fresh directory prevents an old compiled handler from hiding a failed build.
  const outputRoot = join(cloudRoot, 'build', 'cloud');
  mkdirSync(outputRoot, { recursive: true });
  const artifactRoot = mkdtempSync(join(outputRoot, name + '-deployment-'));
  console.log('[' + name + '] Compiling the handler into ' + artifactRoot);
  run(process.execPath, [compiler, '--project', join(sourceRoot, 'tsconfig.json'), '--outDir', artifactRoot], sourceRoot);
  const copied = new Set();
  copyLocalModules(sourceEntry, sourceRoot, artifactRoot, copied);
  for (const file of ['function-config.json', 'package.json', 'package-lock.json']) {
    copyFileSync(join(sourceRoot, file), join(artifactRoot, file));
  }
  console.log('[' + name + '] Installing locked production dependencies in the deployment package.');
  npm(['ci', '--omit=dev'], artifactRoot);
  const required = verifyArtifact(artifactRoot, definition, manifest, lock);
  // CloudDev may deploy the source directory, rather than our ZIP directory.
  // Publish the verified compiled entry there only after a successful build.
  const sourceHandler = publishSourceEntry(sourceRoot, artifactRoot, definition);
  const archive = artifactRoot + '.zip';
  // cwd is the artifact root: the ZIP contains shikeService.js directly,
  // never an outer shike-service/ or deployment directory.
  let manifestHash;
  try {
    run('zip', ['-q', '-r', archive, ...readdirSync(artifactRoot).sort()], artifactRoot);
    manifestHash = verifyArchive(archive, artifactRoot, required);
  } catch (error) {
    rmSync(archive, { force: true });
    throw error;
  }
  console.log('[' + name + '] Deployment package prepared; root files: ' + required.join(', '));
  console.log('Source handler: ' + sourceHandler);
  console.log('ZIP: ' + archive);
  console.log('ZIP package.json SHA256: ' + manifestHash);
  console.log('Handler: ' + config.handler + '; functionType=1; Node.js 20.x.');
  console.log('No cloud deployment or application test was performed. Deploy the function source directory or upload this ZIP.');
}

function main() {
  const args = process.argv.slice(2);
  if (args.length !== 1 || (args[0] !== '--all' &&
    !Object.prototype.hasOwnProperty.call(definitions, args[0]))) {
    throw new Error('Usage: npm run package:cloud:all, or npm run package:cloud -- <shike-object-name>');
  }
  if (Number(process.versions.node.split('.')[0]) !== 20) {
    throw new Error('Use Node.js 20.x for this deployment package. Current: ' + process.versions.node);
  }
  const names = args[0] === '--all' ? Object.keys(definitions) : [args[0]];
  for (const name of names) {
    console.log('[package-cloud-object] Preparing ' + name + '.');
    try {
      prepareObject(name);
    } catch (error) {
      throw new Error(name + ': ' + (error instanceof Error ? error.message : 'Package preparation failed.'));
    }
  }
  console.log('[package-cloud-object] Prepared ' + names.length + ' object(s): ' + names.join(', ') + '.');
}

try {
  main();
} catch (error) {
  console.error('[package-cloud-object] ' + (error instanceof Error ? error.message : 'Package preparation failed.'));
  process.exitCode = 1;
}
