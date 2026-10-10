'use strict';
// User-run boundary regression. No real SDK, credentials, database or Storage.
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { createHandler } = require('../cloudfunctions/shike-image/shikeImage');
const { createImageReader } = require('../cloudfunctions/shared/image-reader');

function request() {
  return { protocolVersion: 'image-read-v1', accessToken: 'test-token-do-not-log',
    readRequestId: 'image-handler-regression', readAttempt: 2,
    items: [{ mediaId: '00000000-0000-4000-8000-000000000001', mode: 'PUBLIC',
      variant: 'ORIGINAL', revisionId: '', knownSha256: '', knownByteSize: 0, wantBytes: true }] };
}
function fixture(read, enabled = 'true') {
  const calls = [], logs = [], env = { SHIKE_IMAGE_READ_ENABLED: enabled };
  const handler = createHandler(async (input, actualEnv) => {
    calls.push({ input, env: actualEnv });
    return read ? read(input) : { protocolVersion: 'image-read-v1', items: [] };
  }, () => env, line => logs.push(line));
  return { handler, calls, logs, env };
}

test('HTTP SDK body reaches the reader intact and keeps the client request identity', async () => {
  const f = fixture(), input = request(); let callbackCount = 0, delivered;
  const response = await f.handler({ httpMethod: 'POST', isBase64Encoded: false, body: JSON.stringify(input),
    accessToken: 'outer-token-must-not-override', readRequestId: 'outer-id' }, {}, value => { callbackCount++; delivered = value; });
  assert.equal(response.ok, true); assert.equal(response.requestId, input.readRequestId);
  assert.deepEqual(f.calls[0].input, input); assert.equal(f.calls[0].env, f.env);
  assert.equal(callbackCount, 1); assert.equal(delivered, response);
});

test('direct local input and object body use the same request contract', async () => {
  for (const event of [request(), JSON.stringify(request()), { body: request() }]) {
    const f = fixture(); assert.equal((await f.handler(event)).ok, true);
    assert.deepEqual(f.calls[0].input, request());
  }
});

test('base64 HTTP body is decoded before protocol validation', async () => {
  const f = fixture();
  const response = await f.handler({ isBase64Encoded: true, body: Buffer.from(JSON.stringify(request())).toString('base64') });
  assert.equal(response.ok, true); assert.deepEqual(f.calls[0].input, request());
});

test('malformed HTTP bodies cannot fall back to outer application fields', async () => {
  for (const body of ['{bad-json', '', 'null', '[]', null, [], 42]) {
    const f = fixture(), response = await f.handler({ ...request(), body });
    assert.equal(response.ok, false); assert.equal(response.code, 'VALIDATION_ERROR');
    assert.equal(response.stage, 'request-decoding'); assert.equal(f.calls.length, 0);
    assert.ok(!f.logs.join('').includes(request().accessToken));
  }
});

test('oversized and invalid encoded requests are rejected before I/O', async () => {
  for (const event of [{ body: ' '.repeat(65537) }, { body: { value: 'x'.repeat(65536) } },
    { isBase64Encoded: true, body: '!!!' }, { isBase64Encoded: true, body: 'A'.repeat(90000) }]) {
    const f = fixture(), response = await f.handler(event);
    assert.equal(response.code, 'VALIDATION_ERROR'); assert.equal(f.calls.length, 0);
  }
});

test('disabled image reads remain disabled before parsing or I/O', async () => {
  const f = fixture(undefined, 'false'), response = await f.handler({ body: '{bad-json' });
  assert.equal(response.code, 'NOT_SUPPORTED'); assert.equal(f.calls.length, 0);
});

test('wrapped private image requests reject invalid tokens before database or storage reads', async () => {
  let verified = 0;
  const reader = createImageReader({ verifyToken: async token => {
    verified++; assert.equal(token, request().accessToken);
    throw Object.assign(new Error('invalid token'), { code: 'AUTH_REQUIRED' });
  }, collection: () => { throw new Error('DB must not run'); }, download: () => { throw new Error('Storage must not run'); } });
  const f = fixture(input => reader.readBatch(input));
  for (const mode of ['REVIEW', 'REVISION']) {
    const input = request(); input.items[0].mode = mode;
    input.items[0].revisionId = mode === 'REVISION' ? 'revision-1' : '';
    const response = await f.handler({ body: JSON.stringify(input) });
    assert.equal(response.code, 'AUTH_REQUIRED');
    assert.equal(response.requestId, input.readRequestId);
    assert.ok(!f.logs.join('').includes(input.accessToken));
  }
  assert.equal(verified, 2);
});

test('wrapped batches still enforce protocol and item limits before authentication', async () => {
  const reader = createImageReader({ verifyToken: () => { throw new Error('Auth must not run'); },
    collection: () => { throw new Error('DB must not run'); }, download: () => { throw new Error('Storage must not run'); } });
  for (const input of [{ ...request(), protocolVersion: 'wrong-version' },
    { ...request(), items: [] }, { ...request(), items: Array(21).fill(request().items[0]) }]) {
    const f = fixture(value => reader.readBatch(value)), response = await f.handler({ body: JSON.stringify(input) });
    assert.equal(response.code, 'VALIDATION_ERROR');
    assert.ok(f.logs[0].includes('BATCH_VALIDATION'));
  }
});

test('wrapped public image requests return verified bytes without validating a stale token', async () => {
  const input = request(), jpeg = Buffer.from([255, 216, 255, 224, 255, 217]);
  const rows = {
    IdentityBinding: [], Friendship: [], FoodCardRevision: [],
    CardMedia: [{ id: input.items[0].mediaId, cardId: 'card-1', ownerUid: 'author', storageUid: 'author',
      status: 'APPROVED', createdAt: 1, byteSize: jpeg.length, width: 1, height: 1,
      preparedSha256: crypto.createHash('sha256').update(jpeg).digest('hex') }],
    FoodCard: [{ id: 'card-1', ownerUid: 'author', status: 'APPROVED', schemaVersion: 0, updatedAt: 1 }],
    UserProfile: [{ uid: 'author', accountStatus: 'ACTIVE' }, { uid: 'viewer', accountStatus: 'ACTIVE' }]
  };
  let downloads = 0, verified = 0;
  const reader = createImageReader({ adminUids: [], verifyToken: async () => {
    verified++; throw Object.assign(new Error('stale public token'), { code: 'AUTH_REQUIRED' });
  }, collection: name => ({ query: () => {
    const filters = []; let size = 100;
    const query = {
      in: (field, values) => { filters.push(row => values.includes(row[field])); return query; },
      equalTo: (field, value) => { filters.push(row => row[field] === value); return query; },
      limit: value => { size = value; return query; },
      get: async () => rows[name].filter(row => filters.every(filter => filter(row))).slice(0, size).map(row => ({ ...row }))
    };
    return query;
  } }), download: async () => { downloads++; return jpeg; } });
  const f = fixture(value => reader.readBatch(value));
  const response = await f.handler({ httpMethod: 'POST', body: JSON.stringify(input) });
  assert.equal(response.ok, true); assert.equal(response.requestId, input.readRequestId);
  assert.equal(response.data.items[0].status, 'BYTES');
  assert.deepEqual(Buffer.from(response.data.items[0].dataBase64, 'base64'), jpeg);
  assert.equal(downloads, 1);
  assert.equal(verified, 0);
});
