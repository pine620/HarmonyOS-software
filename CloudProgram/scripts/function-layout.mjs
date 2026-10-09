import { existsSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';

export const functionDefinitions = {
  'shike-auth': { entry: 'shikeAuth', className: 'ShikeAuth' },
  'shike-service': { entry: 'shikeService', className: 'ShikeService' },
  'shike-location': { entry: 'shikeLocation', className: 'ShikeLocation' },
  'shike-media': { entry: 'shikeMedia', className: 'ShikeMedia', extra: ['cover-worker.js'] },
  'shike-image': { entry: 'shikeImage' },
  'shike-maintenance': { entry: 'shikeMaintenance', extraMedia: true },
  'shike-share': { entry: 'shikeShare' }
};

// Resolve function-owned deployment paths against the single maintained source.
// Never use an older generated copy as input to a new deployment.
export function localDependency(functions, source, request) {
  const folder = relative(functions, source).split(sep)[0];
  let base = resolve(dirname(source), request);
  if (folder !== 'shared' && request.startsWith('./shared/')) {
    base = resolve(functions, 'shared', request.slice('./shared/'.length));
  } else if (['shike-maintenance', 'shike-share'].includes(folder) && request.startsWith('./service/')) {
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
  return ['shared', ...(['shike-maintenance', 'shike-share'].includes(name) ? ['service'] : []),
    ...(name === 'shike-maintenance' ? ['media'] : [])];
}
