'use strict';
const { dateMillis } = require('./shared/content-policy');
const { fail, hash, flag, id, token, encode } = require('./stages47-common');

const TOP_LIMIT = 50;
const PAGE_SIZE = 20;
const RESULT_TTL_MS = 5 * 60 * 1000;
const CARD_SCAN_BUDGET = 200;
const SCOPE = 'ALL_VISIBLE';
const cardStamp = row => hash([row.id, row.ownerUid, row.merchantId, Number(row.tasteScore), dateMillis(row.publishedAt),
  dateMillis(row.modifiedAt), Number(row.updatedAt), Number(row.lifecycleGeneration || 0), row.status, row.reviewState,
  dateMillis(row.deletedAt), dateMillis(row.purgeAt)]);
const compare = (a, b) => b.score - a.score || b.publishedAt - a.publishedAt ||
  (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
const stale = () => fail('榜单内容已变化，请刷新榜单。', 'CURSOR_STALE');

function createFoodRankingServices(ctx) {
  const { collection, one } = ctx;
  async function capability(env, readiness) {
    const reason = !flag(env, 'SHIKE_FOOD_RANKINGS_VERIFIED') ? '新榜单尚未完成上线验证' :
      !readiness.cardCoverageComplete ? '卡片历史回填尚未完成' :
      !flag(env, 'SHIKE_INDEXED_QUERY_VERIFIED') ? '查询索引尚未验证' : '';
    return { enabled: !reason, reason };
  }
  async function friends(uid, env) {
    return new Set((await ctx.friendshipRowsFor(uid, env)).filter(row => row.status === 'ACCEPTED')
      .map(row => row.memberAUid === uid ? row.memberBUid : row.memberAUid).filter(owner => owner !== uid));
  }
  async function assertFriends(uid, kind, expected, env) {
    if (kind === 'FRIENDS' && hash([...await friends(uid, env)].sort()) !== expected) throw stale();
  }
  function response(state, items, nextCursor) {
    return { phase: state.phase === 'READY' ? 'READY' : 'PREPARING', kind: state.kind, scope: SCOPE, items,
      totalCount: state.phase === 'READY' ? state.best.length : 0, nextCursor,
      snapshotAt: state.snapshotAt, updatedAt: state.updatedAt || 0, scannedCardCount: state.scannedCards };
  }
  async function validateBest(uid, state, env) {
    const rows = await ctx.readCardRowsByIds(state.best.map(entry => entry.id), env);
    const ordered = state.best.map(entry => rows.get(entry.id)).filter(Boolean);
    const context = await ctx.createCardReadContext(ordered, uid, env);
    const readable = new Set((await ctx.readableCardRows(ordered, uid, env, true, context)).map(row => row.id));
    for (const entry of state.best) {
      const row = rows.get(entry.id);
      if (!row || !readable.has(entry.id) || cardStamp(row) !== entry.cardStamp) throw stale();
    }
    await assertFriends(uid, state.kind, state.friendHash, env);
    return { rows, context };
  }
  async function page(uid, state, signature, env) {
    if (Date.now() - state.updatedAt >= RESULT_TTL_MS) throw stale();
    const { rows, context } = await validateBest(uid, state, env);
    const entries = state.best.slice(state.offset, state.offset + PAGE_SIZE);
    const sources = entries.map(entry => rows.get(entry.id));
    await ctx.preparePrimaryPhotos(context, sources, env);
    const cards = await Promise.all(sources.map(row => ctx.readCardIfAllowed(row, env,
      null, true, uid, false, 1, null, context)));
    if (cards.some(card => !card)) throw stale();
    const fresh = await ctx.finalizeCardReads(cards, sources, uid, env, state.kind === 'FRIENDS');
    if (fresh.length !== cards.length) throw stale();
    const merchants = await ctx.readMerchantRowsByIds(entries.map(entry => entry.merchantId).filter(Boolean), env);
    await validateBest(uid, state, env);
    const items = cards.map((card, index) => ({ rank: state.offset + index + 1, card,
      merchantName: String(merchants.get(entries[index].merchantId)?.name || card.shop || '') }));
    const offset = state.offset + items.length;
    return response(state, items, offset < state.best.length ? encode(signature, state.updatedAt, { ...state, offset }) : '');
  }
  async function list(uid, payload, env) {
    if (uid) await ctx.contentPolicy(env).assertAccountActive(uid);
    const caps = await capability(env, await ctx.stage1().migrationReadiness(env));
    if (!caps.enabled) throw fail(caps.reason + '，请先完成部署验证。', 'FEATURE_NOT_READY');
    const kind = payload.kind;
    if (!['HIGH_SCORE', 'FRIENDS'].includes(kind)) throw fail('榜单类型无效。');
    if (kind === 'FRIENDS' && !uid) throw fail('登录后查看好友推荐榜。', 'AUTH_REQUIRED');
    const owners = kind === 'FRIENDS' ? await friends(uid, env) : null;
    const friendHash = owners ? hash([...owners].sort()) : '';
    const signature = hash(['food-ranking-v2-global', uid, kind, friendHash]);
    let state = token(payload.cursor, signature) || { phase: 'BUILD', kind, snapshotAt: Date.now(),
      friendHash, best: [], cardAfter: null, scannedCards: 0, offset: 0 };
    if (!Array.isArray(state.best) || state.best.length > TOP_LIMIT || !['BUILD', 'READY'].includes(state.phase) ||
      state.kind !== kind || !Number.isSafeInteger(state.offset) || state.offset < 0 || state.offset > state.best.length) throw stale();
    if (state.phase === 'READY') return page(uid, state, signature, env);
    // Primary-key continuation needs no merchant coordinates or additional index.
    // Each request is bounded, but every candidate is considered before ranking.
    let query = collection(env, 'FoodCard').query();
    if (state.cardAfter) {
      const previous = await one(collection(env, 'FoodCard').query().equalTo('id', id(state.cardAfter.id)));
      if (!previous || cardStamp(previous) !== state.cardAfter.stamp) throw stale();
      query = query.greaterThan('id', state.cardAfter.id);
    }
    const rows = owners && owners.size === 0 ? [] : await query.orderByAsc('id').limit(CARD_SCAN_BUDGET).get();
    state.scannedCards += rows.length;
    const candidates = rows.filter(row => row.status === 'APPROVED' && Number.isSafeInteger(row.tasteScore) &&
      row.tasteScore >= 1 && row.tasteScore <= 10 && dateMillis(row.publishedAt) !== null &&
      dateMillis(row.publishedAt) <= state.snapshotAt && (!owners || owners.has(row.ownerUid)));
    const context = await ctx.createCardReadContext(candidates, uid, env);
    const readable = new Set((await ctx.readableCardRows(candidates, uid, env, true, context)).map(row => row.id));
    for (const row of candidates) {
      if (!readable.has(row.id)) continue;
      state.best.push({ id: row.id, merchantId: row.merchantId || '', score: row.tasteScore,
        publishedAt: dateMillis(row.publishedAt), cardStamp: cardStamp(row) });
      state.best.sort(compare); state.best = state.best.slice(0, TOP_LIMIT);
    }
    if (rows.length) {
      const last = rows[rows.length - 1];
      state.cardAfter = { id: last.id, stamp: cardStamp(last) };
    }
    await assertFriends(uid, kind, friendHash, env);
    if (rows.length === CARD_SCAN_BUDGET) return response(state, [], encode(signature, state.snapshotAt, state));
    state = { ...state, phase: 'READY', updatedAt: Date.now(), offset: 0, cardAfter: null };
    return page(uid, state, signature, env);
  }
  return { capability, list };
}

module.exports = { createFoodRankingServices, compare };
