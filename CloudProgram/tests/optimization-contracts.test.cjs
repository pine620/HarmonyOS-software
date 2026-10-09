// User-run pure regression tests. No SDK, handler, network, cloud or device is loaded.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const {token, encode, withCursorContext, timestampPage, hash} = require('../cloudfunctions/shike-service/stages47-common');
const {shouldReadMetrics} = require('../cloudfunctions/shared/read-errors');
const {createContentPolicy} = require('../cloudfunctions/shared/content-policy');
const configuration = {SHIKE_CURSOR_SIGNING_KEY: 'local-test-only-cursor-key-32-characters', SHIKE_READ_METRICS_ENABLED: 'true'};
const stale = error => error && error.code === 'CURSOR_STALE';

test('cursor binds actor/filter signature and rejects changed bytes', () => withCursorContext(configuration, () => {
  const signature = hash(['viewer', 'mode', 7]), at = Date.now();
  const value = encode(signature, at, {position: 12});
  assert.equal(token(value, signature).position, 12);
  assert.throws(() => token(value, hash(['different-viewer', 'mode', 7])), stale);
  const [body, mac] = value.split('.');
  const changed = JSON.parse(Buffer.from(body, 'base64url')); changed.position = 0;
  assert.throws(() => token(Buffer.from(JSON.stringify(changed)).toString('base64url') + '.' + mac, signature), stale);
  assert.throws(() => token(value.slice(0, -1) + (value.endsWith('0') ? '1' : '0'), signature), stale);
}));

test('cursor rejects expired, future and unsigned legacy values', () => withCursorContext(configuration, () => {
  const signature = hash(['viewer']);
  assert.throws(() => token(encode(signature, Date.now() - 900001, {}), signature), stale);
  assert.throws(() => token(encode(signature, Date.now() + 60000, {}), signature), stale);
  assert.throws(() => token(Buffer.from(JSON.stringify({signature, at: Date.now()})).toString('base64url'), signature), stale);
  assert.throws(() => token('x'.repeat(65602), signature), stale);
}));

test('cursor signing key is isolated per request, with domain-separated fallback', async () => {
  const at = Date.now(), signature = hash(['viewer']);
  const signed = withCursorContext(configuration, () => encode(signature, at, {}));
  await Promise.all([
    withCursorContext(configuration, async () => { await Promise.resolve(); assert.equal(token(signed, signature).at, at); }),
    withCursorContext({SHIKE_CURSOR_SIGNING_KEY: 'different-local-test-key-32-characters'}, async () => {
      await Promise.resolve(); assert.throws(() => token(signed, signature), stale);
    })
  ]);
  withCursorContext({SHIKE_MEDIA_INTERNAL_KEY: configuration.SHIKE_CURSOR_SIGNING_KEY}, () => assert.equal(token(signed, signature).at, at));
  withCursorContext({SHIKE_CURSOR_SIGNING_KEY:'', SHIKE_MEDIA_INTERNAL_KEY:''}, () => assert.throws(() => encode(signature, at, {}), error => error.code === 'CONFIGURATION_REQUIRED'));
});

test('metrics switch and stable sampling are deterministic for linked request IDs', () => {
  assert.equal(shouldReadMetrics({...configuration, SHIKE_READ_METRICS_SAMPLE_RATE: '0'}, 'same-request'), false);
  assert.equal(shouldReadMetrics({...configuration, SHIKE_READ_METRICS_SAMPLE_RATE: '1'}, 'same-request'), true);
  assert.equal(shouldReadMetrics({...configuration, SHIKE_READ_METRICS_ENABLED: 'false'}, 'same-request'), false);
  assert.equal(shouldReadMetrics({...configuration, SHIKE_READ_METRICS_SAMPLE_RATE: 'invalid'}, 'same-request'), false);
  const environment = {...configuration, SHIKE_READ_METRICS_SAMPLE_RATE: '0.25'};
  const result = shouldReadMetrics(environment, 'linked-request');
  for (let index = 0; index < 10; index++) assert.equal(shouldReadMetrics(environment, 'linked-request'), result);
});

