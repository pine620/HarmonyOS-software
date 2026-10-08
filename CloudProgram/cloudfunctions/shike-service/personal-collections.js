'use strict';

const { dateMillis, currentVisibility } = require('./content-policy');
const { fail, hash, id, uuid, int, token, encode, flag, friendsAllowed } = require('./stages47-common');
const TYPE = 'MIGRATE_PERSONAL_COLLECTION';
const VERSION = 1;
const BATCH = 10;
const LEASE_MS = 120000;
const KINDS = ['FAVORITE', 'WANT_TO_EAT'];

function createPersonalCollections(ctx) {
  const { collection, one, models } = ctx;
  const model = (name, row) => Object.assign(new models[name](), row);
  const jobId = uid => hash([TYPE, uid, VERSION]);
  const txOne = (tx, env, name, field, value) => ctx.stage1().txOne(tx, env, name, field, value);
  const upsert = (tx, rows) => ctx.stage1().upsertRows(tx, rows);
  const enabled = env => flag(env, 'SHIKE_COLLECTIONS_VERIFIED');
  function requireEnabled(env) {
    if (!enabled(env)) throw fail('收藏服务尚未就绪，请稍后再试。', 'FEATURE_NOT_READY');
  }
  function checkpoint(job) {
    if (!job) return { phase: 'LISTS', listBoundary: null, activeList: null, itemBoundary: null,
      stateBoundary: null, scanned: 0, createdFavorites: 0, createdWanted: 0, batches: 0 };
    const saved = JSON.parse(String(job.checkpointJson || '{}'));
    if (!['LISTS', 'WANTED', 'DONE'].includes(saved.phase) ||
        ['scanned', 'createdFavorites', 'createdWanted', 'batches'].some(key => !Number.isSafeInteger(saved[key]) || saved[key] < 0) ||
        (job.status === 'DONE' && saved.phase !== 'DONE')) throw fail('整理进度无效。', 'INVALID_STATE');
    return saved;
  }
  function statusView(job, env) {
    const saved = checkpoint(job);
    return { schemaReady: enabled(env), status: job ? job.status : 'NOT_STARTED',
      collectionReady: enabled(env) && !!job && job.jobType === TYPE && Number(job.generation) === VERSION &&
        job.status === 'DONE' && saved.phase === 'DONE',
      phase: saved.phase, processed: saved.scanned, importedFavorites: saved.createdFavorites,
      importedWanted: saved.createdWanted, lastErrorCode: job ? String(job.lastErrorCode || '') : '' };
  }
  async function status(uid, env) {
    await ctx.contentPolicy(env).assertAccountActive(uid);
    const job = await one(collection(env, 'MaintenanceJob').query().equalTo('jobId', jobId(uid)));
    await ctx.contentPolicy(env).assertAccountActive(uid);
    return statusView(job, env);
  }
  async function assertWritable(tx, uid, env) {
    requireEnabled(env);
    const job = await txOne(tx, env, 'MaintenanceJob', 'jobId', jobId(uid));
    if (!job || job.status !== 'DONE') throw fail('收藏正在整理，请在我的收藏中继续。', 'COLLECTION_MIGRATING');
  }
  async function assertLegacyListWritable(tx, uid, env) {
    const job = await txOne(tx, env, 'MaintenanceJob', 'jobId', jobId(uid));
    if (job) throw fail('私人清单已合并到收藏，请更新客户端。', 'CLIENT_UPDATE_REQUIRED');
  }
  async function syncLegacyWanted(tx, uid, cardId, wanted, now, env) {
    const job = await txOne(tx, env, 'MaintenanceJob', 'jobId', jobId(uid));
    if (!job) return; // The first migration still owns the legacy source.
    if (job.status !== 'DONE') throw fail('收藏正在整理，请稍后修改。', 'COLLECTION_MIGRATING');
    requireEnabled(env);
    const key = ctx.actionId('card:WANT_TO_EAT', uid, cardId);
    const old = await txOne(tx, env, 'CardAction', 'id', key);
    if (wanted && !old) {
      const card = await txOne(tx, env, 'FoodCard', 'id', cardId);
      await ctx.transactionPolicy(tx, env).assertCardReadable(uid, card);
      upsert(tx, [model('CardAction', { id: key, actorUid: uid,
      cardId, kind: 'WANT_TO_EAT', createdAt: now })]);
    }
    if (!wanted && old) tx.executeDelete([model('CardAction', old)]);
  }
  async function start(uid, env) {
    requireEnabled(env);
    const committed = await collection(env, 'MaintenanceJob').runTransaction({ apply: async tx => {
      const owner = await ctx.stage1().activeProfile(tx, uid, env);
      const old = await txOne(tx, env, 'MaintenanceJob', 'jobId', jobId(uid));
      if (old) return true;
      const now = ctx.logicalWriteTime(owner.updatedAt);
      upsert(tx, [model('MaintenanceJob', { jobId: jobId(uid), jobType: TYPE, entityId: uid,
        ownerUid: uid, generation: VERSION, status: 'PENDING', runAfterAt: new Date(now),
        leaseUntilAt: null, leaseOwner: '', attemptCount: 0, cursor: '',
        checkpointJson: JSON.stringify(checkpoint(null)), lastErrorCode: '',
        createdAt: new Date(now), updatedAt: new Date(now) }), ctx.profileForWrite(owner, now)]);
      return true;
    }});
    if (!committed) throw fail('收藏整理任务未保存，请重试。', 'CONFLICT');
    return status(uid, env);
  }
  async function resume(uid, payload, env) {
    requireEnabled(env);
    const requestId = uuid(payload.requestId);
    const receiptId = hash([uid, TYPE, requestId]);
    const parentId = jobId(uid);
    const lease = requestId;
    const acquired = await collection(env, 'MaintenanceJob').runTransaction({ apply: async tx => {
      const owner = await ctx.stage1().activeProfile(tx, uid, env);
      const previous = await txOne(tx, env, 'PublishRequestRecord', 'requestId', receiptId);
      if (previous) {
        if (previous.uid !== uid || previous.operationType !== TYPE || previous.status !== 'COMMITTED') throw fail('整理回执无效。', 'CONFLICT');
        return true;
      }
      const job = await txOne(tx, env, 'MaintenanceJob', 'jobId', parentId);
      if (!job || job.ownerUid !== uid || job.jobType !== TYPE || Number(job.generation) !== VERSION)
        throw fail('请先开始整理收藏。', 'MIGRATION_REQUIRED');
      if (job.status === 'DONE') return true;
      if (dateMillis(job.leaseUntilAt) > Date.now() && job.leaseOwner !== lease)
        throw fail('收藏整理正在进行，请稍后继续。', 'JOB_BUSY');
      const now = ctx.logicalWriteTime(owner.updatedAt);
      upsert(tx, [model('MaintenanceJob', { ...job, status: 'RUNNING', leaseOwner: lease,
        leaseUntilAt: new Date(now + LEASE_MS), attemptCount: Number(job.attemptCount || 0) + 1,
        updatedAt: new Date(now), lastErrorCode: '' }), ctx.profileForWrite(owner, now)]);
      return true;
    }});
    if (!acquired) throw fail('整理任务繁忙，请稍后继续。', 'CONFLICT');
    try {
      const committed = await collection(env, 'MaintenanceJob').runTransaction({ apply: async tx => {
        const owner = await ctx.stage1().activeProfile(tx, uid, env);
        const receipt = await txOne(tx, env, 'PublishRequestRecord', 'requestId', receiptId);
        if (receipt) {
          if (receipt.uid !== uid || receipt.operationType !== TYPE || receipt.status !== 'COMMITTED') throw fail('整理回执无效。', 'CONFLICT');
          return true; // Same request never advances the checkpoint twice.
        }
        const job = await txOne(tx, env, 'MaintenanceJob', 'jobId', parentId);
        if (!job) throw fail('整理任务不存在。', 'MIGRATION_REQUIRED');
        if (job.status === 'DONE') return true;
        if (job.ownerUid !== uid || job.leaseOwner !== lease || dateMillis(job.leaseUntilAt) <= Date.now())
          throw fail('整理任务租约已变化，请继续整理。', 'JOB_BUSY');
        const saved = checkpoint(job);
        const now = ctx.logicalWriteTime(owner.updatedAt);
        const created = [], importedKeys = new Set();
        let consumed = 0, directoryReads = 0;
        async function importAction(cardId, kind, createdAt, source) {
          const key = ctx.actionId('card:' + kind, uid, id(cardId));
          if (importedKeys.has(key)) return;
          importedKeys.add(key);
          if (await txOne(tx, env, 'CardAction', 'id', key)) return;
          const row = model('CardAction', { id: key, actorUid: uid, cardId, kind,
            createdAt: dateMillis(createdAt) === null ? now : dateMillis(createdAt) });
          // Invalid references are retained as private references, never exposed as card content.
          upsert(tx, [row]); created.push({ id: key, cardId, kind, createdAt: row.createdAt, source });
          if (kind === 'FAVORITE') saved.createdFavorites++;
          else saved.createdWanted++;
        }
        while (saved.phase === 'LISTS' && consumed < BATCH && directoryReads < BATCH) {
          if (!saved.activeList) {
            let query = collection(env, 'FoodList').query().equalTo('ownerUid', uid)
              .orderByAsc('sortOrder').orderByAsc('listId');
            if (saved.listBoundary) query = query.startAfter(model('FoodList', saved.listBoundary));
            const lists = await tx.executeQuery(query.limit(1)); directoryReads++;
            if (!lists.length) { saved.phase = 'WANTED'; break; }
            const list = lists[0];
            saved.listBoundary = { listId: list.listId, sortOrder: Number(list.sortOrder) };
            if (list.deletedAt != null) continue;
            saved.activeList = list.listId; saved.itemBoundary = null;
          }
          const list = await txOne(tx, env, 'FoodList', 'listId', saved.activeList);
          if (!list || list.ownerUid !== uid || list.deletedAt != null) {
            saved.activeList = null; saved.itemBoundary = null; continue;
          }
          let query = collection(env, 'FoodListItem').query().equalTo('listId', list.listId)
            .orderByAsc('sortKey').orderByAsc('cardId');
          if (saved.itemBoundary) query = query.startAfter(model('FoodListItem', saved.itemBoundary));
          const remaining = BATCH - consumed;
          const rows = await tx.executeQuery(query.limit(remaining));
          for (const row of rows) {
            consumed++; saved.scanned++;
            saved.itemBoundary = { listId: list.listId, cardId: row.cardId, sortKey: Number(row.sortKey) };
            if (row.ownerUid === uid) await importAction(row.cardId, 'FAVORITE', row.createdAt,
              { type: 'FoodListItem', listId: row.listId, cardId: row.cardId });
          }
          if (rows.length < remaining) {
            saved.activeList = null; saved.itemBoundary = null;
          }
        }
        if (saved.phase === 'WANTED' && consumed < BATCH) {
          let query = collection(env, 'PersonalFoodState').query().equalTo('ownerUid', uid)
            .equalTo('state', 'WANT_TO_EAT').orderByDesc('updatedAt').orderByAsc('cardId');
          if (saved.stateBoundary) query = query.startAfter(model('PersonalFoodState', {
            ...saved.stateBoundary, updatedAt: new Date(saved.stateBoundary.updatedAt) }));
          const remaining = BATCH - consumed;
          const rows = await tx.executeQuery(query.limit(remaining));
          for (const row of rows) {
            saved.scanned++; consumed++;
            const updatedAt = dateMillis(row.updatedAt);
            if (updatedAt === null) throw fail('旧想吃记录时间无效，请修复后继续整理。', 'INVALID_STATE');
            saved.stateBoundary = { ownerUid: uid, cardId: row.cardId, updatedAt };
            await importAction(row.cardId, 'WANT_TO_EAT', row.updatedAt,
              { type: 'PersonalFoodState', ownerUid: uid, cardId: row.cardId });
          }
          if (rows.length < remaining) saved.phase = 'DONE';
        }
        saved.batches++;
        const auditId = hash([parentId, requestId, 'batch']);
        upsert(tx, [model('MaintenanceJob', { ...job, status: saved.phase === 'DONE' ? 'DONE' : 'PENDING',
          checkpointJson: JSON.stringify(saved), leaseOwner: '', leaseUntilAt: null, updatedAt: new Date(now), lastErrorCode: '' }),
          model('MaintenanceJob', { jobId: auditId, jobType: TYPE + '_BATCH', entityId: parentId,
            ownerUid: uid, generation: VERSION, status: 'DONE', runAfterAt: new Date(now),
            leaseUntilAt: null, leaseOwner: '', attemptCount: 1, cursor: '',
            checkpointJson: JSON.stringify({ batch: saved.batches, created }), lastErrorCode: '',
            createdAt: new Date(now), updatedAt: new Date(now) }),
          model('PublishRequestRecord', { requestId: receiptId, uid, operationType: TYPE,
            payloadHash: hash([uid, VERSION]), resultEntityId: auditId, status: 'COMMITTED',
            createdAt: new Date(now), expiresAt: new Date(now + 30 * 86400000) }), ctx.profileForWrite(owner, now)]);
        return true;
      }});
      if (!committed) throw fail('整理进度未保存，请继续整理。', 'CONFLICT');
    } catch (error) {
      // Keep the committed checkpoint; a failed batch can be resumed explicitly.
      try {
        await collection(env, 'MaintenanceJob').runTransaction({ apply: async tx => {
          const job = await txOne(tx, env, 'MaintenanceJob', 'jobId', parentId);
          if (job && job.status !== 'DONE' && job.leaseOwner === lease) upsert(tx, [model('MaintenanceJob', {
            ...job, status: 'FAILED', leaseOwner: '', leaseUntilAt: null, updatedAt: new Date(),
            lastErrorCode: String(error.code || 'MIGRATION_FAILED').slice(0, 80) })]);
          return true;
        }});
      } catch (_checkpointError) { /* An expired lease permits later recovery. */ }
      throw error;
    }
    return status(uid, env);
  }
  async function set(uid, payload, env, kind) {
    requireEnabled(env);
    const cardId = id(payload.cardId), requestId = uuid(payload.requestId);
    if (typeof payload.active !== 'boolean') throw fail('收藏状态无效。');
    const desired = payload.active;
    const operation = 'SET_' + kind;
    const receiptId = hash([uid, 'collection-action', requestId]);
    const payloadHash = hash([cardId, kind, desired]);
    const committed = await collection(env, 'CardAction').runTransaction({ apply: async tx => {
      const owner = await ctx.stage1().activeProfile(tx, uid, env);
      await assertWritable(tx, uid, env);
      const receipt = await txOne(tx, env, 'PublishRequestRecord', 'requestId', receiptId);
      if (receipt) {
        if (receipt.uid !== uid || receipt.operationType !== operation || receipt.payloadHash !== payloadHash || receipt.status !== 'COMMITTED')
          throw fail('请求标识已用于其他操作。', 'CONFLICT');
        return true;
      }
      const key = ctx.actionId('card:' + kind, uid, cardId);
      const old = await txOne(tx, env, 'CardAction', 'id', key);
      if (desired) {
        const card = await txOne(tx, env, 'FoodCard', 'id', cardId);
        await ctx.transactionPolicy(tx, env, [owner]).assertCardReadable(uid, card);
      }
      const now = ctx.logicalWriteTime(owner.updatedAt);
      if (desired && !old) upsert(tx, [model('CardAction', { id: key, actorUid: uid, cardId, kind, createdAt: now })]);
      if (!desired && old) tx.executeDelete([model('CardAction', old)]);
      upsert(tx, [model('PublishRequestRecord', { requestId: receiptId, uid, operationType: operation,
        payloadHash, resultEntityId: key, status: 'COMMITTED', createdAt: new Date(now),
        expiresAt: new Date(now + 30 * 86400000) }), ctx.profileForWrite(owner, now)]);
      return true;
    }});
    if (!committed) throw fail('操作未保存，请重试。', 'CONFLICT');
    const result = { cardId, kind, active: desired, requestId, contentAvailable: false };
    const card = await one(collection(env, 'FoodCard').query().equalTo('id', cardId));
    if (!card || !friendsAllowed(env, card) || !await ctx.contentPolicy(env).canReadCard(uid, card)) return result;
    const summary = await ctx.stage1().reactionSummary(cardId, uid, env);
    const fresh = await one(collection(env, 'FoodCard').query().equalTo('id', cardId));
    if (!fresh || Number(fresh.updatedAt) !== Number(card.updatedAt) ||
        !await ctx.contentPolicy(env).canReadCard(uid, fresh)) return result;
    return { ...result, ...summary, contentAvailable: true };
  }
  async function flags(cardId, uid, env) {
    if (!uid) return { viewerWanted: false, collectionReady: false, collectionStatus: 'GUEST' };
    const [wanted, job] = await Promise.all([
      enabled(env) ? one(collection(env, 'CardAction').query().equalTo('id', ctx.actionId('card:WANT_TO_EAT', uid, cardId))) : null,
      one(collection(env, 'MaintenanceJob').query().equalTo('jobId', jobId(uid)))
    ]);
    const view = statusView(job, env);
    return { viewerWanted: !!wanted, collectionReady: view.collectionReady,
      collectionStatus: enabled(env) ? view.status : 'FEATURE_NOT_READY' };
  }
  async function assemble(uid, ids, env) {
    const byId = await ctx.readCardRowsByIds(ids, env);
    const rows = ids.map(key => byId.get(key)).filter(row => row && friendsAllowed(env, row));
    const context = await ctx.createCardReadContext(rows, uid, env);
    const readable = await ctx.readableCardRows(rows, uid, env, false, context);
    await ctx.preparePrimaryPhotos(context, readable, env);
    const cards = readable.map(row => ctx.previewCard(row, context, env));
    const fresh = await ctx.withReadPhase('final-check', () => ctx.finalizeCardReads(cards, readable, uid, env));
    const allowed = new Map(fresh.map(card => [card.id, card]));
    await ctx.contentPolicy(env).assertAccountActive(uid);
    return { items: ids.map(cardId => ({ cardId, accessible: allowed.has(cardId), card: allowed.get(cardId) || null })) };
  }
  async function previews(uid, payload, env) {
    await ctx.contentPolicy(env).assertAccountActive(uid);
    if (!Array.isArray(payload.cardIds) || payload.cardIds.length > BATCH) throw fail('预览每批最多 10 张。');
    const ids = [...new Set(payload.cardIds.map(value => id(value)))];
    return assemble(uid, ids, env);
  }
  async function list(uid, payload, env) {
    const migration = await status(uid, env);
    const kind = payload.kind;
    if (!KINDS.includes(kind)) throw fail('收藏类型无效。');
    if (!migration.collectionReady) return { items: [], nextCursor: '', migration };
    const size = int(payload.pageSize === undefined ? 12 : payload.pageSize, 1, 20);
    const owner = await one(collection(env, 'UserProfile').query().equalTo('uid', uid));
    const signature = hash([uid, kind, VERSION, Number(owner.updatedAt)]);
    const saved = token(payload.cursor, signature), at = saved ? saved.at : Date.now();
    let query = collection(env, 'CardAction').query().equalTo('actorUid', uid).equalTo('kind', kind)
      .lessThanOrEqualTo('createdAt', at).orderByDesc('createdAt').orderByAsc('id');
    if (saved) {
      const last = await one(collection(env, 'CardAction').query().equalTo('id', id(saved.lastId)));
      if (!last || last.actorUid !== uid || last.kind !== kind) throw fail('收藏已变化，请刷新。', 'CURSOR_STALE');
      query = query.startAfter(model('CardAction', last));
    }
    const rows = await query.limit(size).get();
    const result = await assemble(uid, rows.map(row => row.cardId), env);
    const items = result.items;
    const latestOwner = await ctx.contentPolicy(env).assertAccountActive(uid);
    if (Number(latestOwner.updatedAt) !== Number(owner.updatedAt)) throw fail('收藏已变化，请刷新。', 'CURSOR_STALE');
    return { items, nextCursor: rows.length === size ? encode(signature, at, { lastId: rows[rows.length - 1].id }) : '', migration };
  }
  return { enabled, status, start, resume, set, flags, previews, list, assertWritable,
    assertLegacyListWritable, syncLegacyWanted };
}
module.exports = { createPersonalCollections };
