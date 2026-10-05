import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { builtinModules, createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const sourceRoot = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const artifactFlag = args.indexOf('--artifact');
const artifactMode = artifactFlag >= 0;

function usage() {
  console.error('Usage: node check-deployment.mjs [--artifact <unpacked-deployment-directory>]');
  process.exitCode = 2;
}

if ((artifactMode && (args.length !== 2 || artifactFlag !== 0 || !args[1])) || (!artifactMode && args.length !== 0)) {
  usage();
} else {
  const root = artifactMode ? resolve(args[1]) : sourceRoot;
  const errors = [];

  function readJson(filePath, label) {
    try {
      return JSON.parse(readFileSync(filePath, 'utf8'));
    } catch (_error) {
      errors.push(label + ' is missing or invalid JSON.');
      return undefined;
    }
  }

  function hasExactEntry(directory, name) {
    try {
      return readdirSync(directory).includes(name);
    } catch (_error) {
      return false;
    }
  }

  function requireFile(name) {
    const filePath = join(root, name);
    if (!hasExactEntry(root, name) || !existsSync(filePath) || !statSync(filePath).isFile()) {
      errors.push('Required root file is missing or has the wrong case: ' + name);
    }
    return filePath;
  }

  const handlerName = artifactMode ? 'shikeMedia.js' : 'shikeMedia.ts';
  const handlerPath = requireFile(handlerName);
  const runtimePath = requireFile('runtime.js');
  const policyPath = requireFile('content-policy.js');
  const configPath = requireFile('function-config.json');
  const packagePath = requireFile('package.json');
  const lockPath = requireFile('package-lock.json');
  const dependencyDirectory = join(root, 'node_modules');
  if (!existsSync(dependencyDirectory) || !statSync(dependencyDirectory).isDirectory()) {
    errors.push('node_modules is missing; install the locked production dependencies before deployment.');
  }

  const config = readJson(configPath, 'function-config.json');
  if (config && (config.handler !== 'shikeMedia.ShikeMedia' || config.functionType !== 1)) {
    errors.push('function-config.json must keep handler shikeMedia.ShikeMedia and functionType 1.');
  }

  const packageJson = readJson(packagePath, 'package.json');
  const lock = readJson(lockPath, 'package-lock.json');
  const lockedRoot = lock && lock.packages && lock.packages[''];
  if (packageJson && (!packageJson.engines || packageJson.engines.node !== '20.x')) {
    errors.push('package.json must retain the configured Node.js 20.x engine.');
  }
  if (packageJson && lock && (!lockedRoot || lockedRoot.name !== packageJson.name || lockedRoot.version !== packageJson.version)) {
    errors.push('package-lock.json root package identity does not match package.json.');
  }
  if (lock && lock.packages) {
    for (const [location, lockedPackage] of Object.entries(lock.packages)) {
      if (!location.startsWith('node_modules/') || lockedPackage.dev === true || lockedPackage.optional === true) continue;
      const installedPath = join(root, location);
      if (!existsSync(installedPath) || !statSync(installedPath).isDirectory()) {
        errors.push('Locked production dependency is missing: ' + location);
      }
    }
  }

  const handlerCode = existsSync(handlerPath) ? readFileSync(handlerPath, 'utf8') : '';
  const runtimeCode = existsSync(runtimePath) ? readFileSync(runtimePath, 'utf8') : '';
  const policyCode = existsSync(policyPath) ? readFileSync(policyPath, 'utf8') : '';
  const requests = [];
  const requestPattern = /\brequire\(\s*(['"])([^'"]+)\1\s*\)/g;
  for (const source of [handlerCode, runtimeCode, policyCode]) {
    for (const match of source.matchAll(requestPattern)) requests.push(match[2]);
  }
  if (!requests.includes('./runtime')) errors.push(handlerName + ' must retain the relative require(\'./runtime\').');
  if (!runtimeCode.includes('module.exports')) errors.push('runtime.js must export the media runtime methods.');
  for (const method of ['execute', 'prepareCardPhoto', 'uploadCardPhoto', 'getPublicMedia']) {
    if (!runtimeCode.includes(method) || !handlerCode.includes(method)) {
      errors.push('Media runtime method ' + method + ' is missing from the handler/runtime source pair.');
    }
  }

  const handlerRequire = createRequire(join(root, 'shikeMedia.js'));
  const runtimeRequire = createRequire(join(root, 'runtime.js'));
  for (const request of new Set(requests)) {
    if (request.startsWith('.') || request.startsWith('/')) {
      try {
        const resolvedPath = handlerRequire.resolve(request);
        if (!existsSync(resolvedPath)) errors.push('Relative module does not exist: ' + request);
      } catch (_error) {
        errors.push('Relative module cannot be resolved from the package root: ' + request);
      }
      continue;
    }

    const normalizedBuiltin = request.replace(/^node:/, '');
    if (builtinModules.includes(normalizedBuiltin) || builtinModules.includes('node:' + normalizedBuiltin)) continue;

    const parts = request.split('/');
    const packageName = request.startsWith('@') ? parts.slice(0, 2).join('/') : parts[0];
    const declaredVersion = packageJson && packageJson.dependencies && packageJson.dependencies[packageName];
    const lockedVersion = lockedRoot && lockedRoot.dependencies && lockedRoot.dependencies[packageName];
    const packageLockEntry = lock && lock.packages && lock.packages['node_modules/' + packageName];
    if (!declaredVersion || declaredVersion !== lockedVersion || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(declaredVersion)) {
      errors.push('Runtime package ' + packageName + ' must be pinned consistently in package.json and package-lock.json.');
      continue;
    }
    if (!packageLockEntry || packageLockEntry.version !== declaredVersion) {
      errors.push('package-lock.json has no matching locked installation for ' + packageName + '@' + declaredVersion + '.');
    }
    try {
      runtimeRequire.resolve(request);
      const installedManifest = join(root, 'node_modules', ...packageName.split('/'), 'package.json');
      const installedPackage = readJson(installedManifest, 'node_modules/' + packageName + '/package.json');
      if (installedPackage && installedPackage.version !== declaredVersion) {
        errors.push('Installed ' + packageName + ' version does not match the lockfile.');
      }
    } catch (_error) {
      errors.push('Runtime dependency cannot be resolved from node_modules: ' + packageName);
    }
  }

  if (errors.length > 0) {
    console.error('[shike-media] ' + (artifactMode ? 'Deployment artifact' : 'Source package') + ' preflight failed:');
    for (const error of errors) console.error('- ' + error);
    process.exitCode = 1;
  } else {
    console.log('[shike-media] ' + (artifactMode ? 'Deployment artifact' : 'Source package') + ' preflight passed.');
    console.log('Handler: shikeMedia.ShikeMedia; local runtime module and pinned runtime dependencies resolve.');
  }
}
