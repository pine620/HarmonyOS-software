'use strict';

/**
 * 【文件职责】内容可见性策略（所有读取卡片 / 资料 / 图片的云函数共用）：卡片是否可读、作者账号是否有效、
 * 图片是否允许给某个查看者、修订图片与审核图片的权限等。文件内容的 sha256 就是响应中的 policyHash，
 * 可用来确认各个云函数部署的是同一版策略。
 * 【新人注意】这里的模型类字段必须与 clouddb/objecttype 中的定义一致；只有受信任的云函数（Administrator 权限）能执行这些读取。
 */
// Cloud DB 模型基类：AGC 服务端 SDK 通过这些方法获取字段类型、类名、主键与索引。
class PolicyDbModel {
  getFieldTypeMap() { return new Map(Object.entries(this.constructor.fieldTypes)); }
  getClassName() { return this.constructor.name; }
  getPrimaryKeyList() { return [...this.constructor.primaryKeys]; }
  getIndexList() { return [...this.constructor.indexes]; }
  getEncryptedFieldList() { return []; }
}

// 策略相关的模型类（字段与 objecttype 定义一致）。
class FoodCard extends PolicyDbModel {}
// 旧的 Cloud DB 列为兼容已部署的结构而保留；好友可见权限检查已退役。
FoodCard.fieldTypes = Object.freeze({"id": "String", "ownerUid": "String", "productName": "String", "brand": "String", "priceFen": "Integer", "priceLabel": "String", "originalPriceFen": "Integer", "specification": "String", "shop": "String", "sellingPointsJson": "Text", "publicOffersJson": "Text", "reviewText": "Text", "tasteScore": "Integer", "sourceLink": "Text", "category": "String", "mediaId": "String", "latE3": "Integer", "lonE3": "Integer", "district": "String", "geohash": "String", "status": "String", "createdAt": "Long", "updatedAt": "Long", "schemaVersion": "Integer", "migrationSource": "String", "consumptionMode": "String", "visibility": "String", "merchantId": "String", "merchantNameSnapshot": "String", "merchantAddressSnapshot": "Text", "categoryV2": "String", "categoryVersion": "Integer", "itemPriceFen": "Long", "dineInAvgFen": "Long", "orderTotalFen": "Long", "deliveryFeeFen": "Long", "queryPriceFen": "Long", "deliveryPlatformKey": "String", "deliveryPlatformLabelSnapshot": "String", "consumedAt": "Date", "publishedAt": "Date", "modifiedAt": "Date", "edited": "Boolean", "friendVisibilitySince": "Date", "friendVisibilitySequence": "Long", "reviewState": "String", "deletedAt": "Date", "purgeAt": "Date", "lifecycleGeneration": "Long", "searchTextNormalized": "Text", "reviewReason": "String"});
FoodCard.primaryKeys = Object.freeze(['id']);
FoodCard.indexes = Object.freeze(["status,createdAt,id", "status,category,createdAt,id", "ownerUid,createdAt", "ownerUid,status,createdAt", "status,latE3,lonE3,createdAt", "status,createdAt", "merchantId,id", "ownerUid,merchantId,id", "visibility,status,publishedAt,id", "visibility,status,queryPriceFen,publishedAt,id", "visibility,status,queryPriceFen,publishedAt,id", "merchantId,visibility,status,publishedAt,id", "visibility,status,tasteScore,publishedAt,id", "ownerUid,status,createdAt,id", "merchantId,status,tasteScore,publishedAt,id"]);

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
IdentityBinding.indexes = Object.freeze(['provider,providerUid', 'canonicalUid', 'canonicalUid,id']);

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

