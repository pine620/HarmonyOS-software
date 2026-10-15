'use strict';
// User-run behavioral regressions. This file has not been executed by the agent.
const test = require('node:test');
const assert = require('node:assert/strict');
const { createRandomFoodServices } = require('../cloudfunctions/shike-service/random-food-services');
const { isAccountActive, readableCardState } = require('../cloudfunctions/shared/content-policy');
const { withCursorContext } = require('../cloudfunctions/shike-service/stages47-common');
const ROUND = '11111111-1111-4111-8111-111111111111';
const DRAW = '22222222-2222-4222-8222-222222222222';
function fixture() {
  const data = { UserProfile: [{ uid: 'viewer', accountStatus: 'ACTIVE' }, { uid: 'author', accountStatus: 'ACTIVE' },
    { uid: 'other', accountStatus: 'ACTIVE' }], FoodCard: [], CardAction: [], Friendship: [], MealChoiceHistory: [] };
  let ready = true;
  const actionId = (kind, uid, cardId) => kind + ':' + uid + ':' + cardId;
  const socialPairId = (_prefix, a, b) => [a, b].sort().join(':');
  function query(name) {
    const orders = [], groups = [{ expression: null, next: 'AND' }]; let maximum = 1000, last = '';
    const value = input => input instanceof Date ? input.getTime() : input;
    const predicate = condition => {
      const group = groups[groups.length - 1], previous = group.expression, operator = group.next;
      group.expression = previous === null ? condition : row => operator === 'OR' ? previous(row) || condition(row) : previous(row) && condition(row);
      group.next = 'AND'; last = 'condition';
    };
    const api = {
      equalTo: (field, expected) => { predicate(row => value(row[field]) === value(expected)); return api; },
      in: (field, values) => { assert.ok(values.length <= 10, 'batch membership queries must stay bounded'); predicate(row => values.includes(row[field])); return api; },
      isNull: field => { predicate(row => row[field] == null); return api; },
      lessThanOrEqualTo: (field, limit) => { predicate(row => value(row[field]) <= value(limit)); return api; },
      lessThan: (field, limit) => { predicate(row => value(row[field]) < value(limit)); return api; },
      greaterThan: (field, limit) => { predicate(row => value(row[field]) > value(limit)); return api; },
      and: () => { assert.notEqual(last, 'order', 'CloudDB forbids a Boolean connector directly after ordering'); groups[groups.length - 1].next = 'AND'; last = 'and'; return api; },
      or: () => { groups[groups.length - 1].next = 'OR'; return api; },
      beginGroup: () => { groups.push({ expression: null, next: 'AND' }); return api; },
      endGroup: () => { assert.ok(groups.length > 1); const group = groups.pop(); predicate(group.expression); return api; },
      orderByAsc: field => { orders.push([field, 1]); last = 'order'; return api; },
      orderByDesc: field => { orders.push([field, -1]); last = 'order'; return api; },
      limit: size => { maximum = size; return api; },
      get: async () => data[name].filter(row => groups[0].expression === null || groups[0].expression(row)).slice().sort((a, b) => {
        for (const [field, direction] of orders) {
          const left = value(a[field]), right = value(b[field]);
          if (left !== right) return (left < right ? -1 : 1) * direction;
        }
        return 0;
      }).slice(0, maximum).map(row => ({ ...row }))
    };
    return api;
  }
  const collection = (_env, name) => ({ query: () => query(name), runTransaction: async transaction => {
    const writes = []; let writing = false;
    const tx = { executeQuery: input => { assert.equal(writing, false, 'all transaction reads precede writes'); return input.get(); },
      executeUpsert: rows => { writing = true; writes.push(...rows); } };
    const accepted = await transaction.apply(tx);
    if (accepted) for (const row of writes) {
      const index = data.MealChoiceHistory.findIndex(item => item.historyId === row.historyId);
      if (index >= 0) data.MealChoiceHistory[index] = { ...row }; else data.MealChoiceHistory.push({ ...row });
    }
    return accepted;
  } });
  const ctx = {
    collection, models: { MealChoiceHistory: class MealChoiceHistory {} }, actionId, socialPairId,
    collections: () => ({ status: async () => ({ collectionReady: ready }) }),
    contentPolicy: () => ({ assertAccountActive: async uid => {
      if (!isAccountActive(data.UserProfile.find(row => row.uid === uid))) {
        const error = new Error('inactive'); error.code = 'ACCOUNT_INACTIVE'; throw error;
      }
    } }),
    friendshipRowsFor: async uid => data.Friendship.filter(row => row.memberAUid === uid || row.memberBUid === uid),
    readCardRowsByIds: async ids => new Map(data.FoodCard.filter(row => ids.includes(row.id)).map(row => [row.id, { ...row }])),
    createCardReadContext: async () => ({}),
    readableCardRows: async rows => rows.filter(row => readableCardState(row) && isAccountActive(data.UserProfile.find(profile => profile.uid === row.ownerUid))),
    preparePrimaryPhotos: async () => {}, previewCard: row => ({ id: row.id, productName: row.productName, photos: [] }),
    finalizeCardReads: async cards => cards,
    stage1: () => ({ txOne: async (tx, env, name, field, expected) =>
      (await tx.executeQuery(collection(env, name).query().equalTo(field, expected).limit(1)))[0] || null })
  };
  const addCard = (id, ownerUid = 'author', changes = {}) => {
    const row = { id, ownerUid, productName: id, status: 'APPROVED', schemaVersion: 1, reviewState: 'APPROVED',
      createdAt: data.FoodCard.length + 1, consumptionMode: 'DELIVERY', ...changes };
    data.FoodCard.push(row); return row;
  };
  const reference = (cardId, kind) => data.CardAction.push({ id: actionId('card:' + kind, 'viewer', cardId), actorUid: 'viewer',
    cardId, kind, createdAt: data.CardAction.length + 1 });
  return { service: createRandomFoodServices(ctx), data, addCard, reference, setReady: value => { ready = value; } };
}
test('personal pool uses favorites only, deduplicates and requires completed migration', async () => {
  const f = fixture(); f.addCard('a'); f.addCard('b');
  f.reference('a', 'FAVORITE'); f.reference('a', 'WANT_TO_EAT'); f.reference('b', 'FAVORITE');
  f.addCard('wanted-only'); f.reference('wanted-only', 'WANT_TO_EAT');
  const result = await f.service.pool('viewer', { source: 'MY', roundId: ROUND }, {});
  assert.deepEqual(result.cardIds.slice().sort(), ['a', 'b']); assert.equal(result.poolSize, 2);
  f.setReady(false);
  await assert.rejects(f.service.pool('viewer', { source: 'MY', roundId: ROUND }, {}), error => error.code === 'COLLECTION_MIGRATING');
});
test('guest pool is bounded, unique, and excludes deleted cards and inactive authors', async () => {
  const f = fixture(); for (let i = 0; i < 100; i++) f.addCard('card-' + i);
  f.data.UserProfile.push({ uid: 'inactive', accountStatus: 'DELETION_IN_PROGRESS' });
  f.addCard('inactive-card', 'inactive'); f.addCard('deleted-card', 'author', { deletedAt: new Date() });
  const result = await f.service.pool('', { source: 'PUBLIC', roundId: ROUND }, {});
  assert.equal(result.poolSize, 60); assert.equal(new Set(result.cardIds).size, 60);
  assert.equal(result.cardIds.includes('inactive-card'), false); assert.equal(result.cardIds.includes('deleted-card'), false);
  assert.equal(result.coverage, 'BOUNDED');
  await assert.rejects(f.service.pool('', { source: 'MY', roundId: ROUND }, {}), error => error.code === 'AUTH_REQUIRED');
});
test('each result read checks current source membership and never substitutes a different card', async () => {
  const f = fixture(); f.addCard('a'); f.addCard('b'); f.reference('a', 'FAVORITE');
  const first = await f.service.cards('viewer', { source: 'MY', drawId: DRAW, cardIds: ['a', 'b'] }, {});
  assert.deepEqual(first.cards.map(card => card.id), ['a']); assert.deepEqual(first.unavailableCardIds, ['b']);
  f.data.CardAction = [];
  assert.equal((await f.service.cards('viewer', { source: 'MY', drawId: DRAW, cardIds: ['a'] }, {})).cards.length, 0);
  await assert.rejects(f.service.cards('', { source: 'PUBLIC', drawId: DRAW, cardIds: ['a', 'a'] }, {}));
});
test('friend pools and result reads require the current accepted relationship', async () => {
  const f = fixture(); f.addCard('friend-card'); f.addCard('other-card', 'other');
  f.data.Friendship.push({ id: 'author:viewer', memberAUid: 'author', memberBUid: 'viewer', status: 'ACCEPTED' });
  assert.deepEqual((await f.service.pool('viewer', { source: 'FRIENDS', roundId: ROUND }, {})).cardIds, ['friend-card']);
  f.data.Friendship[0].status = 'BLOCKED';
  assert.equal((await f.service.cards('viewer', { source: 'FRIENDS', drawId: DRAW, cardIds: ['friend-card'] }, {})).cards.length, 0);
  await assert.rejects(f.service.saveChoice('viewer', { source: 'FRIENDS', roundId: ROUND, drawId: DRAW, cardId: 'friend-card' }, {}),
    error => error.code === 'CONTENT_UNAVAILABLE');
  assert.equal(f.data.MealChoiceHistory.length, 0);
});
test('unavailable cards and removed personal references cannot create new choice records', async () => {
  const f = fixture(); const card = f.addCard('a'); f.reference('a', 'FAVORITE');
  const request = { source: 'MY', roundId: ROUND, drawId: DRAW, cardId: 'a' };
  f.data.CardAction = [];
  await assert.rejects(f.service.saveChoice('viewer', request, {}), error => error.code === 'CONTENT_UNAVAILABLE');
  card.deletedAt = new Date();
  await assert.rejects(f.service.saveChoice('viewer', { ...request, source: 'PUBLIC' }, {}), error => error.code === 'CONTENT_UNAVAILABLE');
  assert.equal(f.data.MealChoiceHistory.length, 0);
});
test('lost-response retry returns the original choice after takedown and deletion cannot resurrect it', async () => {
  const f = fixture(); const card = f.addCard('a');
  const request = { source: 'PUBLIC', roundId: ROUND, drawId: DRAW, cardId: 'a' };
  const first = await f.service.saveChoice('viewer', request, {});
  card.status = 'REMOVED';
  const retried = await f.service.saveChoice('viewer', request, {});
  assert.equal(retried.historyId, first.historyId); assert.equal(retried.selectedAt, first.selectedAt);
  assert.equal(f.data.MealChoiceHistory.length, 1);
  await f.service.deleteChoice('viewer', { historyId: first.historyId }, {});
  await f.service.deleteChoice('viewer', { historyId: first.historyId }, {});
  assert.equal((await f.service.saveChoice('viewer', request, {})).deleted, true);
  assert.equal((await f.service.history('viewer', { cursor: '' }, {})).items.length, 0);
});
test('one draw cannot confirm two choices and users cannot delete another account record', async () => {
  const f = fixture(); f.addCard('a'); f.addCard('b');
  const request = { source: 'PUBLIC', roundId: ROUND, drawId: DRAW, cardId: 'a' };
  const receipt = await f.service.saveChoice('viewer', request, {});
  await assert.rejects(f.service.saveChoice('viewer', { ...request, cardId: 'b' }, {}), error => error.code === 'CONFLICT');
  await assert.rejects(f.service.deleteChoice('other', { historyId: receipt.historyId }, {}), error => error.code === 'FORBIDDEN');
});
test('unavailable recorded cards keep their record identity and time without stale content', async () => {
  const f = fixture(); const card = f.addCard('a');
  const receipt = await f.service.saveChoice('viewer', { source: 'PUBLIC', roundId: ROUND, drawId: DRAW, cardId: 'a' }, {});
  card.status = 'REMOVED';
  const page = await f.service.history('viewer', { cursor: '' }, {});
  assert.equal(page.items.length, 1); assert.equal(page.items[0].card, null);
  assert.equal(page.items[0].historyId, receipt.historyId); assert.equal(page.items[0].selectedAt, receipt.selectedAt);
});
test('history continuation handles equal timestamps and a deleted frontier without duplicates or omissions', () =>
  withCursorContext({ SHIKE_CURSOR_SIGNING_KEY: 'fixture-only-pagination-key-32-characters' }, async () => {
    const f = fixture(); f.addCard('a'); const selectedAt = new Date(Date.now() - 1000);
    for (let index = 0; index < 21; index++) f.data.MealChoiceHistory.push({ historyId: 'record-' + String(index).padStart(2, '0'),
      uid: 'viewer', cardId: 'a', source: 'PUBLIC', selectedAt, deletedAt: null });
    const first = await f.service.history('viewer', { cursor: '' }, {});
    assert.equal(first.items.length, 20); assert.ok(first.nextCursor);
    const frontier = first.items[first.items.length - 1].historyId;
    await f.service.deleteChoice('viewer', { historyId: frontier }, {});
    const second = await f.service.history('viewer', { cursor: first.nextCursor }, {});
    assert.deepEqual(second.items.map(item => item.historyId), ['record-20']); assert.equal(second.nextCursor, '');
    assert.equal(new Set([...first.items, ...second.items].map(item => item.historyId)).size, 21);
  }));
