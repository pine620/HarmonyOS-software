import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { verifyArtifact } from '../../scripts/check-artifact.mjs';
try {
  const args = process.argv.slice(2), source = dirname(fileURLToPath(import.meta.url));
  if (args.length === 2 && args[0] === '--artifact') verifyArtifact(resolve(args[1]));
  else if (args.length === 0) {
    for (const file of ['runtime.js', 'shikeMedia.ts', 'shared/content-policy.js', 'shared/media-descriptor.js', 'shared/read-errors.js', 'shared/image-reader.js', 'shared/release-info.js', 'shared/image-models.js']) if (!existsSync(join(source, file))) throw new Error('Source module missing: ' + file + '; run npm run prepare:deveco from CloudProgram first.');
    const config = JSON.parse(readFileSync(join(source, 'function-config.json')));
    if (config.handler !== 'shikeMedia.ShikeMedia' || config.functionType !== 1) throw new Error('Cloud Object config changed.');
    console.log('Function-owned modules present. Run check:deveco before IDE deployment, or package:cloud -- shike-media and check:artifact for ZIP upload.');
  } else throw new Error('Usage: node check-deployment.mjs [--artifact <unpacked-artifact>]');
} catch (error) { console.error(error.message); process.exitCode = 1; }
