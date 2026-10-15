'use strict';
// Run by the user. The fixture has no network, AGC account or device access.
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { createNicknameAuth, nickname } = require('../cloudfunctions/shike-service/nickname-auth');
const identityId = (provider, uid) => crypto.createHash('sha256').update(`shike-identity:${provider}:${uid}`).digest('hex');

function fixture(t) {
  const data = {
    UserProfile: ['u1', 'u2'].map(uid => ({ uid, nickname: uid, nicknameValue: uid, accountStatus: 'ACTIVE', updatedAt: 1 })),
    NicknameClaim: [{ key: 'migration', ownerUid: 'READY', nickname: '', updatedAt: 1 }],
    PasswordCredential: [], PasswordThrottle: [], IdentityBinding: []
  };
  const keys = { UserProfile: 'uid', NicknameClaim: 'key', PasswordCredential: 'uid', PasswordThrottle: 'id', IdentityBinding: 'id' };
  const models = {};
  for (const name of Object.keys(data)) models[name] = class { getClassName() { return name; } };
  class Query {
    constructor(name) { this.name = name; this.filters = []; this.size = 100; }
    equalTo(key, value) { this.filters.push(row => row[key] === value); return this; }
    greaterThan(key, value) { this.filters.push(row => row[key] > value); return this; }
    orderByAsc(key) { this.sort = key; return this; }
    limit(value) { this.size = value; return this; }
    async get() {
      const rows = data[this.name].filter(row => this.filters.every(filter => filter(row))).map(row => ({ ...row }));
      if (this.sort) rows.sort((a, b) => String(a[this.sort]).localeCompare(String(b[this.sort])));
      return rows.slice(0, this.size);
    }
  }
  let tail = Promise.resolve();
  const collection = (_env, name) => ({
    query: () => new Query(name),
    runTransaction: ({ apply }) => {
      const task = tail.then(async () => {
        const writes = [], deletes = [];
        let writing = false;
        const tx = {
          executeQuery: query => { assert.equal(writing, false, 'authority reads must precede writes'); return query.get(); },
          executeUpsert: rows => {
            assert.ok(new Set(rows.map(row => row.getClassName())).size <= 1,
              'Cloud DB requires one object type per executeUpsert batch (2058)');
            writing = true; writes.push(...rows);
          },
          executeDelete: rows => { writing = true; deletes.push(...rows); }
        };
        // Preserve Cloud DB model identity on transaction read results.
        const originalRead = tx.executeQuery;
        tx.executeQuery = async query => (await originalRead(query)).map(row => Object.assign(new models[query.name](), row));
        const committed = await apply(tx);
        if (committed) {
          for (const row of deletes) {
            const name = row.getClassName(); data[name] = data[name].filter(value => value[keys[name]] !== row[keys[name]]);
          }
          for (const row of writes) {
            const name = row.getClassName(), at = data[name].findIndex(value => value[keys[name]] === row[keys[name]]);
            if (at < 0) data[name].push({ ...row }); else data[name][at] = { ...row };
          }
        }
        return committed;
      });
      tail = task.catch(() => {}); return task;
    }
  });
  let provider = 12, authTime = Date.now() / 1000, verifiedEmail = true, revoked = '';
  let customProvider = 10, customExpiry = undefined, verifyFailure = false;
  let upstreamMode = '', calls = 0;
  const tokens = new Map();
  const cloud = { auth: () => ({
    sign: ({ uid }) => ({ getToken: () => uid }),
    verifyAccessToken: async ({ accessToken }) => {
      if (tokens.has(accessToken) && verifyFailure) throw { getCode: () => 'FIXTURE_VERIFY' };
      return {
      getSub: () => tokens.get(accessToken) || accessToken.split(':')[1],
      getProviderInfo: () => ({ getSignInProvider: () => tokens.has(accessToken) ? customProvider : provider }),
      isEmailVerified: () => verifiedEmail, getAuthTime: () => authTime,
      getExp: () => tokens.has(accessToken) && customExpiry !== undefined ? customExpiry : Date.now() / 1000 + 3600
    }; },
    revokeRefreshTokens: async ({ uid }) => { revoked = uid; }
  }) };
  let beforeTokenReply = undefined;
  const diagnostics = [];
  t.mock.method(console, 'error', value => { diagnostics.push(String(value)); });
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    calls++;
    if (upstreamMode === 'network') throw new Error('fixture-private-network-detail');
    if (upstreamMode === 'http') return { ok: false, status: 503 };
    if (upstreamMode === 'json') return { ok: true, status: 200, json: async () => { throw new Error('fixture-private-body'); } };
    if (url.endsWith('/token')) {
      if (upstreamMode === 'client') return { ok: true, status: 200, json: async () => ({ error: 'invalid_client', error_description: 'fixture-secret' }) };
      return { ok: true, status: 200, json: async () => ({ access_token: 'fixture-api-token' }) };
    }
    const body = JSON.parse(options.body);
    assert.equal(body.provider, 10);
    const providerUid = 'agc-' + crypto.createHash('sha256').update(body.token).digest('hex').slice(0, 20);
    const token = 'fixture-' + providerUid;
    tokens.set(token, providerUid);
    if (beforeTokenReply) { const action = beforeTokenReply; beforeTokenReply = undefined; await action(); }
    if (upstreamMode === 'signin') return { ok: true, status: 200, json: async () => ({ ret: { code: 123456, msg: 'fixture-secret' } }) };
    if (upstreamMode === 'missing-token') return { ok: true, status: 200, json: async () => ({ ret: { code: 0 } }) };
    if (upstreamMode === 'string-fields') return { ok: true, status: 200, json: async () => ({ ret: '{"code":0}', accessToken: JSON.stringify({ token, validPeriod: 3600 }) }) };
    return { ok: true, status: 200, json: async () => ({ ret: { code: 0 }, accessToken: { token, validPeriod: 3600 } }) };
  });
  const ctx = {
    collection, models, cloud, identityBindingId: identityId, requestId: () => 'fixture-request-id',
    one: async query => (await query.limit(1).get())[0],
    verifiedIdentity: async token => {
      const providerUid = tokens.get(token) || token.split(':')[1];
      const binding = data.IdentityBinding.find(row => row.id === identityId('AGC', providerUid));
      if (binding && binding.status !== 'ACTIVE') throw Object.assign(new Error('disabled'), { code: 'ACCOUNT_INACTIVE' });
      return { providerUid, canonicalUid: binding ? binding.canonicalUid : providerUid };
    },
    profileForWrite: (row, now) => Object.assign(new models.UserProfile(), row, { updatedAt: now }),
    profileResponse: row => ({ uid: row.uid, nickname: row.nicknameValue }),
    logicalWriteTime: time => Math.max(Date.now(), Number(time) + 1)
  };
  const env = { SHIKE_NICKNAME_AUTH_ENABLED: 'true', SHIKE_ACCOUNT_SIGNING_PRIVATE_KEY: 'fixture-key',
    SHIKE_AGC_CLIENT_ID: 'fixture-client', SHIKE_AGC_CLIENT_SECRET: 'fixture-secret', SHIKE_AGC_PROJECT_ID: 'fixture-project' };
  const service = createNicknameAuth(ctx);
  const configure = (uid = 'u1', name = '食刻测试员', password = 'Fixture-Only-2026!') =>
    service.configure('email:' + uid, { nickname: name, password }, env);
  return { data, env, service, configure, collection, models,
    provider: value => { provider = value; }, authTime: value => { authTime = value; }, emailVerified: value => { verifiedEmail = value; },
    beforeTokenReply: action => { beforeTokenReply = action; }, revoked: () => revoked,
    upstreamMode: value => { upstreamMode = value; }, calls: () => calls, diagnostics,
    customProvider: value => { customProvider = value; }, customExpiry: value => { customExpiry = value; },
    verifyFailure: value => { verifyFailure = value; } };
}

