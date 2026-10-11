'use strict';
// User-run pure regressions. No SDK, credentials, network or application UI.
const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');

function sourceBlock(source, start, end) {
  const first = source.indexOf(start);
  const last = source.indexOf(end, first + start.length);
  assert.ok(first >= 0 && last > first, 'source function boundaries must exist');
  return source.slice(first, last);
}
function publicFeedFixture(total, hidden = false) {
  const source = readFileSync(join(__dirname, '../cloudfunctions/shike-service/runtime.js'), 'utf8');
  const rows = Array.from({ length: total }, (_, index) => ({ id: 'card-' + index, createdAt: 1000 - index, readable: !hidden }));
  const calls = [];
  const query = () => {
    let size = 0, offset = 0;
    const api = { equalTo: () => api, lessThanOrEqualTo: () => api, orderByDesc: () => api, orderByAsc: () => api,
      limit: (limit, start) => { size = limit; offset = start; return api; },
      get: async () => { calls.push({ size, offset }); return rows.slice(offset, offset + size); } };
    return api;
  };
  const scope = {
    MAX_PAGE_SIZE: 20, VALID_CATEGORY: new Set(['staple']), Date,
    collection: () => ({ query }),
    createCardReadContext: async () => ({}),
    readableCardRows: async batch => batch.filter(row => row.readable),
    preparePrimaryPhotos: async () => {},
    readCardIfAllowed: async row => row,
    finalizeCardReads: async cards => cards
  };
  vm.runInNewContext(sourceBlock(source, 'async function scanCardPage(', 'function cardContractFields(') +
    sourceBlock(source, 'async function listPublicRecommendations(', 'async function listNearby('), scope);
  return { read: payload => scope.listPublicRecommendations(payload, {}), calls };
}

test('ordinary first page reads seven candidates instead of a 400-card recommendation pool', async () => {
  const feed = publicFeedFixture(30);
  const first = await feed.read({ pageSize: 6 });
  assert.deepEqual(Array.from(first.cards, card => card.id), ['card-0', 'card-1', 'card-2', 'card-3', 'card-4', 'card-5']);
  assert.deepEqual(feed.calls, [{ size: 7, offset: 0 }]);
  assert.equal(first.scannedCandidateCount, 6);
  assert.equal(first.fetchedCandidateCount, 7);
  const second = await feed.read({ pageSize: 6, pageToken: first.nextPageToken });
  assert.deepEqual(Array.from(second.cards, card => card.id), ['card-6', 'card-7', 'card-8', 'card-9', 'card-10', 'card-11']);
});
test('ordinary feed terminates an exactly full last page and rejects mismatched cursors', async () => {
  const feed = publicFeedFixture(6);
  const page = await feed.read({ pageSize: 6 });
  assert.equal(page.nextPageToken, '');
  assert.equal(page.coverage, 'COMPLETE');
  await assert.rejects(feed.read({ category: 'staple', pageSize: 6, pageToken: 'g1.all.1000.6' }));
});
test('hidden rows have a bounded scan and a continuation rather than a false empty completion', async () => {
  const feed = publicFeedFixture(300, true);
  const page = await feed.read({ pageSize: 6 });
  assert.equal(page.cards.length, 0);
  assert.equal(page.scannedCandidateCount, 200);
  assert.equal(page.coverage, 'PARTIAL_SCAN_LIMIT');
  assert.ok(page.nextPageToken.endsWith('.200'));
  assert.equal(feed.calls.reduce((count, call) => count + call.size, 0), 200);
});

test('historical comment cleanup drains bounded reaction batches before deleting parents', async () => {
  const source = readFileSync(join(__dirname, '../cloudfunctions/shike-service/lifecycle-services.js'), 'utf8');
  const reactions = Array.from({ length: 21 }, (_, index) => ({ id: 'reaction-' + index, commentId: 'comment-a' }));
  const comments = [{ id: 'comment-a' }];
  const scope = { BATCH: 10, collection: () => ({ query: () => {
    let ids, size;
    const api = { in: (_field, values) => { ids = values; return api; }, limit: value => { size = value; return api; },
      get: async () => reactions.filter(row => ids.includes(row.commentId)).slice(0, size) };
    return api;
  } }) };
  vm.runInNewContext(sourceBlock(source, '  async function deleteLegacyComments(', '  async function deleteRows('), scope);
  const tx = { executeQuery: query => query.get(), executeDelete: rows => {
    for (const row of rows) {
      const store = row.commentId ? reactions : comments;
      store.splice(store.findIndex(item => item.id === row.id), 1);
    }
  } };
  for (const expected of [10, 10, 1]) {
    const result = await scope.deleteLegacyComments(tx, comments.slice(), {});
    assert.equal(result.deleted, expected);
    assert.equal(result.drained, false);
    assert.equal(comments.length, 1);
  }
  const final = await scope.deleteLegacyComments(tx, comments.slice(), {});
  assert.equal(final.drained, true);
  assert.equal(comments.length, 0);
});
