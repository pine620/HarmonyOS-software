'use strict';

const crypto = require('crypto');

// Identical policy is included in each independently deployed cloud-object package.
// Keep all three copies aligned; callers inject their existing database boundary.
class PolicyDbModel {
  getFieldTypeMap() { return new Map(Object.entries(this.constructor.fieldTypes)); }
  getClassName() { return this.constructor.name; }
  getPrimaryKeyList() { return [...this.constructor.primaryKeys]; }
  getIndexList() { return [...this.constructor.indexes]; }
  getEncryptedFieldList() { return []; }
}

class FoodCard extends PolicyDbModel {}
FoodCard.fieldTypes = Object.freeze({
  id: 'String',
  ownerUid: 'String',
  productName: 'String',
  brand: 'String',
  priceFen: 'Integer',
  priceLabel: 'String',
  originalPriceFen: 'Integer',
  specification: 'String',
  shop: 'String',
  sellingPointsJson: 'Text',
  publicOffersJson: 'Text',
  reviewText: 'Text',
  tasteScore: 'Integer',
  sourceLink: 'Text',
  category: 'String',
  mediaId: 'String',
  latE3: 'Integer',
  lonE3: 'Integer',
  district: 'String',
  geohash: 'String',
  status: 'String',
  createdAt: 'Long',
  updatedAt: 'Long',
  schemaVersion: 'Integer',
  migrationSource: 'String',
  consumptionMode: 'String',
  visibility: 'String',
  merchantId: 'String',
  merchantNameSnapshot: 'String',
  merchantAddressSnapshot: 'Text',
  categoryV2: 'String',
  categoryVersion: 'Integer',
  itemPriceFen: 'Long',
  dineInAvgFen: 'Long',
  orderTotalFen: 'Long',
  deliveryFeeFen: 'Long',
  queryPriceFen: 'Long',
  deliveryPlatformKey: 'String',
  deliveryPlatformLabelSnapshot: 'String',
  consumedAt: 'Date',
  publishedAt: 'Date',
  modifiedAt: 'Date',
  edited: 'Boolean',
  friendVisibilitySince: 'Date',
  friendVisibilitySequence: 'Long',
  reviewState: 'String',
  deletedAt: 'Date',
  purgeAt: 'Date',
  lifecycleGeneration: 'Long',
  searchTextNormalized: 'Text'
});
FoodCard.primaryKeys = Object.freeze(['id']);
FoodCard.indexes = Object.freeze(["status,createdAt,id", "status,category,createdAt,id", "ownerUid,createdAt", "ownerUid,status,createdAt", "status,latE3,lonE3,createdAt", "status,createdAt", "ownerUid,status,tasteScore,createdAt", "merchantId,id", "ownerUid,merchantId,id", "visibility,status,publishedAt,id", "visibility,status,tasteScore,publishedAt,id", "visibility,status,queryPriceFen,publishedAt,id", "visibility,status,queryPriceFen,publishedAt,id", "merchantId,visibility,status,publishedAt,id"]);

class UserProfile extends PolicyDbModel {}
UserProfile.fieldTypes = Object.freeze({
  uid: 'String',
  nickname: 'String',
  avatarUrl: 'String',
  nicknameValue: 'String',
  avatarMediaId: 'String',
  avatarStorageUid: 'String',
  coverMediaId: 'String',
  coverStorageUid: 'String',
  friendCode: 'String',
  accountStatus: 'String',
  publishCount: 'Integer',
  createdAt: 'Long',
  updatedAt: 'Long',
  contentSequence: 'Long'
});
UserProfile.primaryKeys = Object.freeze(['uid']);
UserProfile.indexes = Object.freeze(['nicknameValue', 'friendCode']);

