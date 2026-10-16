'use strict';
// Pack 4.1 (2026-10-15): public home snapshot. A 5-minute timer (shike-maintenance action "home-snapshot") renders
// the guest first page once and stores it as JSON in Cloud Storage. Guests read it directly (storage rule allows
// anonymous read of exactly this key) or through Cloud Foundation Kit prefetch (shike-prefetch). Nothing here is
// viewer-specific: it is the same payload an anonymous list-nearby-cards call returns.
const crypto = require('crypto');
const fs = require('fs/promises');
const { AGCClient, CredentialParser } = require('@agconnect/common-server');
const { AGCCloudStorage } = require('@agconnect/cloudstorage-server');

const SNAPSHOT_KEY = 'public/snapshot/home-v1.json';
const SNAPSHOT_VERSION = 'home-snapshot-v1';
// Must stay identical to the client's first public page request (DiscoveryFeed.publicPage with an empty cursor).
const HOME_REQUEST = Object.freeze({ scope: 'all', category: 'all', pageToken: '', pageSize: 6 });
const MAX_SNAPSHOT_BYTES = 256 * 1024;
const CLIENT_NAME = 'shike-snapshot-storage-server';
let ready = false;

function required(env, name) {
  const value = String((env || {})[name] || '').trim();
  if (!value) throw new Error(`云端缺少 ${name} 配置。`);
  return value;
}

function bucket(env) {
  if (!ready) {
    AGCClient.initialize(CredentialParser.toCredentialWithContents(required(env, 'PROJECT_CREDENTIAL')), CLIENT_NAME, 'CN');
    ready = true;
  }
  return AGCCloudStorage.getInstance(CLIENT_NAME).bucket(required(env, 'SHIKE_STORAGE_BUCKET'), 'CN');
}

function validSnapshot(value) {
  return !!value && value.version === SNAPSHOT_VERSION && Number.isSafeInteger(value.generatedAt) &&
    !!value.data && Array.isArray(value.data.cards) && typeof value.data.nextPageToken === 'string';
}

async function writeSnapshot(data, env) {
  const snapshot = { version: SNAPSHOT_VERSION, generatedAt: Date.now(), request: HOME_REQUEST, data };
  if (!validSnapshot(snapshot)) throw new Error('首页快照内容无效。');
  const bytes = Buffer.from(JSON.stringify(snapshot), 'utf8');
  if (bytes.length > MAX_SNAPSHOT_BYTES) throw new Error('首页快照过大。');
  const sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
  const temporaryPath = `/tmp/shike-snapshot-${crypto.randomUUID()}.json`;
  try {
    await fs.writeFile(temporaryPath, bytes);
    const storage = bucket(env);
    const uploaded = await storage.upload(temporaryPath, { destination: SNAPSHOT_KEY, sha256 });
    const file = Array.isArray(uploaded) ? uploaded[0] : storage.file(SNAPSHOT_KEY);
    await file.setMetadata({ contentType: 'application/json', cacheControl: 'no-cache', customMetadata: { sha256 } });
  } finally {
    try { await fs.unlink(temporaryPath); } catch (_error) { }
  }
  return { key: SNAPSHOT_KEY, generatedAt: snapshot.generatedAt, cards: data.cards.length, bytes: bytes.length };
}

function readSnapshot(env) {
  const file = bucket(env).file(SNAPSHOT_KEY);
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    const stream = file.createReadStream();
    stream.on('data', chunk => {
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      total += bytes.length;
      if (total > MAX_SNAPSHOT_BYTES) { stream.destroy(); reject(new Error('首页快照过大。')); return; }
      chunks.push(bytes);
    });
    stream.on('end', () => {
      try {
        const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (!validSnapshot(value)) throw new Error('首页快照内容无效。');
        resolve(value);
      } catch (error) { reject(error); }
    });
    stream.on('error', reject);
  });
}

module.exports = { SNAPSHOT_KEY, SNAPSHOT_VERSION, HOME_REQUEST, writeSnapshot, readSnapshot };
