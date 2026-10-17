/**
 * 【文件职责】推荐页“发现”功能：能力开关（get-discovery-capabilities）、地图视野内的店铺（list-map-merchants）、
 * 公开卡片搜索与筛选（search-public-cards，按分类 / 价格 / 消费方式 / 排序多路归并分页）、单个店铺的推荐（get-merchant-recommendations）。
 * 分页游标带签名，15 分钟有效；地图与搜索分别受 SHIKE_STAGE3_MAP_VERIFIED / SHIKE_STAGE3_SEARCH_VERIFIED 控制，地图要求 GCJ02 坐标系。
 */
'use strict';

const crypto = require('crypto');
const {afterTuple}=require('./stages47-common');
const { accessError, dateMillis } = require('./shared/content-policy');
const MODES = ['ALL', 'DELIVERY', 'DINE_IN'];
const SORTS = ['LATEST', 'SCORE_DESC', 'PRICE_ASC', 'PRICE_DESC'];
const CATEGORIES = ['RICE_SET', 'NOODLES', 'HOT_POT', 'GRILL_FRIED', 'SNACK', 'FAST_WESTERN', 'BREAKFAST_BAKERY', 'DESSERT', 'DRINK', 'PACKAGED', 'OTHER'];
const CURSOR_TTL = 15 * 60 * 1000;
const digest = (value) => crypto.createHash('sha256').update(JSON.stringify(value)).digest('hex');
const setting = (env, key) => String(env[key] === undefined ? process.env[key] || '' : env[key]);
const enabled = (env, key) => setting(env, key) === 'true';
const invalid = (message) => accessError(message, 'VALIDATION_ERROR');
const stale = () => accessError('查询分页已失效，请保留筛选并刷新。', 'CURSOR_STALE');
const normalize = (value) => String(value || '').normalize('NFKC').trim().replace(/\s+/g, ' ').toLowerCase();
// 解析整数参数（带默认值与上限）。
function integer(value, fallback, max) {
  if (value === undefined) return fallback;
  if (!Number.isSafeInteger(value) || value < 1 || value > max) throw invalid('分页数量无效。');
  return value;
}
// 校验消费方式。
function mode(value) {
  const result = value === undefined ? 'ALL' : value;
  if (!MODES.includes(result)) throw invalid('消费方式无效。');
  return result;
}
// 校验地图视野（范围不能过大）。
function viewport(value, env) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw invalid('区域无效。');
  const { north, south, east, west } = value;
  const configured = Number(setting(env, 'SHIKE_STAGE3_MAX_VIEWPORT_SPAN') || 0.2);
  const span = Number.isFinite(configured) && configured > 0 ? Math.min(configured, 0.2) : 0.2;
  if (![north, south, east, west].every(Number.isFinite) || south < -90 || north > 90 || west < -180 || east > 180 ||
      north <= south || east <= west || north - south > span || east - west > span) {
    throw invalid('请放大地图后再搜索此区域。');
  }
  return { north, south, east, west };
}
// 读取签名游标。
function cursorRead(raw, signature) {
  if (!raw) return null;
  if (typeof raw !== 'string' || raw.length > 8192 || !/^[A-Za-z0-9_-]+$/.test(raw)) throw stale();
  let result;
  try { result = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8')); } catch (_) { throw stale(); }
  if (!result || result.version !== 1 || result.signature !== signature || !Number.isSafeInteger(result.at) ||
      result.at > Date.now() || Date.now() - result.at > CURSOR_TTL) throw stale();
  return result;
}
// 生成签名游标。
function cursorWrite(signature, at, state) {
  return Buffer.from(JSON.stringify({ version: 1, signature, at, ...state })).toString('base64url');
}
// 卡片指纹（变化时游标失效）。
function cardStamp(row) {
  return { id: row.id, price: row.queryPriceFen == null ? null : Number(row.queryPriceFen), score: Number(row.tasteScore),
    published: dateMillis(row.publishedAt), modified: dateMillis(row.modifiedAt), generation: Number(row.lifecycleGeneration || 0) };
}
// 店铺指纹。
function merchantStamp(row) {
  return { merchantId: row.merchantId, latitude: Number(row.latitudeE6), longitude: Number(row.longitudeE6),
    updated: dateMillis(row.updatedAt), mapVisible: row.mapVisible, coordinateSystem: row.coordinateSystem,
    status: row.verificationStatus, total: Number(row.publicRecommendationCount), delivery: Number(row.publicDeliveryCount), dine: Number(row.publicDineInCount) };
}
// 店铺是否符合所选消费方式。
function merchantEligible(row, selectedMode) {
  if (!row || row.mapVisible !== true || row.coordinateSystem !== 'GCJ02' ||
      !['VERIFIED_PROVIDER', 'USER_CONFIRMED_APPROVED'].includes(row.verificationStatus) ||
      !Number.isSafeInteger(row.latitudeE6) || !Number.isSafeInteger(row.longitudeE6) ||
      Math.abs(row.latitudeE6) > 90000000 || Math.abs(row.longitudeE6) > 180000000) return false;
  return Number(row[selectedMode === 'DELIVERY' ? 'publicDeliveryCount' : selectedMode === 'DINE_IN' ? 'publicDineInCount' : 'publicRecommendationCount']) > 0;
}
// 店铺是否在视野内。
function inRegion(row, bounds) {
  return row.latitudeE6 >= bounds.south * 1e6 && row.latitudeE6 <= bounds.north * 1e6 &&
    row.longitudeE6 >= bounds.west * 1e6 && row.longitudeE6 <= bounds.east * 1e6;
}


// 创建模块：ctx 由 runtime.js 注入。
function createStage3Services(ctx) {
  const { collection, one, models, contentPolicy, readableCardRows, readCardIfAllowed } = ctx;
  // 记录能力判断的指标。
  function recordCapabilities(result, facts) {
    ctx.recordReadReadiness('search', result.searchEnabled, result.searchReason, facts);
    ctx.recordReadReadiness('map', result.mapEnabled, result.mapReason, facts);
    return result;
  }
  // 计算能力开关（开关 + 数据覆盖情况 + 坐标系一致性）。
  async function capabilities(env, readiness = null) {
    return ctx.withReadPhase('capabilities', async () => {
      const searchFlag = enabled(env, 'SHIKE_STAGE3_SEARCH_VERIFIED');
      const mapFlag = enabled(env, 'SHIKE_STAGE3_MAP_VERIFIED');
      const facts = { searchVerified: searchFlag, mapVerified: mapFlag };
      if (!searchFlag && !mapFlag) return recordCapabilities({ searchEnabled: false, mapEnabled: false, searchReason: 'VALIDATION_REQUIRED', mapReason: 'VALIDATION_REQUIRED' }, facts);
      // 公开的分类 / 搜索查询只需要卡片数据的覆盖情况，不需要反应数据；没有请求地图就绪状态时复用只读的固定卡片任务。
      const ready = readiness || (mapFlag ? await ctx.stage1().migrationReadiness(env) : {
        cardCoverageComplete: (await ctx.stage1().cardHistoryMaintenance({ mode: 'status' }, env)).ready,
        indexedQueryReady: false
      });
      const indexVerified = enabled(env, 'SHIKE_INDEXED_QUERY_VERIFIED');
      const searchQueryReady = ready.cardCoverageComplete === true && indexVerified;
      Object.assign(facts, { cardCoverageComplete: ready.cardCoverageComplete, reactionCoverageComplete: ready.reactionCoverageComplete,
        indexedQueryReady: ready.indexedQueryReady, searchQueryReady, indexVerified,
        mapCoordinateConfigured: setting(env, 'SHIKE_STAGE3_MAP_COORDINATE_SYSTEM') === 'GCJ02' });
      let mapReady = mapFlag && ready.indexedQueryReady && setting(env, 'SHIKE_STAGE3_MAP_COORDINATE_SYSTEM') === 'GCJ02';
      if (mapReady) {
        // 当已建索引的可靠坐标混用了不同坐标系时，绝不声称视野结果是完整的。
        const mixed = await one(collection(env, 'Merchant').query().equalTo('mapVisible', true).equalTo('coordinateSystem', 'WGS84'));
        Object.assign(facts, { mixedCoordinateDetected: !!mixed });
        if (mixed) mapReady = false;
      }
      return recordCapabilities({ searchEnabled: searchFlag && searchQueryReady, mapEnabled: !!mapReady,
        searchReason: !searchFlag ? 'VALIDATION_REQUIRED' : ready.cardCoverageComplete !== true ? 'CARD_HISTORY_REQUIRED' : !indexVerified ? 'INDEX_VERIFICATION_REQUIRED' : '',
        mapReason: !mapFlag ? 'VALIDATION_REQUIRED' : !ready.indexedQueryReady ? 'HISTORY_OR_INDEX_REQUIRED' : !mapReady ? 'COORDINATE_REQUIRED' : '' }, facts);
    });
  }
  // 功能未开放时抛出 FEATURE_NOT_READY。
  async function requireGate(env, kind, uid) {
    if (uid) await contentPolicy(env).assertAccountActive(uid);
    const caps = await capabilities(env);
    if (!caps[kind + 'Enabled']) throw accessError('此功能尚未完成专项验证，请继续使用公开推荐列表。', 'FEATURE_NOT_READY');
  }
  // 分页查询视野内的店铺。
  async function listMapMerchants(uid, payload, env) {
    await requireGate(env, 'map', uid);
    const bounds = viewport(payload.viewport, env); const selectedMode = mode(payload.mode);
    const limit = integer(payload.limit, 100, 200);
    const configured = Number(setting(env, 'SHIKE_STAGE3_MAP_SCAN_BUDGET') || 1000);
    const budget = Number.isSafeInteger(configured) && configured > 0 ? Math.min(configured, 1000) : 1000;
    const signature = digest({ kind: 'map-range-v2', uid, bounds, selectedMode });
    const saved = cursorRead(payload.cursor, signature); const at = saved ? saved.at : Date.now();
    let boundary = null;
    if (saved) {
      if (!saved.last || typeof saved.last.merchantId !== 'string' || saved.last.merchantId.length > 128) throw stale();
      boundary = await one(collection(env, 'Merchant').query().equalTo('merchantId', saved.last.merchantId));
      if (!boundary || digest(merchantStamp(boundary)) !== digest(saved.last) || boundary.mapVisible !== true ||
        boundary.latitudeE6 < Math.ceil(bounds.south * 1e6) || boundary.latitudeE6 > Math.floor(bounds.north * 1e6)) throw stale();
    }
    const merchants = []; let scanned = 0; let fetched = 0; let exhausted = false;
    while (fetched < budget && merchants.length < limit) {
      const batchLimit = Math.min(50, budget - fetched);
      let query = collection(env, 'Merchant').query().equalTo('mapVisible', true)
        .greaterThanOrEqualTo('latitudeE6', Math.ceil(bounds.south * 1e6)).lessThanOrEqualTo('latitudeE6', Math.floor(bounds.north * 1e6))
        .orderByAsc('latitudeE6').orderByAsc('merchantId');
      if (boundary) query = afterTuple(query,[['latitudeE6','ASC'],['merchantId','ASC']],boundary);
      const rows = await query.limit(batchLimit).get(); fetched += rows.length;
      if (!rows.length) { exhausted = true; break; }
      let consumed = 0;
      for (const row of rows) {
        boundary = row; scanned++; consumed++;
        if (merchantEligible(row, selectedMode) && inRegion(row, bounds)) merchants.push({ merchantId: row.merchantId,
          name: String(row.name || ''), address: String(row.address || '').slice(0, 100), latitude: row.latitudeE6 / 1e6,
          longitude: row.longitudeE6 / 1e6, coordinateSystem: 'GCJ02' });
        if (merchants.length === limit) break;
      }
      if (consumed === rows.length && rows.length < batchLimit) { exhausted = true; break; }
    }
    return { merchants, nextCursor: exhausted ? '' : cursorWrite(signature, at, { last: merchantStamp(boundary) }),
      coverage: exhausted ? 'COMPLETE' : merchants.length === limit ? 'PARTIAL_RESULT_LIMIT' : 'PARTIAL_SCAN_LIMIT',
      scannedCandidateCount: scanned, fetchedCandidateCount: fetched, returnedCount: merchants.length };
  }
  // 把请求解析为查询规格（关键词、分类、价格、排序、消费方式）。
  function querySpec(payload, env, merchantId = '') {
    if (payload.keyword !== undefined && typeof payload.keyword !== 'string') throw invalid('搜索内容无效。');
    const keyword = normalize(payload.keyword);
    if (keyword.length > 50) throw invalid('搜索内容最多 50 字符。');
    const categories = payload.categories === undefined ? [] : payload.categories;
    if (!Array.isArray(categories) || categories.length > 3 || categories.some((x) => !CATEGORIES.includes(x)) || new Set(categories).size !== categories.length) throw invalid('最多选择 3 个有效分类。');
    const sort = payload.sort === undefined ? 'LATEST' : payload.sort;
    if (!SORTS.includes(sort)) throw invalid('排序方式无效。');
    const min = payload.priceMinFen; const max = payload.priceMaxExclusiveFen;
    for (const v of [min, max]) if (v !== undefined && (!Number.isSafeInteger(v) || v < 0 || v > 100000000)) throw invalid('价格区间无效。');
    if (max !== undefined && max <= (min === undefined ? 0 : min)) throw invalid('价格上限必须大于下限。');
    const scope = payload.scope === undefined ? 'ALL_PUBLIC' : payload.scope;
    if (!['ALL_PUBLIC', 'VIEWPORT'].includes(scope)) throw invalid('搜索范围无效。');
    return { keyword, categories: categories.slice().sort(), sort, min: min === undefined ? null : min, max: max === undefined ? null : max,
      scope, viewport: scope === 'VIEWPORT' ? viewport(payload.viewport, env) : null, mode: mode(payload.mode), merchantId };
  }
  // 构造某个分类、某个阶段的有序查询。
  function sortedQuery(spec, category, phase, at, env) {
    // 复用已部署的、以 visibility 开头的索引，不改变它们不可修改的定义。所有写入都使用 PUBLIC；历史数据由有上限的维护任务整理，不需要查询好友权限。
    let q = collection(env, 'FoodCard').query().equalTo('visibility', 'PUBLIC')
      .equalTo('status', 'APPROVED').lessThanOrEqualTo('publishedAt', new Date(at));
    if (spec.mode !== 'ALL') q = q.equalTo('consumptionMode', spec.mode);
    if (category) q = q.equalTo('categoryV2', category);
    if (spec.merchantId) q = q.equalTo('merchantId', spec.merchantId);
    if (spec.keyword) q = q.contains('searchTextNormalized', spec.keyword);
    if (spec.min !== null) q = q.greaterThanOrEqualTo('queryPriceFen', spec.min);
    if (spec.max !== null) q = q.lessThan('queryPriceFen', spec.max);
    if (spec.sort.startsWith('PRICE_')) {
      q = phase === 'unknown' ? q.isNull('queryPriceFen') : q.isNotNull('queryPriceFen');
      if (phase !== 'unknown') q = spec.sort === 'PRICE_ASC' ? q.orderByAsc('queryPriceFen') : q.orderByDesc('queryPriceFen');
    } else if (spec.sort === 'SCORE_DESC') q = q.orderByDesc('tasteScore');
    return q.orderByDesc('publishedAt').orderByAsc('id');
  }
  // 候选行是否满足查询条件。
  function candidateMatches(row, spec, category, phase, at, publicOnly = true) {
    const published = dateMillis(row.publishedAt);
    if (row.visibility !== 'PUBLIC' || row.status !== 'APPROVED' || published === null || published > at ||
      (spec.mode !== 'ALL' && row.consumptionMode !== spec.mode) || (category && row.categoryV2 !== category) ||
      (spec.merchantId && row.merchantId !== spec.merchantId) ||
      (spec.keyword && !String(row.searchTextNormalized || '').includes(spec.keyword))) return false;
    const price = row.queryPriceFen == null ? null : Number(row.queryPriceFen);
    if (spec.min !== null && (price === null || price < spec.min)) return false;
    if (spec.max !== null && (price === null || price >= spec.max)) return false;
    if (spec.sort.startsWith('PRICE_') && (phase === 'unknown' ? price !== null : price === null)) return false;
    return true;
  }
  // 按排序规则比较两行。
  function compare(a, b, spec, phase) {
    let diff = 0;
    if (spec.sort.startsWith('PRICE_') && phase !== 'unknown') diff = (Number(a.queryPriceFen) - Number(b.queryPriceFen)) * (spec.sort === 'PRICE_ASC' ? 1 : -1);
    else if (spec.sort === 'SCORE_DESC') diff = Number(b.tasteScore) - Number(a.tasteScore);
    return diff || dateMillis(b.publishedAt) - dateMillis(a.publishedAt) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  }
  // 搜索 / 店铺推荐的分页实现（多个分类流归并，带扫描上限）。
  async function search(uid, payload, env, merchantId = '') {
    await requireGate(env, merchantId ? 'map' : 'search', uid);
    const spec = querySpec(payload, env, merchantId);
    if (spec.scope === 'VIEWPORT') await requireGate(env, 'map', uid);
    const pageSize = integer(payload.pageSize, 20, 30);
    const signature = digest({ kind: 'cards-range-v3-deployed-indexes', uid, spec });
    const saved = cursorRead(payload.cursor, signature); const at = saved ? saved.at : Date.now();
    const categories = spec.categories.length ? spec.categories : [''];
    let phase = saved ? saved.phase : 'known';
    if (!['known', 'unknown'].includes(phase) || (phase === 'unknown' && (!spec.sort.startsWith('PRICE_') || spec.min !== null || spec.max !== null))) throw stale();
    if (saved && (!Array.isArray(saved.streams) || saved.streams.length !== categories.length)) throw stale();
    let streams = [];
    for (let i = 0; i < categories.length; i++) {
      const position = saved ? saved.streams[i] : { last: null, exhausted: false };
      if (!position || typeof position.exhausted !== 'boolean' || (position.last !== null && (!position.last || typeof position.last !== 'object'))) throw stale();
      let last = null;
      if (position.last) {
        if (typeof position.last.id !== 'string' || position.last.id.length > 128) throw stale();
        last = await one(collection(env, 'FoodCard').query().equalTo('id', position.last.id));
        // 扫描边界上的行可能已被作者状态等策略拒绝，这不能阻止继续翻页。
        if (!last || digest(cardStamp(last)) !== digest(position.last) || !candidateMatches(last, spec, categories[i], phase, at)) throw stale();
      }
      streams.push({ category: categories[i], last, exhausted: position.exhausted, buffer: [] });
    }
    const configured = Number(setting(env, 'SHIKE_STAGE3_CARD_SCAN_BUDGET') || 500);
    const requestedBudget = Number.isSafeInteger(configured) && configured > 0 ? Math.min(configured, 500) : 500;
    // 每次归并时，每个未耗尽的分类流都必须有一个队首元素。
    const budget = Math.max(categories.length, requestedBudget);
    const cards = []; const seen = new Set(); const merchantCache = new Map();
    let fetched = 0; let consumed = 0; let merchantReads = 0; let complete = false; let stopped = false;
    while (cards.length < pageSize && !stopped) {
      for (const stream of streams) {
        if (stream.buffer.length || stream.exhausted) continue;
        if (fetched >= budget) { stopped = true; break; }
        const pendingHeads = streams.filter((s) => !s.buffer.length && !s.exhausted).length;
        const count = Math.min(10, Math.floor((budget - fetched) / pendingHeads));
        if (count < 1) { stopped = true; break; }
        let q = sortedQuery(spec, stream.category, phase, at, env);
        if (stream.last) {
          const order = spec.sort.startsWith('PRICE_') && phase !== 'unknown' ? [['queryPriceFen',spec.sort === 'PRICE_ASC' ? 'ASC':'DESC']] : spec.sort === 'SCORE_DESC' ? [['tasteScore','DESC']] : [];
          q = afterTuple(q,order.concat([['publishedAt','DESC'],['id','ASC']]),stream.last);
        }
        const rows = await q.limit(count).get(); fetched += rows.length;
        stream.buffer = rows;
        stream.readContext = await ctx.createCardReadContext(rows,uid,env);
        const readable = await readableCardRows(rows,uid,env,true,stream.readContext);
        stream.readableIds = new Set(readable.map(row=>row.id));
        await ctx.preparePrimaryPhotos(stream.readContext,readable,env);
        // 只有当已读取的行全部消费完之后，才记录“已耗尽”。
        stream.endOfQuery = rows.length < count;
        if (!rows.length) stream.exhausted = true;
        if (spec.scope === 'VIEWPORT') {
          const ids = [...new Set(rows.map((r) => String(r.merchantId || '')).filter((id) => id && !merchantCache.has(id)))];
          if (ids.length) {
            const merchants = await collection(env, 'Merchant').query().in('merchantId', ids).limit(ids.length).get();
            merchantReads += merchants.length;
            for (const id of ids) merchantCache.set(id, null);
            for (const row of merchants) merchantCache.set(row.merchantId, row);
          }
        }
      }
      if (stopped) break;
      const available = streams.filter((s) => s.buffer.length);
      if (!available.length) {
        if (phase === 'known' && spec.sort.startsWith('PRICE_') && spec.min === null && spec.max === null) {
          phase = 'unknown'; streams = categories.map((category) => ({ category, last: null, exhausted: false, buffer: [] })); continue;
        }
        complete = true; break;
      }
      available.sort((a, b) => compare(a.buffer[0], b.buffer[0], spec, phase));
      const stream = available[0]; const row = stream.buffer.shift(); stream.last = row; consumed++;
      if (!stream.buffer.length && stream.endOfQuery) stream.exhausted = true;
      if (seen.has(row.id) || !String(row.mediaId || '')) continue;
      if (spec.scope === 'VIEWPORT') {
        const merchant = merchantCache.get(row.merchantId);
        if (!merchantEligible(merchant, spec.mode) || !inRegion(merchant, spec.viewport)) continue;
      }
      if (!stream.readableIds.has(row.id)) continue;
      // 复用缓冲区中已读的作者 / 图片数据，同时保留完整的列表结构（评分、点评、优惠与头像）；返回前再检查一次。
      const card = await ctx.readCardIfAllowed(row,env,0,true,uid,false,1,null,stream.readContext);
      if (card) { cards.push(card); seen.add(card.id); }
    }
    // 补全与扫描之后，重新确认整页结果（包括本次调用早先收集到的行）。
    const finalById = new Map();
    for (let offset = 0; offset < cards.length; offset += 10) {
      const ids = cards.slice(offset, offset + 10).map((card) => card.id);
      const rows = await collection(env, 'FoodCard').query().in('id', ids).limit(ids.length).get();
      for (const row of rows) finalById.set(row.id, row);
    }
    const finalReadable = new Set((await readableCardRows([...finalById.values()], uid, env, true)).map((row) => row.id));
    const finalMerchants = new Map();
    if (spec.scope === 'VIEWPORT') {
      const ids = [...new Set([...finalById.values()].map((row) => String(row.merchantId || '')).filter(Boolean))];
      for (let offset = 0; offset < ids.length; offset += 10) {
        const batch = ids.slice(offset, offset + 10);
        const rows = await collection(env, 'Merchant').query().in('merchantId', batch).limit(batch.length).get();
        merchantReads += rows.length;
        for (const row of rows) finalMerchants.set(row.merchantId, row);
      }
    }
    const visibleCards = cards.filter((card) => {
      const latest = finalById.get(card.id);
      if (!latest || !finalReadable.has(card.id) || digest(cardStamp(latest)) !== digest(cardStamp(card))) return false;
      if (spec.scope !== 'VIEWPORT') return true;
      const merchant = finalMerchants.get(latest.merchantId);
      return merchantEligible(merchant, spec.mode) && inRegion(merchant, spec.viewport);
    });
    const verifiedCards = await ctx.finalizeCardReads(visibleCards,[...finalById.values()],uid,env);
    // 刚好在 pageSize 处可能已确定耗尽；否则允许一次无害的空续页。
    if (streams.every((s) => s.exhausted && !s.buffer.length) && (phase === 'unknown' || !spec.sort.startsWith('PRICE_') || spec.min !== null || spec.max !== null)) complete = true;
    return { cards: verifiedCards, nextCursor: complete ? '' : cursorWrite(signature, at, { phase, streams: streams.map((s) => ({ last: s.last ? cardStamp(s.last) : null, exhausted: !!s.exhausted && !s.buffer.length })) }),
      coverage: complete ? 'COMPLETE' : stopped ? 'PARTIAL_SCAN_LIMIT' : 'PARTIAL_RESULT_LIMIT',
      scannedCandidateCount: consumed, fetchedCandidateCount: fetched, merchantReadCount: merchantReads, returnedCount: verifiedCards.length, scope: spec.scope };
  }
  // 单个店铺的推荐卡片。
  async function getMerchantRecommendations(uid, payload, env) {
    await requireGate(env, 'map', uid);
    if (typeof payload.merchantId !== 'string' || !payload.merchantId || payload.merchantId.length > 128) throw invalid('店铺标识无效。');
    const merchant = await one(collection(env, 'Merchant').query().equalTo('merchantId', payload.merchantId));
    if (!merchantEligible(merchant, mode(payload.mode))) throw accessError('店铺当前没有可展示的公开推荐，请刷新地图。', 'MERCHANT_UNAVAILABLE');
    // 店铺面板刻意忽略分类、价格与关键词筛选。
    const page = await search(uid, { mode: payload.mode, cursor: payload.cursor, pageSize: payload.pageSize, sort: 'LATEST' }, env, merchant.merchantId);
    return { ...page, merchant: { merchantId: merchant.merchantId, name: String(merchant.name || ''),
      address: String(merchant.address || '').slice(0, 100), latitude: merchant.latitudeE6 / 1e6,
      longitude: merchant.longitudeE6 / 1e6, coordinateSystem: 'GCJ02' } };
  }
  return { capabilities, listMapMerchants, searchPublicCards: search, getMerchantRecommendations,
    querySpec, matchesHardFilters: (row, spec, at) => (spec.categories.length === 0 || spec.categories.includes(row.categoryV2)) && candidateMatches(row, spec, '', 'known', at, false) };
}

module.exports = { createStage3Services };
