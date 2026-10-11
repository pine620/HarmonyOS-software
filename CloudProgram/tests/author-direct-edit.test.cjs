'use strict';
// User-run regression tests. The agent does not execute these tests.
// Real edit and counter services; a transactional in-memory SDK boundary only.
const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');
const { createStage1Services } = require('../cloudfunctions/shike-service/stage1-services');
const { createStage2Services } = require('../cloudfunctions/shike-service/stage2-services');
const { createContentPolicy, accessError } = require('../cloudfunctions/shared/content-policy');

const PHOTO_1 = '11111111-1111-4111-8111-111111111111';
const PHOTO_2 = '22222222-2222-4222-8222-222222222222';
const REQUEST_1 = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const REQUEST_2 = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const primary = { FoodCard: 'id', FoodCardRevision: 'revisionId', CardMedia: 'id', UserProfile: 'uid', Merchant: 'merchantId' };
const clone = value => structuredClone(value);

function helpers() {
  const source = readFileSync(join(__dirname, '../cloudfunctions/shike-service/runtime.js'), 'utf8');
  const block = (start, end) => {
    const first = source.indexOf(start), last = source.indexOf(end, first);
    assert.ok(first >= 0 && last > first);
    return source.slice(first, last);
  };
  const scope = { MAX_CARD_PHOTOS: 6, MAX_CARD_REVIEW_LENGTH: 600, accessError,
    VALID_CATEGORY: new Set(['staple', 'bakery', 'drink', 'snack', 'fresh', 'other']),
    PERSONALIZED: /新客|首单|白条|补贴|会员|账号|用户专享|个人专享/,
    validHttpsUrl: value => { const url = new URL(value); return url.protocol === 'https:' && !url.username && !url.password ? url.toString() : ''; } };
  vm.runInNewContext(block('function validateCard(', 'async function publishCard(') +
    block('function uniqueMediaIds(', 'async function publicProfile('), scope);
  return scope;
}

