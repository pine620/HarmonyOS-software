'use strict';

const { fail, hash, flag, id, uuid } = require('./stages47-common');
const { dateMillis, isAccountActive } = require('./shared/content-policy');
const REACTIONS = ['', 'LIKE', 'DISLIKE'];
const DAY = 86400000;

// Latency design (2026-10-15):
// - Cloud DB transactions are optimistic: every row read through tx.executeQuery
//   is version-checked at commit and the SDK re-runs apply() on conflict. Rows
//   read in the transaction therefore already guard against concurrent card or
//   account changes; rewriting FoodCard/UserProfile only created hot-row conflicts.
// - The per account x card CardReaction row is the write guard and the version.
//   It is kept with reaction '' after a cancel so its version never goes back.
// - Totals use server-side countQuery on existing indexes instead of paging rows.
function createCardInteractionServices(ctx) {
  const { collection, one } = ctx;
  const receiptKey = (uid, requestId) => hash(['card-interaction-v3', uid, requestId]);
  const trace = (requestId, stage, started, extra = '') => console.info('[CardInteractionCloud] requestId=' + requestId +
    ' stage=' + stage + ' elapsedMs=' + (Date.now() - started) + extra);
  const model = (name, value) => ctx.stage1().model(name, value);
  const settle = promise => Promise.resolve(promise).then(value => ({ value, error: null }), error => ({ value: undefined, error }));

  function spec(payload) {
    const cardId = id(payload.cardId), requestId = uuid(payload.requestId);
    const patch = payload.patch;
    if (!patch || typeof patch !== 'object' || Array.isArray(patch) ||
        Object.keys(patch).some(key => !['reaction', 'favorited'].includes(key))) throw fail('互动内容无效。');
    const reaction = patch.reaction === 'NONE' ? '' : patch.reaction;
    if (reaction !== undefined && !REACTIONS.includes(reaction)) throw fail('赞踩状态无效。');
    if (patch.favorited !== undefined && typeof patch.favorited !== 'boolean') throw fail('收藏状态无效。');
    if (reaction === undefined && patch.favorited === undefined) throw fail('请选择一个互动操作。');
    const expected = payload.expected;
    if (!expected || typeof expected !== 'object' || Array.isArray(expected) ||
        !Number.isSafeInteger(expected.writeVersion) || expected.writeVersion < 0 ||
        reaction !== undefined && !REACTIONS.includes(expected.myReaction) ||
        patch.favorited !== undefined && typeof expected.viewerFavorited !== 'boolean') throw fail('互动基准状态无效。');
    const fields = { reaction, favorited: patch.favorited };
    const base = { writeVersion: expected.writeVersion,
      myReaction: reaction === undefined ? undefined : expected.myReaction,
      viewerFavorited: patch.favorited === undefined ? undefined : expected.viewerFavorited };
    return { cardId, requestId, patch: fields, expected: base,
      payloadHash: hash([cardId, fields, base]) };
  }
  function parsedReceipt(row, uid, cardId, requestId, payloadHash) {
    if (!row) return null;
    if (row.uid !== uid || row.operationType !== 'CARD_INTERACTION_V3' || row.resultEntityId !== cardId ||
        row.status !== 'COMMITTED' || payloadHash && row.payloadHash !== payloadHash) throw fail('请求标识已用于其他操作。', 'CONFLICT');
    let result;
    try { result = JSON.parse(String(row.resultJson || '')); } catch (_) { throw fail('互动回执不可读取，请核对部署版本。', 'INVALID_STATE'); }
    if (!result || result.protocolVersion !== 3 || result.cardId !== cardId || result.requestId !== requestId ||
        !['COMMITTED', 'UNCHANGED'].includes(result.status) || !REACTIONS.includes(result.myReaction) ||
        typeof result.viewerFavorited !== 'boolean' || !Number.isSafeInteger(result.writeVersion) || result.writeVersion < 0) {
      throw fail('互动回执状态无效。', 'INVALID_STATE');
    }
    return result;
  }
  async function gates(uid, env) {
    // A broken checkpoint in one group must not disable the other group.
    const [reaction, favorite] = await Promise.all([
      (async () => {
        try {
          const history = await ctx.stage1().reactionHistoryMaintenance({ mode: 'status' }, env);
          const enabled = history.ready === true && flag(env, 'SHIKE_REACTION_VERIFIED');
          return { reactionsEnabled: enabled,
            reactionsReason: !history.ready ? '赞踩历史整理尚未完成。' : !enabled ? '赞踩尚未完成上线验证。' : '' };
        } catch (_) {
          console.warn('[CardInteractionCloud] stage=reaction_gate_read_failed');
          return { reactionsEnabled: false, reactionsReason: '赞踩服务状态读取失败，请刷新重试。' };
        }
      })(),
      (async () => {
        const enabled = ctx.collections().enabled(env);
        if (!enabled) return { collectionEnabled: false, collectionReady: false, collectionReason: '收藏服务暂未开放。' };
        try {
          const migration = await ctx.collections().status(uid, env);
          return { collectionEnabled: true, collectionReady: migration.collectionReady === true,
            collectionReason: !migration.collectionReady ? '请先完成旧收藏整理。' : '' };
        } catch (_) {
          console.warn('[CardInteractionCloud] stage=collection_gate_read_failed');
          return { collectionEnabled: true, collectionReady: false, collectionReason: '收藏服务状态读取失败，请刷新重试。' };
        }
      })()
    ]);
    return { ...reaction, ...favorite };
  }
  function reactionRowQuery(env, cardId, uid) {
    return collection(env, 'CardReaction').query().equalTo('cardId', cardId).equalTo('uid', uid).limit(1);
  }
  function ownRowsQuery(env, cardId, uid, kind) {
    return collection(env, 'CardAction').query().equalTo('cardId', cardId).equalTo('actorUid', uid).equalTo('kind', kind).limit(51);
  }
  function bounded(rows) {
    if (rows.length >= 51) throw fail('旧互动记录过多，请先整理后再操作。', 'MIGRATION_REQUIRED');
    return rows;
  }
  function ownReaction(row, likes) {
    if (row && !REACTIONS.includes(row.reaction)) throw fail('已有赞踩记录无效，请先核对历史数据。', 'INVALID_STATE');
    return row ? row.reaction : likes.length ? 'LIKE' : '';
  }
  // Per account x card version. Date fields round-trip with millisecond precision
  // in this SDK (written as epoch ms, read back as "yyyy-MM-dd HH:mm:ss SSS" UTC).
  function rowVersion(row) {
    if (!row) return 0;
    const updated = dateMillis(row.updatedAt);
    if (updated !== null) return updated;
    const created = dateMillis(row.createdAt);
    return created === null ? 0 : created;
  }
  function sameRow(before, after) {
    return !!before === !!after && rowVersion(before) === rowVersion(after) &&
      (!before || String(before.reaction) === String(after.reaction));
  }
  async function historyReady(env) {
    try { return (await ctx.stage1().reactionHistoryMaintenance({ mode: 'status' }, env)).ready === true; }
    catch (_) { return false; }
  }
  async function countOf(query, field) {
    if (typeof query.countQuery !== 'function') throw new Error('countQuery unavailable');
    const value = Number(await query.countQuery(field));
    if (!Number.isSafeInteger(value) || value < 0) throw fail('统计结果无效。', 'INVALID_STATE');
    return value;
  }
  // Server-side COUNT on the existing (cardId, reaction, uid) and (cardId, kind, id)
  // indexes. CardReaction's primary key is (cardId, uid); every FAVORITE writer
  // uses the deterministic actionId, so each counted row is one distinct account.
  function countTotals(cardId, env) {
    return Promise.all([
      countOf(collection(env, 'CardReaction').query().equalTo('cardId', cardId).equalTo('reaction', 'LIKE'), 'uid'),
      countOf(collection(env, 'CardReaction').query().equalTo('cardId', cardId).equalTo('reaction', 'DISLIKE'), 'uid'),
      countOf(collection(env, 'CardAction').query().equalTo('cardId', cardId).equalTo('kind', 'FAVORITE'), 'id')
    ]).then(([likeCount, dislikeCount, favoriteCount]) => ({ likeCount, dislikeCount, favoriteCount }));
  }
  async function totals(cardId, uid, env, ready, counted) {
    if (ready && counted) {
      const fast = await counted;
      if (!fast.error) return fast.value;
      console.warn('[CardInteractionCloud] stage=count_query_fallback code=' + String(fast.error && fast.error.code || 'UNKNOWN'));
    }
    // Legacy LIKE history not yet merged, or COUNT unavailable: exact scan path.
    const result = await ctx.stage1().reactionSummary(cardId, uid, env, { historyComplete: ready, includePrivateFlags: false });
    return { likeCount: result.likeCount, dislikeCount: result.dislikeCount, favoriteCount: result.favoriteCount };
  }

  async function state(uid, payload, env) {
    const cardId = id(payload.cardId), policy = ctx.contentPolicy(env);
    for (let attempt = 0; attempt < 2; attempt++) {
      // Phase 1: gates, account, card and the version row in parallel.
      const [caps, owner, card, before] = await Promise.all([gates(uid, env),
        one(collection(env, 'UserProfile').query().equalTo('uid', uid)),
        one(collection(env, 'FoodCard').query().equalTo('id', cardId)), one(reactionRowQuery(env, cardId, uid))]);
      if (!isAccountActive(owner)) throw fail('账号已不可用。', 'ACCOUNT_INACTIVE');
      // Phase 2 starts after the version row was read, so an unchanged version
      // after phase 2 proves the relation reads belong to one committed state.
      const [, likes, favorites] = await Promise.all([policy.assertCardReadable(uid, card),
        ownRowsQuery(env, cardId, uid, 'LIKE').get(), ownRowsQuery(env, cardId, uid, 'FAVORITE').get()]);
      bounded(likes); bounded(favorites);
      const after = await one(reactionRowQuery(env, cardId, uid));
      if (!sameRow(before, after)) continue;
      return { protocolVersion: 3, cardId, myReaction: ownReaction(after, likes),
        viewerFavorited: favorites.length > 0, writeVersion: rowVersion(after), ...caps };
    }
    throw fail('互动状态正在变化，请重试读取。', 'STALE_VERSION');
  }
  async function set(uid, payload, env) {
    const started = Date.now(), input = spec(payload), key = receiptKey(uid, input.requestId);
    trace(input.requestId, 'gate', started);
    const [existing, history] = await Promise.all([
      one(collection(env, 'PublishRequestRecord').query().equalTo('requestId', key)),
      input.patch.reaction === undefined ? Promise.resolve(null) :
        settle(ctx.stage1().reactionHistoryMaintenance({ mode: 'status' }, env))]);
    if (existing) {
      // Completed receipts remain recoverable even if a release gate closes later.
      const policy = ctx.contentPolicy(env);
      const [, card] = await Promise.all([policy.assertAccountActive(uid),
        one(collection(env, 'FoodCard').query().equalTo('id', input.cardId))]);
      await policy.assertCardReadable(uid, card);
      return parsedReceipt(existing, uid, input.cardId, input.requestId, input.payloadHash);
    }
    if (input.patch.reaction !== undefined) {
      if (!flag(env, 'SHIKE_REACTION_VERIFIED')) throw fail('赞踩尚未完成上线验证。', 'FEATURE_NOT_READY');
      if (history.error) throw history.error;
      if (!history.value || history.value.ready !== true) throw fail('赞踩历史整理尚未完成。', 'FEATURE_NOT_READY');
    }
    let result = null, attempts = 0;
    trace(input.requestId, 'transaction_start', started);
    const committed = await collection(env, 'CardReaction').runTransaction({ apply: async tx => {
      result = null; attempts++;
      const s1 = ctx.stage1();
      // One round trip for every independent read; each row read here is
      // version-checked by the SDK at commit.
      const [owner, card, saved, rows, likes, favorites, writable] = await Promise.all([
        s1.activeProfile(tx, uid, env),
        s1.txOne(tx, env, 'FoodCard', 'id', input.cardId),
        s1.txOne(tx, env, 'PublishRequestRecord', 'requestId', key),
        tx.executeQuery(reactionRowQuery(env, input.cardId, uid)),
        tx.executeQuery(ownRowsQuery(env, input.cardId, uid, 'LIKE')),
        tx.executeQuery(ownRowsQuery(env, input.cardId, uid, 'FAVORITE')),
        input.patch.favorited === undefined ? Promise.resolve(null) : settle(ctx.collections().assertWritable(tx, uid, env))
      ]);
      await ctx.transactionPolicy(tx, env, [owner]).assertCardReadable(uid, card);
      if (saved) { result = parsedReceipt(saved, uid, input.cardId, input.requestId, input.payloadHash); return true; }
      if (writable && writable.error) throw writable.error;
      bounded(likes); bounded(favorites);
      const row = rows[0] || null;
      const previousReaction = ownReaction(row, likes), previousFavorite = favorites.length > 0;
      const nextReaction = input.patch.reaction === undefined ? previousReaction : input.patch.reaction;
      const nextFavorite = input.patch.favorited === undefined ? previousFavorite : input.patch.favorited;
      const changed = nextReaction !== previousReaction || nextFavorite !== previousFavorite;
      // Value compare-and-set on the groups this patch touches. An unrelated
      // account write (another card, profile edit) is no longer a conflict.
      if (changed && (input.patch.reaction !== undefined && input.expected.myReaction !== previousReaction ||
          input.patch.favorited !== undefined && input.expected.viewerFavorited !== previousFavorite)) {
        throw fail('互动状态已在其他位置变化，请重新选择。', 'STALE_VERSION');
      }
      const now = ctx.logicalWriteTime(row ? rowVersion(row) : null);
      const favoriteId = ctx.actionId('card:FAVORITE', uid, input.cardId);
      const deletes = [], creates = [];
      if (input.patch.reaction !== undefined) deletes.push(...likes);
      if (input.patch.favorited !== undefined) {
        deletes.push(...favorites.filter(item => !nextFavorite || item.id !== favoriteId));
        if (nextFavorite && !favorites.some(item => item.id === favoriteId)) creates.push(model('CardAction', { id: favoriteId,
          actorUid: uid, cardId: input.cardId, kind: 'FAVORITE', createdAt: favorites[0] ? Number(favorites[0].createdAt || now) : now }));
      }
      const touched = changed || deletes.length > 0 || creates.length > 0;
      result = { protocolVersion: 3, cardId: input.cardId, requestId: input.requestId,
        status: changed ? 'COMMITTED' : 'UNCHANGED', myReaction: nextReaction, viewerFavorited: nextFavorite,
        writeVersion: touched ? now : rowVersion(row) };
      // All reads above; relation, version row and immutable receipt commit together.
      if (deletes.length) tx.executeDelete(deletes);
      const writes = [];
      if (touched) {
        writes.push(model('CardReaction', { cardId: input.cardId, uid, reaction: nextReaction,
          createdAt: row && row.createdAt ? row.createdAt : new Date(now), updatedAt: new Date(now) }));
        // Without an existing version row two first writes would not conflict.
        // Only this first contact writes the account row as a serialization guard.
        if (!row) writes.push(ctx.profileForWrite(owner, ctx.logicalWriteTime(owner.updatedAt)));
      }
      writes.push(...creates, model('PublishRequestRecord', {
        requestId: key, uid, operationType: 'CARD_INTERACTION_V3', payloadHash: input.payloadHash,
        resultEntityId: input.cardId, status: 'COMMITTED', resultJson: JSON.stringify(result),
        createdAt: new Date(now), expiresAt: new Date(now + 30 * DAY)
      }));
      s1.upsertRows(tx, writes);
      return true;
    } });
    if (!committed || !result) throw fail('互动事务没有完成，请核对原请求。', 'TRANSACTION_UNCONFIRMED');
    trace(input.requestId, 'committed', started, ' attempts=' + attempts);
    // Intentionally no all-user aggregation after this commit.
    return result;
  }
  async function receipt(uid, payload, env) {
    const cardId = id(payload.cardId), requestId = uuid(payload.requestId), policy = ctx.contentPolicy(env);
    const [, card, row] = await Promise.all([policy.assertAccountActive(uid),
      one(collection(env, 'FoodCard').query().equalTo('id', cardId)),
      one(collection(env, 'PublishRequestRecord').query().equalTo('requestId', receiptKey(uid, requestId)))]);
    await policy.assertCardReadable(uid, card);
    const result = row ? parsedReceipt(row, uid, cardId, requestId) : null;
    return { protocolVersion: 3, cardId, requestId, found: !!result, receipt: result };
  }
  async function counts(uid, payload, env) {
    const cardId = id(payload.cardId), policy = ctx.contentPolicy(env);
    const [owner, card, before, ready] = await Promise.all([
      one(collection(env, 'UserProfile').query().equalTo('uid', uid)),
      one(collection(env, 'FoodCard').query().equalTo('id', cardId)),
      one(reactionRowQuery(env, cardId, uid)), historyReady(env)]);
    if (!isAccountActive(owner)) throw fail('账号已不可用。', 'ACCOUNT_INACTIVE');
    // Totals are settled so an access denial always wins over a counting error.
    const counted = ready ? settle(countTotals(cardId, env)) : null;
    const [, total, likes, favorites] = await Promise.all([policy.assertCardReadable(uid, card),
      settle(totals(cardId, uid, env, ready, counted)),
      ownRowsQuery(env, cardId, uid, 'LIKE').get(), ownRowsQuery(env, cardId, uid, 'FAVORITE').get()]);
    if (total.error) throw total.error;
    bounded(likes); bounded(favorites);
    const after = await one(reactionRowQuery(env, cardId, uid));
    if (!sameRow(before, after)) throw fail('统计期间本人状态已变化，请重新读取。', 'STALE_VERSION');
    return { protocolVersion: 3, cardId, likeCount: total.value.likeCount, dislikeCount: total.value.dislikeCount,
      favoriteCount: total.value.favoriteCount, myReaction: ownReaction(after, likes),
      viewerFavorited: favorites.length > 0, writeVersion: rowVersion(after) };
  }
  // Detail-page action summary with the same shape as stage1.reactionSummary.
  async function summary(cardId, viewerUid, env) {
    const counted = settle(countTotals(cardId, env));
    const [ready, row, likes, favorites, flags, fast] = await Promise.all([historyReady(env),
      viewerUid ? one(reactionRowQuery(env, cardId, viewerUid)) : Promise.resolve(null),
      viewerUid ? ownRowsQuery(env, cardId, viewerUid, 'LIKE').get() : Promise.resolve([]),
      viewerUid ? ownRowsQuery(env, cardId, viewerUid, 'FAVORITE').get() : Promise.resolve([]),
      ctx.collections().flags(cardId, viewerUid, env), counted]);
    if (!ready || fast.error) {
      if (fast.error) console.warn('[CardInteractionCloud] stage=detail_count_fallback code=' + String(fast.error.code || 'UNKNOWN'));
      return ctx.stage1().reactionSummary(cardId, viewerUid, env);
    }
    const myReaction = row ? (REACTIONS.includes(row.reaction) ? row.reaction : '') : likes.length ? 'LIKE' : '';
    return { ...fast.value, myReaction, viewerLiked: myReaction === 'LIKE', viewerFavorited: favorites.length > 0, ...flags };
  }
  return { state, set, receipt, counts, summary };
}
module.exports = { createCardInteractionServices };