class Report extends PolicyDbModel {}
Report.fieldTypes = Object.freeze({"id": "String", "reporterUid": "String", "cardId": "String", "reason": "String", "status": "String", "createdAt": "Long", "targetType": "String", "targetId": "String", "updatedAt": "Long", "resolutionAction": "String", "resolutionReason": "String", "resolvedByUid": "String", "resolvedAt": "Long", "reasonType": "String", "description": "String", "cardTitle": "String", "reportedRevision": "String", "submissionRequestId": "String", "submissionPayloadHash": "String", "resolutionRequestId": "String", "resolutionPayloadHash": "String", "resolvedCardRevision": "String"});
Report.primaryKeys = Object.freeze(['id']);
Report.indexes = Object.freeze(['cardId', 'reporterUid,createdAt', 'status,createdAt,id', 'reporterUid,createdAt,id']);

const policyModels = Object.freeze({ FoodCard, UserProfile, IdentityBinding, FoodCardRevision, Report });

// 创建带错误码的业务错误（默认 CONTENT_ACCESS_DENIED）。
function accessError(message, code = 'CONTENT_ACCESS_DENIED') {
  const error = new Error(message);
  error.code = code;
  return error;
}

// 把 Date / 数字 / 数字字符串转换为毫秒时间戳，无法识别时返回 null。
function dateMillis(value) {
  // Cloud DB SDK 会把 Long 字段返回为十进制字符串。这里只转换有界的整数；空串、指数形式和超出安全范围的整数都不当作日期。
  const millis = value instanceof Date ? value.getTime() :
    typeof value === 'string' && /^\d{1,16}$/.test(value) ? Number(value) : value;
  return typeof millis === 'number' && Number.isSafeInteger(millis) && millis >= 0 ? millis : null;
}

// 账号是否有效（未停用、未注销）。
function isAccountActive(profile) {
  // 旧资料可能没有状态字段（视为有效）；资料不存在则一定无效。
  return !!profile && String(profile.accountStatus || 'ACTIVE') === 'ACTIVE';
}

// 忽略旧的可见性取值：所有已发布的卡片都是公开的。
// 卡片当前可见性。
function currentVisibility(card) { return card ? 'PUBLIC' : ''; }

// 卡片的可读状态（公开 / 已下架 / 已删除等）。
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

// 卡片内容版本（取修改时间 / 更新时间 / 创建时间）。
function cardContentRevision(card) { return String(dateMillis(card && card.modifiedAt) ?? dateMillis(card && card.updatedAt) ?? dateMillis(card && card.createdAt) ?? 0) + ':' + String(card && card.lifecycleGeneration || 0); }