function fixture() {
  let tables = Object.fromEntries(Object.keys(primary).map(name => [name, new Map()]));
  const events = [], promotions = [], refreshes = [];
  const put = (name, row) => tables[name].set(row[primary[name]], clone({ ...row }));
  const row = (name, id) => clone(tables[name].get(id));
  const snapshot = () => Object.fromEntries(Object.entries(tables).map(([name, rows]) => [name, clone([...rows])]));
  const restore = saved => { tables = Object.fromEntries(Object.entries(saved).map(([name, rows]) => [name, new Map(clone(rows))])); };
  const serialized = () => JSON.stringify(snapshot());
  const state = { failCommit: false, beforeTransaction: null, beforeCardRead: null };
  const query = name => {
    const filters = [], order = [];
    let count = Infinity, offset = 0;
    const api = { name,
      equalTo: (field, value) => { filters.push(row => row[field] === value); return api; },
      orderByAsc: field => { order.push([field, 1]); return api; },
      orderByDesc: field => { order.push([field, -1]); return api; },
      limit: (size, start = 0) => { count = size; offset = start; return api; },
      get: async () => {
        if (name === 'FoodCard' && state.beforeCardRead) {
          const hook = state.beforeCardRead; state.beforeCardRead = null; await hook();
        }
        return api.rows();
      },
      rows: () => [...tables[name].values()].filter(row => filters.every(filter => filter(row)))
        .sort((a, b) => { for (const [field, sign] of order) { if (a[field] < b[field]) return -sign; if (a[field] > b[field]) return sign; } return 0; })
        .slice(offset, offset + count).map(clone) };
    return api;
  };
  let tail = Promise.resolve();
  const transaction = ({ apply }) => {
    const pending = tail.then(async () => {
      if (state.beforeTransaction) { const hook = state.beforeTransaction; state.beforeTransaction = null; hook(); }
      const queued = [];
      let writing = false;
      const tx = {
        executeQuery: async query => { assert.equal(writing, false, 'all transaction reads must precede queued writes'); events.push(['read', query.name]); return query.rows(); },
        executeUpsert: rows => {
          assert.ok(rows.length > 0);
          const name = rows[0].getClassName();
          assert.ok(rows.every(row => row.getClassName() === name), 'SDK operation must contain one model class');
          writing = true; events.push(['write', name]); queued.push([name, rows.map(row => clone({ ...row }))]);
        }
      };
      const committed = await apply(tx);
      if (state.failCommit) throw new Error('SDK_COMMIT_FAILED');
      if (committed) for (const [name, rows] of queued) for (const row of rows) put(name, row);
      return committed;
    });
    tail = pending.catch(() => {});
    return pending;
  };
  const collection = (_env, name) => ({ query: () => query(name), runTransaction: transaction });
  const one = async query => (await query.limit(1).get())[0] || null;
  const models = Object.fromEntries(Object.keys(primary).map(name => [name, class { getClassName() { return name; } }]));
  const h = helpers();
  let stage2;
  const ctx = { collection, one, models,
    logicalWriteTime: (...values) => Math.max(2000, ...values.filter(value => value != null).map(value => Number(value) + 1)),
    profileForWrite: (profile, now) => Object.assign(new models.UserProfile(), profile, { updatedAt: now, contentSequence: Number(profile.contentSequence || 0) + 1 }),
    contentPolicy: () => createContentPolicy(name => collection({}, name), one),
    stage2: () => stage2, safeArray: value => { try { const result = JSON.parse(value || '[]'); return Array.isArray(result) ? result : []; } catch (_) { return []; } },
    personalized: h.PERSONALIZED, validateCard: h.validateCard, uniqueMediaIds: h.uniqueMediaIds,
    promotePendingMedia: async media => { promotions.push(media.id); media.status = 'APPROVED'; },
    refreshPublishCount: async uid => { refreshes.push(uid); }
  };
  stage2 = createStage2Services(ctx);
  const service = createStage1Services(ctx);
  put('UserProfile', { uid: 'author', accountStatus: 'ACTIVE', updatedAt: 1000, publishCount: 1 });
  put('UserProfile', { uid: 'other', accountStatus: 'ACTIVE', updatedAt: 1000 });
  put('FoodCard', { id: 'card', ownerUid: 'author', productName: '原版美食', reviewText: '原点评', tasteScore: 8,
    sourceLink: '', category: 'staple', categoryV2: 'RICE_SET', categoryVersion: 2, status: 'APPROVED', reviewState: 'APPROVED',
    schemaVersion: 2, migrationSource: 'SERVER', visibility: 'PUBLIC', edited: false, lifecycleGeneration: 0,
    createdAt: 500, publishedAt: new Date(500), modifiedAt: new Date(1000), updatedAt: 1000,
    merchantId: 'shop-1', consumptionMode: 'DELIVERY', itemPriceFen: 1200, priceFen: 1200, shop: '原店铺',
    mediaId: PHOTO_1, consumedAt: null, sellingPointsJson: '[]', publicOffersJson: '[]' });
  for (const [id, name, count] of [['shop-1', '原店铺', 1], ['shop-2', '新店铺', 0]]) put('Merchant', {
    merchantId: id, name, address: name + '地址', verificationStatus: 'VERIFIED_PROVIDER', coordinateSystem: 'GCJ02',
    publicRecommendationCount: count, publicDeliveryCount: count, publicDineInCount: 0, mapVisible: count > 0, updatedAt: new Date(1000)
  });
  put('CardMedia', { id: PHOTO_1, ownerUid: 'author', cardId: 'card', status: 'APPROVED', createdAt: 500 });
  put('CardMedia', { id: PHOTO_2, ownerUid: 'author', cardId: '', status: 'PENDING_UPLOAD', createdAt: 1500 });
  const request = (overrides = {}) => ({ cardId: 'card', requestId: REQUEST_1, baseModifiedAt: 1000, baseLifecycleGeneration: 0,
    changes: { productName: '新版美食', reviewText: '新点评', tasteScore: 9, merchantId: 'shop-2', consumptionMode: 'DINE_IN', dineInAvgFen: 3500 },
    mediaIds: [PHOTO_2], ...overrides });
  const submit = (payload = request(), uid = 'author') => service.submitRevision(uid, payload, {});
  // Create a historically stored version with the exact server-normalized
  // payload, then restore the public card and counters to the pre-apply state.
  const legacy = async (status = 'PENDING', withHash = true) => {
    const before = snapshot(), result = await submit(), revision = row('FoodCardRevision', result.revision.revisionId);
    restore(before); revision.status = status; revision.submittedAt = new Date(1500); revision.reviewedAt = null;
    if (!withHash) delete revision.requestPayloadHash;
    put('FoodCardRevision', revision);
    put('CardMedia', { ...row('CardMedia', PHOTO_2), cardId: 'revision:' + revision.revisionId, status: 'APPROVED' });
    events.length = 0; promotions.length = 0; refreshes.length = 0;
    return revision;
  };
  return { row, put, snapshot, serialized, state, events, promotions, refreshes, request, submit, legacy };
}