test('normalization reserves equivalent case/full-width names and rejects invisible names', () => {
  assert.equal(nickname(' Ｓhike ').key, nickname('shike').key);
  assert.throws(() => nickname('食刻\u200b用户'), { code: 'INVALID_NICKNAME' });
});

test('setup requires fresh verified email or Huawei; a password token cannot reset itself', async t => {
  const f = fixture(t);
  f.provider(10); await assert.rejects(f.configure(), { code: 'REAUTH_REQUIRED' });
  f.provider(12); f.emailVerified(false); await assert.rejects(f.configure(), { code: 'REAUTH_REQUIRED' });
  f.emailVerified(true); f.authTime(Date.now() / 1000 - 601); await assert.rejects(f.configure(), { code: 'REAUTH_REQUIRED' });
  f.authTime(Date.now() / 1000); f.provider(1); assert.equal((await f.configure()).uid, 'u1');
  assert.equal(f.data.PasswordCredential[0].passwordHash.includes('Fixture'), false);
  assert.equal(f.data.PasswordCredential[0].salt.length, 64);
});

test('two accounts cannot claim one nickname, and failed setup leaves no credential', async t => {
  const f = fixture(t);
  const results = await Promise.allSettled([f.configure('u1', 'Shike'), f.configure('u2', 'ＳＨＩＫＥ')]);
  assert.equal(results.filter(row => row.status === 'fulfilled').length, 1);
  assert.equal(results.find(row => row.status === 'rejected').reason.code, 'NICKNAME_TAKEN');
  assert.equal(f.data.PasswordCredential.length, 1);
});