// 创建一个策略实例：getCollection / readOne 由调用方注入（便于在事务中复用与测试）；实例内会缓存已读的资料与卡片。
function createContentPolicy(getCollection, readOne, initialState = null) {
  // 公开内容不需要查看者登录，但作者账号必须仍然有效。
  const profiles = new Map();
  const cards = new Map((initialState && initialState.cards || []).map(row => [String(row.id), Promise.resolve(row)]));
  const revisions = new Map((initialState && initialState.revisions || []).map(row => [String(row.revisionId), Promise.resolve(row)]));
  for (const id of initialState && initialState.cardIds || []) if (!cards.has(String(id))) cards.set(String(id), Promise.resolve(null));
  for (const id of initialState && initialState.revisionIds || []) if (!revisions.has(String(id))) revisions.set(String(id), Promise.resolve(null));
  // 事务可以预先放入已经读到的行，避免同一事务中对同一条权威记录读出两个版本。
  for (const row of initialState && initialState.profiles || []) {
    if (row && row.uid) profiles.set(String(row.uid), Promise.resolve(row));
  }
  // 预先放入已读到的资料行。
  function seedProfiles(entries) {
    for (const [uid, row] of entries) if (uid && !profiles.has(uid)) profiles.set(uid, Promise.resolve(row || null));
  }

  // 读取用户资料（带缓存）。
  async function profile(uid) {
    const key = String(uid || '');
    if (!key) return null;
    if (!profiles.has(key)) profiles.set(key, readOne(getCollection('UserProfile').query().equalTo('uid', key)));
    return profiles.get(key);
  }

  // 读取卡片（带缓存）。
  async function readCard(id) {
    const key = String(id || '');
    if (!cards.has(key)) cards.set(key, readOne(getCollection('FoodCard').query().equalTo('id', key)));
    return cards.get(key);
  }

  // 读取修订（带缓存）。
  async function readRevision(id) {
    const key = String(id || '');
    if (!revisions.has(key)) revisions.set(key, readOne(getCollection('FoodCardRevision').query().equalTo('revisionId', key)));
    return revisions.get(key);
  }

  // 断言账号有效，否则抛出 ACCOUNT_INACTIVE（allowMissing=true 时允许资料尚不存在）。
  async function assertAccountActive(uid, allowMissing = false) {
    const row = await profile(uid);
    if ((!row && !allowMissing) || (row && !isAccountActive(row))) {
      throw accessError('账号已停用或正在注销。', 'ACCOUNT_INACTIVE');
    }
    return row;
  }

  // 卡片是否可读（公开且作者有效）。
  async function canReadCard(_viewerUid, card) {
    return readableCardState(card) && isAccountActive(await profile(card.ownerUid));
  }
  // 卡片是否公开可见。
  async function isCardPubliclyVisible(card) { return canReadCard('', card); }

  // 断言作者资料可读。
  async function assertProfileReadable(_viewerUid, authorUid) {
    await assertAccountActive(authorUid);
  }

  // 断言卡片可读，否则抛出 CONTENT_ACCESS_DENIED / CONTENT_UNAVAILABLE。
  async function assertCardReadable(viewerUid, card) {
    if (!await canReadCard(viewerUid, card)) throw accessError('内容不存在或当前不可访问。');
  }

  // 图片是否可读：属于可读卡片的已通过图片，或资料头像 / 背景。
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
    return !!card && String(card.ownerUid || '') === ownerUid && await canReadCard('', card);
  }

  // 修订图片是否可读（仅作者本人）。
  async function canReadRevisionMedia(viewerUid, media, revisionId) {
    if (!viewerUid || !media || media.status !== 'APPROVED' || !isAccountActive(await profile(viewerUid))) return false;
    if (!revisionId && media.ownerUid === viewerUid) { const own = await readCard(media.cardId); if (own && own.ownerUid === viewerUid && own.reviewState === 'REQUEST_CHANGE' && own.deletedAt == null && own.purgeAt == null) return true; }
    const revision = await readRevision(revisionId);
    if (!revision || !isAccountActive(await profile(revision.authorUid)) || media.ownerUid !== revision.authorUid) return false;
    const author = viewerUid === revision.authorUid;
    if (!author || !['PENDING', 'REJECTED'].includes(revision.status)) return false;
    const card = await readCard(revision.cardId);
    if (!card || card.ownerUid !== revision.authorUid || !(readableCardState(card) || card.reviewState === 'REQUEST_CHANGE' && card.deletedAt == null && card.purgeAt == null)) return false;
    let ids;
    try { ids = JSON.parse(String(revision.mediaManifestJson || '[]')); } catch (_error) { return false; }
    return Array.isArray(ids) && ids.includes(String(media.id)) &&
      [String(card.id), 'revision:' + String(revision.revisionId)].includes(String(media.cardId));
  }

  // 待更正卡片的图片是否可读（作者或审核员）。
  async function canReadCorrectionMedia(viewerUid,media) {
    if (!viewerUid || !media || media.status !== 'APPROVED' || !isAccountActive(await profile(viewerUid))) return false;
    if (!isAccountActive(await profile(media.ownerUid))) return false;
    const card=await readCard(media.cardId);
    if (!card || card.ownerUid !== media.ownerUid || card.deletedAt != null || card.purgeAt != null) return false;
    return viewerUid === card.ownerUid && card.reviewState === 'REQUEST_CHANGE';
  }

  return { seedProfiles, assertAccountActive, assertProfileReadable, isCardPubliclyVisible, canReadCard,
    assertCardReadable, canReadMedia, canReadRevisionMedia, canReadCorrectionMedia };
}

module.exports = { createContentPolicy, policyModels, isAccountActive, readableCardState,
  currentVisibility, dateMillis, cardContentRevision, accessError };