test('author save applies text, server snapshots, image replacement and merchant counters atomically', async () => {
  const f = fixture(), result = await f.submit();
  const card = f.row('FoodCard', 'card');
  assert.equal(result.revision.status, 'APPROVED');
  assert.equal(result.alreadyProcessed, false);
  assert.equal(card.productName, '新版美食'); assert.equal(card.reviewText, '新点评');
  assert.equal(card.queryPriceFen, 3500); assert.equal(card.merchantNameSnapshot, '新店铺');
  assert.equal(card.searchTextNormalized, '新版美食 新店铺');
  assert.equal(card.reviewState, 'PENDING_POST_REVIEW'); assert.equal(card.edited, true);
  assert.equal(card.modifiedAt.getTime(), 2000); assert.equal(card.lifecycleGeneration, 1);
  assert.equal(card.createdAt, 500); assert.equal(card.publishedAt.getTime(), 500);
  assert.equal(card.mediaId, PHOTO_2);
  assert.equal(f.row('CardMedia', PHOTO_2).cardId, 'card'); assert.equal(f.row('CardMedia', PHOTO_2).status, 'APPROVED');
  assert.equal(f.row('CardMedia', PHOTO_1).cardId, 'revision:' + result.revision.revisionId);
  assert.equal(f.row('CardMedia', PHOTO_1).status, 'RETIRED');
  assert.deepEqual([f.row('Merchant', 'shop-1').publicRecommendationCount, f.row('Merchant', 'shop-1').publicDeliveryCount], [0, 0]);
  assert.equal(f.row('Merchant', 'shop-1').mapVisible, false);
  assert.deepEqual([f.row('Merchant', 'shop-2').publicRecommendationCount, f.row('Merchant', 'shop-2').publicDineInCount], [1, 1]);
  assert.equal(f.row('Merchant', 'shop-2').mapVisible, true);
  assert.equal(f.refreshes.length, 0, 'ordinary edit must not scan all author cards');
});

test('changing consumption mode within one merchant preserves total count and moves mode counts', async () => {
  const f = fixture();
  await f.submit(f.request({ changes: { consumptionMode: 'DINE_IN', dineInAvgFen: 2200 }, mediaIds: [PHOTO_1] }));
  const shop = f.row('Merchant', 'shop-1');
  assert.deepEqual([shop.publicRecommendationCount, shop.publicDeliveryCount, shop.publicDineInCount], [1, 0, 1]);
  assert.equal(f.promotions.length, 0);
});

test('retained photos and text-only edits avoid promotions and counter writes; dates use CloudDB Date', async () => {
  const f = fixture();
  await f.submit(f.request({ changes: { productName: '文字更新', consumedAt: 86400000 }, mediaIds: [PHOTO_1] }));
  assert.equal(f.row('CardMedia', PHOTO_1).cardId, 'card');
  assert.equal(f.row('FoodCard', 'card').consumedAt.getTime(), 86400000);
  assert.equal(f.events.filter(event => event[0] === 'write' && event[1] === 'Merchant').length, 0);
  assert.equal(f.promotions.length, 0);
});

test('successful immutable receipt replays after later edits without overwriting content or counting twice', async () => {
  const f = fixture(), request = f.request(), first = await f.submit(request), card = f.row('FoodCard', 'card');
  await f.submit(f.request({ requestId: REQUEST_2, baseModifiedAt: card.modifiedAt.getTime(), baseLifecycleGeneration: card.lifecycleGeneration,
    changes: { productName: '之后的编辑' } }));
  const before = f.serialized(), replay = await f.submit(request);
  assert.equal(replay.alreadyProcessed, true); assert.deepEqual(replay.revision, first.revision);
  assert.equal(f.serialized(), before);
  await assert.rejects(f.submit({ ...request, changes: { ...request.changes, productName: '偷换请求' } }), { code: 'CONFLICT' });
  await assert.rejects(f.submit({ ...request, mediaIds: [PHOTO_1] }), { code: 'CONFLICT' });
  assert.equal(f.serialized(), before);
});

