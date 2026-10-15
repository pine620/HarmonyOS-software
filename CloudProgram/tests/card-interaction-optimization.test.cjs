'use strict';
// User-run regressions only. In-memory records, no SDK/cloud/credentials/UI.
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { createStage1Services } = require('../cloudfunctions/shike-service/stage1-services');
const { createStage7Services } = require('../cloudfunctions/shike-service/stage7-services');
const { createPersonalCollections } = require('../cloudfunctions/shike-service/personal-collections');
const { hash } = require('../cloudfunctions/shike-service/stages47-common');

const ENV = { SHIKE_REACTION_VERIFIED: 'true', SHIKE_COLLECTIONS_VERIFIED: 'true' };
const requestId = suffix => '00000000-0000-4000-8000-' + String(suffix).padStart(12, '0');
class Model { getClassName() { return this.constructor.name; } }
class FoodCard extends Model {}
class UserProfile extends Model {}
class MaintenanceJob extends Model {}
class CardAction extends Model {}
class CardReaction extends Model {}
class PublishRequestRecord extends Model {}
const models = { FoodCard, UserProfile, MaintenanceJob, CardAction, CardReaction, PublishRequestRecord };
const keys = { FoodCard: ['id'], UserProfile: ['uid'], MaintenanceJob: ['jobId'], CardAction: ['id'],
  CardReaction: ['cardId', 'uid'], PublishRequestRecord: ['requestId'] };
const copy = row => Object.assign(new row.constructor(), row);
const reactionJobId = crypto.createHash('sha256').update('MIGRATE_REACTION:stage1-v1:1').digest('hex');
function fixture() {
  const data = Object.fromEntries(Object.keys(models).map(name => [name, []]));
  data.FoodCard.push(Object.assign(new FoodCard(), { id: 'card', ownerUid: 'viewer', status: 'APPROVED', updatedAt: 10 }));
  data.UserProfile.push(Object.assign(new UserProfile(), { uid: 'viewer', accountStatus: 'ACTIVE', updatedAt: 10 }));
  data.MaintenanceJob.push(Object.assign(new MaintenanceJob(), { jobId: reactionJobId, jobType: 'MIGRATE_REACTION',
    entityId: 'stage1-v1', generation: 1, status: 'DONE', checkpointJson: JSON.stringify({
      phase: 'VERIFY', baselineAt: 1, coverageComplete: true, failures: 0, verificationMissing: 0 }) }));
  data.MaintenanceJob.push(Object.assign(new MaintenanceJob(), { jobId: hash(['MIGRATE_PERSONAL_COLLECTION', 'viewer', 1]),
    jobType: 'MIGRATE_PERSONAL_COLLECTION', entityId: 'viewer', generation: 1, status: 'DONE',
    checkpointJson: JSON.stringify({ phase: 'DONE', scanned: 0, createdFavorites: 0, createdWanted: 0, batches: 0 }) }));
  const reads = []; let writeCount = 0, flagCalls = 0;
  function query(name) {
    const filters = [], orders = []; let size = Infinity, offset = 0;
    const q = {
      equalTo(field, value) { filters.push([field, value]); return q; },
      orderByAsc(field) { orders.push(field); return q; },
      limit(count, start = 0) { size = count; offset = start; return q; },
      async getFrom(store) {
        reads.push({ name, filters: filters.map(pair => pair.slice()) });
        return store[name].filter(row => filters.every(([field, value]) => row[field] === value))
          .sort((a, b) => { for (const field of orders) {
            if (a[field] < b[field]) return -1;
            if (a[field] > b[field]) return 1;
          } return 0; }).slice(offset, offset + size).map(copy);
      },
      get: () => q.getFrom(data)
    };
    return q;
  }
  const collection = (_env, name) => ({
    query: () => query(name),
    async runTransaction({ apply }) {
      const staged = Object.fromEntries(Object.entries(data).map(([table, rows]) => [table, rows.map(copy)]));
      let writes = 0;
      const tx = {
        executeQuery: q => q.getFrom(staged),
        executeUpsert(rows) {
          const name = rows[0].getClassName();
          assert.ok(rows.every(row => row.getClassName() === name), 'SDK upserts must contain a single object type');
          for (const row of rows) {
            const at = staged[name].findIndex(old => keys[name].every(field => old[field] === row[field]));
            if (at < 0) staged[name].push(copy(row)); else staged[name][at] = copy(row);
            writes++;
          }
        },
        executeDelete(rows) {
          for (const row of rows) {
            const name = row.getClassName();
            const at = staged[name].findIndex(old => keys[name].every(field => old[field] === row[field]));
            if (at >= 0) staged[name].splice(at, 1);
            writes++;
          }
        }
      };
      const committed = await apply(tx);
      if (committed) { Object.assign(data, staged); writeCount += writes; }
      return committed;
    }
  });
  const unavailable = () => Object.assign(new Error('Content unavailable'), { code: 'CONTENT_ACCESS_DENIED' });
  const readable = (uid, card) => !!card && card.status === 'APPROVED' &&
    data.UserProfile.some(row => row.uid === uid && row.accountStatus === 'ACTIVE');
  const ctx = { collection, models, one: async q => (await q.limit(1).get())[0] || null,
    logicalWriteTime: (...values) => Math.max(0, ...values.map(Number).filter(Number.isFinite)) + 1,
    profileForWrite: (row, updatedAt) => Object.assign(new UserProfile(), row, { updatedAt }),
    actionId: (kind, uid, cardId) => kind + ':' + uid + ':' + cardId,
    contentPolicy: () => ({ canReadCard: async (uid, card) => readable(uid, card),
      assertCardReadable: async (uid, card) => { if (!readable(uid, card)) throw unavailable(); } }),
    transactionPolicy: () => ({ assertCardReadable: async (uid, card) => { if (!readable(uid, card)) throw unavailable(); } }),
    stage3: () => ({ capabilities: async () => { throw new Error('Reaction write entered discovery readiness'); } }),
    foodRankings: () => ({ capability: async () => { throw new Error('Reaction write entered ranking readiness'); } })
  };
  const stage1 = createStage1Services(ctx); ctx.stage1 = () => stage1;
  const collections = createPersonalCollections(ctx);
  ctx.collections = () => ({ ...collections, flags: async (...args) => { flagCalls++; return collections.flags(...args); } });
  return { data, reads, stage1, collections, service: createStage7Services(ctx), ctx,
    writes: () => writeCount, flagCalls: () => flagCalls };
}
function favorite(f, id, actorUid) {
  f.data.CardAction.push(Object.assign(new CardAction(), { id, cardId: 'card', actorUid, kind: 'FAVORITE', createdAt: 1 }));
}