class Friendship extends PolicyDbModel {}
Friendship.fieldTypes = Object.freeze({
  id: 'String',
  memberAUid: 'String',
  memberBUid: 'String',
  requesterUid: 'String',
  addresseeUid: 'String',
  status: 'String',
  createdAt: 'Long',
  updatedAt: 'Long'
});
Friendship.primaryKeys = Object.freeze(['id']);
Friendship.indexes = Object.freeze(['memberAUid', 'memberBUid', 'requesterUid', 'addresseeUid']);

class FriendContentAccessGrant extends PolicyDbModel {}
FriendContentAccessGrant.fieldTypes = Object.freeze({
  authorUid: 'String',
  viewerUid: 'String',
  accessThroughAt: 'Date',
  accessThroughSequence: 'Long',
  revoked: 'Boolean',
  revokedAt: 'Date',
  updatedAt: 'Date'
});
FriendContentAccessGrant.primaryKeys = Object.freeze(['authorUid', 'viewerUid']);
FriendContentAccessGrant.indexes = Object.freeze(['authorUid,viewerUid', 'viewerUid,authorUid']);

class IdentityBinding extends PolicyDbModel {}
IdentityBinding.fieldTypes = Object.freeze({
  id: 'String',
  provider: 'String',
  providerUid: 'String',
  canonicalUid: 'String',
  status: 'String',
  createdAt: 'Long',
  updatedAt: 'Long'
});
IdentityBinding.primaryKeys = Object.freeze(['id']);
IdentityBinding.indexes = Object.freeze(['provider,providerUid', 'canonicalUid']);

class FoodCardRevision extends PolicyDbModel {}
FoodCardRevision.fieldTypes = Object.freeze({
  "revisionId": "String",
  "cardId": "String",
  "authorUid": "String",
  "baseModifiedAt": "Date",
  "baseLifecycleGeneration": "Long",
  "requestPayloadHash": "String",
  "payloadJson": "Text",
  "mediaManifestJson": "Text",
  "status": "String",
  "submittedAt": "Date",
  "reviewedAt": "Date",
  "reviewReason": "String"
});
FoodCardRevision.primaryKeys = Object.freeze(["revisionId"]);
FoodCardRevision.indexes = Object.freeze(["cardId,status,submittedAt,revisionId", "authorUid,submittedAt,revisionId", "status,submittedAt,revisionId", "cardId,submittedAt,revisionId"]);

const policyModels = Object.freeze({ FoodCard, UserProfile, Friendship, FriendContentAccessGrant, IdentityBinding, FoodCardRevision });

function accessError(message, code = 'CONTENT_ACCESS_DENIED') {
  const error = new Error(message);
  error.code = code;
  return error;
}

function dateMillis(value) {
  const millis = value instanceof Date ? value.getTime() : value;
  return typeof millis === 'number' && Number.isSafeInteger(millis) && millis >= 0 ? millis : null;
}

function isAccountActive(profile) {
  // Existing profiles may omit the status; an absent profile is never active.
  return !!profile && String(profile.accountStatus || 'ACTIVE') === 'ACTIVE';
}

function currentVisibility(card) {
  if (!card) return '';
  const value = String(card.visibility || '');
  const version = Number(card.schemaVersion || 0);
  return !value && version === 0 ? 'PUBLIC' : value;
}

function readableCardState(card) {
  if (!card || card.status !== 'APPROVED' || !String(card.ownerUid || '') ||
      card.deletedAt != null || card.purgeAt != null) return false;
  const version = Number(card.schemaVersion || 0);
  if (!Number.isSafeInteger(version) || version < 0) return false;
  const visibility = currentVisibility(card);
  if (visibility !== 'PUBLIC' && visibility !== 'FRIENDS') return false;
  const review = String(card.reviewState || '');
  if (version === 0) return !review && visibility === 'PUBLIC';
  if (review === 'LEGACY_APPROVED') return version === 1 && card.migrationSource === 'LEGACY';
  return review === 'PENDING_POST_REVIEW' || review === 'APPROVED';
}

function relationshipId(firstUid, secondUid) {
  const first = String(firstUid || '');
  const second = String(secondUid || '');
  return crypto.createHash('sha256')
    .update('friend:' + (first < second ? first + ':' + second : second + ':' + first))
    .digest('hex');
}