test('identical request committed between the receipt read and card read returns its immutable success', async () => {
  const f = fixture(); let first;
  f.state.beforeCardRead = async () => { first = await f.submit(); };
  const replay = await f.submit();
  assert.equal(replay.alreadyProcessed, true); assert.deepEqual(replay.revision, first.revision);
  assert.equal(f.row('FoodCard', 'card').lifecycleGeneration, 1);
  assert.equal(f.row('Merchant', 'shop-2').publicRecommendationCount, 1);
});

test('unauthorized author, inactive account, foreign photos, deletion and take-down cannot apply edits', async () => {
  const cases = [
    f => ['other', f.request()],
    f => { f.put('UserProfile', { ...f.row('UserProfile', 'author'), accountStatus: 'DELETION_IN_PROGRESS' }); return ['author', f.request()]; },
    f => { f.put('CardMedia', { ...f.row('CardMedia', PHOTO_2), ownerUid: 'other' }); return ['author', f.request()]; },
    f => { f.put('CardMedia', { ...f.row('CardMedia', PHOTO_2), cardId: 'other-card', status: 'APPROVED' }); return ['author', f.request()]; },
    f => { f.put('FoodCard', { ...f.row('FoodCard', 'card'), deletedAt: new Date(1100), purgeAt: new Date(2200) }); return ['author', f.request()]; },
    f => { f.put('FoodCard', { ...f.row('FoodCard', 'card'), status: 'REMOVED', reviewState: 'TAKEN_DOWN' }); return ['author', f.request()]; }
  ];
  for (const setup of cases) {
    const f = fixture(), [uid, payload] = setup(f), before = f.serialized();
    await assert.rejects(f.submit(payload, uid)); assert.equal(f.serialized(), before);
  }
  const f = fixture(), request = f.request(); await f.submit(request);
  f.put('UserProfile', { ...f.row('UserProfile', 'author'), accountStatus: 'INACTIVE' });
  await assert.rejects(f.submit(request), { code: 'ACCOUNT_INACTIVE' });
});

test('invalid content, server-owned fields and incomplete or repeated photos are rejected', async () => {
  const cases = [{ changes: { productName: '短' } }, { changes: { priceFen: -1 } }, { changes: { itemPriceFen: -1 } },
    { changes: { tasteScore: 11 } }, { changes: { reviewText: '评'.repeat(601) } },
    { changes: { ownerUid: 'other' } }, { mediaIds: [] }, { mediaIds: [PHOTO_1, PHOTO_1] }];
  for (const overrides of cases) {
    const f = fixture(), before = f.serialized();
    await assert.rejects(f.submit(f.request(overrides))); assert.equal(f.serialized(), before);
    assert.equal(f.promotions.length, 0);
  }
});

test('stale base versions and transaction-time changes reject without partial application', async () => {
  for (const overrides of [{ baseModifiedAt: 999 }, { baseLifecycleGeneration: 1 }]) {
    const f = fixture(), before = f.serialized();
    await assert.rejects(f.submit(f.request(overrides)), { code: 'CONFLICT' }); assert.equal(f.serialized(), before);
    assert.equal(f.promotions.length, 0, 'stale edit must fail before storage promotion');
  }
  const f = fixture(); let afterExternalChange;
  f.state.beforeTransaction = () => {
    f.put('FoodCard', { ...f.row('FoodCard', 'card'), productName: '其他设备修改', modifiedAt: new Date(1100), lifecycleGeneration: 1 });
    afterExternalChange = f.serialized();
  };
  await assert.rejects(f.submit(), { code: 'CONFLICT' }); assert.equal(f.serialized(), afterExternalChange);
});

