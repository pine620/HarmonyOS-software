/**
 * 【文件职责】统一打包器（必须使用 Node.js 20.x）：packageFunction(name) 为一个云函数生成可上传到 AGC 的独立 ZIP，输出到 CloudProgram/build/。
 * 步骤：校验 function-config 与 package.json / package-lock → 编译 TS 入口 → 递归收集本地 require 依赖并复制到正确位置 →
 * npm ci 安装生产依赖 → 生成包含每个文件 sha256 的清单（buildId、policyHash、schemaHash）→ 压缩并用 check-artifact 校验。
 * 只准备本地产物，不会部署到 AGC。命令行：node scripts/package-functions.mjs <函数名>。
 */
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
// 执行子进程命令，失败时抛错。
function run(command, args, cwd, capture = false) {
  const result = spawnSync(command, args, { cwd, shell: false, encoding: 'utf8', stdio: capture ? 'pipe' : 'inherit',
    env: { ...process.env, PATH: dirname(process.execPath) + (process.platform === 'win32' ? ';' : ':') + (process.env.PATH || '') } });
  if (result.error || result.status !== 0) throw new Error(command + ' failed: ' + (result.error?.message || result.stderr || result.status));
  return result.stdout || '';
}
// 执行 npm（优先使用当前 npm 的 CLI 路径）。
function npm(args, cwd) {
  const cli = process.env.npm_execpath;
  return cli && existsSync(cli) && cli.endsWith('.js') ? run(process.execPath, [cli, ...args], cwd) : run(process.platform === 'win32' ? 'npm.cmd' : 'npm', args, cwd);
}
// 递归列出目录中的全部文件。
function filesIn(directory, prefix = '') {
  return readdirSync(directory).sort().flatMap(name => {
    const path = join(directory, name), next = prefix ? prefix + '/' + name : name;
    return statSync(path).isDirectory() ? filesIn(path, next) : [next];
  });
}
// 打包一个函数（流程见文件头）。
export function packageFunction(name) {
  if (Number(process.versions.node.split('.')[0]) !== 20) throw new Error('Use Node.js 20.x.');
  const definition = definitions[name]; if (!definition) throw new Error('Unknown function: ' + name);
  const sourceRoot = join(functions, name), dependencyRoot = sourceRoot;
  const config = JSON.parse(readFileSync(join(sourceRoot, 'function-config.json'), 'utf8'));
  if (config.functionType !== (definition.className ? 1 : 0) || config.handler !== definition.entry + '.' + (definition.className || 'handler')) throw new Error('Handler/type mismatch.');
  // 通过 SDK 调用的读图函数必须保留应用鉴权，绝不能开放匿名 HTTP。
  if (name === 'shike-image' && !config.triggers?.every(trigger => trigger.properties?.authFlag === 'true' && trigger.properties?.enableUrlDecode === false)) throw new Error('Image trigger must retain app authentication.');
  const manifest = JSON.parse(readFileSync(join(dependencyRoot, 'package.json'), 'utf8'));
  const lock = JSON.parse(readFileSync(join(dependencyRoot, 'package-lock.json'), 'utf8'));
  manifest.name = name; lock.name = name; lock.packages[''].name = name;
  if (manifest.engines?.node !== '20.x' || JSON.stringify(manifest.dependencies || {}) !== JSON.stringify(lock.packages[''].dependencies || {})) throw new Error('Package/lock dependency mismatch.');
  const parent = join(root, 'build', 'cloud'); mkdirSync(parent, { recursive: true });
  const target = mkdtempSync(join(parent, name + '-deployment-')), sources = {}, copied = new Set();
  const destination = source => join(target, moduleDestination(functions, name, source));
  // 把一个本地模块复制到产物中，并递归复制它 require 的本地依赖（改写为产物中的相对路径）。
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
    // 按原始 TS 文件的位置解析编译产物中的 require，然后改写到独立产物中的位置。
    copyModule(entrySource, readFileSync(join(compiled, definition.entry + '.js'), 'utf8').replace(/\n?\/\/# sourceMappingURL=.*$/m, ''));
    const temporaryEntry = destination(entrySource); copyFileSync(temporaryEntry, join(target, definition.entry + '.js')); rmSync(temporaryEntry);
    rmSync(compiled, { recursive: true });
    sources[relative(root, join(sourceRoot, 'tsconfig.json')).split(sep).join('/')] = hash(readFileSync(join(sourceRoot, 'tsconfig.json')));
  } else copyModule(entrySource);
  for (const extra of definition.extra || []) copyModule(join(sourceRoot, extra));
  if (definition.extraMedia) copyModule(join(functions, 'shike-media', 'cover-worker.js'));
  // 认证函数也要输出完全相同的共享策略哈希，但不引入业务 runtime。
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
  // 对所有要发布的文件（包括实际安装的依赖）计算哈希；清单只排除它自己。
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
