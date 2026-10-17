/**
 * 【文件职责】shike-media 的实现：所有 Cloud Storage 读写集中在这里（使用平台注入的 PROJECT_CREDENTIAL）。
 *   - 客户端接口：prepareCardPhoto / uploadCardPhoto / confirmCardPhotoUpload / getPublicMedia（均校验 AGC Token 与 CardMedia 记录）；
 *   - 内部接口 execute：校验 shike-service 的 HMAC 签名（SHIKE_MEDIA_INTERNAL_KEY，60 秒内有效）后执行 write-approved / promote / remove；
 *   - 封面：buildCover 在上传后生成 480px 封面（需 SHIKE_MEDIA_COVERS_VERIFIED=true）；runCoverBackfill 给维护函数回填旧图封面。
 * 存储路径：公开原图 public/approved/{storageUid}/{mediaId}.jpg、封面 *.cover-v1.jpg、直传暂存 private/pending/{uid}/{mediaId}.jpg。
 */
'use strict';
const { errorCode, requestId, READ_OPT_VERSION, shouldReadMetrics } = require('./shared/read-errors');

const crypto = require('crypto');
const { originalSha256, mediaVariant, sameMediaSource, verifyMediaBytes } = require('./shared/media-descriptor');
const { AsyncLocalStorage } = require('async_hooks');
const fs = require('fs/promises');
const { cloud } = require('@hw-agconnect/cloud-server');
const { createContentPolicy, policyModels, accessError } = require('./shared/content-policy');
const { AGCClient, CredentialParser } = require('@agconnect/common-server');
const { AGCCloudStorage } = require('@agconnect/cloudstorage-server');

// 单张图片上限 2MB、内部请求有效期 60 秒、存储客户端名。
const MAX_PHOTO_BYTES = 2 * 1024 * 1024;
const MAX_REQUEST_AGE_MS = 60 * 1000;
const STORAGE_CLIENT_NAME = 'shike-media-storage-server';
let storageReady = false;
const readMetricsScope = new AsyncLocalStorage();

// Cloud DB 模型基类与本函数用到的模型（字段与 objecttype 一致）。
const { CloudDbModel, CardMedia } = require('./shared/image-models');

class IdentityBinding extends CloudDbModel {}
IdentityBinding.fieldTypes = Object.freeze({
  id: 'String', provider: 'String', providerUid: 'String', canonicalUid: 'String',
  status: 'String', createdAt: 'Long', updatedAt: 'Long'
});
IdentityBinding.primaryKeys = Object.freeze(['id']);
IdentityBinding.indexes = Object.freeze(['provider,providerUid', 'canonicalUid', 'canonicalUid,id']);

class MaintenanceJob extends CloudDbModel {}
MaintenanceJob.fieldTypes = Object.freeze({"jobId": "String", "jobType": "String", "entityId": "String", "ownerUid": "String", "generation": "Long", "status": "String", "runAfterAt": "Date", "leaseUntilAt": "Date", "leaseOwner": "String", "attemptCount": "Integer", "cursor": "String", "checkpointJson": "Text", "lastErrorCode": "String", "createdAt": "Date", "updatedAt": "Date", "authCredentialCiphertext": "Text", "authProviderUid": "String"});
MaintenanceJob.primaryKeys = Object.freeze(['jobId']);
MaintenanceJob.indexes = Object.freeze(["status,runAfterAt,jobId", "status,leaseUntilAt,jobId", "ownerUid,jobType,jobId", "entityId,jobType,generation", "status,jobType,runAfterAt,jobId", "status,jobType,leaseUntilAt,jobId"]);

const OBJECT_TYPES = Object.freeze({ ...policyModels, CardMedia, IdentityBinding, MaintenanceJob });

// 读取必需的环境变量。
function required(env, name) {
  const value = String((env || {})[name] || '').trim();
  if (!value) throw new Error(`云端缺少 ${name} 配置。`);
  return value;
}

// 取得存储桶（SHIKE_STORAGE_BUCKET）客户端，首次调用时初始化平台凭据。
function storageBucket(env) {
  if (!storageReady) {
    const credential = CredentialParser.toCredentialWithContents(required(env, 'PROJECT_CREDENTIAL'));
    AGCClient.initialize(credential, STORAGE_CLIENT_NAME, 'CN');
    storageReady = true;
  }
  return AGCCloudStorage.getInstance(STORAGE_CLIENT_NAME)
    .bucket(required(env, 'SHIKE_STORAGE_BUCKET'), 'CN');
}

