'use strict';
const { errorCode, requestId, READ_OPT_VERSION } = require('./read-errors');

const crypto = require('crypto');
const { AsyncLocalStorage } = require('async_hooks');
const fs = require('fs/promises');
const { cloud } = require('@hw-agconnect/cloud-server');
const { createContentPolicy, policyModels, accessError } = require('./content-policy');
const { AGCClient, CredentialParser } = require('@agconnect/common-server');
const { AGCCloudStorage } = require('@agconnect/cloudstorage-server');

const MAX_PHOTO_BYTES = 2 * 1024 * 1024;
const MAX_REQUEST_AGE_MS = 60 * 1000;
const STORAGE_CLIENT_NAME = 'shike-media-storage-server';
let storageReady = false;
const readMetricsScope = new AsyncLocalStorage();

class CloudDbModel {
  getFieldTypeMap() { return new Map(Object.entries(this.constructor.fieldTypes)); }
  getClassName() { return this.constructor.name; }
  getPrimaryKeyList() { return [...this.constructor.primaryKeys]; }
  getIndexList() { return [...this.constructor.indexes]; }
  getEncryptedFieldList() { return []; }
}

class CardMedia extends CloudDbModel {}
CardMedia.fieldTypes = Object.freeze({
  id: 'String', cardId: 'String', ownerUid: 'String', storageUid: 'String',
  objectKey: 'String', sha256: 'String', preparedSha256: 'String', mimeType: 'String', byteSize: 'Integer',
  width: 'Integer', height: 'Integer', status: 'String', createdAt: 'Long'
});
CardMedia.primaryKeys = Object.freeze(['id']);
CardMedia.indexes = Object.freeze(['cardId', 'cardId,createdAt', 'ownerUid,createdAt']);

class IdentityBinding extends CloudDbModel {}
IdentityBinding.fieldTypes = Object.freeze({
  id: 'String', provider: 'String', providerUid: 'String', canonicalUid: 'String',
  status: 'String', createdAt: 'Long', updatedAt: 'Long'
});
IdentityBinding.primaryKeys = Object.freeze(['id']);
IdentityBinding.indexes = Object.freeze({"provider_providerUid": ["provider", "providerUid"], "canonicalUid": ["canonicalUid"], "canonicalUid_id": ["canonicalUid", "id"]});

const OBJECT_TYPES = Object.freeze({ ...policyModels, CardMedia, IdentityBinding });

function required(env, name) {
  const value = String((env || {})[name] || '').trim();
  if (!value) throw new Error(`云端缺少 ${name} 配置。`);
  return value;
}

function storageBucket(env) {
  if (!storageReady) {
    const credential = CredentialParser.toCredentialWithContents(required(env, 'PROJECT_CREDENTIAL'));
    AGCClient.initialize(credential, STORAGE_CLIENT_NAME, 'CN');
    storageReady = true;
  }
  return AGCCloudStorage.getInstance(STORAGE_CLIENT_NAME)
    .bucket(required(env, 'SHIKE_STORAGE_BUCKET'), 'CN');
}

function validKey(value) {
  const key = String(value || '').trim();
  if (!/^public\/approved\/[^/]+\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$/i.test(key)
    && !/^private\/pending\/[^/]+\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$/i.test(key)) {
    throw new Error('拒绝访问未知的云存储路径。');
  }
  return key;
}

function collection(env, name) {
  const zoneName = String((env && env.SHIKE_DB_ZONE) || process.env.SHIKE_DB_ZONE || 'shike');
  const objectType = OBJECT_TYPES[name];
  if (!objectType) throw new Error(`未知云数据库对象类型 ${name}`);
  const target = cloud.database({ zoneName }).collection(objectType);
  const metrics = readMetricsScope.getStore();
  if (!metrics) return target;
  return new Proxy(target, { get(object, property) {
    if (property === 'query') return (...args) => measuredQuery(object.query(...args), name, metrics);
    const value = Reflect.get(object, property, object);
    if (property === 'constructor') return value;
    return typeof value === 'function' ? value.bind(object) : value;
  } });
}

