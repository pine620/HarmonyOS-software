'use strict';

// Shared content state and private write/review helpers for independent artifacts.
class PolicyDbModel {
  getFieldTypeMap() { return new Map(Object.entries(this.constructor.fieldTypes)); }
  getClassName() { return this.constructor.name; }
  getPrimaryKeyList() { return [...this.constructor.primaryKeys]; }
  getIndexList() { return [...this.constructor.indexes]; }
  getEncryptedFieldList() { return []; }
}

class FoodCard extends PolicyDbModel {}
// Legacy CloudDB columns remain for deployed-schema compatibility; public reads ignore them.
FoodCard.fieldTypes = Object.freeze({"id": "String", "ownerUid": "String", "productName": "String", "brand": "String", "priceFen": "Integer", "priceLabel": "String", "originalPriceFen": "Integer", "specification": "String", "shop": "String", "sellingPointsJson": "Text", "publicOffersJson": "Text", "reviewText": "Text", "tasteScore": "Integer", "sourceLink": "Text", "category": "String", "mediaId": "String", "latE3": "Integer", "lonE3": "Integer", "district": "String", "geohash": "String", "status": "String", "createdAt": "Long", "updatedAt": "Long", "schemaVersion": "Integer", "migrationSource": "String", "consumptionMode": "String", "visibility": "String", "merchantId": "String", "merchantNameSnapshot": "String", "merchantAddressSnapshot": "Text", "categoryV2": "String", "categoryVersion": "Integer", "itemPriceFen": "Long", "dineInAvgFen": "Long", "orderTotalFen": "Long", "deliveryFeeFen": "Long", "queryPriceFen": "Long", "deliveryPlatformKey": "String", "deliveryPlatformLabelSnapshot": "String", "consumedAt": "Date", "publishedAt": "Date", "modifiedAt": "Date", "edited": "Boolean", "friendVisibilitySince": "Date", "friendVisibilitySequence": "Long", "reviewState": "String", "deletedAt": "Date", "purgeAt": "Date", "lifecycleGeneration": "Long", "searchTextNormalized": "Text", "reviewReason": "String"});
FoodCard.primaryKeys = Object.freeze(['id']);
FoodCard.indexes = Object.freeze(["status,createdAt,id", "status,category,createdAt,id", "ownerUid,createdAt", "ownerUid,status,createdAt", "status,latE3,lonE3,createdAt", "status,createdAt", "ownerUid,status,tasteScore,createdAt", "merchantId,id", "ownerUid,merchantId,id", "status,publishedAt,id", "status,queryPriceFen,publishedAt,id", "status,queryPriceFen,publishedAt,id", "merchantId,status,publishedAt,id", "status,tasteScore,publishedAt,id", "ownerUid,status,createdAt,id"]);

class UserProfile extends PolicyDbModel {}
UserProfile.fieldTypes = Object.freeze({"uid": "String", "nickname": "String", "avatarUrl": "String", "nicknameValue": "String", "avatarMediaId": "String", "avatarStorageUid": "String", "coverMediaId": "String", "coverStorageUid": "String", "friendCode": "String", "accountStatus": "String", "publishCount": "Integer", "createdAt": "Long", "updatedAt": "Long", "contentSequence": "Long", "deletionJobId": "String"});
UserProfile.primaryKeys = Object.freeze(['uid']);
UserProfile.indexes = Object.freeze(["nicknameValue", "friendCode"]);

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

const policyModels = Object.freeze({ FoodCard, UserProfile, IdentityBinding, FoodCardRevision });

function accessError(message, code = 'CONTENT_ACCESS_DENIED') {
  const error = new Error(message);
  error.code = code;
  return error;
}

function dateMillis(value) {
  // The Cloud DB SDK preserves Long fields as decimal strings. Convert only
  // bounded integers; Number(''), exponents and unsafe integers are not dates.
  const millis = value instanceof Date ? value.getTime() :
    typeof value === 'string' && /^\d{1,16}$/.test(value) ? Number(value) : value;
  return typeof millis === 'number' && Number.isSafeInteger(millis) && millis >= 0 ? millis : null;
}

function isAccountActive(profile) {
  // Existing profiles may omit the status; an absent profile is never active.
  return !!profile && String(profile.accountStatus || 'ACTIVE') === 'ACTIVE';
}

// Legacy visibility values are ignored: all published cards are public.
function currentVisibility(card) { return card ? 'PUBLIC' : ''; }

function readableCardState(card) {
  if (!card || card.status !== 'APPROVED' || !String(card.ownerUid || '') ||
      card.deletedAt != null || card.purgeAt != null) return false;
  const version = Number(card.schemaVersion || 0);
  if (!Number.isSafeInteger(version) || version < 0) return false;
  const review = String(card.reviewState || '');
  if (version === 0) return !review;
  if (review === 'LEGACY_APPROVED') return version === 1 && card.migrationSource === 'LEGACY';
  return review === 'PENDING_POST_REVIEW' || review === 'APPROVED';
}

function cardContentRevision(card) { return String(dateMillis(card && card.modifiedAt) ?? dateMillis(card && card.updatedAt) ?? dateMillis(card && card.createdAt) ?? 0) + ':' + String(card && card.lifecycleGeneration || 0); }