test('verified reactions work independently of unrelated discovery and ranking gates', async () => {
  const f = fixture();
  const result = await f.service.reaction('viewer', { cardId: 'card', reaction: 'LIKE', expectedReaction: '', requestId: requestId(1) }, ENV);
  assert.equal(result.myReaction, 'LIKE'); assert.equal(result.likeCount, 1);
  assert.equal(f.flagCalls(), 0);
  assert.equal(f.reads.some(row => row.filters.some(([field, value]) => field === 'kind' && value === 'LIKE')), false);
});
test('verification flag and incomplete reaction coverage still prevent writes', async () => {
  const f = fixture(), payload = { cardId: 'card', reaction: 'LIKE', requestId: requestId(1) };
  await assert.rejects(f.service.reaction('viewer', payload, { ...ENV, SHIKE_REACTION_VERIFIED: 'false' }), { code: 'FEATURE_NOT_READY' });
  assert.equal(f.reads.length, 0); assert.equal(f.writes(), 0);
  const job = f.data.MaintenanceJob.find(row => row.jobId === reactionJobId);
  job.status = 'PENDING';
  await assert.rejects(f.service.reaction('viewer', payload, ENV), { code: 'FEATURE_NOT_READY' });
  assert.equal(f.writes(), 0);
});
test('LIKE to DISLIKE to NONE remains exclusive and a retried receipt does not write twice', async () => {
  const f = fixture(), first = { cardId: 'card', reaction: 'LIKE', expectedReaction: '', requestId: requestId(1) };
  await f.service.reaction('viewer', first, ENV);
  const before = f.writes();
  const repeated = await f.service.reaction('viewer', first, ENV);
  assert.equal(repeated.myReaction, 'LIKE'); assert.equal(f.writes(), before);
  const dislike = await f.service.reaction('viewer', { cardId: 'card', reaction: 'DISLIKE', expectedReaction: 'LIKE', requestId: requestId(2) }, ENV);
  assert.equal(dislike.likeCount, 0); assert.equal(dislike.dislikeCount, 1);
  const none = await f.service.reaction('viewer', { cardId: 'card', reaction: 'NONE', expectedReaction: 'DISLIKE', requestId: requestId(3) }, ENV);
  assert.equal(none.myReaction, ''); assert.equal(none.likeCount, 0); assert.equal(none.dislikeCount, 0);
  assert.equal(f.data.CardReaction.length, 0);
});
test('stale expected state and inactive accounts still reject before committing', async () => {
  const f = fixture();
  await f.service.reaction('viewer', { cardId: 'card', reaction: 'LIKE', expectedReaction: '', requestId: requestId(1) }, ENV);
  const before = f.writes();
  await assert.rejects(f.service.reaction('viewer', { cardId: 'card', reaction: 'DISLIKE', expectedReaction: '', requestId: requestId(2) }, ENV), { code: 'STALE_VERSION' });
  assert.equal(f.writes(), before); assert.equal(f.data.CardReaction[0].reaction, 'LIKE');
  f.data.UserProfile[0].accountStatus = 'DELETION_IN_PROGRESS';
  await assert.rejects(f.service.reaction('viewer', { cardId: 'card', reaction: 'NONE', requestId: requestId(3) }, ENV), { code: 'ACCOUNT_INACTIVE' });
  assert.equal(f.writes(), before);
});
test('legacy callers retain old LIKE handling and full detail flags', async () => {
  const f = fixture();
  f.data.CardAction.push(Object.assign(new CardAction(), { id: 'old-like', cardId: 'card', actorUid: 'viewer', kind: 'LIKE', createdAt: 1 }));
  const result = await f.stage1.mutateReaction('viewer', { cardId: 'card', reaction: 'DISLIKE', expectedReaction: 'LIKE', requestId: requestId(1) }, ENV);
  assert.equal(result.myReaction, 'DISLIKE'); assert.equal(result.viewerWanted, undefined);
  assert.equal(result.collectionReady, true); assert.ok(f.flagCalls() > 0);
  assert.equal(f.data.CardAction.some(row => row.kind === 'LIKE'), false);
});
test('collection summaries deduplicate users and do not scan reaction history', async () => {
  const f = fixture();
  favorite(f, 'f1', 'viewer'); favorite(f, 'f2', 'viewer'); favorite(f, 'f3', 'other');
  const result = await f.stage1.favoriteSummary('card', 'viewer', ENV);
  assert.equal(result.favoriteCount, 2); assert.equal(result.viewerFavorited, true);
  assert.equal(result.collectionReady, true); assert.equal(result.viewerWanted, undefined);
  assert.equal(f.reads.some(row => row.name === 'CardReaction'), false);
  assert.equal(f.reads.some(row => row.filters.some(([field, value]) => field === 'kind' && value === 'LIKE')), false);
});
test('favorite writes keep content checks, fresh flags and idempotent receipts', async () => {
  const f = fixture(), first = { cardId: 'card', active: true, requestId: requestId(1) };
  const result = await f.collections.set('viewer', first, ENV, 'FAVORITE');
  assert.equal(result.viewerFavorited, true); assert.equal(result.favoriteCount, 1);
  assert.equal(result.collectionReady, true); assert.equal(result.contentAvailable, true);
  assert.equal(result.myReaction, undefined); assert.equal(result.likeCount, undefined);
  const before = f.writes();
  await f.collections.set('viewer', first, ENV, 'FAVORITE');
  assert.equal(f.writes(), before);
  const removed = await f.collections.set('viewer', { cardId: 'card', active: false, requestId: requestId(2) }, ENV, 'FAVORITE');
  assert.equal(removed.viewerFavorited, false); assert.equal(removed.favoriteCount, 0);
  f.data.FoodCard[0].status = 'REMOVED';
  await assert.rejects(f.collections.set('viewer', { cardId: 'card', active: true, requestId: requestId(3) }, ENV, 'FAVORITE'), { code: 'CONTENT_ACCESS_DENIED' });
});
test('unavailable content after a committed removal never returns an accessible summary', async () => {
  const f = fixture();
  await f.collections.set('viewer', { cardId: 'card', active: true, requestId: requestId(1) }, ENV, 'FAVORITE');
  f.data.FoodCard[0].status = 'REMOVED';
  const result = await f.collections.set('viewer', { cardId: 'card', active: false, requestId: requestId(2) }, ENV, 'FAVORITE');
  assert.equal(result.active, false); assert.equal(result.contentAvailable, false);
  assert.equal(result.favoriteCount, undefined);
});
test('retired wanted writes are rejected without adding a relationship', async () => {
  const f = fixture();
  await assert.rejects(f.collections.set('viewer', { cardId: 'card', active: true, requestId: requestId(1) }, ENV, 'WANT_TO_EAT'), { code: 'CLIENT_UPDATE_REQUIRED' });
  assert.equal(f.data.CardAction.length, 0); assert.equal(f.writes(), 0);
});
test('favorite removal ACK bypasses all-user statistics and remains idempotent', async () => {
  const f = fixture(); favorite(f, f.ctx.actionId('card:FAVORITE', 'viewer', 'card'), 'viewer');
  const payload = { cardId: 'card', active: false, requestId: requestId(1), responseMode: 'ACK' };
  const result = await f.collections.set('viewer', payload, ENV, 'FAVORITE');
  assert.equal(result.committed, true); assert.equal(result.active, false); assert.equal(result.favoriteCount, undefined);
  assert.equal(f.flagCalls(), 0); assert.equal(f.reads.some(row => row.name === 'CardReaction'), false);
  assert.equal(f.data.CardAction.length, 0); const writes = f.writes();
  assert.equal((await f.collections.set('viewer', payload, ENV, 'FAVORITE')).committed, true);
  assert.equal(f.writes(), writes);
});
