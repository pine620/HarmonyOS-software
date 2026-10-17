'use strict';
// User-run regressions with in-memory records. No SDK, cloud, credentials or UI.
const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const { Buffer } = require('node:buffer');
const { createStage1Services } = require('../cloudfunctions/shike-service/stage1-services');
const { createFoodRankingServices } = require('../cloudfunctions/shike-service/food-ranking-services');
const { readableCardState } = require('../cloudfunctions/shared/content-policy');

const ENV = { SHIKE_MAINTENANCE_ENABLED: 'true', SHIKE_FOOD_RANKINGS_VERIFIED: 'true',
  SHIKE_INDEXED_QUERY_VERIFIED: 'true' };
const JOB_ID = crypto.createHash('sha256').update('BACKFILL_CARD:stage1-v1:1').digest('hex');
class Model { getClassName() { return this.constructor.name; } }
class MaintenanceJob extends Model {}
class FoodCard extends Model {}
class CardAction extends Model {}
class CardReaction extends Model {}
class UserProfile extends Model {}
const models = { MaintenanceJob, FoodCard, CardAction, CardReaction, UserProfile };
const copy = row => Object.assign(new row.constructor(), row);
function legacy(id, createdAt = 1000) {
  return Object.assign(new FoodCard(), { id, ownerUid: 'author', status: 'APPROVED', schemaVersion: 0,
    reviewState: '', createdAt, updatedAt: createdAt, tasteScore: 7, merchantId: 'merchant', category: 'staple' });
}
function modern(id, publishedAt = new Date(1000)) {
  return Object.assign(legacy(id), { schemaVersion: 2, reviewState: 'APPROVED',
    publishedAt, modifiedAt: new Date(2000), lifecycleGeneration: 3 });
}
function pending(id, createdAt = 1000) {
  return Object.assign(legacy(id, createdAt), { status: 'PENDING', tasteScore: 0,
    merchantId: '', lifecycleGeneration: 0, publishedAt: null, modifiedAt: null });
}
function fixture(cards = []) {
  const data = { MaintenanceJob: [], FoodCard: cards, CardAction: [], CardReaction: [], UserProfile: [] };
  let writes = 0;
  const collection = (_env, name) => ({
    query: () => {
      const filters = [], orders = []; let limit = Infinity;
      const q = {
        equalTo: (field, value) => { filters.push(row => row[field] === value); return q; },
        greaterThan: (field, value) => { filters.push(row => row[field] > value); return q; },
        in: (field, values) => { filters.push(row => values.includes(row[field])); return q; },
        orderByAsc: field => { orders.push(field); return q; },
        limit: count => { limit = count; return q; },
        get: async () => data[name].filter(row => filters.every(predicate => predicate(row)))
          .sort((a, b) => { for (const field of orders) {
            if (a[field] < b[field]) return -1;
            if (a[field] > b[field]) return 1;
          } return 0; }).slice(0, limit).map(copy)
      }; return q;
    },
    runTransaction: async ({ apply }) => apply({
      executeQuery: q => q.get(),
      executeUpsert: rows => {
        for (const row of rows) {
          writes++; const table = data[row.getClassName()];
          const primary = row instanceof MaintenanceJob ? 'jobId' : 'id';
          const at = table.findIndex(old => old[primary] === row[primary]);
          if (at < 0) table.push(copy(row)); else table[at] = copy(row);
        }
      },
      executeDelete: rows => {
        for (const row of rows) {
          const table = data[row.getClassName()]; const at = table.findIndex(old => old.id === row.id);
          if (at >= 0) table.splice(at, 1);
        }
      }
    })
  });
  const context = { collection, models, one: async q => (await q.limit(1).get())[0] || null };
  const service = createStage1Services(context);
  return { data, context, service, writes: () => writes,
    maintain: (mode, env = ENV) => service.cardHistoryMaintenance({ mode }, env) };
}