function createContentPolicy(getCollection, readOne, initialState = null) {
  // Only private operations need account checks; published content has no viewer permissions.
  const profiles = new Map();
  const cards = new Map((initialState && initialState.cards || []).map(row => [String(row.id), Promise.resolve(row)]));
  const revisions = new Map((initialState && initialState.revisions || []).map(row => [String(row.revisionId), Promise.resolve(row)]));
  for (const id of initialState && initialState.cardIds || []) if (!cards.has(String(id))) cards.set(String(id), Promise.resolve(null));
  for (const id of initialState && initialState.revisionIds || []) if (!revisions.has(String(id))) revisions.set(String(id), Promise.resolve(null));
  // A transaction can seed rows it has already read, avoiding a second
  // version of the same authority row within one transaction attempt.
  for (const row of initialState && initialState.profiles || []) {
    if (row && row.uid) profiles.set(String(row.uid), Promise.resolve(row));
  }
  function seedProfiles(entries) {
    for (const [uid, row] of entries) if (uid && !profiles.has(uid)) profiles.set(uid, Promise.resolve(row || null));
  }

  async function profile(uid) {
    const key = String(uid || '');
    if (!key) return null;
    if (!profiles.has(key)) profiles.set(key, readOne(getCollection('UserProfile').query().equalTo('uid', key)));
    return profiles.get(key);
  }

  async function readCard(id) {
    const key = String(id || '');
    if (!cards.has(key)) cards.set(key, readOne(getCollection('FoodCard').query().equalTo('id', key)));
    return cards.get(key);
  }

  async function readRevision(id) {
    const key = String(id || '');
    if (!revisions.has(key)) revisions.set(key, readOne(getCollection('FoodCardRevision').query().equalTo('revisionId', key)));
    return revisions.get(key);
  }

  async function assertAccountActive(uid, allowMissing = false) {
    const row = await profile(uid);
    if ((!row && !allowMissing) || (row && !isAccountActive(row))) {
      throw accessError('账号已停用或正在注销。', 'ACCOUNT_INACTIVE');
    }
    return row;
  }

  // Public reads depend on content state, never on the viewer or friendships.
  function isCardPubliclyVisible(card) { return readableCardState(card); }
  function canReadCard(_viewerUid, card) { return readableCardState(card); }

  async function assertProfileReadable(_viewerUid, authorUid) {
    await assertAccountActive(authorUid);
  }

  async function assertCardReadable(viewerUid, card) {
    if (!await canReadCard(viewerUid, card)) throw accessError('内容不存在或当前不可访问。');
  }

  async function canReadMedia(_viewerUid, media) {
    if (!media || media.status !== 'APPROVED') return false;
    const ownerUid = String(media.ownerUid || '');
    const cardId = String(media.cardId || '');
    if (!ownerUid || !cardId) return false;
    if (cardId === 'profile:' + ownerUid || cardId === 'profile-cover:' + ownerUid) {
      const owner = await profile(ownerUid);
      if (!isAccountActive(owner)) return false;
      const mediaId = cardId === 'profile:' + ownerUid ? owner.avatarMediaId : owner.coverMediaId;
      return String(mediaId || '') === String(media.id || '');
    }
    const card = await readCard(cardId);
    return !!card && String(card.ownerUid || '') === ownerUid && readableCardState(card);
  }

  async function canReadRevisionMedia(viewerUid, media, revisionId, administrator = false) {
    if (!viewerUid || !media || media.status !== 'APPROVED' || !isAccountActive(await profile(viewerUid))) return false;
    if (!revisionId && media.ownerUid === viewerUid) { const own = await readCard(media.cardId); if (own && own.ownerUid === viewerUid && own.reviewState === 'REQUEST_CHANGE' && own.deletedAt == null && own.purgeAt == null) return true; }
    const revision = await readRevision(revisionId);
    if (!revision || !isAccountActive(await profile(revision.authorUid)) || media.ownerUid !== revision.authorUid) return false;
    const author = viewerUid === revision.authorUid;
    if (author ? !['PENDING', 'REJECTED'].includes(revision.status) : !administrator || revision.status !== 'PENDING') return false;
    const card = await readCard(revision.cardId);
    if (!card || card.ownerUid !== revision.authorUid || !(readableCardState(card) || card.reviewState === 'REQUEST_CHANGE' && card.deletedAt == null && card.purgeAt == null)) return false;
    let ids;
    try { ids = JSON.parse(String(revision.mediaManifestJson || '[]')); } catch (_error) { return false; }
    return Array.isArray(ids) && ids.includes(String(media.id)) &&
      [String(card.id), 'revision:' + String(revision.revisionId)].includes(String(media.cardId));
  }

  async function canReadModerationMedia(viewerUid,media,administrator=false) {
    if (!viewerUid || !media || media.status !== 'APPROVED' || !isAccountActive(await profile(viewerUid))) return false;
    if (!isAccountActive(await profile(media.ownerUid))) return false;
    const card=await readCard(media.cardId);
    if (!card || card.ownerUid !== media.ownerUid || card.deletedAt != null || card.purgeAt != null) return false;
    return administrator || viewerUid === card.ownerUid && card.reviewState === 'REQUEST_CHANGE';
  }

  return { seedProfiles, assertAccountActive, assertProfileReadable, isCardPubliclyVisible, canReadCard,
    assertCardReadable, canReadMedia, canReadRevisionMedia, canReadModerationMedia };
}

module.exports = { createContentPolicy, policyModels, isAccountActive, readableCardState,
  currentVisibility, dateMillis, cardContentRevision, accessError };
