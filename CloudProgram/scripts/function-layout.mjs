import { existsSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';

export const functionDefinitions = {
  'shike-auth': { entry: 'shikeAuth', className: 'ShikeAuth' },
  'shike-service': { entry: 'shikeService', className: 'ShikeService' },
  'shike-media': { entry: 'shikeMedia', className: 'ShikeMedia', extra: ['cover-worker.js'] },
  'shike-image': { entry: 'shikeImage' },
  'shike-maintenance': { entry: 'shikeMaintenance', extraMedia: true },
  // Pack 4.4: domain split of shike-service. Each runs a derived copy of the shike-service runtime under ./service.
  'shike-content': { entry: 'shikeContent', className: 'ShikeContent' },
  'shike-social': { entry: 'shikeSocial', className: 'ShikeSocial' },
  'shike-account': { entry: 'shikeAccount', className: 'ShikeAccount' },
  'shike-governance': { entry: 'shikeGovernance', className: 'ShikeGovernance' },
  // Pack 4.1: Cloud Foundation Kit prefetch target; returns the stored home snapshot only.
  'shike-prefetch': { entry: 'shikePrefetch' }
};

// Functions that embed the shike-service runtime as a derived ./service subtree.
const serviceConsumers = new Set(['shike-maintenance', 'shike-content', 'shike-social', 'shike-account', 'shike-governance']);

// Resolve function-owned deployment paths against the single maintained source.
// Never use an older generated copy as input to a new deployment.
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

export function moduleDestination(functions, name, source) {
  const location = relative(functions, source).split(sep), folder = location.shift();
  const nested = folder === 'shike-service' ? 'service' : folder === 'shike-media' ? 'media' : folder;
  return [...(folder === name ? [] : [nested]), ...location].join('/');
}

export function generatedDirectories(name) {
  return ['shared', ...(serviceConsumers.has(name) ? ['service'] : []),
    ...(name === 'shike-maintenance' ? ['media'] : [])];
}