test('login keeps the canonical owner and reveals neither email nor password hashes', async t => {
  const f = fixture(t); await f.configure();
  const result = await f.service.login({ nickname: '食刻测试员', password: 'Fixture-Only-2026!' }, f.env);
  assert.deepEqual(Object.keys(result).sort(), ['accessToken', 'expiresAt']);
  assert.equal(f.data.IdentityBinding[0].canonicalUid, 'u1');
  await f.service.logout(result.accessToken, f.env);
  assert.equal(f.revoked(), f.data.IdentityBinding[0].providerUid);
  await assert.rejects(f.service.login({ nickname: '食刻测试员', password: 'Wrong-password' }, f.env), { code: 'INVALID_CREDENTIALS' });
  await assert.rejects(f.service.login({ nickname: '不存在的昵称', password: 'Wrong-password' }, f.env), { code: 'INVALID_CREDENTIALS' });
});

test('rename updates both the claim and login name; the old name no longer logs in', async t => {
  const f = fixture(t); await f.configure();
  await f.collection(f.env, 'UserProfile').runTransaction({ apply: async tx => {
    const current = (await tx.executeQuery(f.collection(f.env, 'UserProfile').query().equalTo('uid', 'u1')))[0];
    const saved = Object.assign(new f.models.UserProfile(), current, { nickname: '新的昵称', nicknameValue: '新的昵称' });
    await f.service.rename(tx, f.env, current, saved); tx.executeUpsert([saved]); return true;
  } });
  await assert.rejects(f.service.login({ nickname: '食刻测试员', password: 'Fixture-Only-2026!' }, f.env), { code: 'INVALID_CREDENTIALS' });
  await f.service.login({ nickname: '新的昵称', password: 'Fixture-Only-2026!' }, f.env);
  assert.equal(f.data.UserProfile[0].uid, 'u1');
});

test('reset disables the old password identity and blocks an in-flight old-password login', async t => {
  const f = fixture(t); await f.configure();
  await f.service.login({ nickname: '食刻测试员', password: 'Fixture-Only-2026!' }, f.env);
  f.beforeTokenReply(() => f.configure('u1', '食刻测试员', 'Replacement-2026!'));
  await assert.rejects(f.service.login({ nickname: '食刻测试员', password: 'Fixture-Only-2026!' }, f.env), { code: 'INVALID_CREDENTIALS' });
  assert.equal(f.data.IdentityBinding[0].status, 'DISABLED');
  await f.service.login({ nickname: '食刻测试员', password: 'Replacement-2026!' }, f.env);
  assert.equal(f.data.IdentityBinding.filter(row => row.status === 'ACTIVE').length, 1);
});

