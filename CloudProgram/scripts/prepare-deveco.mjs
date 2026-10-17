import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { builtinModules } from 'node:module';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { functionDefinitions, generatedDirectories, localDependency, moduleDestination } from './function-layout.mjs';

/**
 * 【文件职责】npm run prepare:deveco：为 DevEco 右键部署生成函数内依赖副本（shared/、service/、media/）与源码清单
 * shared/deveco-source-manifest.json；npm run check:deveco 只检查副本是否与源码同步。
 * 只做源码同步：不安装依赖、不编译、不打包、不执行 handler、不接触凭据或网络、不部署。
 * 【新人注意】修改 shared/ 或 shike-service/、shike-media/ 后，DevEco 部署前必须重新运行本脚本，否则会部署旧代码。
 */
// 路径、哈希函数、Node 内置模块列表、require 匹配正则与清单文件名。
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const functions = join(root, 'cloudfunctions');
const hash = value => createHash('sha256').update(value).digest('hex');
const builtins = new Set(builtinModules.flatMap(name => [name, 'node:' + name]));
const requires = /\brequire\(\s*(['"])([^'"]+)\1\s*\)/g;
const manifestName = 'shared/deveco-source-manifest.json';

// 为一个函数计算需要生成的文件（递归跟踪 require）与清单。
function planFunction(name) {
  const definition = functionDefinitions[name], sourceRoot = join(functions, name);
  const files = new Map(), generated = new Map(), sources = {};
  const record = path => {
    const bytes = readFileSync(path);
    sources[relative(root, path).split(sep).join('/')] = hash(bytes);
    return bytes;
  };
  // 递归访问一个源文件及其 require 的本地依赖，计算它在目标函数中的位置与改写后的内容。
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
      // 维护的源文件本身已经使用函数内的路径；只有派生副本（service / media / shared 子目录）需要改写相对 require。
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
  // release-info 通过 fs 读取 content-policy，而不是字面的 require，所以要显式加入。
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

// 递归遍历目录。
function walk(directory, prefix) {
  return readdirSync(directory).sort().flatMap(name => {
    const path = join(directory, name), next = prefix + '/' + name;
    return statSync(path).isDirectory() ? walk(path, next) : [next];
  });
}
// 检查函数内已有的生成副本与计划完全一致（--check 模式）。
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
  console.log(`DevEco source dependency closure ready for ${plans.length} functions. No compilation, handler execution or deployment performed.`);
} catch (error) { console.error(error.message); process.exitCode = 1; }
