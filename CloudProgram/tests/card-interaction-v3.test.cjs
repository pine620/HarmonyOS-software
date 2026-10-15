'use strict';
// User-run contracts: atomic fake transactions, no AGC, device or application calls.
const test = require('node:test');
const assert = require('node:assert/strict');
const { createCardInteractionServices } = require('../cloudfunctions/shike-service/card-interaction-services');
const { isAccountActive } = require('../cloudfunctions/shared/content-policy');
const rid = number => 'c0000000-0000-4000-8000-' + String(number).padStart(12, '0');
const error = code => Object.assign(new Error(code), { code });

function fixture() {
  const data = {
    UserProfile: [{ uid: 'alice', accountStatus: 'ACTIVE', updatedAt: 100 }, { uid: 'bob', accountStatus: 'ACTIVE', updatedAt: 100 }],
    FoodCard: [{ id: 'card', ownerUid: 'bob', status: 'APPROVED' }], CardReaction: [], CardAction: [], PublishRequestRecord: []
  };
  const controls = { reactionReady: true, collectionReady: true, reactionStatusError: false, collectionStatusError: false,
    failCommit: false, failCounts: false, bumpDuringCounts: false, commits: 0, aggregations: 0, countQueries: 0, scans: 0, writes: [] };
  let revision = 0;
  const models = {};
  for (const name of Object.keys(data)) models[name] = class { getClassName() { return name; } };
  const model = (name, row) => Object.assign(new models[name](), row);
  const clone = source => Object.fromEntries(Object.entries(source).map(([name, rows]) => [name, rows.map(row => model(name, row))]));
  const identity = (name, row) => name === 'UserProfile' ? row.uid : name === 'CardReaction' ? row.cardId + ':' + row.uid : name === 'PublishRequestRecord' ? row.requestId : row.id;
  class Query {
    constructor(name) { this.name = name; this.filters = []; this.size = 100; }
    equalTo(key, value) { this.filters.push(row => row[key] === value); return this; }
    limit(size) { this.size = size; return this; }
    async get(source = data) { return source[this.name].filter(row => this.filters.every(filter => filter(row))).slice(0, this.size).map(row => model(this.name, row)); }
    // Server-side COUNT, as CloudDBZoneQuery.countQuery in @hw-agconnect/cloud-server.
    async countQuery(_field) {
      controls.aggregations++; controls.countQueries++; if (controls.failCounts) throw error('3007009');
      if (controls.bumpDuringCounts) {
        const own = data.CardReaction.find(row => row.uid === 'alice');
        if (own) own.updatedAt = new Date(own.updatedAt.getTime() + 1);
      }
      return String(data[this.name].filter(row => this.filters.every(filter => filter(row))).length);
    }
  }
  const collection = (_env, name) => ({ query: () => new Query(name), runTransaction: async ({ apply }) => {
    // Retry with a fresh snapshot if a concurrent transaction committed first.
    for (let attempt = 0; attempt < 5; attempt++) {
      const version = revision, snapshot = clone(data), writes = [];
      let queued = false;
      const tx = {
        executeQuery: async query => { assert.equal(queued, false, 'all queries must precede mutations'); return query.get(snapshot); },
        executeUpsert: rows => { queued = true; writes.push({ kind: 'upsert', rows }); },
        executeDelete: rows => { queued = true; writes.push({ kind: 'delete', rows }); }
      };
      const ok = await apply(tx);
      if (!ok || controls.failCommit) return false;
      if (version !== revision) continue;
      for (const write of writes) for (const row of write.rows) {
        controls.writes.push(row.getClassName() + ':' + write.kind);
        const type = row.getClassName(), rows = data[type], at = rows.findIndex(item => identity(type, item) === identity(type, row));
        if (write.kind === 'delete') { if (at >= 0) rows.splice(at, 1); }
        else if (at < 0) rows.push(model(type, row));
        else rows[at] = model(type, row);
      }
      if (writes.length) { revision++; controls.commits++; }
      return true;
    }
    return false;
  } });
  const one = async query => (await query.limit(1).get())[0] || null;
  const stage1 = {
    model,
    txOne: async (tx, env, name, field, value) => (await tx.executeQuery(collection(env, name).query().equalTo(field, value).limit(1)))[0] || null,
    activeProfile: async (tx, uid, env) => { const profile = await stage1.txOne(tx, env, 'UserProfile', 'uid', uid); if (!isAccountActive(profile)) throw error('ACCOUNT_INACTIVE'); return profile; },
    upsertRows: (tx, rows) => { for (const row of rows) tx.executeUpsert([row]); },
    reactionHistoryMaintenance: async () => { if (controls.reactionStatusError) throw error('INVALID_STATE'); return { ready: controls.reactionReady }; },
    reactionSummary: async (cardId, uid) => {
      controls.aggregations++; controls.scans++; if (controls.failCounts) throw error('3007009');
      const reactions = new Map(), favorites = new Set();
      for (const row of data.CardAction.filter(row => row.cardId === cardId)) {
        if (row.kind === 'LIKE') reactions.set(row.actorUid, 'LIKE');
        if (row.kind === 'FAVORITE') favorites.add(row.actorUid);
      }
      for (const row of data.CardReaction.filter(row => row.cardId === cardId)) reactions.set(row.uid, row.reaction);
      return { myReaction: reactions.get(uid) || '', viewerFavorited: favorites.has(uid), likeCount: [...reactions.values()].filter(value => value === 'LIKE').length,
        dislikeCount: [...reactions.values()].filter(value => value === 'DISLIKE').length, favoriteCount: favorites.size };
    }
  };
  const assertActive = async uid => { if (!isAccountActive(data.UserProfile.find(row => row.uid === uid))) throw error('ACCOUNT_INACTIVE'); };
  const assertReadable = async (_uid, card) => { if (!card || card.status !== 'APPROVED') throw error('CONTENT_UNAVAILABLE'); };
  const ctx = { collection, one, stage1: () => stage1,
    contentPolicy: () => ({ assertAccountActive: assertActive, assertCardReadable: assertReadable }),
    transactionPolicy: () => ({ assertCardReadable: assertReadable }),
    collections: () => ({ enabled: () => true, status: async () => { if (controls.collectionStatusError) throw error('INVALID_STATE'); return { collectionReady: controls.collectionReady }; },
      assertWritable: async () => { if (!controls.collectionReady) throw error('COLLECTION_MIGRATING'); } }),
    logicalWriteTime: (...values) => Math.max(Date.now(), ...values.filter(value => value != null).map(value => Number(value) + 1)),
    profileForWrite: (row, now) => model('UserProfile', { ...row, updatedAt: now }),
    actionId: (_kind, uid, cardId) => 'favorite:' + uid + ':' + cardId
  };
  const env = { SHIKE_REACTION_VERIFIED: 'true' }, service = createCardInteractionServices(ctx);
  const request = async (patch, number, uid = 'alice') => {
    const state = await service.state(uid, { cardId: 'card' }, env);
    return { cardId: 'card', requestId: rid(number), patch,
      expected: { writeVersion: state.writeVersion, ...(patch.reaction !== undefined ? { myReaction: state.myReaction } : {}),
        ...(patch.favorited !== undefined ? { viewerFavorited: state.viewerFavorited } : {}) } };
  };
  return { data, controls, service, env, request };
}