function createContentPolicy(getCollection, readOne, initialState = null) {
  // These caches belong to one policy instance within one request. They never
  // survive a request or enter Redis; every new request reads current authority.
  const profiles = new Map();
  const relationships = new Map();
  // A transaction can seed rows it has already read, avoiding a second
  // version of the same authority row within one transaction attempt.
  for (const row of initialState && initialState.profiles || []) {
    if (row && row.uid) profiles.set(String(row.uid), Promise.resolve(row));
  }
  for (const row of initialState && initialState.relationships || []) {
    if (row && row.id) relationships.set(String(row.id), Promise.resolve(row));
  }

  async function profile(uid) {
    const key = String(uid || '');
    if (!key) return null;
    if (!profiles.has(key)) profiles.set(key, readOne(getCollection('UserProfile').query().equalTo('uid', key)));
    return profiles.get(key);
  }

  async function relation(authorUid, viewerUid) {
    if (!authorUid || !viewerUid || authorUid === viewerUid) return null;
    const id = relationshipId(authorUid, viewerUid);
    if (!relationships.has(id)) relationships.set(id, readOne(getCollection('Friendship').query().equalTo('id', id)));
    return relationships.get(id);
  }

  async function prepareCardReads(viewerUid, cards) {
    const authors = [...new Set(cards.filter(readableCardState).map((card) => String(card.ownerUid || '')))];
    const uids = [...new Set([...authors, String(viewerUid || '')].filter(Boolean))].filter((uid) => !profiles.has(uid));
    for (let start = 0; start < uids.length; start += 50) {
      const batch = uids.slice(start, start + 50);
      const rows = await getCollection('UserProfile').query().in('uid', batch).limit(batch.length).get();
      const byUid = new Map(rows.map((row) => [String(row.uid || ''), row]));
      for (const uid of batch) profiles.set(uid, Promise.resolve(byUid.get(uid) || null));
    }
    if (!viewerUid || !isAccountActive(await profile(viewerUid))) return;
    const ids = authors.filter((uid) => uid !== viewerUid).map((uid) => relationshipId(uid, viewerUid))
      .filter((id) => !relationships.has(id));
    for (let start = 0; start < ids.length; start += 50) {
      const batch = ids.slice(start, start + 50);
      const rows = await getCollection('Friendship').query().in('id', batch).limit(batch.length).get();
      const byId = new Map(rows.map((row) => [String(row.id || ''), row]));
      for (const id of batch) relationships.set(id, Promise.resolve(byId.get(id) || null));
    }
  }

  async function assertAccountActive(uid, allowMissing = false) {
    const row = await profile(uid);
    if ((!row && !allowMissing) || (row && !isAccountActive(row))) {
      throw accessError('账号已停用或正在注销。', 'ACCOUNT_INACTIVE');
    }
    return row;
  }

  async function isCardPubliclyVisible(card) {
    return readableCardState(card) && currentVisibility(card) === 'PUBLIC' &&
      isAccountActive(await profile(String(card.ownerUid || '')));
  }

  async function canReadFriendCard(viewerUid, card, relationship = null) {
    if (!viewerUid || !readableCardState(card) || currentVisibility(card) !== 'FRIENDS') return false;
    const authorUid = String(card.ownerUid || '');
    if (!isAccountActive(await profile(authorUid)) || !isAccountActive(await profile(viewerUid))) return false;
    if (viewerUid === authorUid) return true;
    const current = relationship || await relation(authorUid, viewerUid);
    if (current && current.status === 'BLOCKED') return false;
    if (current && current.status === 'ACCEPTED') return true;
    const grant = await readOne(getCollection('FriendContentAccessGrant').query()
      .equalTo('authorUid', authorUid).equalTo('viewerUid', viewerUid));
    if (!grant || grant.revoked !== false) return false;
    const since = dateMillis(card.friendVisibilitySince);
    const through = dateMillis(grant.accessThroughAt);
    const cardSequence = Number(card.friendVisibilitySequence);
    const throughSequence = Number(grant.accessThroughSequence);
    // Both server chronology and logical sequence must agree. Missing sequence
    // denies access instead of guessing an order for equal millisecond times.
    return since !== null && through !== null && since <= through &&
      Number.isSafeInteger(cardSequence) && cardSequence > 0 &&
      Number.isSafeInteger(throughSequence) && throughSequence >= cardSequence;
  }

  async function canReadCard(viewerUid, card) {
    if (!readableCardState(card)) return false;
    const authorUid = String(card.ownerUid || '');
    if (!isAccountActive(await profile(authorUid))) return false;
    if (!viewerUid) return currentVisibility(card) === 'PUBLIC';
    if (!isAccountActive(await profile(viewerUid))) return false;
    if (viewerUid === authorUid) return true;
    const relationship = await relation(authorUid, viewerUid);
    if (relationship && relationship.status === 'BLOCKED') return false;
    if (currentVisibility(card) === 'PUBLIC') return true;
    return canReadFriendCard(viewerUid, card, relationship);
  }

  async function assertCardReadable(viewerUid, card) {
    if (!await canReadCard(viewerUid, card)) throw accessError('内容不存在或当前不可访问。');
  }

  async function canReadMedia(viewerUid, media) {
    if (!media || media.status !== 'APPROVED') return false;
    const ownerUid = String(media.ownerUid || '');
    const cardId = String(media.cardId || '');
    if (!ownerUid || !cardId || !isAccountActive(await profile(ownerUid))) return false;
    if (viewerUid && !isAccountActive(await profile(viewerUid))) return false;
    if (cardId === 'profile:' + ownerUid || cardId === 'profile-cover:' + ownerUid) {
      const owner = await profile(ownerUid);
      const relationship = await relation(ownerUid, viewerUid);
      if (relationship && relationship.status === 'BLOCKED') return false;
      if (cardId === 'profile:' + ownerUid) return String(owner.avatarMediaId || '') === String(media.id || '');
      return String(owner.coverMediaId || '') === String(media.id || '') && !!viewerUid &&
        (viewerUid === ownerUid || (relationship && relationship.status === 'ACCEPTED'));
    }
    const card = await readOne(getCollection('FoodCard').query().equalTo('id', cardId));
    return !!card && String(card.ownerUid || '') === ownerUid && await canReadCard(viewerUid, card);
  }

  async function canReadRevisionMedia(viewerUid, media, revisionId, administrator = false) {
    if (!viewerUid || !media || media.status !== 'APPROVED' || !isAccountActive(await profile(viewerUid))) return false;
    const revision = await readOne(getCollection('FoodCardRevision').query().equalTo('revisionId', String(revisionId || '')));
    if (!revision || !isAccountActive(await profile(revision.authorUid)) || media.ownerUid !== revision.authorUid) return false;
    const author = viewerUid === revision.authorUid;
    if (author ? !['PENDING', 'REJECTED'].includes(revision.status) : !administrator || revision.status !== 'PENDING') return false;
    const card = await readOne(getCollection('FoodCard').query().equalTo('id', String(revision.cardId)));
    if (!card || card.ownerUid !== revision.authorUid || !readableCardState(card)) return false;
    let ids;
    try { ids = JSON.parse(String(revision.mediaManifestJson || '[]')); } catch (_error) { return false; }
    return Array.isArray(ids) && ids.includes(String(media.id)) &&
      [String(card.id), 'revision:' + String(revision.revisionId)].includes(String(media.cardId));
  }

  return { prepareCardReads, assertAccountActive, isCardPubliclyVisible, canReadCard, canReadFriendCard,
    assertCardReadable, canReadMedia, canReadRevisionMedia };
}

module.exports = { createContentPolicy, policyModels, isAccountActive, readableCardState,
  currentVisibility, dateMillis, accessError };