test('legacy duplicate nicknames stay unclaimed and require a new unique name', async t => {
  const f = fixture(t); f.data.NicknameClaim = [];
  for (const row of f.data.UserProfile) row.nicknameValue = '食刻用户';
  f.env.SHIKE_NICKNAME_MIGRATING = 'true';
  assert.equal((await f.service.migrate(f.env)).complete, true);
  assert.equal(f.data.NicknameClaim.find(row => row.key === nickname('食刻用户').key).ownerUid, 'CONFLICT');
  f.env.SHIKE_NICKNAME_MIGRATING = 'false';
  await assert.rejects(f.configure('u1', '食刻用户'), { code: 'NICKNAME_TAKEN' });
  await f.configure('u1', '新的独立昵称');
});

test('rate limits reserve attempts before expensive authentication and unknown names stay bounded', async t => {
  const f = fixture(t);
  f.data.PasswordThrottle.push({ id: 'login:global', windowAt: Date.now(), count: 120 });
  await assert.rejects(f.service.login({ nickname: '任意昵称', password: 'Guess-2026!' }, f.env), { code: 'AUTH_RATE_LIMITED' });
  assert.equal(f.data.PasswordCredential.length, 0);
  assert.equal(f.data.IdentityBinding.length, 0);
});

test('payload identities cannot select another account, and inactive accounts cannot set passwords', async t => {
  const f = fixture(t);
  await f.service.configure('email:u1', { nickname: '食刻测试员', password: 'Fixture-Only-2026!', uid: 'u2', role: 'admin' }, f.env);
  assert.equal(f.data.PasswordCredential[0].uid, 'u1');
  assert.equal(f.data.PasswordCredential[0].role, undefined);
  f.data.UserProfile[0].accountStatus = 'DELETING';
  await assert.rejects(f.configure(), { code: 'ACCOUNT_INACTIVE' });
  await assert.rejects(f.service.login({ nickname: '食刻测试员', password: 'Fixture-Only-2026!' }, f.env), { code: 'INVALID_CREDENTIALS' });
});

test('save-and-login returns a verified session already bound to the same canonical account', async t => {
  const f = fixture(t); const result = await f.configure();
  assert.equal(result.profile.uid, 'u1');
  assert.equal(typeof result.accessToken, 'string'); assert.ok(result.expiresAt > Date.now());
  assert.equal(f.data.IdentityBinding.find(row => row.providerUid === f.data.PasswordCredential[0].customAgcUid).canonicalUid, 'u1');
  assert.equal(f.data.IdentityBinding[0].status, 'ACTIVE');
});

for (const [mode, code, stage] of [
  ['client', 'AUTH_AGC_CLIENT_REJECTED', 'AGC_CLIENT_TOKEN'],
  ['signin', 'AUTH_AGC_SIGN_IN_REJECTED', 'AGC_USER_SIGN_IN'],
  ['network', 'AUTH_UPSTREAM_NETWORK', 'AGC_CLIENT_TOKEN'],
  ['http', 'AUTH_UPSTREAM_HTTP', 'AGC_CLIENT_TOKEN'],
  ['json', 'AUTH_UPSTREAM_RESPONSE', 'AGC_CLIENT_TOKEN'],
  ['missing-token', 'AUTH_UPSTREAM_RESPONSE', 'AGC_USER_SIGN_IN']
]) {
  test(`upstream ${mode} failure does not save a password or expose upstream bodies`, async t => {
    const f = fixture(t); f.upstreamMode(mode);
    await assert.rejects(f.configure(), error => {
      assert.equal(error.code, code); assert.equal(error.message.includes('fixture-secret'), false);
      return true;
    });
    assert.equal(f.data.PasswordCredential.length, 0); assert.equal(f.data.IdentityBinding.length, 0);
    assert.equal(f.data.UserProfile[0].nicknameValue, 'u1');
    assert.ok(f.diagnostics.some(value => value.includes('stage=' + stage)));
    const logs = f.diagnostics.join('\n');
    for (const secret of ['Fixture-Only-2026!', 'fixture-secret', 'fixture-api-token', 'fixture-private']) assert.equal(logs.includes(secret), false);
  });
}

