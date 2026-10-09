'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
// ZIP packaging records the entire artifact. DevEco records the synchronized
// source snapshot separately because the IDE compiles/installs dependencies.
const policyHash = crypto.createHash('sha256').update(fs.readFileSync(path.join(__dirname, 'content-policy.js'))).digest('hex');
let buildInfo = { buildId: 'image-read-v1-source-' + policyHash.slice(0, 12), policyHash, protocolVersion: 'image-read-v1' };
const manifest = path.join(__dirname, 'release-manifest.json');
if (fs.existsSync(manifest)) {
  const value = JSON.parse(fs.readFileSync(manifest, 'utf8'));
  if (value.policyHash !== policyHash || !/^[a-f0-9]{64}$/.test(value.buildId)) throw new Error('Invalid release manifest');
  buildInfo = { buildId: value.buildId, policyHash, protocolVersion: 'image-read-v1' };
} else {
  const sourceManifest = path.join(__dirname, 'deveco-source-manifest.json');
  if (fs.existsSync(sourceManifest)) {
    const { buildId, ...identity } = JSON.parse(fs.readFileSync(sourceManifest, 'utf8'));
    const expected = 'image-read-v1-deveco-' + crypto.createHash('sha256').update(JSON.stringify(identity)).digest('hex');
    if (identity.manifestVersion !== 1 || identity.deploymentMode !== 'deveco-source' ||
      identity.protocolVersion !== 'image-read-v1' || identity.policyHash !== policyHash || buildId !== expected) {
      throw new Error('Invalid DevEco source manifest');
    }
    buildInfo = { buildId, policyHash, protocolVersion: 'image-read-v1' };
  }
}
module.exports = { buildInfo: Object.freeze(buildInfo) };
