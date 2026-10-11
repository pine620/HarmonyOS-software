'use strict';
// User-run tests: in-memory fixtures, no cloud connection, credentials or device.
const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { createFoodRankingServices } = require('../cloudfunctions/shike-service/food-ranking-services');
const { createStage7Services } = require('../cloudfunctions/shike-service/stage7-services');
const { withCursorContext } = require('../cloudfunctions/shike-service/stages47-common');
const { policyModels } = require('../cloudfunctions/shared/content-policy');

const ENV = { SHIKE_FOOD_RANKINGS_VERIFIED: 'true', SHIKE_INDEXED_QUERY_VERIFIED: 'true',
  SHIKE_CURSOR_SIGNING_KEY: '1'.repeat(64) };
const point = { kind: 'HIGH_SCORE', cursor: '' };
function query(getRows) {
  const orders = []; const stack = [{ parts: [], op: 'and' }]; let count = Infinity;
  const value = item => item instanceof Date ? item.getTime() : item;
  function add(predicate) { const group = stack[stack.length - 1]; group.parts.push({ predicate, op: group.op }); group.op = 'and'; }
  function compare(field, expected, predicate) { add(row => predicate(value(row[field]), value(expected))); return q; }
  const q = {
    and: () => { stack[stack.length - 1].op = 'and'; return q; },
    or: () => { stack[stack.length - 1].op = 'or'; return q; },
    beginGroup: () => { stack.push({ parts: [], op: 'and' }); return q; },
    endGroup: () => { const group = stack.pop(); add(row => group.parts.reduce((result, part, index) =>
      index === 0 ? part.predicate(row) : part.op === 'or' ? result || part.predicate(row) : result && part.predicate(row), true)); return q; },
    equalTo: (field, expected) => compare(field, expected, (a, b) => a === b),
    greaterThan: (field, expected) => compare(field, expected, (a, b) => a > b),
    lessThan: (field, expected) => compare(field, expected, (a, b) => a < b),
    greaterThanOrEqualTo: (field, expected) => compare(field, expected, (a, b) => a >= b),
    lessThanOrEqualTo: (field, expected) => compare(field, expected, (a, b) => a <= b),
    orderByAsc: field => { orders.push([field, 1]); return q; },
    orderByDesc: field => { orders.push([field, -1]); return q; },
    limit: size => { count = size; return q; },
    get: async () => getRows().filter(row => stack[0].parts.every(part => part.predicate(row)))
      .sort((a, b) => { for (const [field, sign] of orders) {
        if (value(a[field]) < value(b[field])) return -sign;
        if (value(a[field]) > value(b[field])) return sign;
      } return 0; }).slice(0, count)
  };
  return q;
}
function merchant(merchantId, latitudeE6 = 30000000, longitudeE6 = 120000000, verificationStatus = 'VERIFIED_PROVIDER') {
  return { merchantId, name: merchantId, latitudeE6, longitudeE6, verificationStatus, coordinateSystem: 'GCJ02', updatedAt: new Date(100) };
}
function card(id, merchantId, tasteScore = 8, publishedAt = 100, ownerUid = 'author') {
  return { id, merchantId, ownerUid, tasteScore, publishedAt: new Date(publishedAt), modifiedAt: new Date(100),
    status: 'APPROVED', reviewState: 'APPROVED', lifecycleGeneration: 1, updatedAt: 100 };
}
function fixture(merchants, cards) {
  const data = { Merchant: merchants, FoodCard: cards, UserProfile: [{ uid: 'friend', updatedAt: 100 }] };
  let relations = [{ memberAUid: 'viewer', memberBUid: 'friend', status: 'ACCEPTED' }];
  const context = {
    collection: (_env, name) => ({ query: () => query(() => data[name] || []) }),
    one: async q => (await q.limit(1).get())[0] || null, models: { FoodCard: class FoodCard {} },
    contentPolicy: () => ({ assertAccountActive: async () => {}, assertProfileReadable: async () => {} }),
    stage1: () => ({ migrationReadiness: async () => ({ cardCoverageComplete: true }) }),
    friendshipRowsFor: async () => relations,
    friendshipBetween: async (uid, target) => relations.find(row => [row.memberAUid, row.memberBUid].includes(uid) &&
      [row.memberAUid, row.memberBUid].includes(target)) || null,
    readCardRowsByIds: async ids => new Map(data.FoodCard.filter(row => ids.includes(row.id)).map(row => [row.id, row])),
    readMerchantRowsByIds: async ids => new Map(data.Merchant.filter(row => ids.includes(row.merchantId)).map(row => [row.merchantId, row])),
    createCardReadContext: async () => ({}),
    readableCardRows: async rows => rows.filter(row => !row.deletedAt && row.status === 'APPROVED'),
    preparePrimaryPhotos: async () => {},
    readCardIfAllowed: async row => ({ id: row.id, tasteScore: row.tasteScore, photos: [] }),
    finalizeCardReads: async rows => rows,
    profileResponse: profile => ({ uid: profile.uid, nickname: '好友', publishCount: 0 }),
    previewCard: row => ({ id: row.id, photos: [] })
  };
  const service = createFoodRankingServices(context);
  async function request(payload = point, uid = '') { return withCursorContext(ENV, () => service.list(uid, payload, ENV)); }
  async function ready(payload = point, uid = '') {
    let response = await request(payload, uid), attempts = 0;
    while (response.phase === 'PREPARING') {
      assert.equal(response.items.length, 0, 'incomplete scans must not publish provisional ranks');
      assert.ok(response.nextCursor); assert.ok(++attempts < 100, 'preparation should make progress');
      response = await request({ ...payload, cursor: response.nextCursor }, uid);
    }
    return response;
  }
  return { data, context, request, ready, setRelations: rows => { relations = rows; } };
}