test('one actor/card reaction switches LIKE to DISLIKE and cancels without dual votes', async () => {
  const f = fixture();
  await f.service.set('alice', await f.request({ reaction: 'LIKE' }, 1), f.env);
  await f.service.set('alice', await f.request({ reaction: 'DISLIKE' }, 2), f.env);
  assert.equal(f.data.CardReaction.length, 1); assert.equal(f.data.CardReaction[0].reaction, 'DISLIKE');
  assert.equal((await f.service.counts('alice', { cardId: 'card' }, f.env)).likeCount, 0);
  await f.service.set('alice', await f.request({ reaction: '' }, 3), f.env);
  // Cancel keeps one neutral version row instead of deleting it.
  assert.equal(f.data.CardReaction.length, 1); assert.equal(f.data.CardReaction[0].reaction, '');
  const counts = await f.service.counts('alice', { cardId: 'card' }, f.env);
  assert.equal(counts.likeCount + counts.dislikeCount, 0); assert.equal(counts.myReaction, '');
});
test('lost-response retry replays exactly the original receipt without another commit', async () => {
  const f = fixture(), request = await f.request({ reaction: 'LIKE', favorited: true }, 1);
  const first = await f.service.set('alice', request, f.env), commits = f.controls.commits;
  const receipt = await f.service.receipt('alice', { cardId: 'card', requestId: request.requestId }, f.env);
  assert.equal(receipt.found, true); assert.deepEqual(receipt.receipt, first);
  assert.deepEqual(await f.service.set('alice', request, f.env), first); assert.equal(f.controls.commits, commits);
  assert.equal(f.data.CardReaction.length, 1); assert.equal(f.data.CardAction.length, 1);
});
test('reusing an id with different payload is rejected and an old receipt remains immutable', async () => {
  const f = fixture(), request = await f.request({ reaction: 'LIKE' }, 1);
  const first = await f.service.set('alice', request, f.env);
  await assert.rejects(f.service.set('alice', { ...request, patch: { reaction: 'DISLIKE' } }, f.env), { code: 'CONFLICT' });
  await f.service.set('alice', await f.request({ reaction: 'DISLIKE' }, 2), f.env);
  assert.deepEqual((await f.service.receipt('alice', { cardId: 'card', requestId: rid(1) }, f.env)).receipt, first);
  assert.equal((await f.service.state('alice', { cardId: 'card' }, f.env)).myReaction, 'DISLIKE');
});
test('stale baseline from another device is rejected rather than overwriting its choice', async () => {
  const f = fixture(), stale = await f.request({ reaction: 'DISLIKE' }, 2);
  await f.service.set('alice', await f.request({ reaction: 'LIKE' }, 1), f.env);
  await assert.rejects(f.service.set('alice', stale, f.env), { code: 'STALE_VERSION' });
  assert.equal(f.data.CardReaction[0].reaction, 'LIKE'); assert.equal(f.data.PublishRequestRecord.length, 1);
});
test('concurrent first requests serialize via actor guard and leave one vote', async () => {
  const f = fixture(), like = await f.request({ reaction: 'LIKE' }, 1), dislike = await f.request({ reaction: 'DISLIKE' }, 2);
  const results = await Promise.allSettled([f.service.set('alice', like, f.env), f.service.set('alice', dislike, f.env)]);
  assert.equal(results.filter(value => value.status === 'fulfilled').length, 1);
  assert.equal(results.find(value => value.status === 'rejected').reason.code, 'STALE_VERSION');
  assert.equal(f.data.CardReaction.length, 1);
});
test('favorite target is idempotent, normalizes legacy duplicates and cancels all own duplicates', async () => {
  const f = fixture();
  f.data.CardAction.push({ id: 'old1', actorUid: 'alice', cardId: 'card', kind: 'FAVORITE', createdAt: 1 },
    { id: 'old2', actorUid: 'alice', cardId: 'card', kind: 'FAVORITE', createdAt: 2 },
    { id: 'bob-fav', actorUid: 'bob', cardId: 'card', kind: 'FAVORITE', createdAt: 2 });
  const result = await f.service.set('alice', await f.request({ favorited: true }, 1), f.env);
  assert.equal(result.status, 'UNCHANGED'); assert.equal(f.data.CardAction.filter(row => row.actorUid === 'alice').length, 1);
  await f.service.set('alice', await f.request({ favorited: true }, 2), f.env);
  assert.equal((await f.service.counts('alice', { cardId: 'card' }, f.env)).favoriteCount, 2);
  await f.service.set('alice', await f.request({ favorited: false }, 3), f.env);
  assert.equal(f.data.CardAction.filter(row => row.actorUid === 'alice').length, 0);
  assert.equal(f.data.CardAction.filter(row => row.actorUid === 'bob').length, 1);
});
test('combined reaction/favorite/receipt rollback together when commit is unconfirmed', async () => {
  const f = fixture(), request = await f.request({ reaction: 'LIKE', favorited: true }, 1);
  f.controls.failCommit = true;
  await assert.rejects(f.service.set('alice', request, f.env), { code: 'TRANSACTION_UNCONFIRMED' });
  assert.equal(f.data.CardReaction.length + f.data.CardAction.length + f.data.PublishRequestRecord.length, 0);
  assert.equal(f.data.UserProfile[0].updatedAt, 100);
  f.controls.failCommit = false;
  assert.equal((await f.service.set('alice', request, f.env)).status, 'COMMITTED');
});
test('write returns a small committed ack even if all-user aggregation is unavailable', async () => {
  const f = fixture(); f.controls.failCounts = true;
  const result = await f.service.set('alice', await f.request({ reaction: 'LIKE' }, 1), f.env);
  assert.equal(result.myReaction, 'LIKE'); assert.equal(result.likeCount, undefined); assert.equal(f.controls.aggregations, 0);
  await assert.rejects(f.service.counts('alice', { cardId: 'card' }, f.env), { code: '3007009' });
  assert.equal((await f.service.state('alice', { cardId: 'card' }, f.env)).myReaction, 'LIKE');
});
test('receipts are isolated by verified uid and cannot restore inaccessible content', async () => {
  const f = fixture(); await f.service.set('alice', await f.request({ reaction: 'LIKE' }, 1), f.env);
  assert.equal((await f.service.receipt('bob', { cardId: 'card', requestId: rid(1) }, f.env)).found, false);
  f.data.FoodCard[0].status = 'DELETED';
  await assert.rejects(f.service.receipt('alice', { cardId: 'card', requestId: rid(1) }, f.env), { code: 'CONTENT_UNAVAILABLE' });
  await assert.rejects(f.service.counts('alice', { cardId: 'card' }, f.env), { code: 'CONTENT_UNAVAILABLE' });
});
test('patch updates only its group, removes legacy LIKE and ignores a forged actor payload', async () => {
  const f = fixture(); f.data.CardAction.push({ id: 'old-like', actorUid: 'alice', cardId: 'card', kind: 'LIKE' });
  const request = await f.request({ reaction: 'DISLIKE' }, 1);
  await f.service.set('alice', { ...request, uid: 'bob' }, f.env);
  assert.equal(f.data.CardAction.length, 0); assert.equal(f.data.CardReaction[0].uid, 'alice');
  await f.service.set('alice', await f.request({ favorited: true }, 2), f.env);
  assert.equal(f.data.CardReaction[0].reaction, 'DISLIKE');
});
test('a closed migration gate rejects new changes but keeps completed receipts recoverable', async () => {
  const f = fixture(), original = await f.request({ reaction: 'LIKE' }, 1);
  const saved = await f.service.set('alice', original, f.env); f.controls.reactionReady = false;
  assert.deepEqual(await f.service.set('alice', original, f.env), saved);
  await assert.rejects(f.service.set('alice', await f.request({ reaction: 'DISLIKE' }, 2), f.env), { code: 'FEATURE_NOT_READY' });
  f.controls.collectionReady = false;
  await assert.rejects(f.service.set('alice', await f.request({ favorited: true }, 3), f.env), { code: 'COLLECTION_MIGRATING' });
});
test('one malformed migration checkpoint cannot disable the other interaction group', async () => {
  const f = fixture(); f.controls.collectionStatusError = true;
  let state = await f.service.state('alice', { cardId: 'card' }, f.env);
  assert.equal(state.reactionsEnabled, true); assert.equal(state.collectionReady, false);
  await f.service.set('alice', await f.request({ reaction: 'LIKE' }, 1), f.env);
  f.controls.collectionStatusError = false; f.controls.reactionStatusError = true;
  state = await f.service.state('alice', { cardId: 'card' }, f.env);
  assert.equal(state.reactionsEnabled, false); assert.equal(state.collectionReady, true);
  await f.service.set('alice', await f.request({ favorited: true }, 2), f.env);
  assert.equal(f.data.CardReaction[0].reaction, 'LIKE'); assert.equal(f.data.CardAction.length, 1);
});

