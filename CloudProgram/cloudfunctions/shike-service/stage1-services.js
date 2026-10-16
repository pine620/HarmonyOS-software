'use strict';

const crypto = require('crypto');
const { accessError, dateMillis, isAccountActive, readableCardState, currentVisibility } = require('./shared/content-policy');
const DAY = 24 * 60 * 60 * 1000;
const BATCH = 20;
const CATEGORY_MAP = Object.freeze({ staple: 'RICE_SET', bakery: 'NOODLES', drink: 'DRINK',
  snack: 'GRILL_FRIED', fresh: 'GRILL_FRIED', other: 'OTHER' });

// The entry package injects its existing SDK boundary and models. Nothing here
// executes on import, creates another SDK client, or trusts a payload UID.
function createStage1Services(ctx) {
  const { collection, one, transactionPolicy, profileForWrite, logicalWriteTime,
    validateCard, uniqueMediaIds, promotePendingMedia, refreshPublishCount, models } = ctx;
  const model = (name, row) => Object.assign(new models[name](), row);
  const hash = (value) => crypto.createHash('sha256').update(value).digest('hex');
  function upsertRows(tx, rows) {
    // SDK assigns one objectTypeName to an entire operation, from its first
    // model. Never mix FoodCard/UserProfile/jobs in the same SDK array.
    const groups = new Map();
    for (const row of rows) {
      const name = row.getClassName();
      if (!groups.has(name)) groups.set(name, []);
      groups.get(name).push(row);
    }
    for (const group of groups.values()) tx.executeUpsert(group);
  }

  const cardTime = (card) => dateMillis(card.modifiedAt) === null ? Number(card.updatedAt || card.createdAt || 0) : dateMillis(card.modifiedAt);
  const generation = (card) => {
    const value = Number(card.lifecycleGeneration || 0);
    if (!Number.isSafeInteger(value) || value < 0 || !Number.isSafeInteger(value + 1)) throw accessError('生命周期版本无效。', 'INVALID_STATE');
    return value;
  };
  const editableState = card => readableCardState(card) || !!card && card.reviewState === 'REQUEST_CHANGE' && card.deletedAt == null && card.purgeAt == null;
  const normalize = (value) => String(value || '').normalize('NFKC').trim().replace(/\s+/g, ' ').toLowerCase();
  const derived = (card) => {
    const fields = { categoryV2: CATEGORY_MAP[card.category] || 'OTHER', categoryVersion: 2,
      searchTextNormalized: normalize(String(card.productName || '') + ' ' + String(card.shop || '')) };
    if (Number(card.priceFen || 0) > 0) { fields.itemPriceFen = Number(card.priceFen); fields.queryPriceFen = Number(card.priceFen); }
    return fields;
  };
  function uuid(value) {
    const id = String(value || '').trim().toLowerCase();
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)) throw new Error('请求标识必须为 UUID。');
    return id;
  }
  function publishReceiptSpec(uid, payload) {
    const fields = {};
    for (const key of ['productName', 'brand', 'priceFen', 'priceLabel', 'originalPriceFen', 'specification', 'shop',
      'sellingPoints', 'publicOffers', 'reviewText', 'tasteScore', 'sourceLink', 'category', 'mediaId', 'mediaIds', 'latE3', 'lonE3', 'district',
      'consumptionMode', 'visibility', 'categoryV2', 'merchantId', 'itemPriceFen', 'dineInAvgFen',
      'orderTotalFen', 'deliveryFeeFen', 'deliveryPlatformKey', 'deliveryPlatformLabelSnapshot', 'consumedAt']) {
      if (payload[key] !== undefined) fields[key] = payload[key];
    }
    const payloadHash = hash(JSON.stringify(fields));
    const requestId = payload.requestId ? uuid(payload.requestId) : 'legacy:' + payloadHash;
    return { receiptId: hash('publish:' + uid + ':' + requestId), payloadHash };
  }
  function checkPublishReceipt(row, uid, spec) {
    if (!row) return null;
    if (row.uid !== uid || row.operationType !== 'PUBLISH_CARD' || row.payloadHash !== spec.payloadHash || row.status !== 'COMMITTED') {
      throw accessError('请求标识已用于不同的发布内容。', 'CONFLICT');
    }
    return { cardId: String(row.resultEntityId), status: 'APPROVED', alreadyProcessed: true };
  }
  async function readPublishReceipt(uid, spec, env) {
    return checkPublishReceipt(await one(collection(env, 'PublishRequestRecord').query().equalTo('requestId', spec.receiptId)), uid, spec);
  }
  async function txOne(tx, env, name, field, value) {
    return (await tx.executeQuery(collection(env, name).query().equalTo(field, value).limit(1)))[0] || null;
  }
  async function activeProfile(tx, uid, env) {
    const profile = await txOne(tx, env, 'UserProfile', 'uid', uid);
    if (!isAccountActive(profile)) throw accessError('账号不存在、已停用或正在注销。', 'ACCOUNT_INACTIVE');
    return profile;
  }
  async function all(queryFactory) {
    const result = [];
    for (let offset = 0; ; offset += 100) {
      const rows = await queryFactory().limit(100, offset).get();
      result.push(...rows);
      if (rows.length < 100) return result;
    }
  }
  function jobRow(type, entityId, ownerUid, version, now, runAfterAt, checkpoint = {}) {
    return model('MaintenanceJob', { jobId: hash(type + ':' + entityId + ':' + version), jobType: type,
      entityId, ownerUid, generation: version, status: 'PENDING', attemptCount: 0, cursor: '',
      checkpointJson: JSON.stringify(checkpoint), lastErrorCode: '', createdAt: new Date(now), updatedAt: new Date(now),
      runAfterAt: new Date(runAfterAt), leaseOwner: '', leaseUntilAt: null });
  }
  function jobView(job, includeCheckpoint = false) {
    const view = { jobId: job.jobId, jobType: job.jobType, entityId: job.entityId, generation: Number(job.generation),
      status: job.status, attemptCount: Number(job.attemptCount || 0), cursor: String(job.cursor || ''),
      lastErrorCode: String(job.lastErrorCode || ''), runAfterAt: dateMillis(job.runAfterAt),
      leaseUntilAt: dateMillis(job.leaseUntilAt), createdAt: dateMillis(job.createdAt), updatedAt: dateMillis(job.updatedAt) };
    if (includeCheckpoint) view.checkpoint = JSON.parse(String(job.checkpointJson || '{}'));
    return view;
  }

  async function reactionSummary(cardId, uid, env, options = {}) {
    const [reactions, likes, favoritesRows, privateFlags] = await Promise.all([
      all(() => collection(env, 'CardReaction').query().equalTo('cardId', cardId)),
      options.historyComplete ? [] : all(() => collection(env, 'CardAction').query().equalTo('cardId', cardId).equalTo('kind', 'LIKE').orderByAsc('id')),
      all(() => collection(env, 'CardAction').query().equalTo('cardId', cardId).equalTo('kind', 'FAVORITE').orderByAsc('id')),
      options.includePrivateFlags === false ? {} : ctx.collections().flags(cardId, uid, env)
    ]);
    const actions = likes.concat(favoritesRows);
    const states = new Map();
    const favorites = new Set();
    for (const row of actions) {
      if (row.kind === 'LIKE') states.set(String(row.actorUid), 'LIKE');
      if (row.kind === 'FAVORITE') favorites.add(String(row.actorUid));
    }
    for (const row of reactions) states.set(String(row.uid), row.reaction === 'LIKE' || row.reaction === 'DISLIKE' ? row.reaction : '');
    const myReaction = states.get(uid) || '';
    return { likeCount: [...states.values()].filter((value) => value === 'LIKE').length,
      dislikeCount: [...states.values()].filter((value) => value === 'DISLIKE').length,
      favoriteCount: favorites.size, myReaction, viewerLiked: myReaction === 'LIKE', viewerFavorited: favorites.has(uid), ...privateFlags };
  }
  async function favoriteSummary(cardId, uid, env) {
    // Collection writes do not need to reread all reactions or legacy likes.
    // Keep distinct-user counts and fresh per-account migration flags.
    const [rows, privateFlags] = await Promise.all([
      all(() => collection(env, 'CardAction').query().equalTo('cardId', cardId).equalTo('kind', 'FAVORITE').orderByAsc('id')),
      ctx.collections().flags(cardId, uid, env)
    ]);
    const favorites = new Set(rows.map(row => String(row.actorUid)));
    return { favoriteCount: favorites.size, viewerFavorited: favorites.has(uid), ...privateFlags };
  }
  async function mutateReaction(uid, payload, env, legacyToggle = false, historyComplete = false) {
    const cardId = String(payload.cardId || '');
    const desired = String(payload.reaction || '');
    if (!legacyToggle && !['', 'NONE', 'LIKE', 'DISLIKE'].includes(desired)) throw new Error('赞踩状态无效。');
    const receiptId = !legacyToggle && payload.requestId ? hash('reaction:' + uid + ':' + uuid(payload.requestId)) : '';
    const payloadHash = hash(JSON.stringify([cardId, desired, payload.expectedReaction]));
    if (payload.expectedReaction !== undefined && !['', 'LIKE', 'DISLIKE'].includes(payload.expectedReaction)) {
      throw accessError('赞踩基准状态无效。', 'VALIDATION_ERROR');
    }
    let active = false;
    const committed = await collection(env, 'CardReaction').runTransaction({ apply: async (tx) => {
      const profile = await activeProfile(tx, uid, env);
      const card = await txOne(tx, env, 'FoodCard', 'id', cardId);
      await transactionPolicy(tx, env, [profile]).assertCardReadable(uid, card);
      const receipt = receiptId ? await txOne(tx, env, 'PublishRequestRecord', 'requestId', receiptId) : null;
      if (receipt) {
        if (receipt.uid !== uid || receipt.operationType !== 'REACTION' || receipt.payloadHash !== payloadHash || receipt.status !== 'COMMITTED') {
          throw accessError('请求标识已用于其他操作。', 'CONFLICT');
        }
        active = desired === 'LIKE'; return true;
      }
      const rows = await tx.executeQuery(collection(env, 'CardReaction').query().equalTo('cardId', cardId).equalTo('uid', uid).limit(1));
      // Only the verified V2 entry may skip legacy LIKE reads. Older callers
      // keep the migration-compatible path, including source deletion.
      const old = historyComplete ? [] : await tx.executeQuery(collection(env, 'CardAction').query().equalTo('cardId', cardId)
        .equalTo('actorUid', uid).equalTo('kind', 'LIKE').limit(50));
      if (old.length === 50) throw accessError('旧互动记录过多，请先迁移后再操作。', 'MIGRATION_REQUIRED');
      const current = rows[0] ? String(rows[0].reaction) : old.length > 0 ? 'LIKE' : '';
      if (!legacyToggle && payload.expectedReaction !== undefined && payload.expectedReaction !== current) {
        throw accessError('赞踩状态已在其他设备变化，请刷新后重试。', 'STALE_VERSION');
      }
      const next = legacyToggle ? current === 'LIKE' ? '' : 'LIKE' : desired === 'NONE' ? '' : desired;
      const now = logicalWriteTime(profile.updatedAt, rows[0] && dateMillis(rows[0].updatedAt));
      if (old.length > 0) tx.executeDelete(old);
      if (!next) { if (rows[0]) tx.executeDelete(rows); }
      else upsertRows(tx, [model('CardReaction', { cardId, uid, reaction: next,
        createdAt: rows[0] ? rows[0].createdAt : new Date(now), updatedAt: new Date(now) })]);
      // Existing rows serialize first writes and NONE against legacy migration.
      upsertRows(tx, [model('FoodCard', card), profileForWrite(profile, now)]);
      if (receiptId) upsertRows(tx, [model('PublishRequestRecord', { requestId: receiptId, uid, operationType: 'REACTION',
        payloadHash, resultEntityId: cardId, status: 'COMMITTED', createdAt: new Date(now), expiresAt: new Date(now + 30 * DAY) })]);
      active = next === 'LIKE';
      return true;
    } });
    if (!committed) throw new Error('互动未保存，请重试。');
    const summary = await reactionSummary(cardId, uid, env, { historyComplete, includePrivateFlags: !historyComplete });
    const current = await one(collection(env, 'FoodCard').query().equalTo('id', cardId));
    await ctx.contentPolicy(env).assertCardReadable(uid, current);
    return { active, ...summary };
  }
  async function softDelete(uid, payload, env) {
    const cardId = String(payload.cardId || '');
    let output = null;
    const committed = await collection(env, 'FoodCard').runTransaction({ apply: async (tx) => {
      output = null;
      const owner = await activeProfile(tx, uid, env);
      const card = await txOne(tx, env, 'FoodCard', 'id', cardId);
      if (!card || card.ownerUid !== uid) throw accessError('内容不存在或无权删除。');
      if (card.deletedAt != null) {
        if (dateMillis(card.deletedAt) === null || dateMillis(card.purgeAt) === null) throw accessError('删除状态无效。', 'INVALID_STATE');
        const jobId = hash('PURGE_CARD:' + cardId + ':' + generation(card));
        const existingJob = await txOne(tx, env, 'MaintenanceJob', 'jobId', jobId);
        if (!existingJob) {
          const now = logicalWriteTime(owner.updatedAt);
          upsertRows(tx, [jobRow('PURGE_CARD', cardId, uid, generation(card), now, dateMillis(card.purgeAt),
            { physicalDeletionStarted: false }), profileForWrite(owner, now)]);
        }
        output = { success: true, alreadyDeleted: true, deletedAt: dateMillis(card.deletedAt), purgeAt: dateMillis(card.purgeAt),
          jobId };
        return true;
      }
      const now = logicalWriteTime(owner.updatedAt, card.updatedAt, cardTime(card));
      const version = generation(card) + 1;
      const job = jobRow('PURGE_CARD', cardId, uid, version, now, now + ctx.recoveryPeriod(env), { physicalDeletionStarted: false });
      const deleted = model('FoodCard', { ...card, deletedAt: new Date(now), purgeAt: new Date(now + ctx.recoveryPeriod(env)),
        modifiedAt: new Date(now), updatedAt: now, lifecycleGeneration: version });
      const counters = await ctx.stage2().prepareCounterTransition(tx, card, deleted, owner, env, now);
      upsertRows(tx, [deleted, ...counters]);
      upsertRows(tx, [job, profileForWrite(owner, now)]);
      output = { success: true, alreadyDeleted: false, deletedAt: now, purgeAt: now + ctx.recoveryPeriod(env), jobId: job.jobId };
      return true;
    } });
    if (!committed || !output) throw new Error('删除状态未保存，请重试。');
    await refreshPublishCount(uid, env);
    return output;
  }
  async function beginAccountDeletion(uid, env) {
    let output = null;
    const committed = await collection(env, 'UserProfile').runTransaction({ apply: async (tx) => {
      output = null;
      const profile = await txOne(tx, env, 'UserProfile', 'uid', uid);
      if (!profile) throw accessError('账号不存在。', 'ACCOUNT_INACTIVE');
      const jobs = await tx.executeQuery(collection(env, 'MaintenanceJob').query().equalTo('ownerUid', uid)
        .equalTo('jobType', 'DELETE_ACCOUNT').limit(1));
      if (!isAccountActive(profile)) {
        if (!jobs[0]) throw accessError('停用账号没有可继续的注销任务。', 'INVALID_STATE');
        output = { success: true, cleanupPending: jobs[0].status !== 'DONE', jobId: jobs[0].jobId };
        return true;
      }
      const bindings = await tx.executeQuery(collection(env, 'IdentityBinding').query().equalTo('canonicalUid', uid).limit(50));
      const pushRows = await tx.executeQuery(collection(env, 'PushRegistration').query().equalTo('ownerUid', uid).limit(50));
      const widgetRows = await tx.executeQuery(collection(env, 'WidgetRegistration').query().equalTo('ownerUid', uid).limit(50));
      const now = logicalWriteTime(profile.updatedAt);
      const job = jobRow('DELETE_ACCOUNT', uid, uid, now, now, now,
        { phase: 'BUSINESS_CLEANUP', providerBindingsRetained: true, physicalDeletionStarted: false,
          counterRemovalDeferred: true, registrationCleanupPending: pushRows.length === 50 || widgetRows.length === 50,
          bindingStatusCleanupPending: bindings.length === 50 });
      const counters = []; // Stage 8 removes each card contribution in its durable cleanup batch.
      upsertRows(tx, [model('UserProfile', { ...profileForWrite(profile, now), accountStatus: 'DELETION_IN_PROGRESS', deletionJobId: job.jobId }), job, ...counters]);
      if (bindings.length > 0) upsertRows(tx, bindings.map((row) => model('IdentityBinding', {
        ...row, status: 'INACTIVE', updatedAt: now
      })));
      if (pushRows.length > 0) tx.executeDelete(pushRows);
      if (widgetRows.length > 0) tx.executeDelete(widgetRows);
      output = { success: true, cleanupPending: true, jobId: job.jobId };
      return true;
    } });
    if (!committed || !output) throw new Error('注销申请未保存，请重试。');
    return output;
  }

  const EDIT_FIELDS = Object.freeze(['productName', 'brand', 'priceFen', 'priceLabel', 'originalPriceFen', 'specification',
    'shop', 'sellingPoints', 'publicOffers', 'reviewText', 'tasteScore', 'sourceLink', 'category', 'visibility',
    'consumptionMode', 'categoryV2', 'merchantId', 'itemPriceFen', 'dineInAvgFen', 'orderTotalFen',
    'deliveryFeeFen', 'deliveryPlatformKey', 'deliveryPlatformLabelSnapshot', 'consumedAt']);
  async function editFields(card, changes, uid, env, read) {
    if (!changes || typeof changes !== 'object' || Array.isArray(changes)) throw new Error('编辑内容无效。');
    if (Object.keys(changes).some((key) => !EDIT_FIELDS.includes(key))) throw new Error('包含本阶段不支持的编辑字段。');
    if (changes.priceFen !== undefined) {
      const price = Number(changes.priceFen);
      if (!Number.isSafeInteger(price) || price < 0 || price > 100000000) {
        throw accessError('商品价格无效。', 'VALIDATION_ERROR');
      }
    }
    const base = { ...card, sellingPoints: ctx.safeArray(card.sellingPointsJson), publicOffers: ctx.safeArray(card.publicOffersJson),
      visibility: currentVisibility(card) };
    const candidate = { ...base, consumedAt: dateMillis(card.consumedAt), ...changes };
    if (changes.priceFen !== undefined && changes.itemPriceFen === undefined) candidate.itemPriceFen = Number(changes.priceFen) > 0 ? Number(changes.priceFen) : null;
    if (changes.category !== undefined && changes.categoryV2 === undefined) candidate.categoryV2 = CATEGORY_MAP[changes.category] || 'OTHER';
    const fields = await ctx.stage2().cardFields(candidate, uid, env, read, true);
    Object.assign(candidate, fields);
    const validated = validateCard(candidate);
    return { ...validated, brand: String(candidate.brand || '').slice(0, 80), priceFen: Number(candidate.priceFen || 0),
      priceLabel: String(candidate.priceLabel || '').slice(0, 30), originalPriceFen: Number(candidate.originalPriceFen || 0),
      specification: String(candidate.specification || '').slice(0, 100), shop: String(candidate.shop || '').slice(0, 100),
      sellingPointsJson: JSON.stringify(ctx.safeArray(candidate.sellingPoints).slice(0, 3)),
      publicOffersJson: JSON.stringify(ctx.safeArray(candidate.publicOffers).filter((item) => !ctx.personalized.test(item)).slice(0, 4)),
      category: candidate.category, visibility: candidate.visibility, ...fields };
  }
  function revisionView(row) {
    const stored = JSON.parse(row.payloadJson);
    const { sellingPointsJson, publicOffersJson, ...fields } = stored;
    return { revisionId: row.revisionId, cardId: row.cardId, authorUid: row.authorUid, status: row.status,
      baseModifiedAt: dateMillis(row.baseModifiedAt), baseLifecycleGeneration: Number(row.baseLifecycleGeneration || 0),
      changes: { ...fields, visibility: 'PUBLIC', sellingPoints: ctx.safeArray(sellingPointsJson), publicOffers: ctx.safeArray(publicOffersJson) },
      mediaIds: JSON.parse(row.mediaManifestJson), submittedAt: dateMillis(row.submittedAt),
      reviewedAt: dateMillis(row.reviewedAt), reviewReason: String(row.reviewReason || '') };
  }
  async function reusableRevisionMedia(media, uid, cardId, readRevision) {
    if (!media || media.ownerUid !== uid || !['APPROVED', 'PENDING_UPLOAD'].includes(media.status)) return false;
    if (!media.cardId || media.cardId === cardId) return true;
    if (!String(media.cardId).startsWith('revision:')) return false;
    const previous = await readRevision(String(media.cardId).slice(9));
    return !!previous && previous.authorUid === uid && previous.cardId === cardId &&
      ['PENDING', 'REJECTED', 'WITHDRAWN'].includes(previous.status);
  }
  async function submitRevision(uid, payload, env) {
    const cardId = String(payload.cardId || '');
    const revisionId = hash('revision:' + uid + ':' + uuid(payload.requestId));
    await ctx.contentPolicy(env).assertAccountActive(uid);
    const mediaIds = uniqueMediaIds({ mediaIds: payload.mediaIds });
    if (!Array.isArray(payload.mediaIds)) throw new Error('必须传完整图片列表，保留旧图时也传其 ID。');
    const baseTime = Number(payload.baseModifiedAt);
    const baseGeneration = Number(payload.baseLifecycleGeneration);
    if (!Number.isSafeInteger(baseTime) || !Number.isSafeInteger(baseGeneration) || baseGeneration < 0) throw new Error('编辑基准无效。');
    if (!payload.changes || typeof payload.changes !== 'object' || Array.isArray(payload.changes) ||
        Object.keys(payload.changes).some((key) => !EDIT_FIELDS.includes(key))) throw new Error('编辑字段无效。');
    const inputFields = {};
    for (const key of EDIT_FIELDS) if (payload.changes[key] !== undefined) inputFields[key] = payload.changes[key];
    const requestPayloadHash = hash(JSON.stringify({ cardId, baseTime, baseGeneration, changes: inputFields, mediaIds }));
    // Replay is compared to immutable input before deriving fields from a card
    // or Merchant that may have changed since submission/approval.
    const saved = await one(collection(env, 'FoodCardRevision').query().equalTo('revisionId', revisionId));
    const matchesInput = (row) => row.authorUid === uid && row.cardId === cardId && dateMillis(row.baseModifiedAt) === baseTime &&
      Number(row.baseLifecycleGeneration) === baseGeneration && row.mediaManifestJson === JSON.stringify(mediaIds) &&
      row.requestPayloadHash === requestPayloadHash;
    const concurrentReplay = async () => {
      const receipt = await one(collection(env, 'FoodCardRevision').query().equalTo('revisionId', revisionId));
      if (!receipt || !receipt.requestPayloadHash) return null;
      if (!matchesInput(receipt)) throw accessError('请求标识已经用于其他编辑。', 'CONFLICT');
      return receipt.status === 'PENDING' ? null : { success: true, revision: revisionView(receipt), alreadyProcessed: true };
    };
    if (saved && saved.requestPayloadHash) {
      if (!matchesInput(saved)) throw accessError('请求标识已经用于其他编辑。', 'CONFLICT');
      if (saved.status !== 'PENDING') return { success: true, revision: revisionView(saved), alreadyProcessed: true };
    }
    const initial = await one(collection(env, 'FoodCard').query().equalTo('id', cardId));
    if (!initial || initial.ownerUid !== uid || !editableState(initial)) {
      const replay = await concurrentReplay();
      if (replay) return replay;
      throw accessError('内容不存在、已失效或无权编辑。');
    }
    if ((!saved || saved.requestPayloadHash || saved.status === 'PENDING') &&
        (cardTime(initial) !== baseTime || generation(initial) !== baseGeneration)) {
      // Another invocation may have committed between the receipt read and
      // the card read. Return that immutable result instead of a false conflict.
      const replay = await concurrentReplay();
      if (replay) return replay;
      throw accessError('内容版本已变化，请刷新后重建编辑。', 'CONFLICT');
    }
    const fields = await editFields(initial, payload.changes, uid, env);
    const matches = (row) => row.authorUid === uid && row.cardId === cardId && dateMillis(row.baseModifiedAt) === baseTime &&
      Number(row.baseLifecycleGeneration) === baseGeneration && (row.requestPayloadHash
        ? row.requestPayloadHash === requestPayloadHash : row.payloadJson === JSON.stringify(fields)) &&
      row.mediaManifestJson === JSON.stringify(mediaIds);
    if (saved) {
      if (!matches(saved)) throw accessError('请求标识已经用于其他编辑。', 'CONFLICT');
      if (saved.status !== 'PENDING') return { success: true, revision: revisionView(saved), alreadyProcessed: true };
    }
    if (cardTime(initial) !== baseTime || generation(initial) !== baseGeneration) {
      throw accessError('内容版本已变化，请刷新后重建编辑。', 'CONFLICT');
    }
    for (const id of mediaIds) {
      const media = await one(collection(env, 'CardMedia').query().equalTo('id', id));
      if (!await reusableRevisionMedia(media, uid, cardId, (id) => one(collection(env, 'FoodCardRevision').query().equalTo('revisionId', id)))) {
        throw accessError('编辑图片不属于当前卡片/作者。');
      }
      if (!media.cardId) await promotePendingMedia(media, env);
    }
    let result = null;
    let alreadyProcessed = false;
    let publishCountChanged = false;
    const committed = await collection(env, 'FoodCardRevision').runTransaction({ apply: async (tx) => {
      result = null; alreadyProcessed = false; publishCountChanged = false;
      const owner = await activeProfile(tx, uid, env);
      const card = await txOne(tx, env, 'FoodCard', 'id', cardId);
      const existing = await txOne(tx, env, 'FoodCardRevision', 'revisionId', revisionId);
      if (existing) {
        if (!matches(existing)) throw accessError('请求标识已使用。', 'CONFLICT');
        if (existing.status !== 'PENDING') { result = existing; alreadyProcessed = true; return true; }
      }
      if (!card || card.ownerUid !== uid || !editableState(card) || cardTime(card) !== baseTime || generation(card) !== baseGeneration) {
        throw accessError('内容版本已变化，请刷新后重建编辑。', 'CONFLICT');
      }
      const currentFields = await editFields(card, payload.changes, uid, env, (name, field, value) => txOne(tx, env, name, field, value));
      if (JSON.stringify(currentFields) !== JSON.stringify(fields)) throw accessError('店铺或内容已变化，请刷新。', 'CONFLICT');
      const pending = await tx.executeQuery(collection(env, 'FoodCardRevision').query().equalTo('cardId', cardId).equalTo('status', 'PENDING').limit(20));
      if (pending.length === 20 || pending.some(row => row.authorUid !== uid)) throw accessError('历史编辑版本状态异常。', 'INVALID_STATE');
      const previousMedia = await tx.executeQuery(collection(env, 'CardMedia').query().equalTo('cardId', cardId).limit(20));
      if (previousMedia.length === 20 || previousMedia.some(media => media.ownerUid !== uid)) {
        throw accessError('原图片关联状态异常。', 'INVALID_STATE');
      }
      const medias = [];
      for (const id of mediaIds) {
        const media = await txOne(tx, env, 'CardMedia', 'id', id);
        if (!await reusableRevisionMedia(media, uid, cardId, (id) => txOne(tx, env, 'FoodCardRevision', 'revisionId', id))) {
          throw accessError('图片已被使用或状态已变化。', 'CONFLICT');
        }
        medias.push(media);
      }
      const now = logicalWriteTime(owner.updatedAt, cardTime(card));
      const updated = model('FoodCard', { ...card, ...ctx.stage2().storageFields(currentFields),
        mediaId: mediaIds[0], status: 'APPROVED', schemaVersion: 2, migrationSource: 'SERVER',
        // Keep the existing readable publication state without claiming an
        // administrator reviewed this author save. Do not boost publication time.
        reviewState: 'PENDING_POST_REVIEW', reviewReason: '', edited: true,
        modifiedAt: new Date(now), updatedAt: now, lifecycleGeneration: baseGeneration + 1 });
      const counters = await ctx.stage2().prepareCounterTransition(tx, card, updated, owner, env, now);
      publishCountChanged = !readableCardState(card);
      // APPROVED is the legacy revision enum for an applied receipt. reviewedAt
      // records completion; neither field represents an administrator decision.
      result = model('FoodCardRevision', { revisionId, cardId, authorUid: uid, baseModifiedAt: new Date(baseTime),
        baseLifecycleGeneration: baseGeneration, requestPayloadHash, payloadJson: JSON.stringify(fields), mediaManifestJson: JSON.stringify(mediaIds),
        status: 'APPROVED', submittedAt: existing ? existing.submittedAt : new Date(now), reviewedAt: new Date(now), reviewReason: '' });
      const superseded = pending.filter(row => row.revisionId !== revisionId);
      // No reads after this point: card, receipt, profile, counters and media
      // associations commit or roll back together in one SDK transaction.
      if (superseded.length > 0) upsertRows(tx, superseded.map((row) => model('FoodCardRevision', {
        ...row, status: 'WITHDRAWN', reviewedAt: new Date(now), reviewReason: 'SUPERSEDED'
      })));
      upsertRows(tx, [result, updated, profileForWrite(owner, now), ...counters]);
      upsertRows(tx, medias.map(media => model('CardMedia', { ...media, cardId, status: 'APPROVED' })));
      const retired = previousMedia.filter(media => !mediaIds.includes(media.id));
      if (retired.length > 0) upsertRows(tx, retired.map(media => model('CardMedia', {
        ...media, cardId: 'revision:' + revisionId, status: 'RETIRED'
      })));
      return true;
    } });
    if (!committed || !result) throw new Error('编辑未保存，请重试。');
    // Ordinary edits do not change the owner's publish count. Historical
    // REQUEST_CHANGE recovery does; refresh only that derived profile count.
    if (publishCountChanged) await refreshPublishCount(uid, env);
    return { success: true, revision: revisionView(result), alreadyProcessed };
  }
  async function getEditContext(uid, payload, env) {
    const card = await one(collection(env, 'FoodCard').query().equalTo('id', String(payload.cardId || '')));
    if (!card || card.ownerUid !== uid) throw accessError('无权编辑此卡片。', 'FORBIDDEN');
    if (!card || card.ownerUid !== uid || !editableState(card)) throw accessError('无权编辑此内容。');
    await ctx.contentPolicy(env).assertAccountActive(uid);
    const rows = await collection(env, 'FoodCardRevision').query().equalTo('cardId', card.id)
      .orderByDesc('submittedAt').orderByAsc('revisionId').limit(1).get();
    const latest = rows[0] && ['PENDING', 'REJECTED', 'WITHDRAWN'].includes(rows[0].status) ? rows[0] : null;
    const result = { card: await ctx.publicCard(card, env, 0, true, uid, false, 6, null, null, true), revision: latest ? revisionView(latest) : null };
    const fresh = await one(collection(env, 'FoodCard').query().equalTo('id', card.id));
    await ctx.contentPolicy(env).assertAccountActive(uid);
    if (!fresh || fresh.ownerUid !== uid || !editableState(fresh) || cardTime(fresh) !== cardTime(card)) throw accessError('编辑内容已变化，请刷新。', 'CONFLICT');
    return result;
  }
  async function withdrawRevision(uid, payload, env) {
    let output=null;
    const committed=await collection(env,'FoodCardRevision').runTransaction({apply:async tx=>{
      output=null;await activeProfile(tx,uid,env);
      const revision=await txOne(tx,env,'FoodCardRevision','revisionId',String(payload.revisionId||''));
      if(!revision||revision.authorUid!==uid)throw accessError('版本不存在或无权操作。','FORBIDDEN');
      if(revision.status==='WITHDRAWN'){output={success:true,status:'WITHDRAWN',unchanged:true};return true;}
      if(revision.status!=='PENDING')throw accessError('编辑版本已处理或失效。','CONFLICT');
      const now=logicalWriteTime(dateMillis(revision.submittedAt));
      upsertRows(tx,[model('FoodCardRevision',{...revision,status:'WITHDRAWN',reviewedAt:new Date(now),reviewReason:''})]);
      output={success:true,status:'WITHDRAWN',unchanged:false};return true;
    }});
    if(!committed||!output)throw new Error('撤回未保存，请重试。');return output;
  }

  const MIGRATION_TYPES = Object.freeze(['BACKFILL_CARD', 'MIGRATE_REACTION']);
  const CARD_HISTORY_JOB_ID = hash('BACKFILL_CARD:stage1-v1:1');
  const REACTION_HISTORY_JOB_ID = hash('MIGRATE_REACTION:stage1-v1:1');
  function cardHistoryCheckpoint(job) {
    let checkpoint;
    try { checkpoint = JSON.parse(String(job.checkpointJson || '{}')); }
    catch (_error) { throw accessError('卡片回填检查点无效，请核对维护记录。', 'INVALID_STATE'); }
    if (!checkpoint || typeof checkpoint !== 'object' || Array.isArray(checkpoint)) {
      throw accessError('卡片回填检查点无效，请核对维护记录。', 'INVALID_STATE');
    }
    return checkpoint;
  }
  function cardHistoryState(job) {
    if (!job) return { initialized: false, ready: false, batchSize: BATCH, job: null };
    if (job.jobType !== 'BACKFILL_CARD' || Number(job.generation) !== 1 ||
      (job.entityId && job.entityId !== 'stage1-v1')) throw accessError('卡片回填任务标识冲突。', 'INVALID_STATE');
    const checkpoint = cardHistoryCheckpoint(job);
    const ready = job.status === 'DONE' && checkpoint.coverageComplete === true &&
      Number(checkpoint.failures) === 0 && Number(checkpoint.verificationMissing) === 0;
    return { initialized: true, ready, batchSize: BATCH, job: { ...jobView(job), checkpoint } };
  }
  // Worker-only adapter for the fixed card-history task. It cannot select an
  // arbitrary job/table or schedule account deletion and other maintenance.
  async function cardHistoryMaintenance(payload = {}, env = {}) {
    const mode = payload.mode === undefined ? 'status' : payload.mode;
    if (!['status', 'initialize', 'run', 'retry'].includes(mode)) throw accessError('卡片回填维护模式无效。', 'VALIDATION_ERROR');
    const jobs = collection(env, 'MaintenanceJob');
    if (mode === 'status') return cardHistoryState(await one(jobs.query().equalTo('jobId', CARD_HISTORY_JOB_ID)));
    const enabled = env.SHIKE_MAINTENANCE_ENABLED === undefined ? process.env.SHIKE_MAINTENANCE_ENABLED : env.SHIKE_MAINTENANCE_ENABLED;
    if (String(enabled || '') !== 'true') throw accessError('请先启用维护写入开关。', 'FEATURE_NOT_READY');
    if (mode === 'initialize' || mode === 'retry') {
      const committed = await jobs.runTransaction({ apply: async tx => {
        const current = await txOne(tx, env, 'MaintenanceJob', 'jobId', CARD_HISTORY_JOB_ID);
        if (current) cardHistoryState(current);
        const now = Date.now();
        if (mode === 'initialize') {
          if (!current) upsertRows(tx, [jobRow('BACKFILL_CARD', 'stage1-v1', '', 1, now, now,
            { phase: 'MIGRATE', baselineAt: now, scanned: 0, migrated: 0, skipped: 0, failures: 0,
              verificationCursor: '', verificationScanned: 0, verificationMissing: 0, coverageComplete: false })]);
          return true;
        }
        if (!current) throw accessError('请先初始化卡片回填任务。', 'NOT_FOUND');
        if (!['FAILED', 'RETRY_WAIT', 'DONE'].includes(current.status)) throw accessError('任务尚在处理或已取消，请查看进度后再操作。', 'CONFLICT');
        const checkpoint = cardHistoryCheckpoint(current);
        if (!Number.isSafeInteger(checkpoint.baselineAt) || checkpoint.baselineAt <= 0 || checkpoint.baselineAt > now) {
          throw accessError('卡片回填基线无效，请核对维护记录。', 'INVALID_STATE');
        }
        if (checkpoint.phase === 'VERIFY' || current.status === 'DONE') {
          checkpoint.phase = 'VERIFY'; checkpoint.verificationCursor = ''; checkpoint.verificationScanned = 0;
        }
        checkpoint.failures = 0; checkpoint.failedEntityId = ''; checkpoint.verificationMissing = 0;
        checkpoint.verificationMissingEntityId = ''; checkpoint.coverageComplete = false;
        upsertRows(tx, [model('MaintenanceJob', { ...current, status: 'PENDING', attemptCount: 0,
          checkpointJson: JSON.stringify(checkpoint), lastErrorCode: '', leaseOwner: '', leaseUntilAt: null,
          runAfterAt: new Date(now), updatedAt: new Date(now) })]);
        return true;
      } });
      if (!committed) throw accessError('卡片回填任务未保存，请重试。', 'CONFLICT');
    }
    const current = await one(jobs.query().equalTo('jobId', CARD_HISTORY_JOB_ID));
    const state = cardHistoryState(current);
    if (!current) throw accessError('请先初始化卡片回填任务。', 'NOT_FOUND');
    if (mode !== 'run' || state.ready || ['FAILED', 'CANCELLED', 'DONE'].includes(current.status)) return state;
    const checkpoint = cardHistoryCheckpoint(current);
    if (!Number.isSafeInteger(checkpoint.baselineAt) || checkpoint.baselineAt <= 0 || checkpoint.baselineAt > Date.now()) {
      throw accessError('卡片回填基线无效，请核对维护记录。', 'INVALID_STATE');
    }
    await processMigration({ jobId: CARD_HISTORY_JOB_ID }, env);
    return cardHistoryState(await one(jobs.query().equalTo('jobId', CARD_HISTORY_JOB_ID)));
  }
  // Internal query-coverage gate; task processing is worker-only.
  async function migrationReadiness(env, includeJobs = false) {
    const ids = MIGRATION_TYPES.map(type => hash(type + ':stage1-v1:1'));
    const rows = await collection(env, 'MaintenanceJob').query().in('jobId', ids).limit(ids.length).get();
    const jobs = ids.map(id => rows.find(row => row.jobId === id)).filter(Boolean).map(row => jobView(row, true));
    const cardJob = jobs.find((job) => job.jobType === 'BACKFILL_CARD');
    const reactionJob = jobs.find((job) => job.jobType === 'MIGRATE_REACTION');
    const complete = (job) => !!job && job.status === 'DONE' && job.checkpoint.coverageComplete === true &&
      Number(job.checkpoint.failures) === 0 && Number(job.checkpoint.verificationMissing) === 0;
    const cardReady = complete(cardJob);
    const reactionReady = complete(reactionJob);
    // Stage 3 consumes this gate; an environment variable alone cannot claim
    // that historical indexed queries have coverage.
    return { ...(includeJobs ? { jobs } : {}), cardCoverageComplete: cardReady, reactionCoverageComplete: reactionReady,
      indexedQueryReady: cardReady && reactionReady && String(env.SHIKE_INDEXED_QUERY_VERIFIED || process.env.SHIKE_INDEXED_QUERY_VERIFIED || '') === 'true',
      userQueryVerificationRequired: true };
  }
  function reactionHistoryState(job) {
    if (!job) return { initialized: false, ready: false, batchSize: BATCH, job: null };
    if (job.jobType !== 'MIGRATE_REACTION' || Number(job.generation) !== 1 || job.entityId !== 'stage1-v1') {
      throw accessError('旧互动迁移任务标识冲突。', 'INVALID_STATE');
    }
    let checkpoint;
    try { checkpoint = JSON.parse(String(job.checkpointJson || '{}')); }
    catch (_error) { throw accessError('旧互动迁移检查点无效。', 'INVALID_STATE'); }
    if (!checkpoint || typeof checkpoint !== 'object' || Array.isArray(checkpoint)) {
      throw accessError('旧互动迁移检查点无效。', 'INVALID_STATE');
    }
    if (!['MIGRATE', 'VERIFY'].includes(checkpoint.phase)) throw accessError('旧互动迁移阶段无效。', 'INVALID_STATE');
    const ready = job.status === 'DONE' && checkpoint.coverageComplete === true &&
      Number(checkpoint.failures) === 0 && Number(checkpoint.verificationMissing) === 0;
    return { initialized: true, ready, batchSize: BATCH, job: { ...jobView(job), checkpoint } };
  }
  // Worker-only continuation of the existing fixed reaction migration. It
  // cannot create/select arbitrary jobs or enter deletion maintenance.
  async function reactionHistoryMaintenance(payload = {}, env = {}) {
    const mode = payload.mode === undefined ? 'status' : payload.mode;
    if (!['status', 'run', 'retry'].includes(mode)) throw accessError('旧互动迁移维护模式无效。', 'VALIDATION_ERROR');
    const jobs = collection(env, 'MaintenanceJob');
    const current = await one(jobs.query().equalTo('jobId', REACTION_HISTORY_JOB_ID));
    const initial = reactionHistoryState(current);
    if (mode === 'status') return initial;
    if (!current) throw accessError('旧互动迁移任务不存在，请先核对任务记录。', 'NOT_FOUND');
    const enabled = env.SHIKE_MAINTENANCE_ENABLED === undefined ? process.env.SHIKE_MAINTENANCE_ENABLED : env.SHIKE_MAINTENANCE_ENABLED;
    if (String(enabled || '') !== 'true') throw accessError('请先启用维护写入开关。', 'FEATURE_NOT_READY');
    const baselineAt = Number(initial.job.checkpoint.baselineAt);
    if (!Number.isSafeInteger(baselineAt) || baselineAt <= 0 || baselineAt > Date.now()) {
      throw accessError('旧互动迁移基线无效。', 'INVALID_STATE');
    }
    if (mode === 'retry') {
      const committed = await jobs.runTransaction({ apply: async tx => {
        const job = await txOne(tx, env, 'MaintenanceJob', 'jobId', REACTION_HISTORY_JOB_ID);
        const state = reactionHistoryState(job);
        if (!job) throw accessError('旧互动迁移任务不存在。', 'NOT_FOUND');
        if (!['FAILED', 'RETRY_WAIT', 'DONE'].includes(job.status)) {
          throw accessError('任务尚在处理或已取消，请查看进度后再操作。', 'CONFLICT');
        }
        const checkpoint = state.job.checkpoint;
        if (Number(checkpoint.baselineAt) !== baselineAt) throw accessError('迁移基线已变化。', 'CONFLICT');
        if (checkpoint.phase === 'VERIFY' || job.status === 'DONE') {
          checkpoint.phase = 'VERIFY'; checkpoint.verificationCursor = ''; checkpoint.verificationScanned = 0;
        }
        checkpoint.failures = 0; checkpoint.failedEntityId = ''; checkpoint.verificationMissing = 0;
        checkpoint.verificationMissingEntityId = ''; checkpoint.coverageComplete = false;
        upsertRows(tx, [model('MaintenanceJob', { ...job, status: 'PENDING', attemptCount: 0,
          checkpointJson: JSON.stringify(checkpoint), lastErrorCode: '', leaseOwner: '', leaseUntilAt: null,
          runAfterAt: new Date(), updatedAt: new Date() })]);
        return true;
      } });
      if (!committed) throw accessError('旧互动迁移重试未保存。', 'CONFLICT');
    } else if (!initial.ready && !['FAILED', 'CANCELLED', 'DONE'].includes(current.status)) {
      await processMigration({ jobId: REACTION_HISTORY_JOB_ID }, env);
    }
    return reactionHistoryState(await one(jobs.query().equalTo('jobId', REACTION_HISTORY_JOB_ID)));
  }
  async function claimMigration(jobId, env) {
    const leaseOwner = crypto.randomUUID();
    let result = null;
    const committed = await collection(env, 'MaintenanceJob').runTransaction({ apply: async (tx) => {
      result = null;
      const job = await txOne(tx, env, 'MaintenanceJob', 'jobId', jobId);
      if (!job) throw accessError('任务不存在。', 'NOT_FOUND');
      if (!MIGRATION_TYPES.includes(job.jobType)) throw accessError('此任务不是迁移任务。', 'INVALID_STATE');
      if (['DONE', 'CANCELLED'].includes(job.status)) { result = job; return true; }
      const now = Date.now();
      const lease = dateMillis(job.leaseUntilAt);
      const runAt = dateMillis(job.runAfterAt);
      if (runAt === null) throw accessError('任务调度时间无效。', 'INVALID_STATE');
      if (job.status === 'RUNNING' && lease !== null && lease > now) throw accessError('任务已被另一请求取得。', 'CONFLICT');
      if (!['PENDING', 'RETRY_WAIT', 'RUNNING'].includes(job.status)) throw accessError('请先重试失败任务。', 'INVALID_STATE');
      if (runAt > now) { result = job; return true; }
      result = model('MaintenanceJob', { ...job, status: 'RUNNING', leaseOwner, leaseUntilAt: new Date(now + 60000),
        attemptCount: Number(job.attemptCount || 0) + 1, updatedAt: new Date(now) });
      upsertRows(tx, [result]); return true;
    } });
    if (!committed || !result) throw new Error('任务租约未保存。');
    return { job: result, leaseOwner };
  }
  function requireLease(job, leaseOwner) {
    if (!job || job.status !== 'RUNNING' || job.leaseOwner !== leaseOwner || dateMillis(job.leaseUntilAt) === null ||
      dateMillis(job.leaseUntilAt) <= Date.now()) throw accessError('任务租约已失效。', 'CONFLICT');
  }
  async function processMigration(payload, env) {
    const jobId = String(payload.jobId || '');
    const claimed = await claimMigration(jobId, env);
    if (claimed.job.status !== 'RUNNING' || claimed.job.leaseOwner !== claimed.leaseOwner) return { job: jobView(claimed.job, true) };
    let lastId = '';
    try {
      const checkpoint = JSON.parse(String(claimed.job.checkpointJson || '{}'));
      const verify = checkpoint.phase === 'VERIFY';
      const cursor = verify ? String(checkpoint.verificationCursor || '') : String(claimed.job.cursor || '');
      const object = claimed.job.jobType === 'BACKFILL_CARD' ? 'FoodCard' : 'CardAction';
      let query = collection(env, object).query();
      if (cursor) query = query.greaterThan('id', cursor);
      const rows = await query.orderByAsc('id').limit(BATCH).get();
      let expectedCursor = cursor;
      for (const row of rows) {
        lastId = String(row.id);
        const committed = await collection(env, 'MaintenanceJob').runTransaction({ apply: async (tx) => {
          const job = await txOne(tx, env, 'MaintenanceJob', 'jobId', jobId);
          requireLease(job, claimed.leaseOwner);
          const progress = JSON.parse(String(job.checkpointJson || '{}'));
          const currentCursor = verify ? String(progress.verificationCursor || '') : String(job.cursor || '');
          if (currentCursor !== expectedCursor) throw accessError('迁移进度已变化。', 'CONFLICT');
          const current = await txOne(tx, env, object, 'id', row.id);
          let changed = false;
          let missing = false;
          if (object === 'FoodCard' && current) {
            const created = Number(current.createdAt || 0);
            const legacy = Number(current.schemaVersion || 0) === 0 && !String(current.reviewState || '');
            const pendingLegacy = legacy && current.status === 'PENDING';
            const historical = Number.isSafeInteger(created) && created > 0 && created <= Number(progress.baselineAt);
            const modified = Number(current.updatedAt || created);
            if (legacy && (!historical || !Number.isSafeInteger(modified) || modified < 0 || !['APPROVED', 'REMOVED', 'PENDING'].includes(current.status))) {
              throw accessError('历史卡片不符合确定性迁移基线。', 'INVALID_STATE');
            }
            // Unpublished legacy cards remain untouched. They count as scanned
            // and skipped, and are outside published-card timestamp coverage.
            // Keep the same exception in verification without approving them.
            if (verify) missing = (legacy && !pendingLegacy) || (readableCardState(current) && dateMillis(current.publishedAt) === null);
            else if (legacy && historical && !pendingLegacy) {
              upsertRows(tx, [model('FoodCard', { ...current, ...derived(current), schemaVersion: 1, migrationSource: 'LEGACY',
                consumptionMode: 'UNSPECIFIED', visibility: 'PUBLIC', reviewState: current.status === 'APPROVED' ? 'LEGACY_APPROVED' : 'TAKEN_DOWN',
                publishedAt: new Date(created), modifiedAt: new Date(modified), lifecycleGeneration: generation(current), edited: false })]);
              changed = true;
            }
          } else if (object === 'CardAction' && current && current.kind === 'LIKE') {
            if (verify) missing = true;
            else {
              const card = await txOne(tx, env, 'FoodCard', 'id', current.cardId);
              const actor = await txOne(tx, env, 'UserProfile', 'uid', current.actorUid);
              const reactions = await tx.executeQuery(collection(env, 'CardReaction').query().equalTo('cardId', current.cardId)
                .equalTo('uid', current.actorUid).limit(1));
              // Preserve an existing DISLIKE and never rebuild a deleted NONE:
              // user mutation deletes the source LIKE in the same transaction.
              if (!reactions[0] && card && isAccountActive(actor)) {
                const created = Number(current.createdAt || 0);
                if (!Number.isSafeInteger(created) || created < 0) throw accessError('旧互动时间无效。', 'INVALID_STATE');
                upsertRows(tx, [model('CardReaction', { cardId: current.cardId, uid: current.actorUid, reaction: 'LIKE',
                  createdAt: new Date(created), updatedAt: new Date() })]);
              }
              if (card) upsertRows(tx, [model('FoodCard', card)]);
              if (actor) upsertRows(tx, [profileForWrite(actor, logicalWriteTime(actor.updatedAt))]);
              tx.executeDelete([current]); changed = true;
            }
          }
          if (verify) {
            progress.verificationCursor = lastId;
            progress.verificationScanned = Number(progress.verificationScanned || 0) + 1;
            if (missing) {
              progress.verificationMissing = Number(progress.verificationMissing || 0) + 1;
              progress.verificationMissingEntityId = lastId;
            }
          } else {
            progress.scanned = Number(progress.scanned || 0) + 1;
            progress[changed ? 'migrated' : 'skipped'] = Number(progress[changed ? 'migrated' : 'skipped'] || 0) + 1;
          }
          if (progress.failedEntityId === lastId) { progress.failedEntityId = ''; progress.failures = 0; }
          upsertRows(tx, [model('MaintenanceJob', { ...job, cursor: verify ? job.cursor : lastId,
            checkpointJson: JSON.stringify(progress), leaseUntilAt: new Date(Date.now() + 60000), updatedAt: new Date() })]);
          return true;
        } });
        if (!committed) throw new Error('迁移行与游标未提交。');
        expectedCursor = lastId;
      }
      let finalJob = null;
      const committed = await collection(env, 'MaintenanceJob').runTransaction({ apply: async (tx) => {
        const job = await txOne(tx, env, 'MaintenanceJob', 'jobId', jobId);
        requireLease(job, claimed.leaseOwner);
        const progress = JSON.parse(String(job.checkpointJson || '{}'));
        let status = 'PENDING';
        if (rows.length < BATCH) {
          if (!verify) progress.phase = 'VERIFY';
          else {
            progress.coverageComplete = Number(progress.verificationMissing || 0) === 0 && Number(progress.failures || 0) === 0;
            status = progress.coverageComplete ? 'DONE' : 'FAILED';
          }
        }
        finalJob = model('MaintenanceJob', { ...job, status, checkpointJson: JSON.stringify(progress),
          leaseOwner: '', leaseUntilAt: null, runAfterAt: new Date(), updatedAt: new Date(),
          lastErrorCode: status === 'FAILED' ? 'COVERAGE_INCOMPLETE' : '' });
        upsertRows(tx, [finalJob]); return true;
      } });
      if (!committed || !finalJob) throw new Error('迁移批次未完成。');
      return { job: jobView(finalJob, true) };
    } catch (error) {
      // A failed row never advances its cursor. The next retry sees it again.
      await collection(env, 'MaintenanceJob').runTransaction({ apply: async (tx) => {
        const job = await txOne(tx, env, 'MaintenanceJob', 'jobId', jobId);
        if (!job || job.status !== 'RUNNING' || job.leaseOwner !== claimed.leaseOwner) return true;
        const progress = JSON.parse(String(job.checkpointJson || '{}'));
        progress.failures = Number(progress.failures || 0) + 1; progress.failedEntityId = lastId;
        const attempt = Number(job.attemptCount || 0);
        upsertRows(tx, [model('MaintenanceJob', { ...job, status: attempt >= 5 ? 'FAILED' : 'RETRY_WAIT',
          checkpointJson: JSON.stringify(progress), lastErrorCode: error && typeof error.code === 'string' ? error.code : 'MIGRATION_FAILED',
          runAfterAt: new Date(Date.now() + Math.min(3600000, 60000 * Math.pow(2, Math.min(attempt, 6)))),
          leaseOwner: '', leaseUntilAt: null, updatedAt: new Date() })]); return true;
      } });
      throw error;
    }
  }

  return { editableState, reactionSummary, favoriteSummary, mutateReaction, softDelete, beginAccountDeletion, derived,
    submitRevision, getEditContext, withdrawRevision,
    migrationReadiness, cardHistoryMaintenance, reactionHistoryMaintenance, processMigration, jobRow, jobView, txOne, activeProfile, model, hash, cardTime,
    publishReceiptSpec, checkPublishReceipt, readPublishReceipt, upsertRows };
}

module.exports = { createStage1Services };