test('upstream reset failure retains the previous password generation and active session', async t => {
  const f = fixture(t); await f.configure();
  const previous = { ...f.data.PasswordCredential[0] };
  f.upstreamMode('signin');
  await assert.rejects(f.configure('u1', '食刻测试员', 'Replacement-2026!'), { code: 'AUTH_AGC_SIGN_IN_REJECTED' });
  assert.deepEqual(f.data.PasswordCredential[0], previous);
  assert.equal(f.data.IdentityBinding[0].status, 'ACTIVE');
  f.upstreamMode('');
  await f.service.login({ nickname: '食刻测试员', password: 'Fixture-Only-2026!' }, f.env);
});

test('string-encoded AGC ret/accessToken responses are handled', async t => {
  const f = fixture(t); f.upstreamMode('string-fields');
  assert.equal((await f.configure()).profile.uid, 'u1');
});

test('invalid provider, expired credential and failed SDK verification are rejected before save', async t => {
  const f = fixture(t);
  f.customProvider(12); await assert.rejects(f.configure(), { code: 'AUTH_AGC_TOKEN_INVALID' });
  f.customProvider(10); f.customExpiry(Date.now() / 1000 - 1);
  await assert.rejects(f.configure(), { code: 'AUTH_AGC_TOKEN_INVALID' });
  f.customExpiry(undefined); f.verifyFailure(true);
  await assert.rejects(f.configure(), { code: 'AUTH_AGC_TOKEN_INVALID' });
  assert.equal(f.data.PasswordCredential.length, 0);
});

test('a wrong password does not contact AGC', async t => {
  const f = fixture(t); await f.configure(); const before = f.calls();
  await assert.rejects(f.service.login({ nickname: '食刻测试员', password: 'Wrong-password' }, f.env), { code: 'INVALID_CREDENTIALS' });
  assert.equal(f.calls(), before);
});

test('changing a password preserves the account and nickname and replaces the old password session', async t => {
  const f = fixture(t); const initial = await f.configure();
  const profile = { ...f.data.UserProfile[0] }, claims = f.data.NicknameClaim.map(row => ({ ...row }));
  const previous = { ...f.data.PasswordCredential[0] };
  const result = await f.service.changePassword(initial.accessToken, {
    expectedUid: 'u1', currentPassword: 'Fixture-Only-2026!', newPassword: 'Changed-2026!'
  }, f.env);
  assert.equal(result.profile.uid, 'u1'); assert.equal(result.profile.nickname, '食刻测试员');
  assert.deepEqual(f.data.UserProfile[0], profile); assert.deepEqual(f.data.NicknameClaim, claims);
  assert.notEqual(f.data.PasswordCredential[0].generation, previous.generation);
  assert.equal(f.data.PasswordCredential[0].createdAt, previous.createdAt);
  assert.equal(f.data.IdentityBinding.find(row => row.providerUid === previous.customAgcUid).status, 'DISABLED');
  assert.equal(f.data.IdentityBinding.filter(row => row.status === 'ACTIVE').length, 1);
  assert.equal((await f.service.status(result.accessToken, f.env)).configured, true);
  await assert.rejects(f.service.status(initial.accessToken, f.env), { code: 'ACCOUNT_INACTIVE' });
  await assert.rejects(f.service.login({ nickname: '食刻测试员', password: 'Fixture-Only-2026!' }, f.env), { code: 'INVALID_CREDENTIALS' });
  await f.service.login({ nickname: '食刻测试员', password: 'Changed-2026!' }, f.env);
  for (const secret of ['Fixture-Only-2026!', 'Changed-2026!', result.accessToken]) {
    assert.equal(f.diagnostics.join('\n').includes(secret), false);
  }
});

