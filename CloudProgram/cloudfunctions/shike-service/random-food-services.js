'use strict';
const crypto = require('crypto');
const { isAccountActive, readableCardState, dateMillis } = require('./shared/content-policy');
const { fail, hash, id, uuid, token, encode, afterTuple } = require('./stages47-common');
const SOURCES = ['MY', 'PUBLIC', 'FRIENDS'];
function source(value) {
  if (!SOURCES.includes(value)) throw fail('推荐来源无效。');
  return value;
}
function shuffle(values) {
  const result = values.slice();
  for (let i = result.length - 1; i > 0; i--) {
    const j = crypto.randomInt(i + 1);
    [result[i], result[j]] = [result[j], result[i]];
  }
  return result;
}
function createRandomFoodServices(ctx) {
  const { collection, models } = ctx;
  const model = (name, row) => Object.assign(new models[name](), row);
  async function requireSource(uid, selected, env) {
    if (selected !== 'PUBLIC' && !uid) throw fail('此来源需要登录。', 'AUTH_REQUIRED');
    if (uid) await ctx.contentPolicy(env).assertAccountActive(uid);
    if (selected === 'MY' && !(await ctx.collections().status(uid, env)).collectionReady)
      throw fail('请先在收藏中完成历史整理。', 'COLLECTION_MIGRATING');
  }
  async function sourceMatches(uid, selected, rows, env) {
    if (selected === 'PUBLIC') return rows;
    if (selected === 'FRIENDS') {
      const relations = await ctx.friendshipRowsFor(uid, env);
      const owners = new Set(relations.filter(row => row.status === 'ACCEPTED')
        .map(row => row.memberAUid === uid ? row.memberBUid : row.memberAUid));
      return rows.filter(row => owners.has(row.ownerUid));
    }
    const referenceIds = rows.flatMap(row => ['WANT_TO_EAT', 'FAVORITE'].map(kind => ctx.actionId('card:' + kind, uid, row.id)));
    const present = new Set();
    for (let start = 0; start < referenceIds.length; start += 10) {
      const batch = referenceIds.slice(start, start + 10);
      const refs = await collection(env, 'CardAction').query().in('id', batch).limit(batch.length).get();
      for (const ref of refs) if (ref.actorUid === uid && ['WANT_TO_EAT', 'FAVORITE'].includes(ref.kind)) present.add(ref.cardId);
    }
    return rows.filter(row => present.has(row.id));
  }
  async function currentRows(uid, selected, rows, env) {
    const matched = await sourceMatches(uid, selected, rows.filter(readableCardState), env);
    if (!matched.length) return [];
    const context = await ctx.createCardReadContext(matched, uid, env);
    return ctx.readableCardRows(matched, uid, env, true, context);
  }
  async function pool(uid, payload, env) {
    const selected = source(payload.source), roundId = uuid(payload.roundId);
    await requireSource(uid, selected, env);
    let rows = [], rangeLabel = '', scanned = 0;
    if (selected === 'MY') {
      const [wanted, favorites] = await Promise.all(['WANT_TO_EAT', 'FAVORITE'].map(kind =>
        collection(env, 'CardAction').query().equalTo('actorUid', uid).equalTo('kind', kind)
          .orderByDesc('createdAt').orderByAsc('id').limit(150).get()));
      const ids = [...new Set([...wanted, ...favorites].map(row => row.cardId).filter(Boolean))];
      scanned = wanted.length + favorites.length;
      const byId = await ctx.readCardRowsByIds(ids, env);
      rows = ids.map(cardId => byId.get(cardId)).filter(Boolean);
      rangeLabel = '想吃、收藏各最近最多150条引用，去重后准备本轮';
    } else if (selected === 'PUBLIC') {
      rows = await collection(env, 'FoodCard').query().equalTo('status', 'APPROVED').orderByDesc('createdAt').orderByAsc('id').limit(300).get();
      scanned = rows.length;
      rangeLabel = '从最近最多300张已发布卡片准备本轮';
    } else {
      const relations = await ctx.friendshipRowsFor(uid, env);
      const owners = shuffle([...new Set(relations.filter(row => row.status === 'ACCEPTED')
        .map(row => row.memberAUid === uid ? row.memberBUid : row.memberAUid))]).slice(0, 30);
      for (let start = 0; start < owners.length; start += 3) {
        const pages = await Promise.all(owners.slice(start, start + 3).map(ownerUid =>
          collection(env, 'FoodCard').query().equalTo('ownerUid', ownerUid).equalTo('status', 'APPROVED')
            .orderByDesc('createdAt').orderByAsc('id').limit(10).get()));
        rows.push(...pages.flat());
      }
      scanned = rows.length;
      rangeLabel = '最多30位随机好友，每位最近最多10张卡片';
    }
    const unique = [...new Map(rows.map(row => [row.id, row])).values()];
    const readable = await currentRows(uid, selected, unique, env);
    const cardIds = shuffle(readable.map(row => row.id)).slice(0, 60);
    await requireSource(uid, selected, env);
    return { source: selected, roundId, cardIds, poolSize: cardIds.length, poolLimit: 60,
      rangeLabel, preparedAt: Date.now(), scannedCandidateCount: scanned, coverage: 'BOUNDED' };
  }
  async function cards(uid, payload, env) {
    const selected = source(payload.source);
    await requireSource(uid, selected, env);
    uuid(payload.drawId);
    if (!Array.isArray(payload.cardIds) || payload.cardIds.length < 1 || payload.cardIds.length > 3 ||
        new Set(payload.cardIds).size !== payload.cardIds.length) throw fail('每次最多读取三张不同卡片。');
    const ids = payload.cardIds.map(id), byId = await ctx.readCardRowsByIds(ids, env);
    const rows = await currentRows(uid, selected, ids.map(cardId => byId.get(cardId)).filter(Boolean), env);
    const context = await ctx.createCardReadContext(rows, uid, env);
    await ctx.preparePrimaryPhotos(context, rows, env);
    const results = rows.map(row => ({ ...ctx.previewCard(row, context, env), shop: String(row.shop || '') }));
    const fresh = await ctx.finalizeCardReads(results, rows, uid, env);
    const freshById = await ctx.readCardRowsByIds(fresh.map(card => card.id), env);
    const allowed = new Set((await currentRows(uid, selected, [...freshById.values()], env)).map(row => row.id));
    await requireSource(uid, selected, env);
    const output = fresh.filter(card => allowed.has(card.id));
    return { cards: output, unavailableCardIds: ids.filter(cardId => !output.some(card => card.id === cardId)) };
  }
  async function saveChoice(uid, payload, env) {
    const selected = source(payload.source), drawId = uuid(payload.drawId), roundId = uuid(payload.roundId), cardId = id(payload.cardId);
    await requireSource(uid, selected, env);
    const historyId = hash(['food-choice-v1', uid, drawId]);
    let output = null;
    const committed = await collection(env, 'MealChoiceHistory').runTransaction({ apply: async tx => {
      output = null;
      const read = async (name, field, value) => (await tx.executeQuery(collection(env, name).query().equalTo(field, value).limit(1)))[0] || null;
      const owner = await read('UserProfile', 'uid', uid);
      if (!isAccountActive(owner)) throw fail('账号已停用。', 'ACCOUNT_INACTIVE');
      const existing = await read('MealChoiceHistory', 'historyId', historyId);
      if (existing) {
        if (existing.uid !== uid || existing.cardId !== cardId || existing.source !== selected || existing.roundId !== roundId)
          throw fail('本组三张已经确认了其他选择。', 'CONFLICT');
        output = { historyId, selectedAt: dateMillis(existing.selectedAt), deleted: existing.deletedAt != null };
        return true;
      }
      const card = await read('FoodCard', 'id', cardId), author = card ? await read('UserProfile', 'uid', card.ownerUid) : null;
      if (!readableCardState(card) || !isAccountActive(author)) throw fail('卡片已不可用，未保存选择。', 'CONTENT_UNAVAILABLE');
      if (selected === 'MY') {
        const wanted = await read('CardAction', 'id', ctx.actionId('card:WANT_TO_EAT', uid, cardId));
        const favorite = await read('CardAction', 'id', ctx.actionId('card:FAVORITE', uid, cardId));
        if (!wanted && !favorite) throw fail('这张卡片已不在你的想吃或收藏中。', 'CONTENT_UNAVAILABLE');
      }
      if (selected === 'FRIENDS') {
        const relation = await read('Friendship', 'id', ctx.socialPairId('friend', uid, card.ownerUid));
        if (!relation || relation.status !== 'ACCEPTED') throw fail('作者已不是当前好友。', 'CONTENT_UNAVAILABLE');
      }
      const now = new Date();
      tx.executeUpsert([model('MealChoiceHistory', { historyId, uid, cardId, merchantId: String(card.merchantId || ''),
        consumptionMode: String(card.consumptionMode || 'UNSPECIFIED'), selectedAt: now, source: selected, roundId, drawId, deletedAt: null })]);
      output = { historyId, selectedAt: now.getTime(), deleted: false };
      return true;
    } });
    if (!committed || !output) throw fail('选择尚未保存，请重试。', 'REQUEST_FAILED');
    return output;
  }
  async function history(uid, payload, env) {
    await ctx.contentPolicy(env).assertAccountActive(uid);
    const signature = hash(['food-choice-history-v1', uid]), saved = token(payload.cursor, signature), at = saved ? saved.at : Date.now();
    let query = collection(env, 'MealChoiceHistory').query().equalTo('uid', uid).isNull('deletedAt')
      .lessThanOrEqualTo('selectedAt', new Date(at));
    if (saved) {
      if (!Number.isSafeInteger(saved.selectedAt) || saved.selectedAt < 0 || saved.selectedAt > at) throw fail('记录分页失效，请刷新。', 'CURSOR_STALE');
      query = afterTuple(query, [['selectedAt', 'DESC'], ['historyId', 'ASC']], { selectedAt: new Date(saved.selectedAt), historyId: id(saved.historyId) });
    }
    const rows = await query.orderByDesc('selectedAt').orderByAsc('historyId').limit(21).get(), page = rows.slice(0, 20);
    const byId = await ctx.readCardRowsByIds(page.map(row => row.cardId), env);
    const readable = await currentRows(uid, 'PUBLIC', [...byId.values()], env), context = await ctx.createCardReadContext(readable, uid, env);
    await ctx.preparePrimaryPhotos(context, readable, env);
    const previews = await ctx.finalizeCardReads(readable.map(row => ({ ...ctx.previewCard(row, context, env), shop: String(row.shop || '') })), readable, uid, env);
    const currentCards = new Map(previews.map(card => [card.id, card]));
    const latest = [];
    for (let start = 0; start < page.length; start += 10) {
      const batch = page.slice(start, start + 10).map(row => row.historyId);
      latest.push(...await collection(env, 'MealChoiceHistory').query().in('historyId', batch).limit(batch.length).get());
    }
    const visibleIds = new Set(latest.filter(row => row.uid === uid && row.deletedAt == null).map(row => row.historyId));
    await ctx.contentPolicy(env).assertAccountActive(uid);
    const items = page.filter(row => visibleIds.has(row.historyId)).map(row => ({ historyId: row.historyId, source: SOURCES.includes(row.source) ? row.source : 'PUBLIC',
      selectedAt: dateMillis(row.selectedAt) || 0, card: currentCards.get(row.cardId) || null }));
    const last = page[page.length - 1];
    return { items, nextCursor: rows.length > 20 && last ? encode(signature, at, { selectedAt: dateMillis(last.selectedAt), historyId: last.historyId }) : '' };
  }
  async function deleteChoice(uid, payload, env) {
    const historyId = id(payload.historyId);
    const committed = await collection(env, 'MealChoiceHistory').runTransaction({ apply: async tx => {
      const owner = await ctx.stage1().txOne(tx, env, 'UserProfile', 'uid', uid);
      if (!isAccountActive(owner)) throw fail('账号已停用。', 'ACCOUNT_INACTIVE');
      const row = await ctx.stage1().txOne(tx, env, 'MealChoiceHistory', 'historyId', historyId);
      if (row && row.uid !== uid) throw fail('无权删除该记录。', 'FORBIDDEN');
      if (row && row.deletedAt == null) tx.executeUpsert([model('MealChoiceHistory', { ...row, deletedAt: new Date() })]);
      return true;
    } });
    if (!committed) throw fail('删除尚未完成，请重试。', 'REQUEST_FAILED');
    return { success: true };
  }
  return { pool, cards, saveChoice, history, deleteChoice };
}
module.exports = { createRandomFoodServices };