test('invalid counter or failed SDK commit leaves card, receipt, media and counters unapplied', async () => {
  const invalid = fixture(); invalid.put('Merchant', { ...invalid.row('Merchant', 'shop-1'), publicDeliveryCount: 0 });
  const beforeInvalid = invalid.serialized();
  await assert.rejects(invalid.submit(), { code: 'COUNTER_RECONCILIATION_REQUIRED' });
  assert.equal(invalid.serialized(), beforeInvalid);
  const failed = fixture(), before = failed.serialized(); failed.state.failCommit = true;
  await assert.rejects(failed.submit(), /SDK_COMMIT_FAILED/); assert.equal(failed.serialized(), before);
  assert.ok(failed.events.some(event => event[0] === 'write'), 'failure is after queued writes');
  failed.state.failCommit = false; await failed.submit(); assert.equal(failed.row('FoodCard', 'card').lifecycleGeneration, 1);
});

test('only an author-triggered save applies historical pending receipts, including receipts without an input hash', async () => {
  for (const withHash of [true, false]) {
    const f = fixture(), revision = await f.legacy('PENDING', withHash);
    assert.equal(f.row('FoodCard', 'card').productName, '原版美食');
    const result = await f.submit();
    assert.equal(result.revision.status, 'APPROVED'); assert.equal(result.alreadyProcessed, false);
    assert.equal(result.revision.submittedAt, 1500);
    assert.equal(f.row('CardMedia', PHOTO_2).cardId, 'card');
    assert.equal(f.row('FoodCardRevision', revision.revisionId).status, 'APPROVED');
    assert.equal((await f.submit()).alreadyProcessed, true);
  }
});

test('new saves supersede other pending versions; rejected or withdrawn receipts cannot auto-apply', async () => {
  const f = fixture(), legacy = await f.legacy();
  await f.submit(f.request({ requestId: REQUEST_2 }));
  assert.equal(f.row('FoodCardRevision', legacy.revisionId).status, 'WITHDRAWN');
  assert.equal(f.row('FoodCardRevision', legacy.revisionId).reviewReason, 'SUPERSEDED');
  for (const status of ['REJECTED', 'WITHDRAWN']) {
    const old = fixture(); await old.legacy(status); const before = old.serialized(), result = await old.submit();
    assert.equal(result.revision.status, status); assert.equal(result.alreadyProcessed, true); assert.equal(old.serialized(), before);
    await old.submit(old.request({ requestId: REQUEST_2 })); assert.equal(old.row('FoodCard', 'card').productName, '新版美食');
  }
});

test('REQUEST_CHANGE recovery updates visibility and counts while preserving unverified merchant restrictions', async () => {
  const f = fixture(); f.put('FoodCard', { ...f.row('FoodCard', 'card'), status: 'REMOVED', reviewState: 'REQUEST_CHANGE' });
  f.put('Merchant', { ...f.row('Merchant', 'shop-1'), publicRecommendationCount: 0, publicDeliveryCount: 0, mapVisible: false });
  await f.submit(f.request({ changes: { reviewText: '已修正' }, mediaIds: [PHOTO_1] }));
  assert.equal(f.row('FoodCard', 'card').status, 'APPROVED'); assert.equal(f.row('Merchant', 'shop-1').publicRecommendationCount, 1);
  assert.deepEqual(f.refreshes, ['author']);
  const pending = fixture(); pending.put('Merchant', { ...pending.row('Merchant', 'shop-2'), verificationStatus: 'USER_CONFIRMED_PENDING', createdByUid: 'other' });
  const before = pending.serialized(); await assert.rejects(pending.submit(), { code: 'MERCHANT_NOT_VERIFIED' }); assert.equal(pending.serialized(), before);
});

test('concurrent saves from one base allow one edit; simultaneous identical retries apply once', async () => {
  const f = fixture();
  const outcomes = await Promise.allSettled([f.submit(), f.submit(f.request({ requestId: REQUEST_2 }))]);
  assert.equal(outcomes.filter(result => result.status === 'fulfilled').length, 1);
  assert.equal(outcomes.find(result => result.status === 'rejected').reason.code, 'CONFLICT');
  assert.equal(f.row('FoodCard', 'card').lifecycleGeneration, 1);
  const same = fixture(), results = await Promise.all([same.submit(), same.submit()]);
  assert.deepEqual(results.map(result => result.alreadyProcessed).sort(), [false, true]);
  assert.equal(same.row('FoodCard', 'card').lifecycleGeneration, 1);
  assert.equal(same.row('Merchant', 'shop-2').publicRecommendationCount, 1);
});