test('wrong current passwords do not exchange tokens or modify the saved credential', async t => {
  const f = fixture(t); const initial = await f.configure(), before = f.calls();
  const previous = { ...f.data.PasswordCredential[0] };
  await assert.rejects(f.service.changePassword(initial.accessToken, {
    expectedUid: 'u1', currentPassword: 'Wrong-current-2026!', newPassword: 'Changed-2026!'
  }, f.env), { code: 'CURRENT_PASSWORD_INCORRECT' });
  assert.equal(f.calls(), before); assert.deepEqual(f.data.PasswordCredential[0], previous);
  assert.equal(f.data.IdentityBinding[0].status, 'ACTIVE');
});

test('rate limits and inactive accounts stop password changes before an upstream exchange', async t => {
  const f = fixture(t); const initial = await f.configure(), before = f.calls();
  const previous = { ...f.data.PasswordCredential[0] };
  f.data.PasswordThrottle.find(row => row.id === 'login:global').count = 120;
  await assert.rejects(f.service.changePassword(initial.accessToken, {
    expectedUid: 'u1', currentPassword: 'Fixture-Only-2026!', newPassword: 'Changed-2026!'
  }, f.env), { code: 'AUTH_RATE_LIMITED' });
  f.data.PasswordThrottle = [];
  f.data.UserProfile[0].accountStatus = 'DELETING';
  await assert.rejects(f.service.changePassword(initial.accessToken, {
    expectedUid: 'u1', currentPassword: 'Fixture-Only-2026!', newPassword: 'Changed-2026!'
  }, f.env), { code: 'ACCOUNT_INACTIVE' });
  assert.equal(f.calls(), before); assert.deepEqual(f.data.PasswordCredential[0], previous);
});

test('the account anchor is checked and forged identity or role fields cannot change another account', async t => {
  const f = fixture(t); const initial = await f.configure(), before = f.calls();
  for (const expectedUid of ['u2', undefined]) {
    await assert.rejects(f.service.changePassword(initial.accessToken, {
      expectedUid, uid: 'u2', currentPassword: 'Fixture-Only-2026!', newPassword: 'Changed-2026!'
    }, f.env), { code: 'ACCOUNT_MISMATCH' });
  }
  assert.equal(f.calls(), before);
  await f.service.changePassword(initial.accessToken, {
    expectedUid: 'u1', uid: 'u2', role: 'admin', currentPassword: 'Fixture-Only-2026!', newPassword: 'Changed-2026!'
  }, f.env);
  assert.equal(f.data.PasswordCredential.length, 1); assert.equal(f.data.PasswordCredential[0].uid, 'u1');
  assert.equal(f.data.PasswordCredential[0].role, undefined); assert.equal(f.data.UserProfile[1].nicknameValue, 'u2');
});

for (const provider of [12, 1]) {
  test(`an original provider ${provider} session can change its own password after proving the current password`, async t => {
    const f = fixture(t); await f.configure(); f.provider(provider);
    const result = await f.service.changePassword('email:u1', {
      expectedUid: 'u1', currentPassword: 'Fixture-Only-2026!', newPassword: 'Changed-2026!'
    }, f.env);
    assert.equal(result.profile.uid, 'u1');
    await f.service.login({ nickname: '食刻测试员', password: 'Changed-2026!' }, f.env);
  });
}

test('unchanged or weak new passwords and accounts without a password are rejected without an exchange', async t => {
  const f = fixture(t); const initial = await f.configure(), before = f.calls();
  const previous = { ...f.data.PasswordCredential[0] };
  for (const [newPassword, code] of [['Fixture-Only-2026!', 'PASSWORD_UNCHANGED'],
    ['', 'INVALID_PASSWORD'], ['abcdefgh', 'INVALID_PASSWORD'], ['A1'.repeat(65), 'INVALID_PASSWORD']]) {
    await assert.rejects(f.service.changePassword(initial.accessToken, {
      expectedUid: 'u1', currentPassword: 'Fixture-Only-2026!', newPassword
    }, f.env), { code });
  }
  await assert.rejects(f.service.changePassword('email:u2', {
    expectedUid: 'u2', currentPassword: 'Fixture-Only-2026!', newPassword: 'Changed-2026!'
  }, f.env), { code: 'PASSWORD_NOT_SET' });
  assert.equal(f.calls(), before); assert.deepEqual(f.data.PasswordCredential[0], previous);
});

