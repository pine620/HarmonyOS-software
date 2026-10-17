'use strict';

const { fail, hash, flag, id, uuid } = require('./stages47-common');
const { dateMillis, isAccountActive } = require('./shared/content-policy');
const REACTIONS = ['', 'LIKE', 'DISLIKE'];
const DAY = 86400000;

/**
 * 【文件职责】卡片互动（反应 + 收藏）协议 v3 的低延迟实现：state 读状态、set 写入、receipt 查回执、counts 计数、summary 详情页摘要。
 * 【延迟设计】
 *   - Cloud DB 事务是乐观的：事务内通过 tx.executeQuery 读到的每一行在提交时都会做版本校验，冲突时 SDK 会重跑 apply()。
 *     因此事务内读过的行已能防止卡片或账号的并发变化；以前再改写 FoodCard / UserProfile 只会制造热点行冲突。
 *   - 每个“账号 × 卡片”一行 CardReaction，既是写入保护也是版本号；取消反应后保留该行（reaction=''），版本永不回退。
 *   - 总数使用服务端 countQuery 走现有索引，而不是分页读取行。
 *   - 写入带 requestId，回执行（PublishRequestRecord 同类结构）不可变，客户端超时后可查询或用同一 requestId 重发。
 */
// 创建模块：ctx 由 runtime.js 注入。
function createCardInteractionServices(ctx) {
  const { collection, one } = ctx;
  const receiptKey = (uid, requestId) => hash(['card-interaction-v3', uid, requestId]);
  const trace = (requestId, stage, started, extra = '') => console.info('[CardInteractionCloud] requestId=' + requestId +
    ' stage=' + stage + ' elapsedMs=' + (Date.now() - started) + extra);
  const model = (name, value) => ctx.stage1().model(name, value);
  const settle = promise => Promise.resolve(promise).then(value => ({ value, error: null }), error => ({ value: undefined, error }));

  // 解析并校验写入请求，计算请求指纹（防止同一 requestId 携带不同内容）。
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
  // 解析已存在的回执，并校验属于同一用户、卡片与请求。
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
  // 功能开关：反应与收藏是否开放、旧数据是否已迁移。
  async function gates(uid, env) {
    // 某一组功能的迁移进度损坏时，不能连带关闭另一组功能。
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
  // 查询“我”对卡片的反应行。
  function reactionRowQuery(env, cardId, uid) {
    return collection(env, 'CardReaction').query().equalTo('cardId', cardId).equalTo('uid', uid).limit(1);
  }
  // 查询“我”的收藏行。
  function ownRowsQuery(env, cardId, uid, kind) {
    return collection(env, 'CardAction').query().equalTo('cardId', cardId).equalTo('actorUid', uid).equalTo('kind', kind).limit(51);
  }
  // 限制查询结果数量（防止异常数据导致大量读取）。
  function bounded(rows) {
    if (rows.length >= 51) throw fail('旧互动记录过多，请先整理后再操作。', 'MIGRATION_REQUIRED');
    return rows;
  }
  // “我”当前的反应（兼容旧的 LIKE 数据）。
  function ownReaction(row, likes) {
    if (row && !REACTIONS.includes(row.reaction)) throw fail('已有赞踩记录无效，请先核对历史数据。', 'INVALID_STATE');
    return row ? row.reaction : likes.length ? 'LIKE' : '';
  }
  // “账号 × 卡片”版本号。这个 SDK 中 Date 字段可以保留毫秒精度往返（写入为毫秒时间戳，读出为 UTC 的 "yyyy-MM-dd HH:mm:ss SSS"）。
  // 计算版本号。
  function rowVersion(row) {
    if (!row) return 0;
    const updated = dateMillis(row.updatedAt);
    if (updated !== null) return updated;
    const created = dateMillis(row.createdAt);
    return created === null ? 0 : created;
  }
  // 两次读取的版本行是否相同。
  function sameRow(before, after) {
    return !!before === !!after && rowVersion(before) === rowVersion(after) &&
      (!before || String(before.reaction) === String(after.reaction));
  }
  // 旧历史数据是否已迁移完成。
  async function historyReady(env) {
    try { return (await ctx.stage1().reactionHistoryMaintenance({ mode: 'status' }, env)).ready === true; }
    catch (_) { return false; }
  }
  // 执行 COUNT 查询。
  async function countOf(query, field) {
    if (typeof query.countQuery !== 'function') throw new Error('countQuery unavailable');
    const value = Number(await query.countQuery(field));
    if (!Number.isSafeInteger(value) || value < 0) throw fail('统计结果无效。', 'INVALID_STATE');
    return value;
  }
  // 在现有的 (cardId, reaction, uid) 与 (cardId, kind, id) 索引上执行服务端 COUNT。CardReaction 主键是 (cardId, uid)；所有收藏写入都使用确定性的 actionId，所以每一行计数都代表一个不同的账号。
  // 赞 / 踩 / 收藏的 COUNT 查询。
  function countTotals(cardId, env) {
    return Promise.all([
      countOf(collection(env, 'CardReaction').query().equalTo('cardId', cardId).equalTo('reaction', 'LIKE'), 'uid'),
      countOf(collection(env, 'CardReaction').query().equalTo('cardId', cardId).equalTo('reaction', 'DISLIKE'), 'uid'),
      countOf(collection(env, 'CardAction').query().equalTo('cardId', cardId).equalTo('kind', 'FAVORITE'), 'id')
    ]).then(([likeCount, dislikeCount, favoriteCount]) => ({ likeCount, dislikeCount, favoriteCount }));
  }
  // 取得总数（优先 COUNT，必要时扫描）。
  async function totals(cardId, uid, env, ready, counted) {
    if (ready && counted) {
      const fast = await counted;
      if (!fast.error) return fast.value;
      console.warn('[CardInteractionCloud] stage=count_query_fallback code=' + String(fast.error && fast.error.code || 'UNKNOWN'));
    }
    // 旧的 LIKE 历史尚未合并或 COUNT 不可用时，改用精确扫描。
    const result = await ctx.stage1().reactionSummary(cardId, uid, env, { historyComplete: ready, includePrivateFlags: false });
    return { likeCount: result.likeCount, dislikeCount: result.dislikeCount, favoriteCount: result.favoriteCount };
  }

  // 读取互动状态（两阶段读取保证一致性）。
  async function state(uid, payload, env) {
    const cardId = id(payload.cardId), policy = ctx.contentPolicy(env);
    for (let attempt = 0; attempt < 2; attempt++) {
      // 第 1 阶段：并行读取功能开关、账号、卡片与版本行。
      const [caps, owner, card, before] = await Promise.all([gates(uid, env),
        one(collection(env, 'UserProfile').query().equalTo('uid', uid)),
        one(collection(env, 'FoodCard').query().equalTo('id', cardId)), one(reactionRowQuery(env, cardId, uid))]);
      if (!isAccountActive(owner)) throw fail('账号已不可用。', 'ACCOUNT_INACTIVE');
      // 第 2 阶段在读到版本行之后开始；如果第 2 阶段结束时版本仍未变化，就证明关系数据来自同一个已提交的状态。
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
  // 写入互动（事务 + 回执幂等）。
  async function set(uid, payload, env) {
    const started = Date.now(), input = spec(payload), key = receiptKey(uid, input.requestId);
    trace(input.requestId, 'gate', started);
    const [existing, history] = await Promise.all([
      one(collection(env, 'PublishRequestRecord').query().equalTo('requestId', key)),
      input.patch.reaction === undefined ? Promise.resolve(null) :
        settle(ctx.stage1().reactionHistoryMaintenance({ mode: 'status' }, env))]);
    if (existing) {
      // 已完成的回执始终可以恢复，即使之后功能开关被关闭。
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
      // 所有相互独立的读取在一次往返中完成；这里读到的每一行在提交时都会被 SDK 做版本校验。
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
      // 只对本次修改涉及的分组做“比较并设置”；无关的账号写入（其他卡片、资料修改）不再造成冲突。
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
      // 以上全部是读取；关系行、版本行与不可变回执一起提交。
      if (deletes.length) tx.executeDelete(deletes);
      const writes = [];
      if (touched) {
        writes.push(model('CardReaction', { cardId: input.cardId, uid, reaction: nextReaction,
          createdAt: row && row.createdAt ? row.createdAt : new Date(now), updatedAt: new Date(now) }));
        // 没有现成的版本行时，两次“首次写入”不会互相冲突，所以只有这次首次接触会写账号行作为串行化保护。
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
    // 提交后刻意不做全体用户的聚合统计。
    return result;
  }
  // 查询某个 requestId 的回执。
  async function receipt(uid, payload, env) {
    const cardId = id(payload.cardId), requestId = uuid(payload.requestId), policy = ctx.contentPolicy(env);
    const [, card, row] = await Promise.all([policy.assertAccountActive(uid),
      one(collection(env, 'FoodCard').query().equalTo('id', cardId)),
      one(collection(env, 'PublishRequestRecord').query().equalTo('requestId', receiptKey(uid, requestId)))]);
    await policy.assertCardReadable(uid, card);
    const result = row ? parsedReceipt(row, uid, cardId, requestId) : null;
    return { protocolVersion: 3, cardId, requestId, found: !!result, receipt: result };
  }
  // 读取计数。
  async function counts(uid, payload, env) {
    const cardId = id(payload.cardId), policy = ctx.contentPolicy(env);
    const [owner, card, before, ready] = await Promise.all([
      one(collection(env, 'UserProfile').query().equalTo('uid', uid)),
      one(collection(env, 'FoodCard').query().equalTo('id', cardId)),
      one(reactionRowQuery(env, cardId, uid)), historyReady(env)]);
    if (!isAccountActive(owner)) throw fail('账号已不可用。', 'ACCOUNT_INACTIVE');
    // 先确定总数，这样“无权访问”总是优先于计数错误返回。
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
  // 详情页的互动摘要，结构与 stage1.reactionSummary 相同。
  // 详情页互动摘要。
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