test('counts identify the coherent personal snapshot and reject an own-version race', async () => {
  const f = fixture();
  const saved = await f.service.set('alice', await f.request({ reaction: 'DISLIKE', favorited: true }, 1), f.env);
  const counts = await f.service.counts('alice', { cardId: 'card' }, f.env);
  assert.equal(counts.myReaction, 'DISLIKE'); assert.equal(counts.viewerFavorited, true);
  assert.equal(counts.writeVersion, saved.writeVersion); assert.equal(counts.dislikeCount, 1);
  f.controls.bumpDuringCounts = true;
  await assert.rejects(f.service.counts('alice', { cardId: 'card' }, f.env), { code: 'STALE_VERSION' });
});

test('interaction writes never rewrite the card row and guard the account row only on first contact', async () => {
  const f = fixture();
  const first = await f.service.set('alice', await f.request({ reaction: 'LIKE' }, 1), f.env);
  assert.equal(f.data.UserProfile[0].updatedAt > 100, true);
  const guarded = f.data.UserProfile[0].updatedAt;
  const second = await f.service.set('alice', await f.request({ favorited: true }, 2), f.env);
  const third = await f.service.set('alice', await f.request({ reaction: '' }, 3), f.env);
  assert.equal(f.data.UserProfile[0].updatedAt, guarded);
  assert.equal(f.controls.writes.some(entry => entry.startsWith('FoodCard:')), false);
  assert.equal(first.writeVersion < second.writeVersion && second.writeVersion < third.writeVersion, true);
  const state = await f.service.state('alice', { cardId: 'card' }, f.env);
  assert.equal(state.writeVersion, third.writeVersion); assert.equal(state.viewerFavorited, true); assert.equal(state.myReaction, '');
});
test('an unrelated account write between read and write is not a conflict', async () => {
  const f = fixture();
  await f.service.set('alice', await f.request({ reaction: 'LIKE' }, 1), f.env);
  const request = await f.request({ reaction: 'DISLIKE' }, 2);
  f.data.UserProfile[0].updatedAt += 1000;
  assert.equal((await f.service.set('alice', request, f.env)).status, 'COMMITTED');
});
test('counts use server-side COUNT queries and only scan while legacy history is incomplete', async () => {
  const f = fixture();
  await f.service.set('alice', await f.request({ reaction: 'LIKE', favorited: true }, 1), f.env);
  await f.service.set('bob', await f.request({ reaction: 'DISLIKE' }, 2, 'bob'), f.env);
  let counts = await f.service.counts('alice', { cardId: 'card' }, f.env);
  assert.deepEqual([counts.likeCount, counts.dislikeCount, counts.favoriteCount], [1, 1, 1]);
  assert.equal(f.controls.scans, 0); assert.equal(f.controls.countQueries, 3);
  f.controls.reactionReady = false;
  counts = await f.service.counts('alice', { cardId: 'card' }, f.env);
  assert.deepEqual([counts.likeCount, counts.dislikeCount, counts.favoriteCount], [1, 1, 1]);
  assert.equal(f.controls.scans, 1);
});
