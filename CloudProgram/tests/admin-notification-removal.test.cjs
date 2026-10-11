'use strict';
// User-run regressions of private-media authorization and direct Push routing.
// Injected sources only: no cloud SDK, credentials, network, or app UI.
const test = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');
const { createContentPolicy } = require('../cloudfunctions/shared/content-policy');

function policyFixture(cardChanges = {}, revisionChanges = {}, inactiveOwner = false) {
  const card = { id: 'card', ownerUid: 'owner', status: 'REMOVED', reviewState: 'REQUEST_CHANGE', ...cardChanges };
  const revision = { revisionId: 'revision', cardId: 'card', authorUid: 'owner', status: 'PENDING', mediaManifestJson: '["media"]', ...revisionChanges };
  const profiles = [{ uid: 'owner', accountStatus: inactiveOwner ? 'DELETED' : 'ACTIVE' }, { uid: 'former-admin', accountStatus: 'ACTIVE' }];
  const policy = createContentPolicy(() => { throw new Error('Unexpected unseeded authority read'); },
    () => { throw new Error('Unexpected unseeded authority read'); }, { cards: [card], revisions: [revision], profiles });
  return { policy, media: { id: 'media', cardId: 'card', ownerUid: 'owner', status: 'APPROVED' } };
}
test('correction media is readable by its owner, and a former administrator cannot bypass ownership', async () => {
  const f = policyFixture();
  assert.equal(await f.policy.canReadCorrectionMedia('owner', f.media), true);
  assert.equal(await f.policy.canReadCorrectionMedia('former-admin', f.media, true), false);
});
test('revision media remains author-only even with a legacy privileged argument', async () => {
  const f = policyFixture();
  assert.equal(await f.policy.canReadRevisionMedia('owner', f.media, 'revision'), true);
  assert.equal(await f.policy.canReadRevisionMedia('former-admin', f.media, 'revision', true), false);
});
test('owner media reads still reject deleted cards and inactive accounts', async () => {
  const deleted = policyFixture({ deletedAt: new Date() });
  assert.equal(await deleted.policy.canReadCorrectionMedia('owner', deleted.media), false);
  assert.equal(await deleted.policy.canReadRevisionMedia('owner', deleted.media, 'revision'), false);
  const inactive = policyFixture({}, {}, true);
  assert.equal(await inactive.policy.canReadCorrectionMedia('owner', inactive.media), false);
  assert.equal(await inactive.policy.canReadRevisionMedia('owner', inactive.media, 'revision'), false);
});
function pushFixture(fail = false, configured = true) {
  const source = readFileSync(join(__dirname, '../cloudfunctions/shike-service/runtime.js'), 'utf8');
  const begin = source.indexOf('const SOCIAL_PUSH_TEXT');
  const end = source.indexOf('function serviceCardCategoryLabel', begin);
  assert.ok(begin >= 0 && end > begin);
  const sent = [];
  const scope = {
    pushConfiguration: () => ({}), pushConfigured: () => configured,
    contentPolicy: () => ({ assertAccountActive: async () => {} }),
    bestEffortPush: async (uid, title, body, route) => { if (fail) throw new Error('Transport failed'); sent.push({ uid, title, body, route: JSON.parse(JSON.stringify(route)) }); },
    safeLogError: () => 'REDACTED', console: { error: () => {} }
  };
  vm.runInNewContext(source.slice(begin, end), scope);
  return { send: (...args) => scope.sendSocialPush(...args, {}), sent };
}
test('social Push routes directly to friend and group chats without an inbox event lookup', async () => {
  const f = pushFixture();
  await f.send('recipient', 'sender', 'FRIEND_REQUEST', 'request');
  await f.send('recipient', 'sender', 'FRIEND_ACCEPTED', 'sender');
  await f.send('recipient', 'sender', 'DIRECT_MESSAGE', 'sender');
  await f.send('recipient', 'sender', 'GROUP_MESSAGE', 'group');
  assert.deepEqual(f.sent.map(item => item.route), [
    { shikeRoute: 'tab', shikeTab: '2', shikeFriendSection: 'requests' },
    { shikeRoute: 'friend-chat', shikeFriendUid: 'sender' },
    { shikeRoute: 'friend-chat', shikeFriendUid: 'sender' },
    { shikeRoute: 'group-chat', shikeGroupId: 'group' }
  ]);
});
test('Push transport failures and self-addressed reminders do not fail completed social writes', async () => {
  const failed = pushFixture(true);
  await assert.doesNotReject(failed.send('recipient', 'sender', 'DIRECT_MESSAGE', 'sender'));
  const f = pushFixture();
  await f.send('sender', 'sender', 'DIRECT_MESSAGE', 'sender');
  assert.equal(f.sent.length, 0);
});
test('an unconfigured Push transport performs no authority reads or reminder writes', async () => {
  const source = readFileSync(join(__dirname, '../cloudfunctions/shike-service/runtime.js'), 'utf8');
  const begin = source.indexOf('const SOCIAL_PUSH_TEXT');
  const end = source.indexOf('function serviceCardCategoryLabel', begin);
  const scope = { pushConfiguration: () => ({}), pushConfigured: () => false,
    contentPolicy: () => { assert.fail('Disabled Push must not read accounts'); },
    bestEffortPush: () => { assert.fail('Disabled Push must not send'); },
    console: { error: () => { assert.fail('No failure is expected'); } }, safeLogError: () => '' };
  vm.runInNewContext(source.slice(begin, end), scope);
  await scope.sendSocialPush('recipient', 'sender', 'DIRECT_MESSAGE', 'sender', {});
});