function policyFixture() {
  const records = {UserProfile: [{uid: 'viewer', accountStatus: 'ACTIVE'}, {uid: 'author', accountStatus: 'ACTIVE'}], Friendship: []};
  const calls = {UserProfile: 0, Friendship: 0};
  const collection = name => ({query: () => {
    let field = '', values = [], maximum = 50;
    const query = {
      in: (key, input) => {field = key; values = input; return query;},
      equalTo: (key, value) => {field = key; values = [value]; return query;},
      limit: size => {maximum = size; return query;},
      get: async () => {calls[name]++; await new Promise(resolve => setImmediate(resolve)); return records[name].filter(row => values.includes(row[field])).slice(0, maximum).map(row => ({...row}));}
    }; return query;
  }});
  const create = () => createContentPolicy(collection, async query => (await query.get())[0] || null);
  const card = {id: 'card', ownerUid: 'author', status: 'APPROVED', schemaVersion: 1, reviewState: 'APPROVED', visibility: 'PUBLIC'};
  return {records, calls, create, card};
}

test('overlapping policy preparations share pending and negative reads', async () => {
  const fixture = policyFixture(), policy = fixture.create();
  await Promise.all([policy.prepareCardReads('viewer', [fixture.card]), policy.prepareCardReads('viewer', [fixture.card])]);
  assert.equal(fixture.calls.UserProfile, 1); assert.equal(fixture.calls.Friendship, 1);
  assert.equal(await policy.canReadCard('viewer', fixture.card), true);
  await policy.prepareCardReads('viewer', [fixture.card]);
  assert.equal(fixture.calls.UserProfile, 1); assert.equal(fixture.calls.Friendship, 1);
});

test('fresh final policy observes a block and account deactivation after assembly', async () => {
  const fixture = policyFixture(), first = fixture.create();
  assert.equal(await first.canReadCard('viewer', fixture.card), true);
  const id = crypto.createHash('sha256').update('friend:author:viewer').digest('hex');
  fixture.records.Friendship = [{id, status: 'BLOCKED'}];
  assert.equal(await fixture.create().canReadCard('viewer', fixture.card), false);
  fixture.records.Friendship = [];
  fixture.records.UserProfile = [{uid: 'viewer', accountStatus: 'ACTIVE'}, {uid: 'author', accountStatus: 'DELETING'}];
  assert.equal(await fixture.create().canReadCard('viewer', fixture.card), false);
});

test('overlapping preparations recheck later batches after an await', async () => {
  const fixture = policyFixture(), policy = fixture.create();
  const cards = Array.from({length: 105}, (_, index) => ({...fixture.card, id: 'card-' + index, ownerUid: 'author-' + index}));
  fixture.records.UserProfile = [{uid: 'viewer', accountStatus: 'ACTIVE'}, ...cards.map(card => ({uid: card.ownerUid, accountStatus: 'ACTIVE'}))];
  await Promise.all([policy.prepareCardReads('viewer', cards), policy.prepareCardReads('viewer', cards)]);
  assert.equal(fixture.calls.UserProfile, 3);
  assert.equal(fixture.calls.Friendship, 3);
  assert.equal(await policy.canReadCard('viewer', cards[104]), true);
  await policy.prepareCardReads('viewer', cards);
  assert.equal(fixture.calls.UserProfile, 3); assert.equal(fixture.calls.Friendship, 3);
});

test('timestamp continuation survives deletion before the frontier and equal timestamps', async () => {
  const at = 1000;
  let records = [{id: 'a', createdAt: 900}, {id: 'b', createdAt: 900}, {id: 'c', createdAt: 900}, {id: 'd', createdAt: 800}, {id: 'e', createdAt: 700}];
  const query = () => {let before = at, maximum = 12; const api = {
    lessThanOrEqualTo: (_field, stamp) => {before = stamp; return api;}, limit: size => {maximum = size; return api;},
    get: async () => records.filter(row => row.createdAt <= before).slice(0, maximum)
  }; return api;};
  const first = await timestampPage(query(), null, at, 2, 'id', 'createdAt');
  assert.deepEqual(first.rows.map(row => row.id), ['a', 'b']);
  records = records.filter(row => row.id !== 'a');
  records.unshift({id: 'new', createdAt: 1100});
  const second = await timestampPage(query(), first.next, at, 2, 'id', 'createdAt');
  assert.deepEqual(second.rows.map(row => row.id), ['c', 'd']);
  const third = await timestampPage(query(), second.next, at, 2, 'id', 'createdAt');
  assert.deepEqual(third.rows.map(row => row.id), ['e']); assert.equal(third.next, null);
});