// 校验对象路径（只允许 public/approved 与 private/pending 下的合法路径）。
function validKey(value) {
  const key = String(value || '').trim();
  if (!/^public\/approved\/[^/]+\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?:\.cover-v1)?\.jpg$/i.test(key)
    && !/^private\/pending\/[^/]+\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$/i.test(key)) {
    throw new Error('拒绝访问未知的云存储路径。');
  }
  return key;
}

// 取得 Cloud DB 集合（包装读取计量）。
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

// 给查询包装计量。
function measuredQuery(target, name, metrics) {
  const proxy = new Proxy(target, { get(object, property) {
    if (property === 'get') return async (...args) => {
      const started = Date.now();
      metrics.queryGetCount += 1;
      metrics.inFlightQueries += 1;
      metrics.byObject[name] = (metrics.byObject[name] || 0) + 1;
      try {
        const rows = await object.get(...args);
        metrics.queriedRows += Array.isArray(rows) ? rows.length : 0;
        return rows;
      } catch (error) {
        metrics.queryFailures += 1;
        const code = errorCode(error);
        metrics.byObjectFailures[name] = (metrics.byObjectFailures[name] || 0) + 1;
        if (code === '3007009') {
          metrics.busyErrors += 1;
          metrics.byObjectBusy[name] = (metrics.byObjectBusy[name] || 0) + 1;
        }
        metrics.lastQueryFailure = { collection: name, code };
        try { if (error && typeof error === 'object' && !error.readCollection) error.readCollection = name; } catch (_) { }
        throw error;
      } finally { metrics.dbMs += Date.now() - started; metrics.inFlightQueries -= 1; }
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

// 收集一次操作的读取指标。
async function withReadMetrics(operation, env, action, id) {
  if (!shouldReadMetrics(env, id)) return action();
  const counter = () => ({ calls: 0, failures: 0, ms: 0, successfulBytes: 0 });
  const metrics = { queryGetCount: 0, queriedRows: 0, queryFailures: 0, busyErrors: 0, dbMs: 0, inFlightQueries: 0, inFlightDependencies: 0,
    byObject: {}, byObjectFailures: {}, byObjectBusy: {}, lastQueryFailure: null, action: '',
    dependencies: { authVerify: counter() },
    storage: { download: counter(), upload: counter(), metadata: counter(), exists: counter(), copy: counter(), delete: counter() } };
  return readMetricsScope.run(metrics, async () => {
    const started = Date.now();
    let outcome = 'error', code = '', failureCollection = '';
    try { const result = await action(); outcome = 'success'; return result; }
    catch (error) {
      code = errorCode(error);
      const name = error && error.readCollection;
      failureCollection = typeof name === 'string' && Object.prototype.hasOwnProperty.call(OBJECT_TYPES, name) ? name : '';
      throw error;
    }
    finally {
      // 这里统计的是 SDK 调用次数与成功传输的字节数，不等于 HTTP 请求次数或计费总量。
      console.info(`read.metrics metricsVersion=o0-20261008-v1 boundary=media operation=${operation} action=${metrics.action || 'none'} requestId=${id || 'not-provided'} functionVersion=${READ_OPT_VERSION} outcome=${outcome} code=${code || 'OK'} failureCollection=${failureCollection || 'none'} queryGetCount=${metrics.queryGetCount} ` +
        `queriedRows=${metrics.queriedRows} queryFailures=${metrics.queryFailures} busyErrors=${metrics.busyErrors} ` +
        `dbMs=${metrics.dbMs} totalMs=${Date.now() - started} metricsComplete=${metrics.inFlightQueries === 0 && metrics.inFlightDependencies === 0} pendingQueryGetCount=${metrics.inFlightQueries} pendingDependencyCallCount=${metrics.inFlightDependencies} queryScope=wrapped-query-get dependencyScope=logical-sdk-calls ` +
        `byObject=${JSON.stringify(metrics.byObject)} byObjectFailures=${JSON.stringify(metrics.byObjectFailures)} ` +
        `byObjectBusy=${JSON.stringify(metrics.byObjectBusy)} lastQueryFailure=${JSON.stringify(metrics.lastQueryFailure)} ` +
        `dependencies=${JSON.stringify(metrics.dependencies)} storage=${JSON.stringify(metrics.storage)}`);
    }
  });
}

// 计量一次存储调用。
async function measuredCall(category, method, action, byteSize = 0) {
  const metrics = readMetricsScope.getStore();
  if (!metrics) return action();
  const counter = metrics[category][method];
  const started = Date.now();
  counter.calls += 1;
  metrics.inFlightDependencies += 1;
  try {
    const result = await action();
    counter.successfulBytes += Buffer.isBuffer(result) ? result.length : byteSize;
    return result;
  } catch (error) { counter.failures += 1; throw error; }
  finally { counter.ms += Date.now() - started; metrics.inFlightDependencies -= 1; }
}

// 取查询结果的第一行。
async function one(query) {
  const rows = await query.limit(1).get();
  return rows.length > 0 ? rows[0] : null;
}

// 创建内容策略实例。
function contentPolicy(env) {
  return createContentPolicy((name) => collection(env, name), one);
}

// IdentityBinding 主键（与 shike-service 相同算法）。
function identityBindingId(provider, providerUid) {
  return crypto.createHash('sha256').update(`shike-identity:${String(provider)}:${String(providerUid)}`).digest('hex');
}

// 校验 AGC Token 并映射到业务 UID（与 shike-service 的 verifiedIdentity 一致）。
async function verifiedIdentity(accessToken, env, readOnly = false, policy = contentPolicy(env)) {
  if (!accessToken || String(accessToken).length > 8192) throw accessError('未登录或登录状态已失效。','AUTH_REQUIRED');
  let providerUid = '';
  try {
    const verified = await measuredCall('dependencies', 'authVerify', () => cloud.auth().verifyAccessToken({ accessToken: String(accessToken), checkRevoked: true }));
    providerUid = String(verified.getSub() || '');
  } catch (_error) {
    throw accessError('登录凭证无效或已撤销，请重新登录。','AUTH_REQUIRED');
  }
  if (!providerUid) throw new Error('AGC 访问凭证未包含用户标识。');
  const bindings = collection(env, 'IdentityBinding');
  const id = identityBindingId('AGC', providerUid);
  const binding = await one(bindings.query().equalTo('id', id));
  if (binding && String(binding.status || 'ACTIVE') !== 'ACTIVE') throw accessError('账号身份已停用。', 'ACCOUNT_INACTIVE');
  if (binding && !String(binding.canonicalUid || '').trim()) throw accessError('账号身份绑定无效。', 'INVALID_STATE');
  const canonicalUid = binding ? String(binding.canonicalUid || providerUid) : providerUid;
  await policy.assertAccountActive(canonicalUid, true);
  if (!binding && !readOnly) {
    const now = Date.now();
    await bindings.upsert({
      id, provider: 'AGC', providerUid, canonicalUid, status: 'ACTIVE', createdAt: now, updatedAt: now
    });
  }
  return { providerUid, canonicalUid };
}

// 公开原图路径。
function approvedObjectKey(storageUid, mediaId) {
  const uid = String(storageUid || '');
  const id = String(mediaId || '');
  if (!uid || uid.includes('/') || uid.includes('\\') ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
    throw new Error('实拍图记录无效，请重新选择。');
  }
  return `public/approved/${uid}/${id}.jpg`;
}

// 从公开路径中解析 mediaId。
function mediaIdFromApprovedObjectKey(objectKey) {
  const match = /^public\/approved\/[^/]+\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jpg$/i.exec(String(objectKey || ''));
  return match ? match[1] : '';
}

// 校验 shike-service 发来的签名请求（HMAC + 时间戳 + nonce）。
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

// Base64 解码并校验大小与 sha256。
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

// 从存储读取文件字节。
function readFileBytes(file) {
  return measuredCall('storage', 'download', () => new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    const stream = file.createReadStream();
    stream.on('data', (chunk) => { const bytes=Buffer.isBuffer(chunk)?chunk:Buffer.from(chunk);total+=bytes.length;if(total>MAX_PHOTO_BYTES){stream.destroy();reject(new Error('Media exceeds byte budget'));return;}chunks.push(bytes); });
    stream.on('end', () => resolve(Buffer.concat(chunks)));
    stream.on('error', reject);
  }));
}

// 把字节写入公开路径（附带 sha256 元数据）。
async function writeApproved(payload, env) {
  const key = validKey(payload && payload.key);
  if (!key.startsWith('public/approved/')) throw new Error('媒体上传路径无效。');
  const sha256 = String(payload && payload.sha256 || '').toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(sha256)) throw new Error('图片摘要无效。');
  const bytes = bytesFromBase64(payload && payload.dataBase64, sha256);
  const temporaryPath = `/tmp/shike-media-${crypto.randomUUID()}.jpg`;
  try {
    await fs.writeFile(temporaryPath, bytes);
    const uploadResult = await measuredCall('storage', 'upload', () => storageBucket(env).upload(temporaryPath, {
      destination: key,
      sha256
    }), bytes.length);
    const uploadedFile = Array.isArray(uploadResult) ? uploadResult[0] : storageBucket(env).file(key);
    await measuredCall('storage', 'metadata', () => uploadedFile.setMetadata({
      contentType: 'image/jpeg',
      cacheControl: 'no-store',
      customMetadata: { sha256 }
    }));
  } finally {
    try { await fs.unlink(temporaryPath); } catch (_error) { }
  }
  return { byteSize: bytes.length };
}


// 生成 480px 封面并在事务中把封面信息写入 CardMedia（源图变化时放弃）。
async function buildCover(media,env,sourceBytes){
 if(String(env.SHIKE_MEDIA_COVERS_VERIFIED)!=='true')return false;
 try{mediaVariant(media,'COVER_480');return true;}catch(_){}
 if(!['APPROVED','PENDING_UPLOAD'].includes(media.status))return false;
 const expectedSha256=originalSha256(media);
 const key=approvedObjectKey(String(media.storageUid||media.ownerUid),media.id),coverKey=key.slice(0,-4)+'.cover-v1.jpg';
 const bytes=sourceBytes||await readFileBytes(storageBucket(env).file(key));
 const sourceSha256=verifyMediaBytes(bytes,{byteSize:Number(media.byteSize),sha256:expectedSha256});
 const result=await require('./cover-converter').convert(bytes),cover=Buffer.from(result.bytes);
 const sha256=crypto.createHash('sha256').update(cover).digest('hex');
 await writeApproved({key:coverKey,sha256,dataBase64:cover.toString('base64')},env);
 const target=collection(env,'CardMedia');let saved=false;
 const committed=await target.runTransaction({apply:async tx=>{
   const rows=await tx.executeQuery(target.query().equalTo('id',media.id).limit(1)),current=rows[0];
   if(!sameMediaSource(current,media))return false;
   tx.executeUpsert([Object.assign(new CardMedia(),current,{coverSha256:sha256,coverByteSize:cover.length,coverWidth:result.width,coverHeight:result.height,coverSourceSha256:sourceSha256,coverRecipeVersion:1})]);saved=true;return true;
 }});
 if(!committed||!saved){await remove({keys:[coverKey]},env);return false;}return true;
}

// promote：把暂存区对象复制到公开路径并删除暂存对象。
async function promote(payload, env) {
  const pendingKey = validKey(payload && payload.pendingKey);
  const approvedKey = validKey(payload && payload.approvedKey);
  if (!pendingKey.startsWith('private/pending/') || !approvedKey.startsWith('public/approved/')) throw new Error('媒体确认路径无效。');
  const bucket = storageBucket(env);
  const pending = bucket.file(pendingKey);
  const approved = bucket.file(approvedKey);
  const pendingExists = await measuredCall('storage', 'exists', () => pending.exists());
  const approvedExists = await measuredCall('storage', 'exists', () => approved.exists());
  if (!pendingExists && !approvedExists) throw new Error('实拍图尚未成功上传，请重新选择并上传后再保存。');
  if (pendingExists && !approvedExists) await measuredCall('storage', 'copy', () => pending.copy(approved));
  if (pendingExists) await measuredCall('storage', 'delete', () => pending.delete());
  return { exists: true };
}

// remove：删除对象（原图会连同封面一起删除）。
async function remove(payload, env) {
  const originals = Array.isArray(payload && payload.keys) ? payload.keys : [];
  const keys = [...new Set(originals.flatMap(key => /^public\/approved\/[^/]+\/[0-9a-f-]{36}\.jpg$/i.test(key) ? [key, key.slice(0,-4)+'.cover-v1.jpg'] : [key]))];
  for (const candidate of keys) {
    const key = validKey(candidate);
    const file = storageBucket(env).file(key);
    if (await measuredCall('storage', 'exists', () => file.exists())) await measuredCall('storage', 'delete', () => file.delete());
  }
  return { deleted: keys.length };
}

// 校验准备上传的图片参数（JPEG、≤2MB、长边 ≤1600px、sha256）。
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

// prepare-card-photo：写入 PENDING_UPLOAD 记录，返回 mediaId、目标路径与桶名。
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

// 上传 / 直传确认共用：校验 mediaId 与 sha256，读取调用者本人尚未使用、仍处于 PENDING_UPLOAD 的准备记录。
async function pendingMediaFor(identity, payload, env) {
  const mediaId = String(payload.mediaId || '').trim();
  const sha256 = String(payload.sha256 || '').trim().toLowerCase();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(mediaId)) throw new Error('图片上传标识无效。');
  if (!/^[a-f0-9]{64}$/.test(sha256)) throw new Error('图片摘要无效。');
  const media = await one(collection(env, 'CardMedia').query().equalTo('id', mediaId));
  if (!media || String(media.ownerUid || '') !== identity.canonicalUid || String(media.cardId || '')) {
    throw new Error('图片不存在、不属于当前用户或已被使用。');
  }
  if (String(media.status || '') !== 'PENDING_UPLOAD') throw new Error('图片已上传或状态无效，请重新选择。');
  return { media, mediaId, sha256 };
}

// upload-card-photo：校验 Base64 内容与准备记录一致后写入公开路径，并生成封面。
async function uploadCardPhoto(input, env) {
  const identity = await verifiedIdentity(input && input.accessToken, env);
  const payload = input && input.payload || {};
  const { media, mediaId, sha256 } = await pendingMediaFor(identity, payload, env);
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
  await buildCover(media, env, bytes);
  return { success: true };
}

/**
 * confirm-card-photo-upload：客户端已把准备好的 JPEG 自己上传到 private/pending/{storageUid}/{mediaId}.jpg（存储规则只允许已登录的 AGC 用户本人写入）。这里读回文件，核对所有者、大小与 sha256 是否与准备记录一致，然后与 uploadCardPhoto 一样写入公开对象。任何失败都不改动准备记录，客户端仍可回落到 upload-card-photo。
 */
async function confirmCardPhotoUpload(input, env) {
  const identity = await verifiedIdentity(input && input.accessToken, env);
  const payload = input && input.payload || {};
  const { media, mediaId, sha256 } = await pendingMediaFor(identity, payload, env);
  const storageUid = String(media.storageUid || identity.providerUid);
  if (storageUid !== identity.providerUid) throw accessError('上传账号与准备记录不一致。', 'UPLOAD_OWNER_MISMATCH');
  const preparedSha256 = String(media.preparedSha256 || '').toLowerCase();
  if (sha256 !== preparedSha256) throw new Error('图片内容与准备记录不一致，请重新选择。');
  const pending = storageBucket(env).file(validKey(`private/pending/${storageUid}/${mediaId}.jpg`));
  if (!(await measuredCall('storage', 'exists', () => pending.exists()))) throw accessError('实拍图尚未上传完成。', 'UPLOAD_MISSING');
  const bytes = await readFileBytes(pending);
  if (bytes.length !== Number(media.byteSize || 0)) throw new Error('图片大小与准备记录不一致，请重新选择。');
  const objectKey = approvedObjectKey(storageUid, mediaId);
  await writeApproved({ key: objectKey, dataBase64: bytes.toString('base64'), sha256 }, env);
  await buildCover(media, env, bytes);
  try { await measuredCall('storage', 'delete', () => pending.delete()); } catch (_error) { }
  return { success: true };
}

// get-public-media：按公开模式读取图片（校验桶名与路径）。
async function getPublicMedia(input, env) {
  const payload = input && input.payload || {};
  if (String(payload.bucketName || '').trim() !== required(env, 'SHIKE_STORAGE_BUCKET')) throw new Error('图片所属存储实例无效。');
  const key = validKey(payload.cloudPath);
  return require('./shared/image-reader').readLegacy({ ...payload, key, mediaId: mediaIdFromApprovedObjectKey(key), mode: 'PUBLIC', viewerUid: '', readRequestId: input && input.readRequestId }, env);
}

// 维护任务：逐张为旧图片回填封面（租约 + 断点，连续失败 3 次暂停）。
async function runCoverBackfill(env,retryFailed=false){
 if(String(env.SHIKE_MEDIA_COVERS_VERIFIED)!=='true')return {status:'NOT_READY',reason:'SHIKE_MEDIA_COVERS_VERIFIED'};
 const jobs=collection(env,'MaintenanceJob'),jobId='media-cover-backfill-v1',lease=crypto.randomUUID(),now=Date.now();let job;
 const locked=await jobs.runTransaction({apply:async tx=>{
  const rows=await tx.executeQuery(jobs.query().equalTo('jobId',jobId).limit(1)),old=rows[0];
  if(old&&(old.status==='DONE'||old.status==='FAILED'&&!retryFailed||Number(new Date(old.leaseUntilAt))>now))return false;
  job=Object.assign(new MaintenanceJob(),old||{jobId,jobType:'MEDIA_COVER_BACKFILL',entityId:'COVER_480',generation:1,createdAt:new Date(now),checkpointJson:'{"processed":0,"errors":0}',attemptCount:0},
    {status:'RUNNING',runAfterAt:new Date(now),leaseOwner:lease,leaseUntilAt:new Date(now+90000),updatedAt:new Date(now),attemptCount:Number(old&&old.attemptCount||0)+1});
  tx.executeUpsert([job]);return true;
 }});if(!locked||!job)return {status:'BUSY_OR_DONE'};
 let checkpoint=JSON.parse(job.checkpointJson);if(retryFailed)checkpoint.consecutiveErrors=0;
 let last=checkpoint.last||null,next=last,status='PENDING',error='';
 try{
  const media=collection(env,'CardMedia');let query=media.query().orderByAsc('id');
  if(last){const boundary=Object.assign(new CardMedia(),{id:last});query=query.startAfter(boundary);}
  const rows=await query.limit(1).get();
  if(!rows.length)status='DONE';
  else {const row=rows[0];if(row.status==='APPROVED'&&!await buildCover(row,env))throw new Error('COVER_NOT_COMMITTED');next=row.id;checkpoint.processed++;checkpoint.consecutiveErrors=0;}
 }catch(e){checkpoint.errors++;checkpoint.consecutiveErrors=Number(checkpoint.consecutiveErrors||0)+1;error=require('./shared/read-errors').errorCode(e);status=error==='3007009'?'PENDING':checkpoint.consecutiveErrors>=3?'FAILED':'PENDING';if(error==='3007009')checkpoint.consecutiveErrors=0;}
 checkpoint.last=next;
 await jobs.runTransaction({apply:async tx=>{
  const rows=await tx.executeQuery(jobs.query().equalTo('jobId',jobId).limit(1)),current=rows[0];if(!current||current.leaseOwner!==lease)return false;
  tx.executeUpsert([Object.assign(new MaintenanceJob(),current,{status,lastErrorCode:error,checkpointJson:JSON.stringify(checkpoint),leaseOwner:'',leaseUntilAt:new Date(0),runAfterAt:new Date(Date.now()+60000),updatedAt:new Date()})]);return true;
 }});
 return {status,processed:checkpoint.processed,errors:checkpoint.errors,lastErrorCode:error};
}

// 内部接口分发（只接受签名请求）。
async function execute(input, env) {
  const request = verifySignedInput(input, env);
  const metrics = readMetricsScope.getStore();
  if (metrics && ['write-approved', 'promote', 'remove'].includes(request.action)) metrics.action = request.action;
  switch (request.action) {
    case 'write-approved': return writeApproved(request.payload, env);
    case 'promote': return promote(request.payload, env);
    case 'remove': return remove(request.payload, env);
    default: throw new Error('未知的媒体服务操作。');
  }
}

// 脱敏错误日志。
function safeLogError(error) {
  const message = error instanceof Error ? error.message.replace(/(accessToken|authorization|signature|body)=[^\s,]+/ig, '$1=[REDACTED]') : 'unknown error';
  const checks = ['NOT_BINARY', 'BYTE_BUDGET', 'SIZE_MISMATCH', 'JPEG_MARKERS', 'SHA256_MISMATCH'];
  return error && checks.includes(error.integrityCheck) ? message + ' integrityCheck=' + error.integrityCheck : message;
}

// 导出：客户端接口都包装了读取计量；runCoverBackfill 供维护函数使用。
module.exports = {
  execute: (input, env) => withReadMetrics('execute', env, () => execute(input, env), requestId(input)),
  prepareCardPhoto: (input, env) => withReadMetrics('prepare-card-photo', env, () => prepareCardPhoto(input, env), requestId(input)),
  uploadCardPhoto: (input, env) => withReadMetrics('upload-card-photo', env, () => uploadCardPhoto(input, env), requestId(input)),
  confirmCardPhotoUpload: (input, env) => withReadMetrics('confirm-card-photo-upload', env, () => confirmCardPhotoUpload(input, env), requestId(input)),
  getPublicMedia: (input, env) => withReadMetrics('get-public-media', env, () => getPublicMedia(input, env), requestId(input)),
  runCoverBackfill,
  safeLogError
};
