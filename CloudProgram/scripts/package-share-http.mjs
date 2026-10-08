import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
// User-run artifact preparation only. No handler is imported or invoked.
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const source = join(root, 'cloudfunctions', 'shike-share');
const service = join(root, 'cloudfunctions', 'shike-service');
if (Number(process.versions.node.split('.')[0]) !== 20) throw new Error('Use Node.js 20.x.');
// Schema defaults in the editor do not guarantee that deployment requests carry these fields.
// Validate the explicit source config before installing dependencies or producing an artifact.
const triggerConfigPath = join(source, 'function-config.json');
const triggerConfig = JSON.parse(readFileSync(triggerConfigPath, 'utf8'));
const trigger = triggerConfig && Array.isArray(triggerConfig.triggers) && triggerConfig.triggers.length === 1
  ? triggerConfig.triggers[0] : null;
const properties = trigger && trigger.properties;
if (!triggerConfig || triggerConfig.handler !== 'shikeShare.handler' || triggerConfig.functionType !== 0 ||
    !trigger || trigger.type !== 'http' || !properties || properties.enableUrlDecode !== false ||
    properties.authFlag !== 'false' || properties.authAlgor !== 'HDA-SYSTEM' || properties.authType !== 'apigw-client') {
  throw new Error('Invalid shike-share trigger config: require event functionType=0, shikeShare.handler, HTTP authFlag="false", authAlgor="HDA-SYSTEM", authType="apigw-client", and enableUrlDecode=false.');
}
const targetParent = join(root, 'build', 'cloud'); mkdirSync(targetParent, {recursive: true});
const target = mkdtempSync(join(targetParent, 'shike-share-deployment-')); mkdirSync(join(target, 'service'));
const modules = ['runtime.js', 'content-policy.js', 'stage1-services.js', 'stage2-services.js', 'stage3-services.js', 'stages47-common.js', 'stage4-services.js', 'stage5-services.js', 'stage6-services.js', 'stage7-services.js', 'read-errors.js', 'personal-collections.js', 'moderation-services.js', 'lifecycle-services.js', 'authentication-cleanup.js'];
for (const name of modules) copyFileSync(join(service, name), join(target, 'service', name));
const handler = readFileSync(join(source, 'shikeShare.js'), 'utf8').replace("require('../shike-service/runtime')", "require('./service/runtime')");
writeFileSync(join(target, 'shikeShare.js'), handler);
copyFileSync(triggerConfigPath, join(target, 'function-config.json'));
// Reuse the accepted, exact service dependency/lock contract without executing a compiler.
copyFileSync(join(service, 'package.json'), join(target, 'package.json'));
copyFileSync(join(service, 'package-lock.json'), join(target, 'package-lock.json'));
const npmCli = process.env.npm_execpath;
const command = npmCli && npmCli.endsWith('.js') ? process.execPath : 'npm';
const args = npmCli && npmCli.endsWith('.js') ? [npmCli, 'ci', '--omit=dev'] : ['ci', '--omit=dev'];
const installed = spawnSync(command, args, {cwd: target, shell: false, stdio: 'inherit'});
if (installed.error || installed.status !== 0) throw new Error('Production dependencies were not installed; no ZIP prepared.');
const zipped = spawnSync('zip', ['-q', '-r', target + '.zip', ...readdirSync(target).sort()], {cwd: target, shell: false, stdio: 'inherit'});
if (zipped.error || zipped.status !== 0) throw new Error('ZIP preparation failed.');
console.log('HTTP artifact: ' + target + '.zip');
console.log('Handler shikeShare.handler; event functionType=0; gateway request/response mapping must match gateway-contract.json.');
console.log('No deployment or handler execution performed. The existing Cloud Object authentication stays enabled.');
