'use strict';
const crypto = require('node:crypto');
const { createContentPolicy, policyModels, accessError, cardContentRevision } = require('./content-policy');
const { CardMedia } = require('./image-models');
const { mediaVariant, sameMediaSource, verifyMediaBytes } = require('./media-descriptor');
const { errorCode } = require('./read-errors');
const { buildInfo } = require('./release-info');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SHA = /^[a-f0-9]{64}$/;
const MAX_BYTES = 2097152, COVER_BUDGET = 524288;

function objectKey(media, variant) {
  const uid = String(media.storageUid || media.ownerUid || '');
  if (!uid || /[/\\]/.test(uid) || !UUID.test(String(media.id))) throw accessError('图片不可访问。');
  return `public/approved/${uid}/${media.id}${variant === 'COVER_480' ? '.cover-v1' : ''}.jpg`;
}

function normalize(input) {
  if (Buffer.byteLength(JSON.stringify(input || {})) > 65536) throw accessError('图片请求过大。', 'VALIDATION_ERROR');
  if (!input || input.protocolVersion !== 'image-read-v1' || !Array.isArray(input.items) || input.items.length < 1 || input.items.length > 20)
    throw accessError('图片批次格式无效。', 'VALIDATION_ERROR');
  const keys = new Set();
  return input.items.map(item => {
    if (!item || !UUID.test(String(item.mediaId)) || !['PUBLIC', 'REVIEW', 'REVISION'].includes(item.mode) || !['ORIGINAL', 'COVER_480'].includes(item.variant))
      throw accessError('图片项格式无效。', 'VALIDATION_ERROR');
    const revisionId = String(item.revisionId || '');
    if (revisionId.length > 128) throw accessError('修订标识无效。', 'VALIDATION_ERROR');
    const key = [item.mediaId, item.mode, revisionId, item.variant].join(':');
    if (keys.has(key)) throw accessError('图片项重复。', 'VALIDATION_ERROR');
    keys.add(key);
    return { mediaId: String(item.mediaId), mode: item.mode, variant: item.variant, revisionId,
      knownSha256: SHA.test(item.knownSha256 || '') ? item.knownSha256 : '',
      knownByteSize: Number.isSafeInteger(item.knownByteSize) ? item.knownByteSize : 0, wantBytes: item.wantBytes === true };
  });
}