function measuredQuery(target, name, metrics) {
  const proxy = new Proxy(target, { get(object, property) {
    if (property === 'get') return async (...args) => {
      const started = Date.now();
      metrics.queryGetCount += 1;
      metrics.byObject[name] = (metrics.byObject[name] || 0) + 1;
      try {
        const rows = await object.get(...args);
        metrics.queriedRows += Array.isArray(rows) ? rows.length : 0;
        return rows;
      } catch (error) {
        metrics.queryFailures += 1;
        if (errorCode(error) === '3007009') metrics.busyErrors += 1;
        throw error;
      } finally { metrics.dbMs += Date.now() - started; }
    };
    const value = Reflect.get(object, property, object);
    if (property === 'constructor') return value;
    if (typeof value !== 'function') return value;
    return (...args) => {
      const result = value.apply(object, args);
      return result === object ? proxy : result;
    };
  } });
  return proxy;
}

async function withReadMetrics(operation, env, action, id) {
  const flag = env && env.SHIKE_READ_METRICS_ENABLED !== undefined
    ? env.SHIKE_READ_METRICS_ENABLED : process.env.SHIKE_READ_METRICS_ENABLED;
  if (String(flag || '').trim().toLowerCase() !== 'true') return action();
  const metrics = { queryGetCount: 0, queriedRows: 0, queryFailures: 0, busyErrors: 0, dbMs: 0, byObject: {} };
  return readMetricsScope.run(metrics, async () => {
    const started = Date.now();
    let outcome = 'error';
    try { const result = await action(); outcome = 'success'; return result; }
    finally {
      // Query.get calls only: excludes transactions, Storage and auth SDK requests.
      console.info(`read.metrics operation=${operation} requestId=${id || 'not-provided'} functionVersion=${READ_OPT_VERSION} outcome=${outcome} queryGetCount=${metrics.queryGetCount} ` +
        `queriedRows=${metrics.queriedRows} queryFailures=${metrics.queryFailures} busyErrors=${metrics.busyErrors} ` +
        `dbMs=${metrics.dbMs} totalMs=${Date.now() - started} byObject=${JSON.stringify(metrics.byObject)}`);
    }
  });
}

async function one(query) {
  const rows = await query.limit(1).get();
  return rows.length > 0 ? rows[0] : null;
}

function contentPolicy(env) {
  return createContentPolicy((name) => collection(env, name), one);
}

function identityBindingId(provider, providerUid) {
  return crypto.createHash('sha256').update(`shike-identity:${String(provider)}:${String(providerUid)}`).digest('hex');
}

async function verifiedIdentity(accessToken, env, readOnly = false) {
  if (!accessToken || String(accessToken).length > 8192) throw new Error('未登录或登录状态已失效。');
  let providerUid = '';
  try {
    const verified = await cloud.auth().verifyAccessToken({ accessToken: String(accessToken), checkRevoked: true });
    providerUid = String(verified.getSub() || '');
  } catch (_error) {
    throw new Error('登录凭证无效或已撤销，请重新登录。');
  }
  if (!providerUid) throw new Error('AGC 访问凭证未包含用户标识。');
  const bindings = collection(env, 'IdentityBinding');
  const id = identityBindingId('AGC', providerUid);
  const binding = await one(bindings.query().equalTo('id', id));
  if (binding && String(binding.status || 'ACTIVE') !== 'ACTIVE') throw accessError('账号身份已停用。', 'ACCOUNT_INACTIVE');
  const canonicalUid = binding ? String(binding.canonicalUid || providerUid) : providerUid;
  await contentPolicy(env).assertAccountActive(canonicalUid, true);
  if (!binding && !readOnly) {
    const now = Date.now();
    await bindings.upsert({
      id, provider: 'AGC', providerUid, canonicalUid, status: 'ACTIVE', createdAt: now, updatedAt: now
    });
  }
  return { providerUid, canonicalUid };
}

function approvedObjectKey(storageUid, mediaId) {
  const uid = String(storageUid || '');
  const id = String(mediaId || '');
  if (!uid || uid.includes('/') || uid.includes('\\') ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
    throw new Error('实拍图记录无效，请重新选择。');
  }
  return `public/approved/${uid}/${id}.jpg`;
}

function mediaIdFromApprovedObjectKey(objectKey) {
  const match = /^public\/approved\/[^/]+\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jpg$/i.exec(String(objectKey || ''));
  return match ? match[1] : '';
}

