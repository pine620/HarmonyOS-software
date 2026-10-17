/**
 * 【文件职责】打包与同步脚本共用的“函数布局”定义：每个云函数的入口文件、类名（云对象）或 handler（事件函数），
 * 以及共享依赖从哪里取（shared/、shike-service/、shike-media/ 的唯一维护源码）、复制到函数内的哪个目录（shared/、service/、media/）。
 */
import { existsSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';

// 全部云函数：entry 入口文件名（不含扩展名），className 存在表示云对象（functionType=1），否则为事件函数（functionType=0）。
export const functionDefinitions = {
  'shike-auth': { entry: 'shikeAuth', className: 'ShikeAuth' },
  'shike-service': { entry: 'shikeService', className: 'ShikeService' },
  'shike-media': { entry: 'shikeMedia', className: 'ShikeMedia', extra: ['cover-worker.js'] },
  'shike-image': { entry: 'shikeImage' },
  'shike-maintenance': { entry: 'shikeMaintenance', extraMedia: true },
  // shike-service 的领域拆分：每个领域函数在 ./service 下运行 shike-service runtime 的派生副本。
  'shike-content': { entry: 'shikeContent', className: 'ShikeContent' },
  'shike-social': { entry: 'shikeSocial', className: 'ShikeSocial' },
  'shike-account': { entry: 'shikeAccount', className: 'ShikeAccount' },
  'shike-governance': { entry: 'shikeGovernance', className: 'ShikeGovernance' },
  // Cloud Foundation 预取目标：只返回已保存的首页快照。
  'shike-prefetch': { entry: 'shikePrefetch' }
};

// 在 ./service 目录内嵌 shike-service runtime 派生副本的函数。
const serviceConsumers = new Set(['shike-maintenance', 'shike-content', 'shike-social', 'shike-account', 'shike-governance']);

// 把函数内的部署路径解析回唯一维护的源码；新的部署绝不能用旧的生成副本作为输入。
// 把函数内的相对 require 解析到唯一维护的源文件（./shared/ → cloudfunctions/shared，./service/ → shike-service，./media/ → shike-media）。
export function localDependency(functions, source, request) {
  const folder = relative(functions, source).split(sep)[0];
  let base = resolve(dirname(source), request);
  if (folder !== 'shared' && request.startsWith('./shared/')) {
    base = resolve(functions, 'shared', request.slice('./shared/'.length));
  } else if (serviceConsumers.has(folder) && request.startsWith('./service/')) {
    base = resolve(functions, 'shike-service', request.slice('./service/'.length));
  } else if (folder === 'shike-maintenance' && request.startsWith('./media/')) {
    base = resolve(functions, 'shike-media', request.slice('./media/'.length));
  }
  const file = [base, base + '.js', base + '.json', join(base, 'index.js')]
    .find(path => existsSync(path) && statSync(path).isFile());
  if (!file || !file.startsWith(functions + sep)) {
    throw new Error('Invalid local dependency: ' + request + ' from ' + source);
  }
  return file;
}

// 计算某个源文件在目标函数中的位置（例如 shike-service/runtime.js → service/runtime.js）。
export function moduleDestination(functions, name, source) {
  const location = relative(functions, source).split(sep), folder = location.shift();
  const nested = folder === 'shike-service' ? 'service' : folder === 'shike-media' ? 'media' : folder;
  return [...(folder === name ? [] : [nested]), ...location].join('/');
}

// 某函数需要生成的派生目录。
export function generatedDirectories(name) {
  return ['shared', ...(serviceConsumers.has(name) ? ['service'] : []),
    ...(name === 'shike-maintenance' ? ['media'] : [])];
}
