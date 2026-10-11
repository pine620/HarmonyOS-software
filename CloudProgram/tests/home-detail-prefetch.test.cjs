'use strict';
// Run by the user; injected service context requires no cloud SDK or network.
const test = require('node:test');
const assert = require('node:assert/strict');
const { createPersonalCollections } = require('../cloudfunctions/shike-service/personal-collections');
function fixture() {
  const rows = [{ id: 'a' }, { id: 'b' }], calls = { manifests: [], final: 0 }, state = { deny: '' };
  const service = createPersonalCollections({
    readCardRowsByIds: async ids => new Map(rows.filter(row => ids.includes(row.id)).map(row => [row.id, row])),
    createCardReadContext: async () => ({}), readableCardRows: async values => values,
    preparePrimaryPhotos: async () => {},
    previewCard: row => ({ id: row.id, photos: [{ id: row.id + '-primary' }] }),
    publicPhotos: async row => { calls.manifests.push(row.id); return [{ id: row.id + '-primary' }, { id: row.id + '-secondary' }]; },
    withReadPhase: async (_phase, work) => work(),
    finalizeCardReads: async cards => { calls.final++; return cards.filter(card => card.id !== state.deny); }
  });
  return { service, calls, state };
}
test('ordinary previews keep their primary-only read path', async () => {
  const f = fixture(); const result = await f.service.previews('', { cardIds: ['a'] }, {});
  assert.equal(result.items[0].card.photos.length, 1); assert.deepEqual(f.calls.manifests, []);
});
test('optional batched manifests include secondary photos without duplicate card reads', async () => {
  const f = fixture(); const result = await f.service.previews('', { cardIds: ['a', 'a', 'b'], includeDetailPhotos: true }, {});
  assert.deepEqual(f.calls.manifests, ['a', 'b']); assert.equal(f.calls.final, 1);
  assert.deepEqual(result.items.map(item => item.card.photos.length), [2, 2]);
});
test('final access check removes a revoked card after assembling its photo manifest', async () => {
  const f = fixture(); f.state.deny = 'b';
  const result = await f.service.previews('', { cardIds: ['a', 'b'], includeDetailPhotos: true }, {});
  assert.equal(result.items[0].accessible, true);
  assert.deepEqual(result.items[1], { cardId: 'b', accessible: false, card: null });
});
test('oversized manifest batches are rejected before any photo queries', async () => {
  const f = fixture(); await assert.rejects(f.service.previews('', { cardIds: Array(11).fill('a'), includeDetailPhotos: true }, {}));
  assert.deepEqual(f.calls.manifests, []); assert.equal(f.calls.final, 0);
});