function verifySignedInput(input, env) {
  const body = String(input && input.body || '');
  const signature = String(input && input.signature || '').toLowerCase();
  if (!body || !/^[a-f0-9]{64}$/.test(signature)) throw new Error('媒体服务内部请求无效。');
  const expected = crypto.createHmac('sha256', required(env, 'SHIKE_MEDIA_INTERNAL_KEY')).update(body).digest('hex');
  const actual = Buffer.from(signature, 'hex');
  const expectedBytes = Buffer.from(expected, 'hex');
  if (actual.length !== expectedBytes.length || !crypto.timingSafeEqual(actual, expectedBytes)) {
    throw new Error('媒体服务内部请求未获授权。');
  }
  let request;
  try {
    request = JSON.parse(body);
  } catch (_error) {
    throw new Error('媒体服务内部请求格式错误。');
  }
  const issuedAt = Number(request && request.issuedAt || 0);
  if (!Number.isSafeInteger(issuedAt) || Math.abs(Date.now() - issuedAt) > MAX_REQUEST_AGE_MS) {
    throw new Error('媒体服务内部请求已过期。');
  }
  if (typeof request.action !== 'string' || !request.payload || typeof request.payload !== 'object') {
    throw new Error('媒体服务内部请求内容无效。');
  }
  return request;
}

function bytesFromBase64(value, expectedSha256) {
  const encoded = String(value || '');
  const maximumLength = Math.ceil(MAX_PHOTO_BYTES / 3) * 4 + 4;
  if (encoded.length === 0 || encoded.length > maximumLength || encoded.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)) {
    throw new Error('上传图片内容不是有效的 Base64 数据。');
  }
  const bytes = Buffer.from(encoded, 'base64');
  if (bytes.length === 0 || bytes.length > MAX_PHOTO_BYTES || bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[2] !== 0xff || bytes[bytes.length - 2] !== 0xff || bytes[bytes.length - 1] !== 0xd9) {
    throw new Error('上传图片必须是有效的 JPEG，且不得超过 2MB。');
  }
  const sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
  if (sha256 !== String(expectedSha256 || '').toLowerCase()) throw new Error('图片摘要校验失败。');
  return bytes;
}

function readFileBytes(file) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    const stream = file.createReadStream();
    stream.on('data', (chunk) => chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)));
    stream.on('end', () => resolve(Buffer.concat(chunks)));
    stream.on('error', reject);
  });
}

async function writeApproved(payload, env) {
  const key = validKey(payload && payload.key);
  if (!key.startsWith('public/approved/')) throw new Error('媒体上传路径无效。');
  const sha256 = String(payload && payload.sha256 || '').toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(sha256)) throw new Error('图片摘要无效。');
  const bytes = bytesFromBase64(payload && payload.dataBase64, sha256);
  const temporaryPath = `/tmp/shike-media-${crypto.randomUUID()}.jpg`;
  try {
    await fs.writeFile(temporaryPath, bytes);
    const uploadResult = await storageBucket(env).upload(temporaryPath, {
      destination: key,
      sha256
    });
    const uploadedFile = Array.isArray(uploadResult) ? uploadResult[0] : storageBucket(env).file(key);
    await uploadedFile.setMetadata({
      contentType: 'image/jpeg',
      cacheControl: 'no-store',
      customMetadata: { sha256 }
    });
  } finally {
    try { await fs.unlink(temporaryPath); } catch (_error) { }
  }
  return { byteSize: bytes.length };
}

async function readApproved(payload, env) {
  const key = validKey(payload && payload.key);
  if (!key.startsWith('public/approved/')) throw new Error('媒体读取路径无效。');
  const mediaId = mediaIdFromApprovedObjectKey(key);
  const media = mediaId && await one(collection(env, 'CardMedia').query().equalTo('id', mediaId));
  if (!media || approvedObjectKey(String(media.storageUid || media.ownerUid), mediaId) !== key ||
      !await contentPolicy(env).canReadMedia(String(payload && payload.viewerUid || ''), media)) {
    throw accessError('图片不存在或当前不可访问。');
  }
  const bytes = await readFileBytes(storageBucket(env).file(key));
  if (bytes.length === 0 || bytes.length > MAX_PHOTO_BYTES) throw new Error('图片内容无效或超过允许大小。');
  const current = await one(collection(env, 'CardMedia').query().equalTo('id', mediaId));
  if (!current || current.cardId !== media.cardId || current.ownerUid !== media.ownerUid ||
      approvedObjectKey(String(current.storageUid || current.ownerUid), mediaId) !== key ||
      !await contentPolicy(env).canReadMedia(String(payload && payload.viewerUid || ''), current)) {
    throw accessError('图片已不可访问。');
  }
  return { mimeType: String(media.mimeType || 'image/jpeg'), dataBase64: bytes.toString('base64'), byteSize: bytes.length };
}