test('an upstream change-password failure keeps the old password and session usable', async t => {
  const f = fixture(t); const initial = await f.configure();
  const previous = { ...f.data.PasswordCredential[0] };
  f.upstreamMode('signin');
  await assert.rejects(f.service.changePassword(initial.accessToken, {
    expectedUid: 'u1', currentPassword: 'Fixture-Only-2026!', newPassword: 'Changed-2026!'
  }, f.env), { code: 'AUTH_AGC_SIGN_IN_REJECTED' });
  assert.deepEqual(f.data.PasswordCredential[0], previous); assert.equal(f.data.IdentityBinding[0].status, 'ACTIVE');
  assert.equal((await f.service.status(initial.accessToken, f.env)).configured, true);
  f.upstreamMode('');
  await f.service.login({ nickname: '食刻测试员', password: 'Fixture-Only-2026!' }, f.env);
});

test('an in-flight password change cannot overwrite a more recent provider password reset', async t => {
  const f = fixture(t); const initial = await f.configure();
  f.beforeTokenReply(() => f.configure('u1', '食刻测试员', 'Latest-reset-2026!'));
  await assert.rejects(f.service.changePassword(initial.accessToken, {
    expectedUid: 'u1', currentPassword: 'Fixture-Only-2026!', newPassword: 'Changed-2026!'
  }, f.env), { code: 'PASSWORD_STATE_CHANGED' });
  assert.equal(f.data.IdentityBinding.filter(row => row.status === 'ACTIVE').length, 1);
  await f.service.login({ nickname: '食刻测试员', password: 'Latest-reset-2026!' }, f.env);
  await assert.rejects(f.service.login({ nickname: '食刻测试员', password: 'Changed-2026!' }, f.env), { code: 'INVALID_CREDENTIALS' });
});

async function renameFixture(f, name) {
  await f.collection(f.env, 'UserProfile').runTransaction({ apply: async tx => {
    const current = (await tx.executeQuery(f.collection(f.env, 'UserProfile').query().equalTo('uid', 'u1')))[0];
    const saved = Object.assign(new f.models.UserProfile(), current, { nickname: name, nicknameValue: name });
    await f.service.rename(tx, f.env, current, saved); tx.executeUpsert([saved]); return true;
  } });
}

test('a nickname changed during password exchange remains the login name after the password change', async t => {
  const f = fixture(t); const initial = await f.configure();
  f.beforeTokenReply(() => renameFixture(f, '新的昵称'));
  const result = await f.service.changePassword(initial.accessToken, {
    expectedUid: 'u1', currentPassword: 'Fixture-Only-2026!', newPassword: 'Changed-2026!'
  }, f.env);
  assert.equal(result.profile.nickname, '新的昵称');
  assert.equal(f.data.PasswordCredential[0].nicknameKey, nickname('新的昵称').key);
  await f.service.login({ nickname: '新的昵称', password: 'Changed-2026!' }, f.env);
  await assert.rejects(f.service.login({ nickname: '食刻测试员', password: 'Changed-2026!' }, f.env), { code: 'INVALID_CREDENTIALS' });
});

test('a concurrent nickname change cannot make the new password equal to the resulting nickname', async t => {
  const f = fixture(t); const initial = await f.configure();
  const generation = f.data.PasswordCredential[0].generation;
  f.beforeTokenReply(() => renameFixture(f, 'Changed2026'));
  await assert.rejects(f.service.changePassword(initial.accessToken, {
    expectedUid: 'u1', currentPassword: 'Fixture-Only-2026!', newPassword: 'Changed2026'
  }, f.env), { code: 'INVALID_PASSWORD' });
  assert.equal(f.data.PasswordCredential[0].generation, generation);
  assert.equal(f.data.IdentityBinding[0].status, 'ACTIVE');
  await f.service.login({ nickname: 'Changed2026', password: 'Fixture-Only-2026!' }, f.env);
});