test('rank order is score, original publish time, then stable card ID regardless of distance', async () => {
  const f = fixture([merchant('near'), merchant('far', 30010000)], [
    card('lower-new', 'near', 9, 900), card('old-near', 'near', 10, 100), card('a-far', 'far', 10, 200),
    card('b-near', 'near', 10, 200), card('z-near', 'near', 10, 200)]);
  const response = await f.ready();
  assert.deepEqual(response.items.map(item => item.card.id), ['a-far', 'b-near', 'z-near', 'old-near', 'lower-new']);
  assert.deepEqual(response.items.map(item => item.rank), [1, 2, 3, 4, 5]);
});
test('cards beyond ten kilometers qualify without a location request; pending merchant and score one qualify', async () => {
  const local = merchant('pending', 30000000, 120000000, 'USER_CONFIRMED_PENDING');
  const f = fixture([local, merchant('outside', 30200000)], [card('historic-one', 'pending', 1, 1),
    card('outside-high-score', 'outside', 10, 100)]);
  const response = await f.ready();
  assert.deepEqual(response.items.map(item => item.card.id), ['outside-high-score', 'historic-one']);
  assert.equal(response.scope, 'ALL_VISIBLE'); assert.equal(response.totalCount, 2);
  assert.equal(Object.hasOwn(response, 'radiusMeters'), false);
  assert.equal(Object.hasOwn(response.items[0], 'distanceMeters'), false);
});
test('missing merchant coordinates and associations do not exclude visible cards; integer score rules remain', async () => {
  const f = fixture([merchant('inside', 30089932), merchant('outside', 30089933),
    merchant('unknown'), merchant('missing')], [card('inside', 'inside', 1), card('outside', 'outside', 10),
    card('score-ten', 'inside', 10), card('score-zero', 'inside', 0), card('score-eleven', 'inside', 11),
    card('score-fraction', 'inside', 8.5), card('score-string', 'inside', '8'),
    card('unknown-coordinate', 'unknown'), card('missing-coordinate', 'missing'), card('no-merchant', '')]);
  f.data.Merchant[2].coordinateSystem = 'UNKNOWN'; f.data.Merchant[3].latitudeE6 = null;
  assert.deepEqual((await f.ready()).items.map(item => item.card.id),
    ['outside', 'score-ten', 'missing-coordinate', 'no-merchant', 'unknown-coordinate', 'inside']);
});
test('complete fifty-card ranking paginates 20/20/10 with no duplicate or fifty-first card', async () => {
  const f = fixture([merchant('m')], Array.from({ length: 61 }, (_, index) => card('card-' + index, 'm', 8, 1000 - index)));
  let response = await f.ready(); const items = [...response.items]; const sizes = [response.items.length];
  assert.equal(response.totalCount, 50);
  while (response.nextCursor) {
    response = await f.request({ ...point, cursor: response.nextCursor }); sizes.push(response.items.length); items.push(...response.items);
  }
  assert.deepEqual(sizes, [20, 20, 10]); assert.equal(new Set(items.map(item => item.card.id)).size, 50);
  assert.equal(items[49].card.id, 'card-49'); assert.equal(items[49].rank, 50);
});
test('deleted rows beyond one request budget are skipped without publishing a partial ranking', async () => {
  const rows = Array.from({ length: 205 }, (_, index) => ({ ...card('deleted-' + index, 'm', 10, 1000 - index), deletedAt: new Date(2000) }));
  const f = fixture([merchant('m')], [...rows, card('valid-after-scan', 'm', 2, 1)]);
  const first = await f.request(); assert.equal(first.phase, 'PREPARING'); assert.equal(first.items.length, 0);
  const response = await f.ready({ ...point, cursor: first.nextCursor });
  assert.deepEqual(response.items.map(item => item.card.id), ['valid-after-scan']);
});
test('global preparation crosses its request budget before assigning ranks and includes later high scores', async () => {
  const f = fixture([], Array.from({ length: 225 }, (_, index) =>
    card('c-' + String(index).padStart(3, '0'), '', index === 224 ? 10 : 8, 100 + index)));
  const first = await f.request(); assert.equal(first.phase, 'PREPARING'); assert.equal(first.items.length, 0);
  const response = await f.ready({ ...point, cursor: first.nextCursor });
  assert.equal(response.totalCount, 50); assert.equal(response.items[0].card.id, 'c-224');
  assert.equal(response.scannedCardCount, 225);
});
test('friends ranking includes only current accepted friends and rejects guest reads', async () => {
  const f = fixture([merchant('m')], [card('friend-card', 'm', 1, 1, 'friend'), card('own-card', 'm', 10, 300, 'viewer'),
    card('stranger-card', 'm', 10, 200, 'stranger')]);
  const payload = { ...point, kind: 'FRIENDS' };
  await assert.rejects(f.request(payload), { code: 'AUTH_REQUIRED' });
  assert.deepEqual((await f.ready(payload, 'viewer')).items.map(item => item.card.id), ['friend-card']);
  f.setRelations([]); assert.equal((await f.ready(payload, 'viewer')).totalCount, 0);
});
test('signed pagination rejects changed card keys, friend set, viewer, kind and tampering; coordinates are irrelevant', async () => {
  const make = () => fixture([merchant('m')], Array.from({ length: 25 }, (_, index) => card('c-' + index, 'm', 8, 1000 - index, 'friend')));
  const a = make(), first = await a.ready(); a.data.FoodCard[0].tasteScore = 9;
  await assert.rejects(a.request({ ...point, cursor: first.nextCursor }), { code: 'CURSOR_STALE' });
  const b = make(), second = await b.ready(); b.data.Merchant[0].longitudeE6 += 200000;
  assert.equal((await b.request({ ...point, cursor: second.nextCursor })).phase, 'READY');
  const c = make(), friendsPoint = { ...point, kind: 'FRIENDS' }, third = await c.ready(friendsPoint, 'viewer'); c.setRelations([]);
  await assert.rejects(c.request({ ...friendsPoint, cursor: third.nextCursor }, 'viewer'), { code: 'CURSOR_STALE' });
  const d = make(), fourth = await d.ready();
  assert.equal((await d.request({ ...point, lat: 31, cursor: fourth.nextCursor })).phase, 'READY');
  await assert.rejects(d.request({ ...point, cursor: fourth.nextCursor }, 'viewer'), { code: 'CURSOR_STALE' });
  await assert.rejects(d.request({ ...point, kind: 'FRIENDS', cursor: fourth.nextCursor }, 'viewer'), { code: 'CURSOR_STALE' });
  const altered = (fourth.nextCursor[0] === 'a' ? 'b' : 'a') + fourth.nextCursor.slice(1);
  await assert.rejects(d.request({ ...point, cursor: altered }), { code: 'CURSOR_STALE' });
  const e = make(), fifth = await e.ready(); e.data.FoodCard[0].deletedAt = new Date();
  await assert.rejects(e.request({ ...point, cursor: fifth.nextCursor }), { code: 'CURSOR_STALE' });
});
test('global scope still excludes unreadable cards and rechecks visibility and friends after hydration', async () => {
  const f = fixture([], [card('allowed', '', 1), card('inactive-author', '', 10, 100, 'inactive'),
    { ...card('deleted', '', 10), deletedAt: new Date(200) }, { ...card('pending', '', 10), status: 'PENDING' }]);
  f.context.readableCardRows = async rows => rows.filter(row => !row.deletedAt && row.status === 'APPROVED' && row.ownerUid !== 'inactive');
  assert.deepEqual((await f.ready()).items.map(item => item.card.id), ['allowed']);
  const hidden = fixture([], [card('changed', '')]);
  hidden.context.preparePrimaryPhotos = async () => { hidden.data.FoodCard[0].deletedAt = new Date(); };
  await assert.rejects(hidden.ready(), { code: 'CURSOR_STALE' });
  const changedFriends = fixture([], [card('friend-card', '', 8, 100, 'friend')]);
  changedFriends.context.preparePrimaryPhotos = async () => { changedFriends.setRelations([]); };
  await assert.rejects(changedFriends.ready({ ...point, kind: 'FRIENDS' }, 'viewer'), { code: 'CURSOR_STALE' });
});
test('friend homepage returns FRIEND for accepted relation and VISITOR after removal', async () => {
  const f = fixture([], []), service = createStage7Services(f.context);
  const request = { userUid: 'friend', cursor: '', pageSize: 12 };
  assert.equal((await service.userPage('viewer', request, ENV)).relationshipState, 'FRIEND');
  f.setRelations([]); assert.equal((await service.userPage('viewer', request, ENV)).relationshipState, 'VISITOR');
  assert.equal((await service.userPage('friend', request, ENV)).relationshipState, 'SELF');
});
test('FriendReport runtime matches deployed target-user schema and lookup indexes', () => {
  const root = join(__dirname, '..');
  const source = readFileSync(join(root, 'cloudfunctions/shike-service/runtime.js'), 'utf8');
  const schema = JSON.parse(readFileSync(join(root, 'clouddb/objecttype/FriendReport.json'), 'utf8'));
  const fields = JSON.parse(/FriendReport\.fieldTypes = Object.freeze\(([^\n]+)\);/.exec(source)[1]);
  const indexes = JSON.parse(/FriendReport\.indexes = Object.freeze\(([^\n]+)\);/.exec(source)[1]);
  assert.deepEqual(fields, Object.fromEntries(schema.fields.map(field => [field.fieldName, field.fieldType])));
  assert.deepEqual(indexes, schema.indexes.map(index => index.indexList.map(field => field.fieldName).join(',')));
});

test('identity-binding model indexes are iterable field tuples matching the database definition', () => {
  const root = join(__dirname, '..');
  const schema = JSON.parse(readFileSync(join(root, 'clouddb/objecttype/IdentityBinding.json'), 'utf8'));
  const expected = schema.indexes.map(index => index.indexList.map(field => field.fieldName).join(','));
  assert.deepEqual(new policyModels.IdentityBinding().getIndexList(), expected);
  for (const name of ['shike-service', 'shike-media']) {
    const source = readFileSync(join(root, 'cloudfunctions', name, 'runtime.js'), 'utf8');
    const body = /IdentityBinding\.indexes = Object\.freeze\(([^\n]+)\);/.exec(source)[1];
    const indexes = JSON.parse(body.replaceAll("'", '"'));
    assert.ok(Array.isArray(indexes)); assert.deepEqual(indexes, expected);
  }
});