async function readRevision(payload, env) {
  // This method is reachable only through a verified service HMAC envelope.
  // Administrator is asserted by shike-service; current DB ownership/status is
  // independently checked again here before Storage returns bytes.
  const key = validKey(payload && payload.key);
  if (!key.startsWith('public/approved/')) throw new Error('媒体读取路径无效。');
  const id = mediaIdFromApprovedObjectKey(key);
  const media = id && await one(collection(env, 'CardMedia').query().equalTo('id', id));
  if (!media || approvedObjectKey(String(media.storageUid || media.ownerUid), id) !== key ||
      !await contentPolicy(env).canReadRevisionMedia(String(payload.viewerUid || ''), media,
        String(payload.revisionId || ''), payload.administrator === true)) throw accessError('编辑图片不可访问。');
  const bytes = await readFileBytes(storageBucket(env).file(key));
  if (bytes.length === 0 || bytes.length > MAX_PHOTO_BYTES) throw new Error('图片内容无效或超过允许大小。');
  const fresh = await one(collection(env, 'CardMedia').query().equalTo('id', id));
  if (!fresh || fresh.cardId !== media.cardId || approvedObjectKey(String(fresh.storageUid || fresh.ownerUid), id) !== key ||
      !await contentPolicy(env).canReadRevisionMedia(String(payload.viewerUid || ''), fresh, String(payload.revisionId || ''), payload.administrator === true)) throw accessError('编辑图片已失效。');
  return { dataBase64: bytes.toString('base64'), byteSize: bytes.length };
}

async function readModeration(payload,env) {
  const key=validKey(payload.key),mediaId=mediaIdFromApprovedObjectKey(key);
  const media=await one(collection(env,'CardMedia').query().equalTo('id',mediaId));
  if(!media || approvedObjectKey(String(media.storageUid||media.ownerUid),mediaId)!==key || !await contentPolicy(env).canReadModerationMedia(String(payload.viewerUid||''),media,payload.administrator===true))throw accessError('审核图片不可访问。');
  const bytes=await readFileBytes(storageBucket(env).file(key));
  const fresh=await one(collection(env,'CardMedia').query().equalTo('id',mediaId));
  if(!fresh || fresh.cardId!==media.cardId || approvedObjectKey(String(fresh.storageUid||fresh.ownerUid),mediaId)!==key || !await contentPolicy(env).canReadModerationMedia(String(payload.viewerUid||''),fresh,payload.administrator===true))throw accessError('审核图片已失效。');
  if(!bytes.length || bytes.length>MAX_PHOTO_BYTES)throw new Error('审核图片大小无效。');
  return {dataBase64:bytes.toString('base64'),byteSize:bytes.length};
}

async function promote(payload, env) {
  const pendingKey = validKey(payload && payload.pendingKey);
  const approvedKey = validKey(payload && payload.approvedKey);
  if (!pendingKey.startsWith('private/pending/') || !approvedKey.startsWith('public/approved/')) throw new Error('媒体确认路径无效。');
  const bucket = storageBucket(env);
  const pending = bucket.file(pendingKey);
  const approved = bucket.file(approvedKey);
  const pendingExists = await pending.exists();
  const approvedExists = await approved.exists();
  if (!pendingExists && !approvedExists) throw new Error('实拍图尚未成功上传，请重新选择并上传后再保存。');
  if (pendingExists && !approvedExists) await pending.copy(approved);
  if (pendingExists) await pending.delete();
  return { exists: true };
}

async function remove(payload, env) {
  const keys = Array.isArray(payload && payload.keys) ? payload.keys : [];
  for (const candidate of keys) {
    const key = validKey(candidate);
    const file = storageBucket(env).file(key);
    if (await file.exists()) await file.delete();
  }
  return { deleted: keys.length };
}

function validatePreparedPhoto(payload) {
  if (String(payload && payload.mimeType || '') !== 'image/jpeg') throw new Error('实拍图必须处理为 JPEG。');
  const byteSize = Number(payload && payload.byteSize);
  const width = Number(payload && payload.width);
  const height = Number(payload && payload.height);
  const sha256 = String(payload && payload.sha256 || '').toLowerCase();
  if (!Number.isInteger(byteSize) || byteSize <= 0 || byteSize > MAX_PHOTO_BYTES) throw new Error('实拍图不得超过 2MB。');
  if (!Number.isInteger(width) || !Number.isInteger(height) || width < 1 || height < 1 || Math.max(width, height) > 1600) {
    throw new Error('实拍图长边不得超过 1600px。');
  }
  if (!/^[a-f0-9]{64}$/.test(sha256)) throw new Error('实拍图摘要无效。');
  return { byteSize, width, height, sha256 };
}

