'use strict';

const crypto = require('crypto');
const { accessError, dateMillis, isAccountActive, readableCardState, currentVisibility } = require('./content-policy');
const CATEGORIES = Object.freeze(['NOODLES', 'RICE_SET', 'HOT_POT', 'GRILL_FRIED', 'SNACK',
  'FAST_WESTERN', 'BREAKFAST_BAKERY', 'DESSERT', 'DRINK', 'PACKAGED', 'OTHER']);
const LEGACY_CATEGORY = Object.freeze({ NOODLES: 'bakery', RICE_SET: 'staple', DRINK: 'drink',
  GRILL_FRIED: 'fresh', SNACK: 'snack' });
const LEGACY_TO_V2 = Object.freeze({ staple: 'RICE_SET', bakery: 'NOODLES', drink: 'DRINK',
  snack: 'GRILL_FRIED', fresh: 'GRILL_FRIED', other: 'OTHER' });
const normalize = (value) => String(value || '').normalize('NFKC').trim().replace(/\s+/g, ' ').toLowerCase();
const hash = (value) => crypto.createHash('sha256').update(value).digest('hex');
const COUNTERS = ['publicRecommendationCount', 'publicDeliveryCount', 'publicDineInCount'];

function createStage2Services(ctx) {
  const { collection, one, models, profileForWrite, logicalWriteTime, assertAdmin } = ctx;
  const model = (name, row) => Object.assign(new models[name](), row);
  const txOne = async (tx, env, name, field, value) =>
    (await tx.executeQuery(collection(env, name).query().equalTo(field, value).limit(1)))[0] || null;
  const setting = (env, key) => String(env[key] || process.env[key] || '');
  const coordinateSystem = (value) => ['GCJ02', 'WGS84'].includes(value) ? value : 'UNKNOWN';
  function friendsReady(env) { return setting(env, 'SHIKE_FRIENDS_PUBLISH_VERIFIED') === 'true'; }
  function requireFriendsGate(visibility, env) {
    if (visibility === 'FRIENDS' && !friendsReady(env)) {
      throw accessError('好友内容全入口权限验收完成后才能开放此操作。', 'FRIENDS_VALIDATION_REQUIRED');
    }
  }
  function text(value, max, required = false) {
    const result = String(value || '').trim();
    if (result.length > max || (required && result.length === 0)) throw accessError('店铺信息长度无效。', 'VALIDATION_ERROR');
    return result;
  }
  function uuid(value) {
    const id = String(value || '').toLowerCase();
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)) throw accessError('请求标识必须为 UUID。', 'VALIDATION_ERROR');
    return id;
  }
  function location(payload) {
    if (typeof payload.latitudeE6 !== 'number' || typeof payload.longitudeE6 !== 'number') {
      throw accessError('店铺坐标必须是整数微度。', 'VALIDATION_ERROR');
    }
    const latitudeE6 = Number(payload.latitudeE6), longitudeE6 = Number(payload.longitudeE6);
    if (!Number.isSafeInteger(latitudeE6) || !Number.isSafeInteger(longitudeE6) ||
      Math.abs(latitudeE6) > 90000000 || Math.abs(longitudeE6) > 180000000) {
      throw accessError('请选择有效的店铺地图位置。', 'VALIDATION_ERROR');
    }
    return { latitudeE6, longitudeE6 };
  }
  function money(value) {
    if (value === undefined || value === null || value === '') return null;
    if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0 || value > 100000000) {
      throw accessError('金额必须是 0–100000000 的整数分。', 'VALIDATION_ERROR');
    }
    return value;
  }
  function canAssociate(row, uid) {
    return !!row && (['VERIFIED_PROVIDER', 'USER_CONFIRMED_APPROVED'].includes(row.verificationStatus) ||
      (row.verificationStatus === 'USER_CONFIRMED_PENDING' && row.createdByUid === uid));
  }
  function mapEligible(row) {
    return !!row && ['VERIFIED_PROVIDER', 'USER_CONFIRMED_APPROVED'].includes(row.verificationStatus) &&
      coordinateSystem(row.coordinateSystem) !== 'UNKNOWN' && Number(row.publicRecommendationCount) > 0;
  }
  function merchantView(row) {
    return { merchantId: row.merchantId, name: row.name, address: String(row.address || ''), district: String(row.district || ''),
      sourceType: row.sourceType, provider: String(row.provider || ''), providerPoiId: String(row.providerPoiId || ''),
      latitudeE6: Number(row.latitudeE6), longitudeE6: Number(row.longitudeE6), coordinateSystem: row.coordinateSystem,
      verificationStatus: row.verificationStatus, mapVisible: row.mapVisible === true && mapEligible(row),
      publicRecommendationCount: Number(row.publicRecommendationCount || 0), publicDeliveryCount: Number(row.publicDeliveryCount || 0),
      publicDineInCount: Number(row.publicDineInCount || 0), updatedAt: dateMillis(row.updatedAt),
      reviewAction: String(row.reviewAction || ''), reviewReason: String(row.reviewReason || '') };
  }
  async function cardFields(payload, uid, env, read = (name, field, value) => one(collection(env, name).query().equalTo(field, value)),
    allowUnspecified = false) {
    const mode = String(payload.consumptionMode || 'UNSPECIFIED');
    if (!['DELIVERY', 'DINE_IN'].includes(mode) && !(allowUnspecified && mode === 'UNSPECIFIED')) {
      throw accessError('请选择外卖或到店。', 'VALIDATION_ERROR');
    }
    const visibility = String(payload.visibility || 'PUBLIC');
    if (!['PUBLIC', 'FRIENDS'].includes(visibility)) throw accessError('可见范围无效。', 'VALIDATION_ERROR');
    const categoryV2 = String(payload.categoryV2 || (allowUnspecified ? LEGACY_TO_V2[payload.category] || 'OTHER' : ''));
    if (!CATEGORIES.includes(categoryV2)) throw accessError('请选择有效的主分类。', 'VALIDATION_ERROR');
    const itemPriceFen = money(payload.itemPriceFen === undefined && allowUnspecified
      ? Number(payload.priceFen || 0) > 0 ? Number(payload.priceFen) : null : payload.itemPriceFen);
    const dineInAvgFen = mode === 'DINE_IN' ? money(payload.dineInAvgFen) : null;
    const orderTotalFen = mode === 'DELIVERY' ? money(payload.orderTotalFen) : null;
    const deliveryFeeFen = mode === 'DELIVERY' ? money(payload.deliveryFeeFen) : null;
    const key = mode === 'DELIVERY' ? text(payload.deliveryPlatformKey, 40) : '';
    const label = key ? text(payload.deliveryPlatformLabelSnapshot, 40, true) : '';
    if (key && !/^[A-Z0-9_]{1,40}$/.test(key)) throw accessError('外卖平台标识无效。', 'VALIDATION_ERROR');
    const consumed = mode !== 'DELIVERY' || payload.consumedAt === undefined || payload.consumedAt === null ? null : Number(payload.consumedAt);
    if (consumed !== null && (!Number.isSafeInteger(consumed) || consumed < 0 || consumed > Date.now() + 86400000)) {
      throw accessError('购买时间无效。', 'VALIDATION_ERROR');
    }
    const merchantId = text(payload.merchantId, 100);
    const merchant = merchantId ? await read('Merchant', 'merchantId', merchantId) : null;
    if (merchantId && !canAssociate(merchant, uid)) throw accessError('店铺不存在、已拒绝或无权关联待审店铺。', 'MERCHANT_NOT_VERIFIED');
    // Snapshots, legacy bridges and query fields are always server-derived.
    return { consumptionMode: mode, visibility, categoryV2, categoryVersion: 2,
      category: LEGACY_CATEGORY[categoryV2] || 'other', itemPriceFen, dineInAvgFen, orderTotalFen, deliveryFeeFen,
      queryPriceFen: mode === 'DINE_IN' ? dineInAvgFen : itemPriceFen, priceFen: itemPriceFen === null ? 0 : itemPriceFen,
      merchantId, merchantNameSnapshot: merchant ? merchant.name : '', merchantAddressSnapshot: merchant ? String(merchant.address || '') : '',
      shop: merchant ? merchant.name : text(payload.shop, 100), deliveryPlatformKey: key, deliveryPlatformLabelSnapshot: label,
      consumedAt: consumed, searchTextNormalized: normalize(String(payload.productName || '') + ' ' +
        (merchant ? merchant.name : String(payload.shop || ''))) };
  }
  function storageFields(fields) { return { ...fields, consumedAt: fields.consumedAt === null ? null : new Date(fields.consumedAt) }; }
  function contribution(card, owner) {
    const eligible = card && card.merchantId && isAccountActive(owner) && readableCardState(card) && currentVisibility(card) === 'PUBLIC';
    return eligible ? [1, card.consumptionMode === 'DELIVERY' ? 1 : 0, card.consumptionMode === 'DINE_IN' ? 1 : 0] : [0, 0, 0];
  }
  function changedCounter(row, delta, now) {
    const changed = { ...row, updatedAt: new Date(now) };
    COUNTERS.forEach((key, index) => {
      const next = Number(row[key] || 0) + delta[index];
      if (!Number.isSafeInteger(next) || next < 0 || next > 2147483647) throw accessError('店铺计数需要管理员重算。', 'COUNTER_RECONCILIATION_REQUIRED');
      changed[key] = next;
    });
    changed.mapVisible = mapEligible(changed);
    return model('Merchant', changed);
  }
  // Read/prepare only. Callers queue these rows after ALL transaction reads.
  async function prepareCounterTransition(tx, before, after, owner, env, now) {
    const deltas = new Map();
    for (const [card, sign] of [[before, -1], [after, 1]]) {
      if (!card || !card.merchantId) continue;
      const delta = deltas.get(card.merchantId) || [0, 0, 0];
      contribution(card, owner).forEach((count, index) => { delta[index] += sign * count; });
      deltas.set(card.merchantId, delta);
    }
    const result = [];
    for (const id of [...deltas.keys()].sort()) {
      const delta = deltas.get(id);
      if (delta.every((value) => value === 0)) continue;
      const row = await txOne(tx, env, 'Merchant', 'merchantId', id);
      if (!row) throw accessError('关联店铺已失效。', 'INVALID_STATE');
      result.push(changedCounter(row, delta, now));
    }
    return result;
  }
  async function prepareAccountCounterRemoval(tx, uid, owner, env, now) {
    const deltas = new Map();
    let readCount = 0;
    for (let offset = 0; ; offset += 100) {
      const limit = Math.min(100, 801 - readCount);
      const cards = await tx.executeQuery(collection(env, 'FoodCard').query().equalTo('ownerUid', uid)
        .greaterThan('merchantId', '').orderByAsc('merchantId').orderByAsc('id').limit(limit, offset));
      readCount += cards.length;
      if (readCount > 800) throw accessError('账号内容超过当前计数事务容量；注销未提交，需先完成分批维护方案。', 'COUNTER_TRANSACTION_LIMIT');
      for (const card of cards) {
        if (!card.merchantId) continue;
        const delta = deltas.get(card.merchantId) || [0, 0, 0];
        contribution(card, owner).forEach((count, index) => { delta[index] -= count; });
        deltas.set(card.merchantId, delta);
      }
      if (cards.length < limit) break;
    }
    const rows = [];
    for (const id of [...deltas.keys()].sort()) {
      if (deltas.get(id).every((value) => value === 0)) continue;
      const merchant = await txOne(tx, env, 'Merchant', 'merchantId', id);
      readCount++;
      if (readCount > 800) throw accessError('账号关联店铺超过当前计数事务容量；注销未提交，需先完成分批维护方案。', 'COUNTER_TRANSACTION_LIMIT');
      if (!merchant) throw accessError('关联店铺已失效。', 'INVALID_STATE');
      rows.push(changedCounter(merchant, deltas.get(id), now));
    }
    return rows;
  }
  async function reconcileMerchantPublicCounters(uid, payload, env) {
    await assertAdmin(uid, env);
    let result = null;
    const committed = await collection(env, 'Merchant').runTransaction({ apply: async (tx) => {
      const merchant = await txOne(tx, env, 'Merchant', 'merchantId', text(payload.merchantId, 100, true));
      if (!merchant) throw accessError('店铺不存在。', 'NOT_FOUND');
      const counts = [0, 0, 0], owners = new Map();
      let readCount = 1;
      for (let offset = 0; ; offset += 100) {
        const cards = await tx.executeQuery(collection(env, 'FoodCard').query().equalTo('merchantId', merchant.merchantId).orderByAsc('id').limit(100, offset));
        readCount += cards.length;
        if (readCount > 800) throw accessError('店铺计数重算超过当前事务容量，需分批维护方案。', 'COUNTER_TRANSACTION_LIMIT');
        for (const card of cards) {
          if (!owners.has(card.ownerUid)) {
            owners.set(card.ownerUid, await txOne(tx, env, 'UserProfile', 'uid', card.ownerUid));
            readCount++;
            if (readCount > 800) throw accessError('店铺作者数量超过当前重算事务容量，需分批维护方案。', 'COUNTER_TRANSACTION_LIMIT');
          }
          contribution(card, owners.get(card.ownerUid)).forEach((count, index) => { counts[index] += count; });
        }
        if (cards.length < 100) break;
      }
      result = changedCounter({ ...merchant, publicRecommendationCount: 0, publicDeliveryCount: 0, publicDineInCount: 0 }, counts, Date.now());
      tx.executeUpsert([result]); return true;
    } });
    if (!committed || !result) throw new Error('计数重算未保存。');
    return { merchant: merchantView(result) };
  }
  async function insertMerchant(row, creationHash, env) {
    // executeInsert, not executeUpsert: deterministic primary keys must never
    // let a duplicate resolver overwrite counters or a moderator's decision.
    try { await collection(env, 'Merchant').insert(row); }
    catch (_error) {
      const existing = await one(collection(env, 'Merchant').query().equalTo('merchantId', row.merchantId));
      if (!existing) throw accessError('店铺保存失败，请使用同一请求重试。', 'MERCHANT_SAVE_FAILED');
      if (creationHash && existing.creationRequestHash !== creationHash) throw accessError('请求标识已用于其他店铺。', 'CONFLICT');
      return { merchant: merchantView(existing), alreadyProcessed: true };
    }
    return { merchant: merchantView(row), alreadyProcessed: false };
  }
  async function resolveMerchant(uid, payload, env) {
    await ctx.contentPolicy(env).assertAccountActive(uid);
    if (payload.provider !== 'HUAWEI_MAP') throw accessError('地点提供方无效。', 'VALIDATION_ERROR');
    const siteId = text(payload.providerPoiId, 200, true);
    const id = hash('merchant:HUAWEI_MAP:' + siteId);
    const existing = await one(collection(env, 'Merchant').query().equalTo('merchantId', id));
    if (existing) return { merchant: merchantView(existing), alreadyProcessed: true };
    const key = setting(env, 'SHIKE_HUAWEI_SITE_API_KEY');
    if (!key || setting(env, 'SHIKE_HUAWEI_POI_VERIFIED') !== 'true') {
      throw accessError('官方地点核验尚未配置，可改用用户确认地点并等待审核。', 'POI_VERIFICATION_REQUIRED');
    }
    let body;
    try {
      const response = await fetch('https://siteapi.cloud.huawei.com/mapApi/v1/siteService/searchById', {
        method: 'POST', headers: { Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
        body: JSON.stringify({ siteId, language: 'zh' }), signal: AbortSignal.timeout(8000)
      });
      if (!response.ok) throw new Error('provider response');
      const raw = await response.text();
      if (raw.length > 131072) throw new Error('provider size');
      body = JSON.parse(raw);
    } catch (_error) { throw accessError('官方地点核验暂时不可用，请稍后重试或创建待审地点。', 'POI_LOOKUP_UNAVAILABLE'); }
    const site = body && body.site;
    if (String(body && body.returnCode) !== '0' || !site || String(site.siteId) !== siteId || !site.location ||
        typeof site.location.lat !== 'number' || typeof site.location.lng !== 'number') {
      throw accessError('官方地点标识无法核验。', 'POI_NOT_FOUND');
    }
    const point = location({ latitudeE6: Math.round(site.location.lat * 1000000), longitudeE6: Math.round(site.location.lng * 1000000) });
    const now = Date.now();
    return insertMerchant(model('Merchant', { merchantId: id, name: text(site.name, 100, true), normalizedName: normalize(site.name),
      address: text(site.formatAddress, 600), district: '', sourceType: 'HUAWEI_POI', provider: 'HUAWEI_MAP', providerPoiId: siteId,
      ...point, coordinateSystem: coordinateSystem(setting(env, 'SHIKE_HUAWEI_POI_COORDINATE_SYSTEM')),
      verificationStatus: 'VERIFIED_PROVIDER', createdByUid: uid, createdAt: new Date(now), updatedAt: new Date(now),
      publicRecommendationCount: 0, publicDeliveryCount: 0, publicDineInCount: 0, mapVisible: false,
      reviewAction: '', reviewReason: '', reviewedAt: null, creationRequestHash: '' }), '', env);
  }
  async function createUserMerchant(uid, payload, env) {
    await ctx.contentPolicy(env).assertAccountActive(uid);
    const fields = { name: text(payload.name, 100, true), address: text(payload.address, 600), ...location(payload) };
    const creationHash = hash(JSON.stringify(fields));
    const now = Date.now();
    return insertMerchant(model('Merchant', { merchantId: hash('merchant:user:' + uid + ':' + uuid(payload.requestId)),
      ...fields, normalizedName: normalize(fields.name), district: '', sourceType: 'USER_CONFIRMED', provider: '', providerPoiId: '',
      coordinateSystem: coordinateSystem(setting(env, 'SHIKE_MAP_PICKER_COORDINATE_SYSTEM')),
      verificationStatus: 'USER_CONFIRMED_PENDING', createdByUid: uid, createdAt: new Date(now), updatedAt: new Date(now),
      publicRecommendationCount: 0, publicDeliveryCount: 0, publicDineInCount: 0, mapVisible: false,
      reviewAction: '', reviewReason: '', reviewedAt: null, creationRequestHash: creationHash }), creationHash, env);
  }
  async function updateUserMerchant(uid, payload, env) {
    const requestId = uuid(payload.requestId);
    const fields = { name: text(payload.name, 100, true), address: text(payload.address, 600), ...location(payload) };
    const payloadHash = hash(JSON.stringify(fields));
    let result = null;
    const committed = await collection(env, 'Merchant').runTransaction({ apply: async (tx) => {
      const owner = await txOne(tx, env, 'UserProfile', 'uid', uid);
      if (!isAccountActive(owner)) throw accessError('账号已停用。', 'ACCOUNT_INACTIVE');
      const row = await txOne(tx, env, 'Merchant', 'merchantId', text(payload.merchantId, 100, true));
      if (!row || row.createdByUid !== uid || row.sourceType !== 'USER_CONFIRMED') {
        throw accessError('不能修改此店铺。', 'FORBIDDEN');
      }
      if (row.lastUpdateRequestId === requestId) {
        if (row.lastUpdatePayloadHash !== payloadHash) throw accessError('请求标识已用于其他修正。', 'CONFLICT');
        result = row; return true;
      }
      if (row.verificationStatus === 'USER_CONFIRMED_APPROVED') throw accessError('已批准店铺不能由作者直接修改。', 'FORBIDDEN');
      if (dateMillis(row.updatedAt) !== Number(payload.expectedUpdatedAt)) throw accessError('店铺已变化，请刷新。', 'CONFLICT');
      const now = logicalWriteTime(owner.updatedAt, dateMillis(row.updatedAt));
      result = model('Merchant', { ...row, name: text(payload.name, 100, true), normalizedName: normalize(payload.name),
        address: text(payload.address, 600), ...location(payload), coordinateSystem: coordinateSystem(setting(env, 'SHIKE_MAP_PICKER_COORDINATE_SYSTEM')),
        verificationStatus: 'USER_CONFIRMED_PENDING', mapVisible: false, updatedAt: new Date(now), reviewAction: '', reviewReason: '', reviewedAt: null,
        lastUpdateRequestId: requestId, lastUpdatePayloadHash: payloadHash });
      tx.executeUpsert([result]); tx.executeUpsert([profileForWrite(owner, now)]); return true;
    } });
    if (!committed || !result) throw new Error('店铺修改未保存。');
    return { merchant: merchantView(result) };
  }
  async function getMerchant(uid, payload, env) {
    await ctx.contentPolicy(env).assertAccountActive(uid);
    const row = await one(collection(env, 'Merchant').query().equalTo('merchantId', text(payload.merchantId, 100, true)));
    if (!row || (!canAssociate(row, uid) && row.createdByUid !== uid)) throw accessError('店铺不可访问。', 'NOT_FOUND');
    return { merchant: merchantView(row) };
  }
  async function listModerationMerchants(uid, payload, env) {
    await assertAdmin(uid, env);
    const offset = Number(payload.pageToken || 0);
    if (!Number.isSafeInteger(offset) || offset < 0) throw new Error('分页参数无效。');
    const rows = await collection(env, 'Merchant').query().equalTo('verificationStatus', 'USER_CONFIRMED_PENDING')
      .orderByAsc('createdAt').orderByAsc('merchantId').limit(20, offset).get();
    return { merchants: rows.map(merchantView), nextPageToken: rows.length === 20 ? String(offset + rows.length) : '' };
  }
  async function moderateMerchant(uid, payload, env) {
    await assertAdmin(uid, env);
    const action = String(payload.action || '');
    if (!['APPROVE', 'REQUEST_CHANGE', 'REJECT'].includes(action)) throw new Error('店铺审核动作无效。');
    const reason = text(payload.reason, 200, action !== 'APPROVE');
    let result = null;
    const committed = await collection(env, 'Merchant').runTransaction({ apply: async (tx) => {
      const admin = await txOne(tx, env, 'UserProfile', 'uid', uid);
      if (!isAccountActive(admin)) throw accessError('管理员账号已停用。', 'ACCOUNT_INACTIVE');
      const row = await txOne(tx, env, 'Merchant', 'merchantId', text(payload.merchantId, 100, true));
      if (!row || row.sourceType !== 'USER_CONFIRMED') throw accessError('店铺不存在或不是用户地点。', 'NOT_FOUND');
      if (Number(payload.expectedUpdatedAt) !== dateMillis(row.updatedAt)) throw accessError('店铺已变化，请刷新审核。', 'CONFLICT');
      if (row.verificationStatus !== 'USER_CONFIRMED_PENDING') throw accessError('店铺已审核。', 'CONFLICT');
      const system = action === 'APPROVE' ? coordinateSystem(String(payload.coordinateSystem || row.coordinateSystem)) : row.coordinateSystem;
      if (action === 'APPROVE' && system === 'UNKNOWN') throw accessError('审核前须核实选点坐标系。', 'COORDINATE_VERIFICATION_REQUIRED');
      const now = logicalWriteTime(dateMillis(row.updatedAt), admin.updatedAt);
      result = model('Merchant', { ...row, coordinateSystem: system,
        verificationStatus: action === 'APPROVE' ? 'USER_CONFIRMED_APPROVED' : action === 'REJECT' ? 'REJECTED' : 'USER_CONFIRMED_PENDING',
        reviewAction: action, reviewReason: reason, reviewedAt: new Date(now), updatedAt: new Date(now) });
      result.mapVisible = mapEligible(result);
      tx.executeUpsert([result]); tx.executeUpsert([profileForWrite(admin, now)]); return true;
    } });
    if (!committed || !result) throw new Error('店铺审核未保存。');
    return { merchant: merchantView(result) };
  }
  function capabilities(env) { return { friendsPublishEnabled: friendsReady(env),
    pickerCoordinateSystem: coordinateSystem(setting(env, 'SHIKE_MAP_PICKER_COORDINATE_SYSTEM')),
    providerVerificationEnabled: !!setting(env, 'SHIKE_HUAWEI_SITE_API_KEY') && setting(env, 'SHIKE_HUAWEI_POI_VERIFIED') === 'true' }; }
  return { cardFields, storageFields, requireFriendsGate, prepareCounterTransition, prepareAccountCounterRemoval,
    reconcileMerchantPublicCounters, resolveMerchant, createUserMerchant, updateUserMerchant, getMerchant,
    listModerationMerchants, moderateMerchant, capabilities, normalize, mapEligible };
}

module.exports = { createStage2Services };