test('status is read-only and absent tasks are explicitly uninitialized', async () => {
  const f = fixture();
  const result = await f.maintain('status', { SHIKE_MAINTENANCE_ENABLED: 'false' });
  assert.equal(result.initialized, false); assert.equal(result.ready, false); assert.equal(result.job, null);
  assert.equal(f.writes(), 0);
  assert.equal((await f.service.cardHistoryMaintenance({}, ENV)).initialized, false);
});
test('write modes require the existing maintenance flag and reject unknown modes', async () => {
  const f = fixture();
  for (const mode of ['initialize', 'run', 'retry']) {
    await assert.rejects(f.maintain(mode, { SHIKE_MAINTENANCE_ENABLED: 'false' }), { code: 'FEATURE_NOT_READY' });
  }
  await assert.rejects(f.maintain('delete-account'), { code: 'VALIDATION_ERROR' });
  assert.equal(f.writes(), 0);
});
test('initialize creates the exact readiness task without overwriting existing progress', async () => {
  const f = fixture(); const first = await f.maintain('initialize');
  assert.equal(first.job.jobId, JOB_ID); assert.equal(first.job.jobType, 'BACKFILL_CARD');
  assert.equal(first.job.status, 'PENDING'); assert.equal(first.ready, false); assert.equal(first.batchSize, 20);
  assert.equal(first.job.checkpoint.phase, 'MIGRATE'); assert.ok(first.job.checkpoint.baselineAt > 0);
  f.data.MaintenanceJob[0].cursor = 'previous-card';
  const count = f.writes(), second = await f.maintain('initialize');
  assert.equal(second.job.cursor, 'previous-card'); assert.equal(f.writes(), count);
  assert.equal(second.job.checkpoint.baselineAt, first.job.checkpoint.baselineAt);
});
test('empty databases still complete a scan and a verification before becoming ready', async () => {
  const f = fixture(); await f.maintain('initialize');
  const migrated = await f.maintain('run'); assert.equal(migrated.ready, false);
  assert.equal(migrated.job.status, 'PENDING'); assert.equal(migrated.job.checkpoint.phase, 'VERIFY');
  const verified = await f.maintain('run'); assert.equal(verified.ready, true); assert.equal(verified.job.status, 'DONE');
  const count = f.writes(); assert.equal((await f.maintain('run')).ready, true); assert.equal(f.writes(), count);
});
test('legacy publication timestamps are backfilled while modern timestamps and ranking fields remain intact', async () => {
  const existing = modern('b', new Date(500)); const f = fixture([legacy('a'), existing]);
  await f.maintain('initialize'); await f.maintain('run');
  const a = f.data.FoodCard.find(row => row.id === 'a'), b = f.data.FoodCard.find(row => row.id === 'b');
  assert.equal(a.publishedAt.getTime(), 1000); assert.equal(a.modifiedAt.getTime(), 1000);
  assert.equal(a.reviewState, 'LEGACY_APPROVED'); assert.equal(a.schemaVersion, 1);
  assert.equal(a.tasteScore, 7); assert.equal(a.merchantId, 'merchant');
  assert.equal(b.publishedAt.getTime(), 500); assert.equal(b.modifiedAt.getTime(), 2000);
  assert.equal(b.lifecycleGeneration, 3); assert.equal((await f.maintain('run')).ready, true);
  const readiness = await f.service.migrationReadiness(ENV);
  assert.equal(readiness.cardCoverageComplete, true); assert.equal(readiness.reactionCoverageComplete, false);
  const rankings = createFoodRankingServices({ ...f.context, stage1: () => f.service });
  assert.equal((await rankings.capability(ENV, readiness)).enabled, true);
});
test('valid pending legacy cards remain untouched while published and removed cards finish migration and verification', async () => {
  const waiting = pending('b', String(Date.now() - 1000)), original = copy(waiting);
  const removed = Object.assign(legacy('c'), { status: 'REMOVED' });
  const f = fixture([legacy('a'), waiting, removed, modern('d')]);
  await f.maintain('initialize');
  const migrated = await f.maintain('run');
  assert.equal(migrated.job.checkpoint.scanned, 4);
  assert.equal(migrated.job.checkpoint.migrated, 2);
  assert.equal(migrated.job.checkpoint.skipped, 2);
  assert.equal(migrated.job.checkpoint.phase, 'VERIFY');
  assert.deepEqual(f.data.FoodCard.find(row => row.id === 'b'), original);
  assert.equal(f.data.FoodCard.find(row => row.id === 'a').reviewState, 'LEGACY_APPROVED');
  assert.equal(f.data.FoodCard.find(row => row.id === 'c').reviewState, 'TAKEN_DOWN');
  const verified = await f.maintain('run');
  assert.equal(verified.ready, true); assert.equal(verified.job.status, 'DONE');
  assert.equal(verified.job.checkpoint.verificationScanned, 4);
  assert.equal(verified.job.checkpoint.verificationMissing, 0);
  assert.deepEqual(f.data.FoodCard.find(row => row.id === 'b'), original);
  assert.equal(readableCardState(f.data.FoodCard.find(row => row.id === 'b')), false);
});
test('retry resumes an existing pending-card failure after thirteen scanned cards without resetting earlier progress', async () => {
  const prefix = Array.from({ length: 13 }, (_, index) => {
    const row = modern('card-' + String(index).padStart(2, '0'));
    return index < 12 ? Object.assign(row, { schemaVersion: 1, migrationSource: 'LEGACY',
      reviewState: 'LEGACY_APPROVED', modifiedAt: new Date(1000) }) : row;
  });
  const waiting = pending('card-13'), original = copy(waiting);
  const f = fixture([...prefix, waiting, legacy('card-14')]);
  await f.maintain('initialize');
  const job = f.data.MaintenanceJob[0], checkpoint = JSON.parse(job.checkpointJson);
  Object.assign(checkpoint, { scanned: 13, migrated: 12, skipped: 1, failures: 2, failedEntityId: 'card-13' });
  Object.assign(job, { status: 'RETRY_WAIT', attemptCount: 2, cursor: 'card-12', lastErrorCode: 'INVALID_STATE',
    runAfterAt: new Date(Date.now() + 240000), checkpointJson: JSON.stringify(checkpoint) });
  const preserved = f.data.FoodCard.slice(0, 13).map(copy);
  const retried = await f.maintain('retry');
  assert.equal(retried.job.cursor, 'card-12');
  assert.equal(retried.job.checkpoint.baselineAt, checkpoint.baselineAt);
  assert.equal(retried.job.checkpoint.scanned, 13);
  assert.equal(retried.job.checkpoint.migrated, 12);
  assert.equal(retried.job.checkpoint.skipped, 1);
  assert.equal(retried.job.checkpoint.failures, 0);
  const migrated = await f.maintain('run');
  assert.equal(migrated.job.checkpoint.scanned, 15);
  assert.equal(migrated.job.checkpoint.migrated, 13);
  assert.equal(migrated.job.checkpoint.skipped, 2);
  assert.equal(migrated.job.checkpoint.phase, 'VERIFY');
  const verified = await f.maintain('run');
  assert.equal(verified.ready, true); assert.equal(verified.job.status, 'DONE');
  assert.equal(verified.job.checkpoint.verificationScanned, 15);
  assert.equal(verified.job.checkpoint.failures, 0);
  assert.deepEqual(f.data.FoodCard.slice(0, 13), preserved);
  assert.deepEqual(f.data.FoodCard.find(row => row.id === 'card-13'), original);
});
test('invalid pending legacy timestamps still fail and retain the failed frontier', async () => {
  const waiting = pending('b', 0), original = copy(waiting);
  const f = fixture([legacy('a'), waiting]); await f.maintain('initialize');
  await assert.rejects(f.maintain('run'), { code: 'INVALID_STATE' });
  const result = await f.maintain('status');
  assert.equal(result.ready, false); assert.equal(result.job.cursor, 'a');
  assert.equal(result.job.checkpoint.scanned, 1);
  assert.equal(result.job.checkpoint.failedEntityId, 'b');
  assert.equal(result.job.checkpoint.failures, 1);
  assert.deepEqual(f.data.FoodCard.find(row => row.id === 'b'), original);
});
test('verification still rejects unmigrated published cards alongside valid pending legacy cards', async () => {
  const waiting = pending('b'), original = copy(waiting), f = fixture([legacy('a'), waiting]);
  await f.maintain('initialize');
  const job = f.data.MaintenanceJob[0], checkpoint = JSON.parse(job.checkpointJson);
  checkpoint.phase = 'VERIFY'; job.checkpointJson = JSON.stringify(checkpoint);
  const result = await f.maintain('run');
  assert.equal(result.ready, false); assert.equal(result.job.status, 'FAILED');
  assert.equal(result.job.lastErrorCode, 'COVERAGE_INCOMPLETE');
  assert.equal(result.job.checkpoint.verificationScanned, 2);
  assert.equal(result.job.checkpoint.verificationMissing, 1);
  assert.equal(result.job.checkpoint.verificationMissingEntityId, 'a');
  assert.equal(result.job.checkpoint.coverageComplete, false);
  assert.deepEqual(f.data.FoodCard.find(row => row.id === 'b'), original);
});
test('card-history calls scan at most twenty records and retain progress across batches', async () => {
  const f = fixture(Array.from({ length: 45 }, (_, index) => legacy('card-' + String(index).padStart(2, '0'))));
  await f.maintain('initialize'); let previous = 0, calls = 0, result;
  do {
    result = await f.maintain('run'); calls++;
    const checked = result.job.checkpoint.scanned + result.job.checkpoint.verificationScanned;
    assert.ok(checked - previous <= 20); previous = checked;
    assert.ok(calls <= 8);
  } while (!result.ready);
  assert.equal(calls, 6); assert.equal(result.job.checkpoint.scanned, 45);
  assert.equal(result.job.checkpoint.verificationScanned, 45);
});
test('invalid legacy data retains its failed frontier and retry continues after correction', async () => {
  const f = fixture([legacy('a'), legacy('b', 0)]); await f.maintain('initialize');
  await assert.rejects(f.maintain('run'), { code: 'INVALID_STATE' });
  let state = await f.maintain('status'); assert.equal(state.ready, false); assert.equal(state.job.cursor, 'a');
  assert.equal(state.job.checkpoint.failedEntityId, 'b'); assert.equal(state.job.checkpoint.failures, 1);
  f.data.FoodCard[1].createdAt = 1000; f.data.FoodCard[1].updatedAt = 1000;
  state = await f.maintain('retry'); assert.equal(state.job.cursor, 'a'); assert.equal(state.ready, false);
  await f.maintain('run'); assert.equal((await f.maintain('run')).ready, true);
});
test('verification rejects readable modern cards without publishedAt and restarts verification after correction', async () => {
  const f = fixture([modern('missing', null)]); await f.maintain('initialize'); await f.maintain('run');
  const bad = await f.maintain('run'); assert.equal(bad.ready, false); assert.equal(bad.job.status, 'FAILED');
  assert.equal(bad.job.lastErrorCode, 'COVERAGE_INCOMPLETE'); assert.equal(bad.job.checkpoint.verificationMissing, 1);
  assert.equal(bad.job.checkpoint.verificationMissingEntityId, 'missing');
  f.data.FoodCard[0].publishedAt = new Date(1000);
  const retry = await f.maintain('retry'); assert.equal(retry.job.checkpoint.verificationCursor, '');
  assert.equal(retry.job.checkpoint.coverageComplete, false); assert.equal((await f.maintain('run')).ready, true);
});
test('fixed history entry rejects a conflicting job and does not select arbitrary maintenance jobs', async () => {
  const f = fixture(); await assert.rejects(f.maintain('run'), { code: 'NOT_FOUND' });
  await f.maintain('initialize'); f.data.MaintenanceJob[0].jobType = 'DELETE_ACCOUNT';
  const count = f.writes(); await assert.rejects(f.maintain('initialize'), { code: 'INVALID_STATE' });
  assert.equal(f.writes(), count);
});