// Injected boundary makes permission/race/budget contracts user-testable without a cloud account.
function createImageReader(deps) {
  const bytesCache = new Map(), storageInFlight = new Map();
  let cachedBytes = 0;
  function remember(key, bytes) {
    const old = bytesCache.get(key); if (old) cachedBytes -= old.length;
    bytesCache.delete(key); bytesCache.set(key, bytes); cachedBytes += bytes.length;
    while (cachedBytes > 16 * 1024 * 1024 || bytesCache.size > 32) {
      const first = bytesCache.keys().next().value;
      cachedBytes -= bytesCache.get(first).length; bytesCache.delete(first);
    }
  }
  async function load(media, descriptor, metrics) {
    const cacheKey = descriptor.sha256 ? [media.id, descriptor.variant, descriptor.sha256, media.coverRecipeVersion || 0].join(':') : '';
    if (cacheKey && bytesCache.has(cacheKey)) {
      const bytes = bytesCache.get(cacheKey); bytesCache.delete(cacheKey); bytesCache.set(cacheKey, bytes); metrics.byteCacheHits++;
      return bytes;
    }
    if (cacheKey && storageInFlight.has(cacheKey)) return storageInFlight.get(cacheKey);
    const task = (async () => {
      metrics.storageDownloads++;
      const bytes = await deps.download(objectKey(media, descriptor.variant), Math.min(MAX_BYTES, descriptor.byteSize));
      verifyMediaBytes(bytes, descriptor);
      if (cacheKey) remember(cacheKey, bytes);
      return bytes;
    })();
    if (cacheKey) storageInFlight.set(cacheKey, task);
    try { return await task; } finally { if (cacheKey && storageInFlight.get(cacheKey) === task) storageInFlight.delete(cacheKey); }
  }
  async function batchRows(name, field, keys, metrics) {
    const unique = [...new Set(keys.filter(Boolean))];
    if (!unique.length) return [];
    metrics.dbGet++; metrics.byObject[name] = (metrics.byObject[name] || 0) + 1;
    try { return await deps.collection(name).query().in(field, unique).limit(unique.length).get(); }
    catch (error) { metrics.failureCollection = name; throw error; }
  }
  async function authority(viewerUid, items, metrics) {
    const media = await batchRows('CardMedia', 'id', items.map(item => item.mediaId), metrics);
    const cardIds = media.map(row => row.cardId).filter(id => id && !id.startsWith('profile:') && !id.startsWith('profile-cover:') && !id.startsWith('revision:'));
    const cards = await batchRows('FoodCard', 'id', cardIds, metrics);
    const revisions = await batchRows('FoodCardRevision', 'revisionId', items.filter(item => item.mode === 'REVISION').map(item => item.revisionId), metrics);
    const missingCards = revisions.map(row => row.cardId).filter(id => !cards.some(card => card.id === id));
    if (missingCards.length) cards.push(...await batchRows('FoodCard', 'id', missingCards, metrics));
    const collection = name => {
      const target = deps.collection(name);
      // The shared policy uses at most one profile/relationship batch in ordinary mode.
      function wrap(query) {
        return new Proxy(query, { get(target, property) {
          if (property === 'get') return async () => {
            metrics.dbGet++; metrics.byObject[name] = (metrics.byObject[name] || 0) + 1;
            try { return await target.get(); } catch (error) { metrics.failureCollection = name; throw error; }
          };
          const value = target[property];
          if (typeof value !== 'function') return value;
          return (...args) => { const next = value.apply(target, args); return next && typeof next.get === 'function' ? wrap(next) : next; };
        } });
      }
      return { query: () => wrap(target.query()) };
    };
    const policy = createContentPolicy(collection, async query => (await query.limit(1).get())[0] || null, { cards, revisions, cardIds: [...cardIds, ...missingCards], revisionIds: items.filter(item => item.mode === 'REVISION').map(item => item.revisionId) });
    await policy.prepareMediaReads(viewerUid, media);
    if (viewerUid) await policy.assertAccountActive(viewerUid, true);
    return { media: new Map(media.map(row => [String(row.id), row])), cards: new Map(cards.map(row => [String(row.id), row])), policy };
  }
  async function allowed(state, viewerUid, item, media, administrator) {
    if (!media) return false;
    if (item.mode === 'REVIEW') return state.policy.canReadModerationMedia(viewerUid, media, administrator);
    if (item.mode === 'REVISION') return state.policy.canReadRevisionMedia(viewerUid, media, item.revisionId, administrator);
    return state.policy.canReadMedia(viewerUid, media);
  }
  async function read(input, trustedViewer) {
    const items = normalize(input), metrics = { dbGet: 0, byObject: {}, storageDownloads: 0, authVerify: 0, byteCacheHits: 0, failureCollection: '', phase: 'authentication', phaseMs: {}, responseBytes: 0, wireImageBytes: 0 };
    const started = Date.now(); let phaseStarted = started;
    function phase(next) { const now = Date.now(); metrics.phaseMs[metrics.phase] = (metrics.phaseMs[metrics.phase] || 0) + now - phaseStarted; metrics.phase = next; phaseStarted = now; }
    let viewerUid = '', outcome = 'error', failure = '';
    try {
      if (trustedViewer !== undefined) viewerUid = trustedViewer;
      else if (input.accessToken !== undefined && input.accessToken !== '') {
        if (typeof input.accessToken !== 'string' || input.accessToken.length > 8192) throw accessError('登录凭证无效。', 'AUTH_REQUIRED');
        metrics.authVerify++;
        const providerUid = await deps.verifyToken(input.accessToken);
        const id = crypto.createHash('sha256').update('shike-identity:AGC:' + providerUid).digest('hex');
        const binding = (await batchRows('IdentityBinding', 'id', [id], metrics))[0];
        if (binding && (String(binding.status || 'ACTIVE') !== 'ACTIVE' || !binding.canonicalUid)) throw accessError('账号身份已停用。', 'ACCOUNT_INACTIVE');
        viewerUid = binding ? String(binding.canonicalUid) : providerUid;
      }
      const administrator = !!viewerUid && deps.adminUids.includes(viewerUid);
      phase('media-permissions');
      const initial = await authority(viewerUid, items, metrics), results = [], downloaded = [];
      let remaining = COVER_BUDGET, downloadCount = 0;
      for (let index = 0; index < items.length; index++) {
        const item = items[index], media = initial.media.get(item.mediaId);
        const result = { mediaId: item.mediaId, mode: item.mode, revisionId: item.revisionId, requestedVariant: item.variant, status: 'DENIED', code: 'CONTENT_ACCESS_DENIED' };
        results.push(result);
        if (!await allowed(initial, viewerUid, item, media, administrator)) continue;
        const key = objectKey(media, 'ORIGINAL');
        if (input.expectedKey && input.expectedKey !== key) continue;
        let descriptor;
        try { descriptor = mediaVariant(media, item.variant); }
        catch (error) { if (errorCode(error) !== 'MEDIA_VARIANT_UNAVAILABLE') throw error; descriptor = mediaVariant(media, 'ORIGINAL'); }
        if (descriptor.variant === 'COVER_480' && descriptor.byteSize > COVER_BUDGET) descriptor = mediaVariant(media, 'ORIGINAL');
        if (!Number.isSafeInteger(descriptor.byteSize) || descriptor.byteSize < 4 || descriptor.byteSize > MAX_BYTES) {
          result.status = 'RETRYABLE_ERROR'; result.code = 'MEDIA_INTEGRITY_FAILED'; continue;
        }
        result.descriptor = { ...descriptor, ownerUid: String(media.ownerUid), cardId: String(media.cardId), recipeVersion: descriptor.variant === 'COVER_480' ? 1 : 0,
          cardRevision: cardContentRevision(initial.cards.get(media.cardId)) };
        result.code = '';
        if (descriptor.sha256 && descriptor.sha256 === item.knownSha256 && descriptor.byteSize === item.knownByteSize) { result.status = 'CACHE_OK'; continue; }
        if (!item.wantBytes && (descriptor.sha256 || !item.knownSha256)) { result.status = 'VERSION_CHANGED'; continue; }
        const original = descriptor.variant === 'ORIGINAL';
        if (downloadCount >= 4 || original && (downloadCount > 0 || items.filter(row => row.wantBytes).length > 1) || !original && descriptor.byteSize > remaining) {
          result.status = 'DEFERRED'; continue;
        }
        phase('storage'); downloadCount++;
        let bytes;
        try { bytes = await load(media, descriptor, metrics); }
        catch (error) {
          if (errorCode(error) === '3007009') throw error;
          result.status = 'RETRYABLE_ERROR'; result.code = errorCode(error); continue;
        }
        descriptor = { ...descriptor, sha256: verifyMediaBytes(bytes, descriptor) };
        Object.assign(result.descriptor, descriptor);
        if (descriptor.sha256 === item.knownSha256 && bytes.length === item.knownByteSize) result.status = 'CACHE_OK';
        else { result.status = 'BYTES'; result.dataBase64 = bytes.toString('base64'); metrics.wireImageBytes += bytes.length; }
        downloaded.push({ index, media, descriptor });
        remaining = original ? 0 : remaining - bytes.length;
      }
      // Final authority is always new after storage/cache-byte access, never a global permission cache.
      if (downloaded.length) {
        phase('final-check');
        const fresh = await authority(viewerUid, downloaded.map(entry => items[entry.index]), metrics);
        for (const entry of downloaded) {
          const item = items[entry.index], current = fresh.media.get(item.mediaId), result = results[entry.index];
          let valid = sameMediaSource(current, entry.media) && await allowed(fresh, viewerUid, item, current, administrator);
          if (valid) {
            try { const now = mediaVariant(current, entry.descriptor.variant); valid = (!now.sha256 || now.sha256 === entry.descriptor.sha256) && now.byteSize === entry.descriptor.byteSize; } catch (_error) { valid = false; }
          }
          if (valid) result.descriptor.cardRevision = cardContentRevision(fresh.cards.get(current.cardId));
          if (!valid) { result.status = 'DENIED'; result.code = 'CONTENT_ACCESS_DENIED'; delete result.dataBase64; delete result.descriptor; }
        }
      }
      const response = { ...buildInfo, requestId: input.readRequestId || '', retryAfterMs: 0, items: results };
      metrics.wireImageBytes = results.reduce((total, result) => total + (result.dataBase64 ? Buffer.byteLength(result.dataBase64, 'base64') : 0), 0);
      metrics.statusCounts = results.reduce((counts, result) => { counts[result.status] = (counts[result.status] || 0) + 1; return counts; }, {});
      metrics.responseBytes = Buffer.byteLength(JSON.stringify(response));
      if (metrics.responseBytes > 3 * 1024 * 1024) throw accessError('图片响应超过预算。', 'RESPONSE_TOO_LARGE');
      outcome = 'success'; return response;
    } catch (error) { failure = errorCode(error); if (error && typeof error === 'object') error.readStage = metrics.phase; throw error; }
    finally { phase('complete'); console.info('image.read ' + JSON.stringify({ ...metrics, ...buildInfo, traceId: input.readRequestId || '', requestId: input.readRequestId || '', modes: [...new Set(items.map(item => item.mode))], variants: [...new Set(items.map(item => item.variant))], attempt: input.readAttempt || 1, count: items.length, outcome, code: failure || 'OK', ms: Date.now() - started })); }
  }
  return { readBatch: input => read(input), readTrusted: (input, viewerUid) => read(input, viewerUid) };
}

