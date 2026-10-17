'use strict';
/**
 * 【文件职责】游客首页快照的读写。shike-maintenance 的 home-snapshot 定时任务（建议每 5 分钟）把游客首页第一页渲染一次，
 * 以 JSON 保存到 Cloud Storage 的 public/snapshot/home-v1.json；游客直接读取（存储规则只对这一个路径开放匿名读），
 * 或经 Cloud Foundation 预取（shike-prefetch）读取。内容与匿名调用 list-nearby-cards 的返回完全相同，不含任何查看者相关数据。
 */
const crypto = require('crypto');
const fs = require('fs/promises');
const { AGCClient, CredentialParser } = require('@agconnect/common-server');
const { AGCCloudStorage } = require('@agconnect/cloudstorage-server');

// 快照路径、格式版本、首页请求参数、大小上限（256KB）、存储客户端名。
const SNAPSHOT_KEY = 'public/snapshot/home-v1.json';
const SNAPSHOT_VERSION = 'home-snapshot-v1';
// 必须与客户端首页第一页的请求完全一致（DiscoveryFeed.publicPage，游标为空，每页 6 条）。
const HOME_REQUEST = Object.freeze({ scope: 'all', category: 'all', pageToken: '', pageSize: 6 });
const MAX_SNAPSHOT_BYTES = 256 * 1024;
const CLIENT_NAME = 'shike-snapshot-storage-server';
let ready = false;

// 读取必需的环境变量（缺失时抛错）。
function required(env, name) {
  const value = String((env || {})[name] || '').trim();
  if (!value) throw new Error(`云端缺少 ${name} 配置。`);
  return value;
}

// 创建 Cloud Storage 存储桶客户端（使用平台注入的 PROJECT_CREDENTIAL）。
function bucket(env) {
  if (!ready) {
    AGCClient.initialize(CredentialParser.toCredentialWithContents(required(env, 'PROJECT_CREDENTIAL')), CLIENT_NAME, 'CN');
    ready = true;
  }
  return AGCCloudStorage.getInstance(CLIENT_NAME).bucket(required(env, 'SHIKE_STORAGE_BUCKET'), 'CN');
}

// 校验快照结构。
function validSnapshot(value) {
  return !!value && value.version === SNAPSHOT_VERSION && Number.isSafeInteger(value.generatedAt) &&
    !!value.data && Array.isArray(value.data.cards) && typeof value.data.nextPageToken === 'string';
}

// 写入快照（先写临时文件再上传）。
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

// 读取快照（预取函数使用）。
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

module.exports = { HOME_REQUEST, writeSnapshot, readSnapshot };