function handlerFixture() {
  const calls = [], secret = '1'.repeat(32), exports = {};
  const source = readFileSync(join(__dirname, '../cloudfunctions/shike-maintenance/shikeMaintenance.js'), 'utf8');
  // The VM has its own global object; supply Node's real Buffer for credential checks.
  const scope = { exports, Buffer, process: { env: { SHIKE_MAINTENANCE_TRIGGER_KEY: secret } },
    console: { error: () => {} }, require: name => {
      if (name === 'crypto') return crypto;
      if (name === './service/runtime') return {
        maintainCardHistory: async payload => { calls.push(['history', payload.mode]); return { ready: false }; },
        runMaintenance: async () => { calls.push(['lifecycle']); return {}; },
        normalizePublicContent: async () => { calls.push(['public']); return {}; }, safeLogError: () => 'REDACTED'
      };
      if (name === './media/runtime') return { runCoverBackfill: async () => { calls.push(['covers']); return {}; } };
      // home-snapshot 动作的依赖；这里的用例不触发它，调用即记录。
      if (name === './shared/public-snapshot') return { HOME_REQUEST: {}, writeSnapshot: async () => { calls.push(['snapshot']); return {}; } };
      if (name === './shared/read-errors') return { READ_OPT_VERSION: 'test-only', errorCode: error => error.code || 'REQUEST_FAILED' };
      if (name === './shared/release-info') return { buildInfo: {} };
      throw new Error('Unexpected dependency ' + name);
    } };
  vm.runInNewContext(source, scope);
  return { calls, secret, invoke: event => exports.handler(event) };
}
test('history action requires the existing worker credential before any maintenance call', async () => {
  const f = handlerFixture();
  const denied = await f.invoke({ workerToken: '2'.repeat(32), action: 'card-history', mode: 'initialize' });
  assert.equal(denied.ok, false); assert.equal(denied.code, 'TRIGGER_ACCESS_DENIED'); assert.equal(f.calls.length, 0);
});
test('authenticated history action is routed alone and preserves existing worker actions', async () => {
  const f = handlerFixture();
  const result = await f.invoke({ workerToken: f.secret, action: 'card-history', mode: 'status' });
  assert.equal(result.ok, true); assert.deepEqual(f.calls, [['history', 'status']]);
  await f.invoke({ workerToken: f.secret, action: 'public-content' });
  await f.invoke({ workerToken: f.secret, action: 'media-covers' });
  await f.invoke({ workerToken: f.secret });
  assert.deepEqual(f.calls, [['history', 'status'], ['public'], ['covers'], ['lifecycle']]);
});