let defaultReader;
function reader(env) {
  if (!defaultReader) {
    const { cloud } = require('@hw-agconnect/cloud-server');
    const { AGCClient, CredentialParser } = require('@agconnect/common-server');
    const { AGCCloudStorage } = require('@agconnect/cloudstorage-server');
    const models = { ...policyModels, CardMedia }; let storageReady = false;
    defaultReader = createImageReader({ adminUids: String(env.SHIKE_ADMIN_UIDS || '').split(',').map(value => value.trim()).filter(Boolean),
      collection: name => cloud.database({ zoneName: env.SHIKE_DB_ZONE || 'shike' }).collection(models[name]),
      verifyToken: async token => {
        try { const verified = await cloud.auth().verifyAccessToken({ accessToken: token, checkRevoked: true }); const uid = String(verified.getSub() || ''); if (!uid) throw new Error('Missing subject'); return uid; }
        catch (error) { if (errorCode(error) === '3007009') throw error; throw accessError('登录凭证无效或已撤销。', 'AUTH_REQUIRED'); }
      },
      download: async (key, maximum) => {
        if (!storageReady) {
          if (!env.PROJECT_CREDENTIAL || !env.SHIKE_STORAGE_BUCKET) throw new Error('Missing image storage configuration');
          AGCClient.initialize(CredentialParser.toCredentialWithContents(env.PROJECT_CREDENTIAL), 'shike-image-storage', 'CN'); storageReady = true;
        }
        const file = AGCCloudStorage.getInstance('shike-image-storage').bucket(env.SHIKE_STORAGE_BUCKET, 'CN').file(key);
        return new Promise((resolve, reject) => {
          const chunks = []; let total = 0, settled = false;
          const stream = file.createReadStream();
          const timeout = setTimeout(() => { stream.destroy(); fail(accessError('图片存储读取超时。', 'MEDIA_TIMEOUT')); }, 15000);
          function fail(error) { if (!settled) { settled = true; clearTimeout(timeout); reject(error); } }
          stream.on('data', chunk => { if (settled) return; const bytes = Buffer.from(chunk); total += bytes.length;
            if (total > maximum) { stream.destroy(); fail(accessError('图片超过大小限制。', 'MEDIA_INTEGRITY_FAILED')); } else chunks.push(bytes); });
          stream.on('end', () => { if (!settled) { settled = true; clearTimeout(timeout); resolve(Buffer.concat(chunks)); } });
          stream.on('error', fail);
        });
      } });
  }
  return defaultReader;
}
async function readBatch(input, env) { return reader(env).readBatch(input); }
async function readLegacy(payload, env, accessToken) {
  const item = { mediaId: payload.mediaId, mode: payload.mode || 'PUBLIC', revisionId: payload.revisionId || '', variant: payload.variant || 'ORIGINAL', knownSha256: payload.knownSha256 || '', knownByteSize: payload.knownByteSize || 0, wantBytes: !payload.metadataOnly };
  const input = { protocolVersion: 'image-read-v1', accessToken: accessToken || '', items: [item], expectedKey: payload.key || '', readRequestId: payload.readRequestId || '' };
  const response = accessToken === undefined ? await reader(env).readTrusted(input, String(payload.viewerUid || '')) : await reader(env).readBatch(input);
  const result = response.items[0];
  if (!result.descriptor || result.status === 'DENIED') throw accessError('图片不可访问。');
  if (result.status === 'RETRYABLE_ERROR' || result.status === 'DEFERRED') throw accessError('图片暂时不可用，请重试。', result.code || 'MEDIA_DEFERRED');
  if (payload.version && result.descriptor.sha256 !== payload.version) throw accessError('图片版本已变化。', 'MEDIA_VERSION_STALE');
  return { ...result.descriptor, status: result.status, mimeType: 'image/jpeg', metadataOnly: !!payload.metadataOnly, dataBase64: result.dataBase64 || '' };
}
module.exports = { createImageReader, readBatch, readLegacy };