async function prepareCardPhoto(input, env) {
  const identity = await verifiedIdentity(input && input.accessToken, env);
  const prepared = validatePreparedPhoto(input && input.payload);
  const mediaId = crypto.randomUUID();
  const objectKey = approvedObjectKey(identity.providerUid, mediaId);
  await collection(env, 'CardMedia').insert({
    id: mediaId,
    cardId: '',
    ownerUid: identity.canonicalUid,
    storageUid: identity.providerUid,
    objectKey,
    sha256: prepared.sha256,
    preparedSha256: prepared.sha256,
    mimeType: 'image/jpeg',
    byteSize: prepared.byteSize,
    width: prepared.width,
    height: prepared.height,
    status: 'PENDING_UPLOAD',
    createdAt: Date.now()
  });
  return { mediaId, cloudPath: objectKey, bucketName: required(env, 'SHIKE_STORAGE_BUCKET') };
}

async function uploadCardPhoto(input, env) {
  const identity = await verifiedIdentity(input && input.accessToken, env);
  const payload = input && input.payload || {};
  const mediaId = String(payload.mediaId || '').trim();
  const sha256 = String(payload.sha256 || '').trim().toLowerCase();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(mediaId)) throw new Error('图片上传标识无效。');
  if (!/^[a-f0-9]{64}$/.test(sha256)) throw new Error('图片摘要无效。');
  const media = await one(collection(env, 'CardMedia').query().equalTo('id', mediaId));
  if (!media || String(media.ownerUid || '') !== identity.canonicalUid || String(media.cardId || '')) {
    throw new Error('图片不存在、不属于当前用户或已被使用。');
  }
  if (String(media.status || '') !== 'PENDING_UPLOAD') throw new Error('图片已上传或状态无效，请重新选择。');
  const bytes = bytesFromBase64(payload.dataBase64, sha256);
  const preparedSha256 = String(media.preparedSha256 || '').toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(preparedSha256)) {
    throw new Error('图片准备记录版本已过期，请重新选择。');
  }
  if (bytes.length !== Number(media.byteSize || 0) || sha256 !== preparedSha256) {
    throw new Error('图片内容与准备记录不一致，请重新选择。');
  }
  const objectKey = approvedObjectKey(String(media.storageUid || identity.providerUid), mediaId);
  await writeApproved({ key: objectKey, dataBase64: payload.dataBase64, sha256 }, env);
  return { success: true };
}

async function getPublicMedia(input, env) {
  const identity = await verifiedIdentity(input && input.accessToken, env, true);
  const payload = input && input.payload || {};
  const bucketName = String(payload.bucketName || '').trim();
  const objectKey = String(payload.cloudPath || '').trim();
  if (bucketName !== required(env, 'SHIKE_STORAGE_BUCKET')) throw new Error('图片所属云存储实例无效。');
  const response = await readApproved({ key: objectKey, viewerUid: identity.canonicalUid }, env);
  return response;
}

async function execute(input, env) {
  const request = verifySignedInput(input, env);
  switch (request.action) {
    case 'write-approved': return writeApproved(request.payload, env);
    case 'read-approved': return readApproved(request.payload, env);
    case 'read-revision': return readRevision(request.payload, env);
    case 'read-moderation': return readModeration(request.payload, env);
    case 'promote': return promote(request.payload, env);
    case 'remove': return remove(request.payload, env);
    default: throw new Error('未知的媒体服务操作。');
  }
}

function safeLogError(error) {
  return error instanceof Error ? error.message.replace(/(accessToken|authorization|signature|body)=[^\s,]+/ig, '$1=[REDACTED]') : 'unknown error';
}

module.exports = {
  execute: (input, env) => withReadMetrics('execute', env, () => execute(input, env), requestId(input)),
  prepareCardPhoto, uploadCardPhoto,
  getPublicMedia: (input, env) => withReadMetrics('get-public-media', env, () => getPublicMedia(input, env), requestId(input)),
  safeLogError
};
