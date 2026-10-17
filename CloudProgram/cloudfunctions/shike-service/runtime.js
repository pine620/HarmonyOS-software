/**
 * 【文件职责】食刻业务云函数的核心实现（约 4000 行）。shike-service 与四个领域函数（shike-content / -social / -account /
 * -governance）运行的都是这一份代码（领域函数里的 service/ 目录由 npm run prepare:deveco 或打包脚本复制生成），shike-maintenance 也复用它。
 * 【请求入口】云对象 TS 文件调用 executeOperation(操作名, 信封, env) → 在请求上下文中执行 operations[操作名]
 * → verifiedUid() 校验 AGC Token 得到业务 UID → 调用本文件或 stage1~7 等子模块中的业务函数 → 读写 Cloud DB。
 * 【文件分区（按出现顺序）】
 *   1. 常量、实例内缓存（身份缓存 90 秒、游客首页 30 秒）、请求上下文（AsyncLocalStorage）
 *   2. Cloud DB 模型类（必须与 clouddb/objecttype/*.json 一致）
 *   3. 私信加密（AES-256-GCM）  4. Push 设备 / 桌面卡片登记与 Push Kit 发送
 *   5. 日志脱敏、collection()、读取计量  6. 卡片读取辅助  7. 身份：Token 校验、IdentityBinding、迁移票据、邮箱绑定
 *   8. 位置工具（旧发布位置）  9. 调用 shike-media（HMAC 委托）与对象路径  10. 用户资料  11. 卡片校验与发布
 *   12. 卡片读取组装（作者、图片、店铺、互动）  14. 推荐流 / 详情 / 我的卡片
 *   15. 好友关系  16. 私信  17. 群聊  18. 删除卡片与注销  19. 子模块装配  20. operations 操作表  21. 入口与维护导出
 * 【新人注意】新增操作要同步修改 operations 表、shikeService.ts、对应领域函数 TS 与客户端 CloudRoutes.ets（见报告第 5 节）。
 */
'use strict';

const crypto = require('crypto');
const { mediaVariant } = require('./shared/media-descriptor');
const { AsyncLocalStorage } = require('async_hooks');
const { cloud } = require('@hw-agconnect/cloud-server');
const { createContentPolicy, isAccountActive, readableCardState, currentVisibility, dateMillis, accessError } = require('./shared/content-policy');

const MAX_PAGE_SIZE = 20;
const MAX_CARD_PHOTOS = 6;
const CARD_READ_BATCH_SIZE = 10;
// 请求级上下文：读取计量、逻辑请求号、当前读取阶段、本次请求内的卡片读取缓存、当前操作名。
const readMetricsScope = new AsyncLocalStorage();
const readRequestScope = new AsyncLocalStorage();
const readPhaseScope = new AsyncLocalStorage();
const cardReadScope = new AsyncLocalStorage();
const operationScope = new AsyncLocalStorage();

// 【分区 1】实例内缓存：每个函数实例各自一份，实例之间不共享，所以每条缓存都用短 TTL 限制，而不是做跨实例失效。
const IDENTITY_CACHE_TTL_MS = 90 * 1000;
const IDENTITY_CACHE_MAX_ENTRIES = 2000;
const IDENTITY_CACHE_EXCLUDED_OPERATIONS = new Set(['get-password-account']);
const IDENTITY_STATE_OPERATIONS = new Set(['logout-nickname', 'change-password-account', 'configure-password-account']);
const identityCache = new Map();
const GUEST_PAGE_CACHE_TTL_MS = 30 * 1000;
const GUEST_PAGE_CACHE_MAX_ENTRIES = 50;
const GUEST_PAGE_CACHE_MAX_BYTES = 512 * 1024;
const guestPageCache = new Map();

// 是否为只读操作（get- / list- / search- 开头）。
function readOnlyOperation(operation) {
  return /^(get|list|search)-/.test(String(operation || ''));
}

// 记录一次缓存命中 / 未命中计数（写入读取指标）。
function recordCacheCount(name) {
  const metrics = readMetricsScope.getStore();
  if (metrics) metrics.counts[name] = (metrics.counts[name] || 0) + 1;
}

// 身份缓存的键：Token 的 sha256（不保存 Token 原文）。
function identityCacheKey(accessToken) {
  return crypto.createHash('sha256').update('shike-identity-cache:' + String(accessToken)).digest('hex');
}

// 当前操作是否允许使用身份缓存（只读且不在排除列表中）。
function identityCacheable() {
  const operation = operationScope.getStore() || '';
  return readOnlyOperation(operation) && !IDENTITY_CACHE_EXCLUDED_OPERATIONS.has(operation);
}

// 读取未过期的身份缓存。
function cachedIdentity(key) {
  const entry = identityCache.get(key);
  if (!entry) return null;
  if (entry.expiresAt <= Date.now()) { identityCache.delete(key); return null; }
  return entry;
}

// 记住已验证的身份（不超过 Token 到期时间，超过容量时淘汰最旧的）。
function rememberIdentity(key, providerUid, canonicalUid, tokenExpiresAt) {
  const now = Date.now();
  let expiresAt = now + IDENTITY_CACHE_TTL_MS;
  if (tokenExpiresAt > 0) expiresAt = Math.min(expiresAt, tokenExpiresAt);
  if (expiresAt <= now) return;
  identityCache.delete(key);
  while (identityCache.size >= IDENTITY_CACHE_MAX_ENTRIES) identityCache.delete(identityCache.keys().next().value);
  identityCache.set(key, { providerUid, canonicalUid, expiresAt });
}

// 删除某业务 UID 的身份缓存（密码修改、退出等身份状态变化后）。
function forgetIdentity(canonicalUid) {
  for (const [key, entry] of identityCache) {
    if (entry.canonicalUid === canonicalUid) identityCache.delete(key);
  }
}

// 游客没有个人化字段，所以首页第一页（无游标）可以共享几秒钟；缓存页里的游标仍携带原始快照时间，翻页保持一致。
// 游客首页第一页的实例内缓存（30 秒，最多 50 条、512KB）。
async function guestFirstPage(operation, payload, load) {
  const key = operation + ':' + JSON.stringify(payload || {});
  const entry = guestPageCache.get(key);
  if (entry && entry.expiresAt > Date.now()) { recordCacheCount('guestPageCacheHit'); return JSON.parse(entry.json); }
  if (entry) guestPageCache.delete(key);
  const result = await load();
  recordCacheCount('guestPageCacheMiss');
  const json = JSON.stringify(result);
  if (typeof json === 'string' && json.length <= GUEST_PAGE_CACHE_MAX_BYTES) {
    while (guestPageCache.size >= GUEST_PAGE_CACHE_MAX_ENTRIES) guestPageCache.delete(guestPageCache.keys().next().value);
    guestPageCache.set(key, { json, expiresAt: Date.now() + GUEST_PAGE_CACHE_TTL_MS });
  }
  return result;
}

// 所有操作都在这个作用域内运行。非只读操作会清掉本实例的游客页缓存，使这里处理的发布、修改、删除立即对游客可见（其他实例最长 30 秒）。
// 在操作上下文中执行；非只读操作会清空本实例的游客首页缓存。
function runOperation(operation, action) {
  if (!readOnlyOperation(operation)) guestPageCache.clear();
  return operationScope.run(operation, action);
}
const { withCursorContext } = require('./stages47-common');
const { requestId, errorCode, readStage, READ_OPT_VERSION, shouldReadMetrics } = require('./shared/read-errors');
// 在指定的读取阶段中执行（用于错误定位与耗时统计）。
function withReadPhase(phase, action) {
  return readPhaseScope.run(phase, async () => {
    const metrics = readMetricsScope.getStore();
    const started = Date.now();
    if (metrics) metrics.phaseCalls[phase] = (metrics.phaseCalls[phase] || 0) + 1;
    try { return await action(); }
    catch (error) {
      // 外层阶段退出时，保留最内层失败的阶段名。
      try { if (error && typeof error === 'object' && !error.readStage) error.readStage = phase; } catch (_) { }
      throw error;
    } finally {
      // 记录每个阶段的总耗时（含嵌套），嵌套阶段不能累加成总耗时。
      if (metrics) metrics.phaseMs[phase] = (metrics.phaseMs[phase] || 0) + Date.now() - started;
    }
  });
}
const MAX_CARD_REVIEW_LENGTH = 600;
const MAX_SOCIAL_RESULTS = 50;
const MAX_SOCIAL_PAGE_SIZE = 50;
const SOCIAL_QUERY_BATCH_SIZE = 200;
const SOCIAL_PROFILE_QUERY_BATCH_SIZE = 50;
const MAX_MESSAGE_LENGTH = 1000;
const MAX_MESSAGE_PAGE_SIZE = 50;
const MAX_GROUP_MEMBERS = 20;
const MIN_GROUP_FRIENDS = 2;
const MAX_GROUP_NAME_LENGTH = 32;
const FRIEND_REQUEST_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const PRIVATE_TEXT_KEY_BYTES = 32;
const MAX_SERVICE_CARD_FORM_REGISTRATIONS = 16;
const MAX_SERVICE_CARD_REGISTRATIONS_PER_ACCOUNT = 100;
const MAX_SERVICE_CARD_FORM_ID = 2147483647;
const DEFAULT_SERVICE_CARD_DAILY_PUSH_LIMIT = 2;
const VALID_CATEGORY = new Set(['staple', 'bakery', 'drink', 'snack', 'fresh', 'other']);
const PERSONALIZED = /新客|首单|白条|补贴|会员|账号|用户专享|个人专享/;

// 【分区 2：Cloud DB 模型】服务端模型类，字段类型、主键与索引必须与 CloudProgram/clouddb/objecttype/*.json 保持一致。
// Cloud DB 模型基类（shared/image-models.js）：AGC 服务端 SDK 通过它取得字段类型、类名（等于 objecttype 名称）、主键与索引。下面每个子类对应一个对象类型。
const { CloudDbModel, CardMedia } = require('./shared/image-models');

class UserProfile extends CloudDbModel {}
UserProfile.fieldTypes = Object.freeze({"uid": "String", "nickname": "String", "avatarUrl": "String", "nicknameValue": "String", "avatarMediaId": "String", "avatarStorageUid": "String", "coverMediaId": "String", "coverStorageUid": "String", "friendCode": "String", "accountStatus": "String", "publishCount": "Integer", "createdAt": "Long", "updatedAt": "Long", "contentSequence": "Long", "deletionJobId": "String"});
UserProfile.primaryKeys = Object.freeze(['uid']);
UserProfile.indexes = Object.freeze(["nicknameValue", "friendCode"]);

class FoodCard extends CloudDbModel {}
// 旧的 Cloud DB 列为兼容已部署结构而保留；公开读取不使用它们。
FoodCard.fieldTypes = Object.freeze({"id": "String", "ownerUid": "String", "productName": "String", "brand": "String", "priceFen": "Integer", "priceLabel": "String", "originalPriceFen": "Integer", "specification": "String", "shop": "String", "sellingPointsJson": "Text", "publicOffersJson": "Text", "reviewText": "Text", "tasteScore": "Integer", "sourceLink": "Text", "category": "String", "mediaId": "String", "latE3": "Integer", "lonE3": "Integer", "district": "String", "geohash": "String", "status": "String", "createdAt": "Long", "updatedAt": "Long", "schemaVersion": "Integer", "migrationSource": "String", "consumptionMode": "String", "visibility": "String", "merchantId": "String", "merchantNameSnapshot": "String", "merchantAddressSnapshot": "Text", "categoryV2": "String", "categoryVersion": "Integer", "itemPriceFen": "Long", "dineInAvgFen": "Long", "orderTotalFen": "Long", "deliveryFeeFen": "Long", "queryPriceFen": "Long", "deliveryPlatformKey": "String", "deliveryPlatformLabelSnapshot": "String", "consumedAt": "Date", "publishedAt": "Date", "modifiedAt": "Date", "edited": "Boolean", "friendVisibilitySince": "Date", "friendVisibilitySequence": "Long", "reviewState": "String", "deletedAt": "Date", "purgeAt": "Date", "lifecycleGeneration": "Long", "searchTextNormalized": "Text", "reviewReason": "String"});
FoodCard.primaryKeys = Object.freeze(['id']);
FoodCard.indexes = Object.freeze(["status,createdAt,id", "status,category,createdAt,id", "ownerUid,createdAt", "ownerUid,status,createdAt", "status,latE3,lonE3,createdAt", "status,createdAt", "merchantId,id", "ownerUid,merchantId,id", "visibility,status,publishedAt,id", "visibility,status,queryPriceFen,publishedAt,id", "visibility,status,queryPriceFen,publishedAt,id", "merchantId,visibility,status,publishedAt,id", "visibility,status,tasteScore,publishedAt,id", "ownerUid,status,createdAt,id", "merchantId,status,tasteScore,publishedAt,id"]);

class Merchant extends CloudDbModel {}
Merchant.fieldTypes = Object.freeze({
  "merchantId": "String",
  "name": "String",
  "normalizedName": "String",
  "address": "Text",
  "district": "String",
  "sourceType": "String",
  "provider": "String",
  "providerPoiId": "String",
  "latitudeE6": "Long",
  "longitudeE6": "Long",
  "coordinateSystem": "String",
  "verificationStatus": "String",
  "createdByUid": "String",
  "createdAt": "Date",
  "updatedAt": "Date",
  "publicRecommendationCount": "Integer",
  "publicDeliveryCount": "Integer",
  "publicDineInCount": "Integer",
  "mapVisible": "Boolean",
  "reviewAction": "String",
  "reviewReason": "String",
  "reviewedAt": "Date",
  "creationRequestHash": "String",
  "lastUpdateRequestId": "String",
  "lastUpdatePayloadHash": "String"
});
Merchant.primaryKeys = Object.freeze(['merchantId']);
Merchant.indexes = Object.freeze(["provider,providerPoiId", "verificationStatus,createdAt,merchantId", "createdByUid,createdAt,merchantId", "mapVisible,latitudeE6,merchantId", "coordinateSystem,latitudeE6,merchantId"]);

class Report extends CloudDbModel {}
Report.fieldTypes = Object.freeze({"id": "String", "reporterUid": "String", "cardId": "String", "reason": "String", "status": "String", "createdAt": "Long", "targetType": "String", "targetId": "String", "updatedAt": "Long", "resolutionAction": "String", "resolutionReason": "String", "resolvedByUid": "String", "resolvedAt": "Long", "reasonType": "String", "description": "String", "cardTitle": "String", "reportedRevision": "String", "submissionRequestId": "String", "submissionPayloadHash": "String", "resolutionRequestId": "String", "resolutionPayloadHash": "String", "resolvedCardRevision": "String"});
Report.primaryKeys = Object.freeze(['id']);
Report.indexes = Object.freeze(["cardId", "reporterUid,createdAt", "status,createdAt,id", "reporterUid,createdAt,id"]);

class CardAction extends CloudDbModel {}
CardAction.fieldTypes = Object.freeze({
  id: 'String',
  actorUid: 'String',
  cardId: 'String',
  kind: 'String',
  createdAt: 'Long'
});
CardAction.primaryKeys = Object.freeze(['id']);
CardAction.indexes = Object.freeze([
  'actorUid,kind,createdAt,id',
  'cardId',
  'actorUid,createdAt',
  'cardId,kind,id'
]);

// 已退役的评论存储仍需注册，用于历史数据的生命周期清理。
class CardComment extends CloudDbModel {}
CardComment.fieldTypes = Object.freeze({"id": "String", "cardId": "String", "authorUid": "String", "parentId": "String", "replyToNickname": "String", "replyToUid": "String", "content": "Text", "status": "String", "createdAt": "Long", "updatedAt": "Long"});
CardComment.primaryKeys = Object.freeze(['id']);
CardComment.indexes = Object.freeze(["cardId,createdAt", "cardId,createdAt", "authorUid,createdAt", "parentId,createdAt", "replyToUid,createdAt", "authorUid"]);

class CommentReaction extends CloudDbModel {}
CommentReaction.fieldTypes = Object.freeze({
  id: 'String',
  actorUid: 'String',
  commentId: 'String',
  kind: 'String',
  createdAt: 'Long'
});
CommentReaction.primaryKeys = Object.freeze(['id']);
CommentReaction.indexes = Object.freeze(['commentId', 'actorUid,createdAt']);

class Friendship extends CloudDbModel {}
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

class FriendReport extends CloudDbModel {}
FriendReport.fieldTypes = Object.freeze({"id": "String", "reporterUid": "String", "targetUid": "String", "reason": "String", "status": "String", "createdAt": "Long"});
FriendReport.primaryKeys = Object.freeze(['id']);
FriendReport.indexes = Object.freeze(["targetUid", "reporterUid"]);

class Conversation extends CloudDbModel {}
Conversation.fieldTypes = Object.freeze({
  id: 'String',
  memberAUid: 'String',
  memberBUid: 'String',
  lastMessageId: 'String',
  lastMessageKind: 'String',
  lastMessagePreview: 'Text',
  lastMessageAt: 'Long',
  unreadA: 'Integer',
  unreadB: 'Integer',
  createdAt: 'Long',
  updatedAt: 'Long'
});
Conversation.primaryKeys = Object.freeze(['id']);
Conversation.indexes = Object.freeze(['memberAUid', 'memberBUid']);

class ChatMessage extends CloudDbModel {}
ChatMessage.fieldTypes = Object.freeze({
  id: 'String',
  conversationId: 'String',
  senderUid: 'String',
  recipientUid: 'String',
  kind: 'String',
  text: 'Text',
  link: 'Text',
  cardId: 'String',
  createdAt: 'Long',
  readAt: 'Long'
});
ChatMessage.primaryKeys = Object.freeze(['id']);
ChatMessage.indexes = Object.freeze(['conversationId,createdAt', 'senderUid', 'recipientUid']);

class GroupConversation extends CloudDbModel {}
GroupConversation.fieldTypes = Object.freeze({
  id: 'String',
  ownerUid: 'String',
  name: 'String',
  memberCount: 'Integer',
  lastMessageId: 'String',
  lastMessageKind: 'String',
  lastMessagePreview: 'Text',
  lastMessageAt: 'Long',
  createdAt: 'Long',
  updatedAt: 'Long'
});
GroupConversation.primaryKeys = Object.freeze(['id']);
GroupConversation.indexes = Object.freeze(['ownerUid', 'lastMessageAt']);

class GroupMember extends CloudDbModel {}
GroupMember.fieldTypes = Object.freeze({
  id: 'String',
  groupId: 'String',
  memberUid: 'String',
  role: 'String',
  unreadCount: 'Integer',
  joinedAt: 'Long',
  updatedAt: 'Long'
});
GroupMember.primaryKeys = Object.freeze(['id']);
GroupMember.indexes = Object.freeze(['groupId', 'memberUid']);

class GroupMessage extends CloudDbModel {}
GroupMessage.fieldTypes = Object.freeze({
  id: 'String',
  groupId: 'String',
  senderUid: 'String',
  kind: 'String',
  text: 'Text',
  cardId: 'String',
  referenceId: 'String',
  createdAt: 'Long'
});
GroupMessage.primaryKeys = Object.freeze(['id']);
GroupMessage.indexes = Object.freeze(['groupId,createdAt', 'senderUid']);

class NotificationEvent extends CloudDbModel {}
NotificationEvent.fieldTypes = Object.freeze({
  id: 'String', recipientUid: 'String', actorUid: 'String', kind: 'String',
  sourceId: 'String', targetId: 'String', createdAt: 'Long', readAt: 'Long'
});
NotificationEvent.primaryKeys = Object.freeze(['id']);
NotificationEvent.indexes = Object.freeze(['recipientUid', 'recipientUid,createdAt', 'actorUid']);

class PushRegistration extends CloudDbModel {}
PushRegistration.fieldTypes = Object.freeze({
  id: 'String',
  ownerUid: 'String',
  token: 'Text',
  createdAt: 'Long',
  updatedAt: 'Long'
});
PushRegistration.primaryKeys = Object.freeze(['id']);
PushRegistration.indexes = Object.freeze(['ownerUid']);

class WidgetRegistration extends CloudDbModel {}
WidgetRegistration.fieldTypes = Object.freeze({
  id: 'String',
  ownerUid: 'String',
  deviceId: 'String',
  formId: 'String',
  token: 'Text',
  updateVersion: 'Long',
  pushDay: 'String',
  pushCount: 'Integer',
  createdAt: 'Long',
  updatedAt: 'Long'
});
WidgetRegistration.primaryKeys = Object.freeze(['id']);
WidgetRegistration.indexes = Object.freeze(['ownerUid', 'ownerUid,deviceId']);

class IdentityBinding extends CloudDbModel {}
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

class AuthMigrationTicket extends CloudDbModel {}
AuthMigrationTicket.fieldTypes = Object.freeze({
  id: 'String',
  kind: 'String',
  canonicalUid: 'String',
  sourceProviderUid: 'String',
  targetProviderUid: 'String',
  status: 'String',
  createdAt: 'Long',
  expiresAt: 'Long',
  usedAt: 'Long'
});
AuthMigrationTicket.primaryKeys = Object.freeze(['id']);
AuthMigrationTicket.indexes = Object.freeze(['canonicalUid', 'expiresAt']);

class CardReaction extends CloudDbModel {}
CardReaction.fieldTypes = Object.freeze({
  cardId: 'String',
  uid: 'String',
  reaction: 'String',
  createdAt: 'Date',
  updatedAt: 'Date'
});
CardReaction.primaryKeys = Object.freeze(['cardId', 'uid']);
CardReaction.indexes = Object.freeze([
  'cardId,reaction,uid',
  'uid,updatedAt,cardId'
]);

class PublishRequestRecord extends CloudDbModel {}
PublishRequestRecord.fieldTypes = Object.freeze({
  requestId: 'String',
  uid: 'String',
  operationType: 'String',
  payloadHash: 'String',
  resultEntityId: 'String',
  resultJson: 'Text',
  status: 'String',
  createdAt: 'Date',
  expiresAt: 'Date'
});
PublishRequestRecord.primaryKeys = Object.freeze(['requestId']);
PublishRequestRecord.indexes = Object.freeze([
  'uid,createdAt,requestId',
  'status,expiresAt,requestId'
]);

class FoodCardRevision extends CloudDbModel {}
FoodCardRevision.fieldTypes = Object.freeze({
  revisionId: 'String',
  cardId: 'String',
  authorUid: 'String',
  baseModifiedAt: 'Date',
  baseLifecycleGeneration: 'Long',
  requestPayloadHash: 'String',
  payloadJson: 'Text',
  mediaManifestJson: 'Text',
  status: 'String',
  submittedAt: 'Date',
  reviewedAt: 'Date',
  reviewReason: 'String'
});
FoodCardRevision.primaryKeys = Object.freeze(['revisionId']);
FoodCardRevision.indexes = Object.freeze([
  'cardId,status,submittedAt,revisionId',
  'authorUid,submittedAt,revisionId',
  'status,submittedAt,revisionId',
  'cardId,submittedAt,revisionId'
]);

class MaintenanceJob extends CloudDbModel {}
MaintenanceJob.fieldTypes = Object.freeze({"jobId": "String", "jobType": "String", "entityId": "String", "ownerUid": "String", "generation": "Long", "status": "String", "runAfterAt": "Date", "leaseUntilAt": "Date", "leaseOwner": "String", "attemptCount": "Integer", "cursor": "String", "checkpointJson": "Text", "lastErrorCode": "String", "createdAt": "Date", "updatedAt": "Date", "authCredentialCiphertext": "Text", "authProviderUid": "String"});
MaintenanceJob.primaryKeys = Object.freeze(['jobId']);
MaintenanceJob.indexes = Object.freeze(["status,runAfterAt,jobId", "status,leaseUntilAt,jobId", "ownerUid,jobType,jobId", "entityId,jobType,generation", "status,jobType,runAfterAt,jobId", "status,jobType,leaseUntilAt,jobId"]);

// 已退役的偏好 / 清单 / 状态类型仍需保留，用于迁移与注销清理。
class TastePreference extends CloudDbModel {}
TastePreference.fieldTypes = Object.freeze({"uid": "String", "likedCategoriesJson": "Text", "lessCategoriesJson": "Text", "preferredMode": "String", "budgetMinFen": "Long", "budgetMaxFen": "Long", "updatedAt": "Date", "version": "Long"});
TastePreference.primaryKeys = Object.freeze(["uid"]);
TastePreference.indexes = Object.freeze(["uid"]);

class FoodList extends CloudDbModel {}
FoodList.fieldTypes = Object.freeze({"listId": "String", "ownerUid": "String", "name": "String", "coverCardId": "String", "sortOrder": "Long", "createdAt": "Date", "updatedAt": "Date", "version": "Long", "deletedAt": "Date"});
FoodList.primaryKeys = Object.freeze(["listId"]);
FoodList.indexes = Object.freeze(["ownerUid,sortOrder,listId"]);

class FoodListItem extends CloudDbModel {}
FoodListItem.fieldTypes = Object.freeze({"listId": "String", "cardId": "String", "ownerUid": "String", "sortKey": "Long", "createdAt": "Date"});
FoodListItem.primaryKeys = Object.freeze(["listId", "cardId"]);
FoodListItem.indexes = Object.freeze(["listId,sortKey,cardId", "ownerUid,cardId,listId"]);

class PersonalFoodState extends CloudDbModel {}
PersonalFoodState.fieldTypes = Object.freeze({"ownerUid": "String", "cardId": "String", "state": "String", "privateNote": "Text", "eatenAt": "Date", "personalScore": "Integer", "createdAt": "Date", "updatedAt": "Date", "version": "Long"});
PersonalFoodState.primaryKeys = Object.freeze(["ownerUid", "cardId"]);
PersonalFoodState.indexes = Object.freeze(["ownerUid,state,updatedAt,cardId"]);


class MealChoiceHistory extends CloudDbModel {}
MealChoiceHistory.fieldTypes = Object.freeze({ historyId: 'String', uid: 'String', cardId: 'String', merchantId: 'String',
  consumptionMode: 'String', selectedAt: 'Date', source: 'String', roundId: 'String', drawId: 'String', deletedAt: 'Date' });
MealChoiceHistory.primaryKeys = Object.freeze(['historyId']);
MealChoiceHistory.indexes = Object.freeze(['uid,selectedAt,historyId']);

class MealPoll extends CloudDbModel {}
MealPoll.fieldTypes = Object.freeze({"pollId": "String", "groupId": "String", "creatorUid": "String", "title": "String", "mode": "String", "visibilityMode": "String", "consumptionMode": "String", "status": "String", "deadlineAt": "Date", "acceptingOptions": "Boolean", "closeOutcome": "String", "closeReason": "String", "winnerOptionId": "String", "winnerResolvedAt": "Date", "resultCountsJson": "Text", "createdAt": "Date", "updatedAt": "Date", "version": "Long", "requestPayloadHash": "String"});
MealPoll.primaryKeys = Object.freeze(["pollId"]);
MealPoll.indexes = Object.freeze(["groupId,createdAt,pollId", "groupId,status,pollId", "creatorUid"]);

class MealPollOption extends CloudDbModel {}
MealPollOption.fieldTypes = Object.freeze({"pollId": "String", "optionId": "String", "addedByUid": "String", "cardId": "String", "merchantId": "String", "status": "String", "createdAt": "Date"});
MealPollOption.primaryKeys = Object.freeze(["pollId", "optionId"]);
MealPollOption.indexes = Object.freeze(["pollId,optionId", "addedByUid"]);

class MealPollVote extends CloudDbModel {}
MealPollVote.fieldTypes = Object.freeze({"pollId": "String", "voterUid": "String", "optionId": "String", "updatedAt": "Date"});
MealPollVote.primaryKeys = Object.freeze(["pollId", "voterUid"]);
MealPollVote.indexes = Object.freeze(["pollId,optionId,voterUid", "voterUid"]);

class NicknameClaim extends CloudDbModel {}
NicknameClaim.fieldTypes = Object.freeze({ key: 'String', ownerUid: 'String', nickname: 'String', updatedAt: 'Long' });
NicknameClaim.primaryKeys = Object.freeze(['key']);
NicknameClaim.indexes = Object.freeze(['ownerUid']);
class PasswordCredential extends CloudDbModel {}
PasswordCredential.fieldTypes = Object.freeze({ uid: 'String', nicknameKey: 'String', salt: 'String', passwordHash: 'String', generation: 'String', customAgcUid: 'String', createdAt: 'Long', updatedAt: 'Long' });
PasswordCredential.primaryKeys = Object.freeze(['uid']);
PasswordCredential.indexes = Object.freeze([]);
class PasswordThrottle extends CloudDbModel {}
PasswordThrottle.fieldTypes = Object.freeze({ id: 'String', windowAt: 'Long', count: 'Integer' });
PasswordThrottle.primaryKeys = Object.freeze(['id']);
PasswordThrottle.indexes = Object.freeze([]);

const OBJECT_TYPES = Object.freeze({
  NicknameClaim, PasswordCredential, PasswordThrottle, UserProfile, FoodCard, CardMedia, Report, CardAction, CardComment, CommentReaction,
  TastePreference, FoodList, FoodListItem, PersonalFoodState, MealChoiceHistory, MealPoll, MealPollOption, MealPollVote,
  Friendship, FriendReport, Conversation, ChatMessage, GroupConversation, GroupMember, GroupMessage,
  NotificationEvent, PushRegistration, WidgetRegistration,
  IdentityBinding, AuthMigrationTicket,
  CardReaction, PublishRequestRecord, FoodCardRevision, MaintenanceJob, Merchant
});

// 【分区 3：私信加密】读取必需的环境变量，缺失时抛错。
function required(env, name) {
  const value = env[name] || process.env[name];
  if (!value) throw new Error(`云端部署单元缺少环境变量 ${name}`);
  return value;
}

/**
 * 私信内容必须能被受信任的云函数查询，但 Cloud DB 的敏感字段查询时不会返回、也不支持 Text 类型，所以改为在只有 Administrator 能访问的对象中保存“带认证的密文”。密钥只存在于部署配置中，永远不会到达 App 或 Cloud DB。
 */
// 私信加密密钥（SHIKE_MESSAGE_ENCRYPTION_KEY，Base64 的 32 字节）。
function privateTextKey(env) {
  const encoded = String(required(env, 'SHIKE_MESSAGE_ENCRYPTION_KEY')).trim();
  const isBase64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded);
  if (!isBase64) {
    throw new Error('SHIKE_MESSAGE_ENCRYPTION_KEY 必须使用标准 Base64 编码。');
  }
  const key = Buffer.from(encoded, 'base64');
  if (key.length !== PRIVATE_TEXT_KEY_BYTES) {
    throw new Error('SHIKE_MESSAGE_ENCRYPTION_KEY 必须是 32 字节密钥的 Base64 编码。');
  }
  return key;
}

// AES-256-GCM 加密；context 作为附加认证数据，防止把密文挪用到别的消息。
function encryptPrivateText(value, context, env) {
  const plaintext = String(value || '');
  if (!plaintext) return '';
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', privateTextKey(env), iv);
  cipher.setAAD(Buffer.from(String(context || ''), 'utf8'));
  const ciphertext = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return `v1:${iv.toString('base64')}:${tag.toString('base64')}:${ciphertext.toString('base64')}`;
}

// 解密（认证失败时抛错）。
function decryptPrivateText(value, context, env) {
  const encoded = String(value || '');
  if (!encoded) return '';
  try {
    const parts = encoded.split(':');
    if (parts.length !== 4 || parts[0] !== 'v1') throw new Error('unsupported ciphertext');
    const iv = Buffer.from(parts[1], 'base64');
    const tag = Buffer.from(parts[2], 'base64');
    const ciphertext = Buffer.from(parts[3], 'base64');
    if (iv.length !== 12 || tag.length !== 16 || ciphertext.length === 0) {
      throw new Error('invalid ciphertext');
    }
    const decipher = crypto.createDecipheriv('aes-256-gcm', privateTextKey(env), iv);
    decipher.setAAD(Buffer.from(String(context || ''), 'utf8'));
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8');
  } catch (_error) {
    throw new Error('受保护数据校验失败，请联系管理员检查消息加密密钥。');
  }
}

// 【分区 4：Push 与桌面卡片】校验设备标识。
function validPushDeviceId(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

// 校验 Push Token。
function validPushToken(value) {
  return value.length >= 20 && value.length <= 4096 && /^\S+$/.test(value);
}

// Push 登记行的主键。
function pushRegistrationId(uid, deviceId) {
  return crypto.createHash('sha256').update(`push:${uid}:${deviceId}`).digest('hex');
}

// 登记本设备 Push Token（加密保存）。
async function registerPushDevice(uid, payload, env) {
  const deviceId = String(payload.deviceId || '').trim();
  const token = String(payload.token || '').trim();
  if (!validPushDeviceId(deviceId)) throw new Error('通知设备标识格式无效。');
  if (!validPushToken(token)) throw new Error('Push Token 格式无效。');
  const id = pushRegistrationId(uid, deviceId);
  const registrations = collection(env, 'PushRegistration');
  const existing = await one(registrations.query().equalTo('id', id));
  const now = Date.now();
  await registrations.upsert({
    id,
    ownerUid: uid,
    token: encryptPrivateText(token, `push:${id}:token`, env),
    createdAt: existing ? Number(existing.createdAt || now) : now,
    updatedAt: now
  });
  return { success: true };
}

// 删除本设备 Push 登记。
async function unregisterPushDevice(uid, payload, env) {
  const deviceId = String(payload.deviceId || '').trim();
  if (!validPushDeviceId(deviceId)) throw new Error('通知设备标识格式无效。');
  const id = pushRegistrationId(uid, deviceId);
  const registrations = collection(env, 'PushRegistration');
  const row = await one(registrations.query().equalTo('id', id));
  if (row && String(row.ownerUid || '') === uid) await registrations.delete(row);
  return { success: true };
}

// 校验桌面卡片实例 id。
function validServiceCardFormId(value) {
  return /^[1-9][0-9]{0,9}$/.test(value) && Number(value) <= MAX_SERVICE_CARD_FORM_ID;
}

// 解析请求中的卡片实例 id 列表。
function serviceCardFormIds(payload) {
  const raw = Array.isArray(payload.formIds) ? payload.formIds : [];
  if (raw.length > MAX_SERVICE_CARD_FORM_REGISTRATIONS) {
    throw new Error(`桌面卡片实例不能超过 ${MAX_SERVICE_CARD_FORM_REGISTRATIONS} 个。`);
  }
  const ids = [];
  for (const item of raw) {
    const formId = String(item || '').trim();
    if (!validServiceCardFormId(formId)) throw new Error('桌面卡片实例标识格式无效。');
    if (!ids.includes(formId)) ids.push(formId);
  }
  return ids;
}

// 桌面卡片登记行的主键。
function widgetRegistrationId(uid, deviceId, formId) {
  return crypto.createHash('sha256').update(`widget:${uid}:${deviceId}:${formId}`).digest('hex');
}

// 校验非负整数。
function nonNegativeInteger(value) {
  const numeric = Number(value);
  return Number.isInteger(numeric) && numeric >= 0 ? numeric : 0;
}

// 登记本设备的桌面卡片实例（每设备最多 16 张、每账号最多 100 张）。
async function syncServiceCardForms(uid, payload, env) {
  const deviceId = String(payload.deviceId || '').trim();
  const token = String(payload.token || '').trim();
  if (!validPushDeviceId(deviceId)) throw new Error('桌面卡片设备标识格式无效。');
  if (!validPushToken(token)) throw new Error('Push Token 格式无效。');
  const formIds = serviceCardFormIds(payload);
  const registrations = collection(env, 'WidgetRegistration');
  const existingRows = await registrations.query().equalTo('ownerUid', uid)
    .equalTo('deviceId', deviceId).limit(MAX_SERVICE_CARD_FORM_REGISTRATIONS + 1).get();
  const wanted = new Set(formIds);
  const staleRows = existingRows.filter((row) => !wanted.has(String(row.formId || '')));
  // 账号级上限独立于每设备上限；多查一行，如果异常或旧部署已经超过文档规定的最大值，直接拒绝（失败即关闭）。
  const accountRows = await registrations.query().equalTo('ownerUid', uid)
    .limit(MAX_SERVICE_CARD_REGISTRATIONS_PER_ACCOUNT + 1).get();
  const accountRegistrationIds = new Set();
  for (const row of accountRows) accountRegistrationIds.add(String(row.id || ''));
  const staleRegistrationIds = new Set();
  for (const row of staleRows) staleRegistrationIds.add(String(row.id || ''));
  const retainedRegistrationCount = accountRows
    .filter((row) => !staleRegistrationIds.has(String(row.id || ''))).length;
  let newRegistrationCount = 0;
  for (const formId of formIds) {
    if (!accountRegistrationIds.has(widgetRegistrationId(uid, deviceId, formId))) {
      newRegistrationCount += 1;
    }
  }
  if (accountRows.length > MAX_SERVICE_CARD_REGISTRATIONS_PER_ACCOUNT ||
    retainedRegistrationCount + newRegistrationCount > MAX_SERVICE_CARD_REGISTRATIONS_PER_ACCOUNT) {
    throw new Error(`每个账号最多登记 ${MAX_SERVICE_CARD_REGISTRATIONS_PER_ACCOUNT} 张桌面卡片。`);
  }
  if (staleRows.length > 0) await registrations.delete(staleRows);
  const existingById = new Map();
  for (const row of existingRows) existingById.set(String(row.id || ''), row);
  const now = Date.now();
  for (const formId of formIds) {
    const id = widgetRegistrationId(uid, deviceId, formId);
    const existing = existingById.get(id);
    await registrations.upsert({
      id,
      ownerUid: uid,
      deviceId,
      formId,
      token: encryptPrivateText(token, `widget:${id}:token`, env),
      updateVersion: nonNegativeInteger(existing && existing.updateVersion),
      pushDay: existing ? String(existing.pushDay || '') : '',
      pushCount: nonNegativeInteger(existing && existing.pushCount),
      createdAt: existing ? nonNegativeInteger(existing.createdAt) || now : now,
      updatedAt: now
    });
  }
  return { success: true, registeredFormCount: formIds.length };
}

// 删除本设备的桌面卡片登记。
async function unregisterServiceCardForms(uid, payload, env) {
  const deviceId = String(payload.deviceId || '').trim();
  if (!validPushDeviceId(deviceId)) throw new Error('桌面卡片设备标识格式无效。');
  const registrations = collection(env, 'WidgetRegistration');
  const rows = await registrations.query().equalTo('ownerUid', uid)
    .equalTo('deviceId', deviceId).limit(MAX_SERVICE_CARD_FORM_REGISTRATIONS + 1).get();
  if (rows.length > 0) await registrations.delete(rows);
  return { success: true };
}

// Base64URL 编码。
function base64Url(value) {
  return Buffer.from(value).toString('base64url');
}

// 读取 Push Kit 服务账号配置。
function pushConfiguration(env) {
  const source = env || {};
  const projectId = String(source.SHIKE_PUSH_PROJECT_ID || process.env.SHIKE_PUSH_PROJECT_ID || '').trim();
  const subAccount = String(source.SHIKE_PUSH_SUB_ACCOUNT || process.env.SHIKE_PUSH_SUB_ACCOUNT || '').trim();
  const keyId = String(source.SHIKE_PUSH_KEY_ID || process.env.SHIKE_PUSH_KEY_ID || '').trim();
  const privateKeyBase64 = String(
    source.SHIKE_PUSH_PRIVATE_KEY_BASE64 || process.env.SHIKE_PUSH_PRIVATE_KEY_BASE64 || ''
  ).trim();
  return { projectId, subAccount, keyId, privateKeyBase64 };
}

// Push 是否已配置。
function pushConfigured(config) {
  return config.projectId.length > 0 && config.subAccount.length > 0 &&
    config.keyId.length > 0 && config.privateKeyBase64.length > 0;
}

// 生成 Push Kit 服务账号 JWT。
function pushJwt(config) {
  const now = Math.floor(Date.now() / 1000);
  const header = base64Url(JSON.stringify({ kid: config.keyId, typ: 'JWT', alg: 'PS256' }));
  const payload = base64Url(JSON.stringify({
    aud: 'https://oauth-login.cloud.huawei.com/oauth2/v3/token',
    iss: config.subAccount,
    iat: now,
    exp: now + 3600
  }));
  let privateKey = '';
  try {
    const isBase64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(config.privateKeyBase64);
    if (!isBase64) throw new Error('invalid base64');
    privateKey = Buffer.from(config.privateKeyBase64, 'base64').toString('utf8');
  } catch (_error) {
    throw new Error('Push Kit 服务账号私钥不是有效的 Base64 内容。');
  }
  if (!privateKey.includes('PRIVATE KEY')) {
    throw new Error('Push Kit 服务账号私钥格式无效。');
  }
  const signingInput = `${header}.${payload}`;
  const signature = crypto.sign('sha256', Buffer.from(signingInput, 'utf8'), {
    key: privateKey,
    padding: crypto.constants.RSA_PKCS1_PSS_PADDING,
    saltLength: crypto.constants.RSA_PSS_SALTLEN_DIGEST
  });
  return `${signingInput}.${base64Url(signature)}`;
}

// 读取某用户全部设备的 Push Token（解密）。
async function pushTokensFor(uid, env) {
  const profile = await one(collection(env, 'UserProfile').query().equalTo('uid', uid));
  if (!isAccountActive(profile)) return [];
  const rows = await collection(env, 'PushRegistration').query().equalTo('ownerUid', uid).limit(20).get();
  const tokens = [];
  for (const row of rows) {
    const id = String(row.id || '');
    if (!id) continue;
    const token = decryptPrivateText(row.token, `push:${id}:token`, env);
    if (validPushToken(token) && !tokens.includes(token)) tokens.push(token);
  }
  return tokens;
}

// 调用 Push Kit 发送接口（pushType：0 通知消息，1 卡片刷新）；label 用于错误提示。
async function postPushMessage(config, pushType, body, label) {
  const response = await fetch(`https://push-api.cloud.huawei.com/v3/${config.projectId}/messages:send`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${pushJwt(config)}`,
      'push-type': pushType
    },
    body: JSON.stringify(body)
  });
  let result = {};
  try {
    result = JSON.parse(await response.text());
  } catch (_error) {
    throw new Error(`Push Kit ${label}返回了无法解析的响应，HTTP ${response.status}。`);
  }
  if (!response.ok || String(result.code || '') !== '80000000') {
    throw new Error(`Push Kit ${label}失败，HTTP ${response.status}，业务码 ${String(result.code || 'unknown')}。`);
  }
}

// 向某用户发送通知。
async function sendPushToUser(uid, title, body, routeData, env) {
  const config = pushConfiguration(env);
  if (!pushConfigured(config)) return;
  const tokens = await pushTokensFor(uid, env);
  if (tokens.length === 0) return;
  const target = { token: tokens };
  if (uid.length <= 64) target.profileId = uid;
  await postPushMessage(config, '0', {
    payload: { notification: { category: 'IM', title, body, clickAction: { actionType: 0, data: routeData } } },
    target
  }, '通知发送');
}

// 尽力发送通知：失败只记日志，不影响业务结果。
async function bestEffortPush(uid, title, body, routeData, env) {
  try {
    await sendPushToUser(uid, title, body, routeData, env);
  } catch (error) {
    // 通知发送失败绝不能回滚已经完成的好友或消息操作；绝不记录 Token 或请求体。
    console.error(`push notification failed: ${safeLogError(error)}`);
  }
}

const SOCIAL_PUSH_TEXT = Object.freeze({
  FRIEND_REQUEST: { title: '新的好友申请', body: '有人向你发送了食刻好友申请。' },
  FRIEND_ACCEPTED: { title: '好友申请已通过', body: '你们现在可以在食刻互相分享推荐了。' },
  DIRECT_MESSAGE: { title: '新的食刻私信', body: '打开食刻查看好友消息。' },
  GROUP_MESSAGE: { title: '群聊有新消息', body: '打开食刻查看群聊。' },
});
// 发送社交通知（好友申请、私信、群消息）。
async function sendSocialPush(recipientUid, actorUid, kind, targetId, env) {
  const copy=SOCIAL_PUSH_TEXT[kind];
  if(!recipientUid||recipientUid===actorUid||!copy)return;
  try {
    if(!pushConfigured(pushConfiguration(env)))return;
    const policy=contentPolicy(env);
    await policy.assertAccountActive(recipientUid);await policy.assertAccountActive(actorUid);
    const route=kind==='FRIEND_REQUEST'?{shikeRoute:'tab',shikeTab:'2',shikeFriendSection:'requests'}:
      kind==='GROUP_MESSAGE'?{shikeRoute:'group-chat',shikeGroupId:targetId}:
      {shikeRoute:'friend-chat',shikeFriendUid:actorUid};
    await bestEffortPush(recipientUid,copy.title,copy.body,route,env);
  } catch(error) { console.error(`social push failed: ${safeLogError(error)}`); }
}

// 桌面卡片上的分类名称。
function serviceCardCategoryLabel(category) {
  if (category === 'staple') return '米饭';
  if (category === 'bakery') return '汤粉';
  if (category === 'snack') return '炸鸡';
  if (category === 'fresh') return '烧烤';
  if (category === 'drink') return '饮品';
  return '其他';
}

// 桌面卡片远程更新的数据（公开摘要 + 图片身份）。
function serviceCardFormData(card, primaryPhoto = { path: '', bucket: '' }) {
  const mode = String(card.consumptionMode || 'UNSPECIFIED');
  const currentPrice = mode === 'DINE_IN' ? card.dineInAvgFen : card.itemPriceFen;
  const known = currentPrice != null && Number.isSafeInteger(Number(currentPrice)) && Number(currentPrice) >= 0;
  const priceFen = known ? Number(currentPrice) : mode === 'UNSPECIFIED' ? nonNegativeInteger(card.priceFen) : 0;
  const unit = mode === 'DINE_IN' ? ' / 人均' : mode === 'DELIVERY' ? ' / 单品' : known ? ' / 历史单品' : '';
  const labels = { NOODLES: '粉面', RICE_SET: '米饭 / 套餐', HOT_POT: '火锅 / 麻辣烫', GRILL_FRIED: '烧烤 / 炸物',
    SNACK: '小吃', FAST_WESTERN: '快餐 / 西式', BREAKFAST_BAKERY: '早餐 / 烘焙', DESSERT: '甜品', DRINK: '饮品', PACKAGED: '零食 / 包装食品', OTHER: '其他' };
  const tasteScore = Number(card.tasteScore);
  return {
    cardId: String(card.id || ''),
    productName: String(card.productName || '').trim().slice(0, 36) || '附近值得一试',
    scoreText: `${Number.isInteger(tasteScore) ? tasteScore : 0}/10 好味评分`,
    priceText: known || priceFen > 0 ? `¥${(priceFen / 100).toFixed(2)}${unit}` : mode === 'DINE_IN' ? '人均待补充' : '价格待补充',
    locationText: String(card.merchantAddressSnapshot || card.district || '').trim().slice(0, 24) || '未关联店铺',
    categoryText: card.categoryV2 ? labels[card.categoryV2] || '其他' : serviceCardCategoryLabel(String(card.category || '')),
    // 这里只有图片身份：字节保存在 App 的已通过图片缓存中，通过 Form Kit 绑定；远程更新绝不能显示一张不相关的旧封面。
    photoPath: String(primaryPhoto.path || '').trim(),
    photoBucket: String(primaryPhoto.bucket || '').trim()
  };
}

// 推送日（用于每日次数限制）。
function serviceCardPushDay(now) {
  return new Date(now).toISOString().slice(0, 10);
}

// 每个卡片实例每日推送次数上限（1–5，默认 2）。
function serviceCardDailyPushLimit(env) {
  const raw = Number((env && env.SHIKE_SERVICE_CARD_DAILY_PUSH_LIMIT) ||
    process.env.SHIKE_SERVICE_CARD_DAILY_PUSH_LIMIT || DEFAULT_SERVICE_CARD_DAILY_PUSH_LIMIT);
  if (!Number.isInteger(raw)) return DEFAULT_SERVICE_CARD_DAILY_PUSH_LIMIT;
  return Math.max(1, Math.min(5, raw));
}

// 联调用的测试消息开关。
function serviceCardTestMessage(env) {
  const raw = String((env && env.SHIKE_SERVICE_CARD_TEST_MESSAGE) ||
    process.env.SHIKE_SERVICE_CARD_TEST_MESSAGE || '').trim().toLowerCase();
  return raw === 'true';
}

// 下一个卡片数据版本。
function nextServiceCardVersion(row, now) {
  const previous = nonNegativeInteger(row.updateVersion);
  return Math.max(now, previous + 1);
}

// 向一张桌面卡片发送更新。
async function sendServiceCardUpdate(token, formId, version, formData, env) {
  const config = pushConfiguration(env);
  if (!pushConfigured(config)) return false;
  const body = {
    payload: {
      moduleName: 'entry',
      abilityName: 'ServiceCardFormAbility',
      formName: 'ServiceCard',
      formId: Number(formId),
      version,
      formData
    },
    target: { token: [token] }
  };
  if (serviceCardTestMessage(env)) body.pushOptions = { testMessage: true };
  await postPushMessage(config, '1', body, '卡片更新');
  return true;
}

// push-service-card-update：把当前推荐推送到本账号登记的桌面卡片。
async function pushServiceCardUpdate(uid, payload, env) {
  const cardId = String(payload.cardId || '').trim();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(cardId)) {
    throw new Error('公开卡片标识无效。');
  }
  const card = await one(collection(env, 'FoodCard').query().equalTo('id', cardId));
  if (!await contentPolicy(env).isCardPubliclyVisible(card) || !await contentPolicy(env).canReadCard(uid, card)) {
    throw accessError('该卡片不再公开，无法同步到桌面。');
  }
  const registrations = collection(env, 'WidgetRegistration');
  const rows = await registrations.query().equalTo('ownerUid', uid)
    .limit(MAX_SERVICE_CARD_REGISTRATIONS_PER_ACCOUNT).get();
  const activeRows = rows.filter((row) => validServiceCardFormId(String(row.formId || '')));
  const result = {
    success: true,
    registeredFormCount: activeRows.length,
    deliveredFormCount: 0,
    rateLimitedFormCount: 0,
    deliveryAvailable: pushConfigured(pushConfiguration(env))
  };
  if (!result.deliveryAvailable || activeRows.length === 0) return result;
  const now = Date.now();
  const day = serviceCardPushDay(now);
  const dailyLimit = serviceCardDailyPushLimit(env);
  let photos = [];
  try {
    photos = await publicPhotos(card, env, true);
  } catch (_error) {
    // 读取元数据失败可以清掉封面，但不能阻止文字更新。
    console.warn('service-card cover identity was unavailable.');
  }
  const formData = serviceCardFormData(card, photos[0]);
  for (const row of activeRows) {
    const previousCount = String(row.pushDay || '') === day ? nonNegativeInteger(row.pushCount) : 0;
    if (previousCount >= dailyLimit) {
      result.rateLimitedFormCount += 1;
      continue;
    }
    const id = String(row.id || '');
    if (!id) continue;
    let token = '';
    try {
      token = decryptPrivateText(row.token, `widget:${id}:token`, env);
    } catch (error) {
      console.error(`service-card token could not be read: ${safeLogError(error)}`);
      continue;
    }
    if (!validPushToken(token)) continue;
    const version = nextServiceCardVersion(row, now);
    // 在网络请求之前先保存版本号与已尝试发送次数：Push 接口响应丢失时也绝不会产生重复的版本。
    await registrations.upsert({
      id,
      ownerUid: uid,
      deviceId: String(row.deviceId || ''),
      formId: String(row.formId || ''),
      token: row.token,
      updateVersion: version,
      pushDay: day,
      pushCount: previousCount + 1,
      createdAt: nonNegativeInteger(row.createdAt) || now,
      updatedAt: now
    });
    try {
      const delivered = await sendServiceCardUpdate(token, String(row.formId), version, formData, env);
      if (delivered) result.deliveredFormCount += 1;
    } catch (error) {
      // 远程卡片刷新是可选的，不能改变本机已选的推荐；绝不记录其 Token 或请求体。
      console.error(`service-card remote update failed: ${safeLogError(error)}`);
    }
  }
  return result;
}

// 【分区 5：基础设施】脱敏错误日志（去掉 Token、签名、请求体）。
function safeLogError(error) {
  const name = error && error.name ? String(error.name) : 'Error';
  const code = error && error.code !== undefined ? ` code=${String(error.code).slice(0, 32)}` : '';
  const message = error && error.message ? String(error.message) : 'unknown';
  const redacted = message
    .replace(/https?:\/\/\S+/gi, '[url]')
    .replace(/(?:Bearer\s+)?[A-Za-z0-9_\-+/=]{48,}/g, '[credential]')
    .slice(0, 300);
  const checks = ['NOT_BINARY', 'BYTE_BUDGET', 'SIZE_MISMATCH', 'JPEG_MARKERS', 'SHA256_MISMATCH'];
  const integrity = error && checks.includes(error.integrityCheck) ? ` integrityCheck=${error.integrityCheck}` : '';
  return `${name}${code}: ${redacted}${integrity}`;
}

// 取得 Cloud DB 对象类型的集合（存储区 SHIKE_DB_ZONE，默认 shike），并包装读取计量。
function collection(env, name) {
  const zoneName = env.SHIKE_DB_ZONE || process.env.SHIKE_DB_ZONE || 'shike';
  const objectType = OBJECT_TYPES[name];
  if (!objectType) throw new Error(`未知云数据库对象类型 ${name}`);
  const target = cloud.database({ zoneName }).collection(objectType);
  const metrics = readMetricsScope.getStore();
  if (!metrics) return target;
  return new Proxy(target, { get(object, property) {
    if (property === 'query') return (...args) => measuredQuery(object.query(...args), name, metrics);
    // 统计事务调用次数，保持 SDK 事务与回调本身不变。
    if (property === 'runTransaction') return (...args) => measuredDependency('transaction', () => object.runTransaction(...args));
    const value = Reflect.get(object, property, object);
    if (property === 'constructor') return value;
    return typeof value === 'function' ? value.bind(object) : value;
  } });
}

// 给查询包装计量（次数、耗时、行数）。
function measuredQuery(target, name, metrics) {
  const proxy = new Proxy(target, { get(object, property) {
    if (property === 'get') return async (...args) => {
      const started = Date.now();
      metrics.queryGetCount += 1;
      metrics.inFlightQueries += 1;
      metrics.byObject[name] = (metrics.byObject[name] || 0) + 1;
      const phase = readPhaseScope.getStore() || 'cloud-operation';
      metrics.byPhase[phase] = (metrics.byPhase[phase] || 0) + 1;
      try {
        const rows = await object.get(...args);
        metrics.queriedRows += Array.isArray(rows) ? rows.length : 0;
        return rows;
      } catch (error) {
        metrics.queryFailures += 1;
        const code = errorCode(error);
        metrics.byObjectFailures[name] = (metrics.byObjectFailures[name] || 0) + 1;
        metrics.byPhaseFailures[phase] = (metrics.byPhaseFailures[phase] || 0) + 1;
        if (code === '3007009') {
          metrics.busyErrors += 1;
          metrics.byObjectBusy[name] = (metrics.byObjectBusy[name] || 0) + 1;
          metrics.byPhaseBusy[phase] = (metrics.byPhaseBusy[phase] || 0) + 1;
        }
        metrics.lastQueryFailure = { stage: phase, collection: name, code };
        try {
          if (error && typeof error === 'object') {
            if (!error.readStage) error.readStage = phase;
            if (!error.readCollection) error.readCollection = name;
          }
        } catch (_) { }
        throw error;
      } finally { metrics.dbMs += Date.now() - started; metrics.inFlightQueries -= 1; }
    };
    const value = Reflect.get(object, property, object);
    if (property === 'constructor') return value;
    if (typeof value !== 'function') return value;
    return (...args) => {
      const result = value.apply(object, args);
      return result === object ? proxy : result;
    };
  } });
  return proxy;
}

// 计量一次外部依赖调用（Auth、Media、Push 等）。
async function measuredDependency(kind, action) {
  const metrics = readMetricsScope.getStore();
  if (!metrics) return action();
  const counter = metrics.dependencies[kind];
  const started = Date.now();
  counter.calls += 1;
  metrics.inFlightDependencies += 1;
  try {
    const result = await action();
    if (kind === 'transaction' && result === false) counter.notCommitted += 1;
    return result;
  } catch (error) {
    counter.failures += 1;
    throw error;
  } finally { counter.ms += Date.now() - started; metrics.inFlightDependencies -= 1; }
}

// 累加读取计数。
function recordReadCounts(values) {
  const metrics = readMetricsScope.getStore();
  if (!metrics) return;
  for (const key of ['scannedCandidateCount', 'consumedCandidateCount', 'fetchedCandidateCount',
    'eligibleCandidateCount', 'candidatePoolCount', 'sourceReferenceCount']) {
    if (Number.isSafeInteger(values[key]) && values[key] >= 0) metrics.counts[key] = values[key];
  }
}

// 记录功能就绪判断。
function recordReadReadiness(feature, enabled, reason, facts = {}) {
  const metrics = readMetricsScope.getStore();
  if (!metrics || !['search', 'map'].includes(feature)) return;
  const reasons = ['VALIDATION_REQUIRED', 'HISTORY_OR_INDEX_REQUIRED', 'CARD_HISTORY_REQUIRED', 'INDEX_VERIFICATION_REQUIRED', 'COORDINATE_REQUIRED', ''];
  metrics.readiness[feature] = { enabled: enabled === true, reason: reasons.includes(reason) ? reason : 'UNKNOWN' };
  for (const key of ['searchVerified', 'mapVerified', 'cardCoverageComplete', 'reactionCoverageComplete',
    'indexedQueryReady', 'searchQueryReady', 'indexVerified', 'mapCoordinateConfigured', 'mixedCoordinateDetected']) {
    if (typeof facts[key] === 'boolean') metrics.readiness[feature][key] = facts[key];
  }
}

// 为一次操作收集读取指标并在结束时输出一行日志。
async function withReadMetrics(operation, env, action, id, attempt = 1) {
  if (!shouldReadMetrics(env, id)) return action();
  const metrics = { queryGetCount: 0, queriedRows: 0, queryFailures: 0, busyErrors: 0, dbMs: 0, inFlightQueries: 0, inFlightDependencies: 0,
    byObject: {}, byPhase: {}, byObjectFailures: {}, byPhaseFailures: {}, byObjectBusy: {}, byPhaseBusy: {},
    phaseCalls: {}, phaseMs: {}, counts: {}, readiness: {}, lastQueryFailure: null,
    dependencies: { authVerify: { calls: 0, failures: 0, ms: 0 },
      transaction: { calls: 0, failures: 0, notCommitted: 0, ms: 0 }, mediaGateway: { calls: 0, failures: 0, ms: 0 } } };
  return readMetricsScope.run(metrics, async () => {
    const started = Date.now();
    let outcome = 'error';
    let returnedCount = 0, code = '', failureStage = '', failureCollection = '';
    try {
      const result = await withReadPhase('cloud-operation', action);
      outcome = 'success';
      const rows = result && (result.cards || result.candidates || result.items);
      returnedCount = Array.isArray(rows) ? rows.length : 0;
      if (result) recordReadCounts(result);
      return result;
    } catch (error) {
      code = errorCode(error); failureStage = readStage(error);
      const name = error && error.readCollection;
      failureCollection = typeof name === 'string' && Object.prototype.hasOwnProperty.call(OBJECT_TYPES, name) ? name : '';
      throw error;
    }
    finally {
      // 只统计逻辑上的 SDK 调用：事务内部、Storage 字节和 SDK 自身重试都不计入。
      console.info(`read.metrics metricsVersion=o0-20261008-v1 operation=${operation} requestId=${id || 'not-provided'} attempt=${attempt} functionVersion=${READ_OPT_VERSION} outcome=${outcome} code=${code || 'OK'} failureStage=${failureStage || 'none'} failureCollection=${failureCollection || 'none'} returnedCount=${returnedCount} scanned=${metrics.counts.scannedCandidateCount || 0} consumed=${metrics.counts.consumedCandidateCount || 0} fetched=${metrics.counts.fetchedCandidateCount || 0} queryGetCount=${metrics.queryGetCount} ` +
        `queriedRows=${metrics.queriedRows} queryFailures=${metrics.queryFailures} busyErrors=${metrics.busyErrors} ` +
        `dbMs=${metrics.dbMs} totalMs=${Date.now() - started} metricsComplete=${metrics.inFlightQueries === 0 && metrics.inFlightDependencies === 0} pendingQueryGetCount=${metrics.inFlightQueries} pendingDependencyCallCount=${metrics.inFlightDependencies} queryScope=wrapped-query-get dependencyScope=logical-sdk-calls ` +
        `byObject=${JSON.stringify(metrics.byObject)} byPhase=${JSON.stringify(metrics.byPhase)} ` +
        `byObjectFailures=${JSON.stringify(metrics.byObjectFailures)} byPhaseFailures=${JSON.stringify(metrics.byPhaseFailures)} ` +
        `byObjectBusy=${JSON.stringify(metrics.byObjectBusy)} byPhaseBusy=${JSON.stringify(metrics.byPhaseBusy)} ` +
        `phaseCalls=${JSON.stringify(metrics.phaseCalls)} phaseMs=${JSON.stringify(metrics.phaseMs)} ` +
        `counts=${JSON.stringify(metrics.counts)} dependencies=${JSON.stringify(metrics.dependencies)} ` +
        `readiness=${JSON.stringify(metrics.readiness)} lastQueryFailure=${JSON.stringify(metrics.lastQueryFailure)}`);
    }
  });
}

// 取查询结果的第一行。
async function one(query) {
  const rows = await query.limit(1).get();
  return rows.length > 0 ? rows[0] : null;
}

// 【分区 6：卡片读取辅助】按 id 批量读取卡片。
async function readCardRowsByIds(ids, env) {
  const unique = [...new Set(ids.filter(Boolean))];
  const result = new Map();
  for (let start = 0; start < unique.length; start += CARD_READ_BATCH_SIZE) {
    const batch = unique.slice(start, start + CARD_READ_BATCH_SIZE);
    const rows = await collection(env, 'FoodCard').query().in('id', batch).limit(batch.length).get();
    for (const row of rows) result.set(String(row.id), row);
  }
  return result;
}

// 创建内容策略实例（shared/content-policy.js）。
function contentPolicy(env) {
  return createContentPolicy((name) => collection(env, name), one);
}

// 生成单调递增的逻辑写入时间（不早于已有时间）。
function logicalWriteTime(...values) {
  let now = Date.now();
  for (const value of values) {
    if (value == null) continue;
    const previous = Number(value);
    if (!Number.isSafeInteger(previous) || previous < 0 || !Number.isSafeInteger(previous + 1)) {
      throw accessError('服务端版本时间无效。', 'INVALID_STATE');
    }
    now = Math.max(now, previous + 1);
  }
  return now;
}

// 资料行写入前的整理（恢复 Cloud DB 读不到的敏感镜像字段）。
function profileForWrite(row, now) {
  // Cloud DB 读取时可能不返回敏感镜像字段；更新资料时用已有的、非敏感的服务端字段恢复它们。
  const nickname = String(row.nicknameValue || row.nickname || '食刻用户');
  const avatarMediaId = String(row.avatarMediaId || '');
  return Object.assign(new UserProfile(), row, {
    nickname, nicknameValue: nickname,
    avatarUrl: avatarMediaId ? approvedObjectKey(String(row.avatarStorageUid || row.uid), avatarMediaId) : '',
    // 保留已部署的旧列；它已不再控制内容读取。
    contentSequence: 0, updatedAt: now
  });
}

// 事务内读取双方资料（社交操作用）。
async function pairProfiles(transaction, uid, otherUid, env, requireOtherActive = false) {
  const pair = socialPair(uid, otherUid);
  const profiles = [];
  for (const memberUid of [pair.memberAUid, pair.memberBUid]) {
    const rows = await transaction.executeQuery(collection(env, 'UserProfile').query().equalTo('uid', memberUid).limit(1));
    const row = rows[0];
    if (!row || ((memberUid === uid || requireOtherActive) && !isAccountActive(row))) {
      throw accessError('账号不存在、已停用或正在注销。', 'ACCOUNT_INACTIVE');
    }
    profiles.push(row);
  }
  return profiles;
}

// 事务内使用的内容策略（复用已读的资料）。
function transactionPolicy(transaction, env, profiles = []) {
  return createContentPolicy((name) => collection(env, name), async (query) => {
    const rows = await transaction.executeQuery(query.limit(1));
    return rows[0] || null;
  }, { profiles });
}

// 过滤出查看者可读的卡片行。
async function readableCardRows(rows, viewerUid, env, _publicOnly = false, readContext = null) {
  const context = readContext || await createCardReadContext(rows, viewerUid, env);
  return rows.filter(row => readableCardState(row) && isAccountActive(context.profiles.get(String(row.ownerUid))));
}

// 若可读，转换为返回给客户端的卡片。
async function readCardIfAllowed(row, env, distanceKm = 0, includePhoto = true, viewerUid = '',
  includeActions = false, maxPhotoCount = MAX_CARD_PHOTOS, metrics = null, readContext = null) {
  try {
    return await publicCard(row, env, distanceKm, includePhoto, viewerUid, includeActions, maxPhotoCount, metrics, readContext);
  } catch (error) {
    if (error && error.code === 'CONTENT_ACCESS_DENIED') return null;
    throw error;
  }
}

// 偏移量统计的是已消费的数据库行（包括被拒绝的行）。有上限的扫描会越过隐藏内容，预算用完时返回续页。
// 带扫描上限的卡片分页：跳过不可见的行，预算用完时返回续页信息。
async function scanCardPage(queryFactory, viewerUid, env, offset, pageSize, publicOnly = false, photoCount = 1, maxBatchSize = 50) {
  const cards = [];
  const sourceRows = [];
  let cursor = offset;
  let scanned = 0;
  let fetched = 0;
  const finish = async (hasMore) => ({ cards: await finalizeCardReads(cards, sourceRows, viewerUid, env), nextOffset: cursor, hasMore, scannedCandidateCount: scanned, fetchedCandidateCount: fetched });
  while (scanned < 200 && cards.length < pageSize) {
    const limit = Math.min(maxBatchSize, 200 - scanned);
    const rows = await queryFactory().limit(limit, cursor).get();
    fetched += rows.length;
    if (rows.length === 0) return finish(false);
    const readContext = await createCardReadContext(rows, viewerUid, env);
    const readableRows = new Set(await readableCardRows(rows, viewerUid, env, publicOnly, readContext));
    if (photoCount === 1) await preparePrimaryPhotos(readContext, [...readableRows].slice(0, pageSize - cards.length), env);
    for (let index = 0; index < rows.length; index += 1) {
      const row = rows[index];
      cursor += 1;
      scanned += 1;
      if (readableRows.has(row)) {
        const card = await readCardIfAllowed(row, env, 0, true, viewerUid, false, photoCount, null, readContext);
        if (card) { cards.push(card); sourceRows.push(row); }
      }
      if (cards.length === pageSize) {
        return finish(index + 1 < rows.length || rows.length === limit);
      }
    }
    if (rows.length < limit) return finish(false);
  }
  return finish(true);
}

// 卡片中客户端协议需要的字段。
function cardContractFields(row) {
  const output = {
    contentRevision: require('./shared/content-policy').cardContentRevision(row),
    schemaVersion: Number(row.schemaVersion || 0),
    consumptionMode: ['DELIVERY', 'DINE_IN'].includes(row.consumptionMode) ? row.consumptionMode : 'UNSPECIFIED',
    visibility: currentVisibility(row),
    reviewState: String(row.reviewState || 'LEGACY_APPROVED'),
    categoryVersion: Number(row.categoryVersion || 0),
    publishedAt: dateMillis(row.publishedAt) === null ? Number(row.createdAt || 0) : dateMillis(row.publishedAt),
    modifiedAt: dateMillis(row.modifiedAt) === null ? Number(row.updatedAt || row.createdAt || 0) : dateMillis(row.modifiedAt),
    edited: row.edited === true,
    lifecycleGeneration: Number(row.lifecycleGeneration || 0)
  };
  for (const key of ['migrationSource', 'merchantId', 'merchantNameSnapshot', 'merchantAddressSnapshot',
    'categoryV2', 'deliveryPlatformKey', 'deliveryPlatformLabelSnapshot']) {
    if (typeof row[key] === 'string' && row[key]) output[key] = row[key];
  }
  for (const key of ['itemPriceFen', 'dineInAvgFen', 'orderTotalFen', 'deliveryFeeFen', 'queryPriceFen']) {
    if (row[key] != null && Number.isSafeInteger(Number(row[key])) && Number(row[key]) >= 0) output[key] = Number(row[key]);
  }
  if (Number(row.schemaVersion || 0) === 0 && Number(row.priceFen || 0) > 0) {
    output.itemPriceFen = Number(row.priceFen);
    output.queryPriceFen = Number(row.priceFen);
  }
  for (const key of ['consumedAt']) {
    const value = dateMillis(row[key]);
    if (value !== null) output[key] = value;
  }
  return output;
}

// 【分区 7：身份】IdentityBinding 主键：provider + providerUid 的 sha256。
function identityBindingId(provider, providerUid) {
  return crypto.createHash('sha256')
    .update(`shike-identity:${String(provider)}:${String(providerUid)}`)
    .digest('hex');
}

// 读取身份绑定。
async function identityBinding(provider, providerUid, env) {
  return one(collection(env, 'IdentityBinding').query()
    .equalTo('id', identityBindingId(provider, providerUid)));
}

// 确保身份绑定存在（同一认证身份不能绑定到两个业务账号）。
async function ensureIdentityBinding(provider, providerUid, canonicalUid, env) {
  const normalizedProvider = String(provider || '').trim();
  const normalizedProviderUid = String(providerUid || '').trim();
  const normalizedCanonicalUid = String(canonicalUid || '').trim();
  if (!normalizedProvider || !normalizedProviderUid || !normalizedCanonicalUid) {
    throw new Error('身份绑定参数无效。');
  }
  const bindings = collection(env, 'IdentityBinding');
  const id = identityBindingId(normalizedProvider, normalizedProviderUid);
  const existing = await one(bindings.query().equalTo('id', id));
  if (existing && String(existing.canonicalUid || '') !== normalizedCanonicalUid) {
    throw new Error('该认证身份已经绑定到另一个食刻账号。');
  }
  const now = Date.now();
  await bindings.upsert({
    id,
    provider: normalizedProvider,
    providerUid: normalizedProviderUid,
    canonicalUid: normalizedCanonicalUid,
    status: 'ACTIVE',
    createdAt: existing ? Number(existing.createdAt || now) : now,
    updatedAt: now
  });
}

// 校验 AGC Access Token（可选检查是否被撤销），返回 provider UID 与到期时间。
async function verifiedAgcToken(accessToken, checkRevoked = true) {
  if (!accessToken || String(accessToken).length > 8192) {
    throw accessError('未登录或登录状态已失效。', 'AUTH_REQUIRED');
  }
  try {
    const verified = await measuredDependency('authVerify', () => cloud.auth().verifyAccessToken({
      accessToken: String(accessToken),
      checkRevoked
    }));
    const uid = String(verified.getSub() || '');
    if (!uid) throw new Error('AGC 访问凭证未包含用户标识。');
    let expiresAt = 0;
    try {
      const exp = typeof verified.getExp === 'function' ? Number(verified.getExp()) : 0;
      if (Number.isFinite(exp) && exp > 0) expiresAt = exp * 1000;
    } catch (_) { expiresAt = 0; }
    return { uid, expiresAt };
  } catch (_error) {
    // 这里刻意不接受 Account Kit（华为账号）的 Access Token，只接受 AGC Token。
    throw accessError('登录凭证无效或已撤销，请重新登录。', 'AUTH_REQUIRED');
  }
}

// 校验 Token 并只返回 provider UID。
async function verifiedAgcUid(accessToken) {
  const verified = await verifiedAgcToken(accessToken, true);
  return verified.uid;
}

// 校验 Token → 查 IdentityBinding → 得到业务 canonical UID，并确认账号有效（只读操作可使用 90 秒身份缓存）。
async function verifiedIdentity(accessToken, env, readOnly = false) {
  // 只读操作在本实例内最多复用已验证身份 90 秒（且不超过 Token 到期时间）：省去 Token 校验、IdentityBinding 与 UserProfile 的读取。写操作与账号操作始终完整校验（包括撤销检查）。
  const cacheable = readOnly && identityCacheable() && !!accessToken;
  const cacheKey = cacheable ? identityCacheKey(accessToken) : '';
  if (cacheKey) {
    const hit = cachedIdentity(cacheKey);
    if (hit) { recordCacheCount('identityCacheHit'); return { providerUid: hit.providerUid, canonicalUid: hit.canonicalUid }; }
  }
  return withReadPhase('authentication', async () => {
    const verified = await verifiedAgcToken(accessToken, !cacheable);
    const providerUid = verified.uid;
    const binding = await identityBinding('AGC', providerUid, env);
    if (binding && String(binding.status || 'ACTIVE') !== 'ACTIVE') throw accessError('账号身份已停用。', 'ACCOUNT_INACTIVE');
    if (binding && !String(binding.canonicalUid || '').trim()) throw accessError('账号身份绑定无效。', 'INVALID_STATE');
    const canonicalUid = binding ? String(binding.canonicalUid || providerUid) : providerUid;
    const profile = await contentPolicy(env).assertAccountActive(canonicalUid, true);
    const scope = cardReadScope.getStore();
    if (scope && readOnly) {
      let seeds = scope.get('verified-profiles');
      if (!seeds) { seeds = new Map(); scope.set('verified-profiles', seeds); }
      seeds.set(canonicalUid, profile);
    }
    // 上面的绑定已经校验过；普通写操作不能每次点击都重新查询并重写一个没有变化的身份绑定。
    if (!readOnly && !binding) await ensureIdentityBinding('AGC', providerUid, canonicalUid, env);
    if (cacheKey) {
      recordCacheCount('identityCacheMiss');
      // 能走到这里的一定是有效账号（上面已 assertAccountActive）。
      rememberIdentity(cacheKey, providerUid, canonicalUid, verified.expiresAt);
    }
    if (IDENTITY_STATE_OPERATIONS.has(operationScope.getStore() || '')) forgetIdentity(canonicalUid);
    return { providerUid, canonicalUid };
  });
}

// 最常用的入口：返回业务 UID。
async function verifiedUid(accessToken, env, readOnly = false) {
  const identity = await verifiedIdentity(accessToken, env, readOnly);
  return identity.canonicalUid;
}

// Base64URL 解码。
function fromBase64Url(value) {
  const encoded = String(value || '').replace(/-/g, '+').replace(/_/g, '/');
  const padding = '='.repeat((4 - encoded.length % 4) % 4);
  return Buffer.from(encoded + padding, 'base64');
}

// 迁移票据密钥（SHIKE_IDENTITY_TICKET_KEY，与 shike-auth 相同）。
function identityTicketKey(env) {
  return crypto.createHash('sha256').update(required(env, 'SHIKE_IDENTITY_TICKET_KEY')).digest();
}

// 解密并校验迁移票据（10 分钟有效）。
function decryptIdentityTicket(ticket, env) {
  const parts = String(ticket || '').split('.');
  if (parts.length !== 4 || parts[0] !== 'v1') {
    throw new Error('迁移凭证无效或已过期。');
  }
  try {
    const iv = fromBase64Url(parts[1]);
    const ciphertext = fromBase64Url(parts[2]);
    const tag = fromBase64Url(parts[3]);
    if (iv.length !== 12 || tag.length !== 16 || ciphertext.length === 0) {
      throw new Error('invalid ticket');
    }
    const decipher = crypto.createDecipheriv('aes-256-gcm', identityTicketKey(env), iv);
    decipher.setAuthTag(tag);
    const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8');
    const decoded = JSON.parse(plaintext);
    const now = Math.floor(Date.now() / 1000);
    if (!decoded || Number(decoded.version) !== 1 || !decoded.kind || !decoded.ticketId ||
      !Number.isFinite(Number(decoded.expiresAt)) || Number(decoded.expiresAt) <= now) {
      throw new Error('invalid ticket payload');
    }
    return decoded;
  } catch (_error) {
    throw new Error('迁移凭证无效或已过期。');
  }
}

// 加密生成票据。
function sealIdentityTicket(payload, env) {
  const now = Math.floor(Date.now() / 1000);
  const body = {
    version: 1,
    ...payload,
    issuedAt: now,
    expiresAt: now + 600,
    ticketId: crypto.randomUUID()
  };
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', identityTicketKey(env), iv);
  const ciphertext = Buffer.concat([
    cipher.update(JSON.stringify(body), 'utf8'),
    cipher.final()
  ]);
  return `v1.${iv.toString('base64url')}.${ciphertext.toString('base64url')}.${cipher.getAuthTag().toString('base64url')}`;
}

// 确认票据未被使用过（一次性）。
async function assertMigrationTicketAvailable(ticket, kind, env) {
  if (String(ticket.kind || '') !== kind) throw new Error('迁移凭证用途不匹配。');
  const existing = await one(collection(env, 'AuthMigrationTicket').query()
    .equalTo('id', String(ticket.ticketId)));
  if (existing) throw new Error('迁移凭证已使用或正在处理。');
}

// 记录票据已被使用。
async function recordMigrationTicket(ticket, kind, sourceProviderUid, targetProviderUid, canonicalUid, env) {
  const issuedAtSeconds = Number(ticket.issuedAt);
  const expiresAtSeconds = Number(ticket.expiresAt);
  await collection(env, 'AuthMigrationTicket').insert({
    id: String(ticket.ticketId),
    kind,
    canonicalUid: String(canonicalUid),
    sourceProviderUid: String(sourceProviderUid || ''),
    targetProviderUid: String(targetProviderUid || ''),
    status: 'CONSUMED',
    createdAt: Number.isFinite(issuedAtSeconds) ? issuedAtSeconds * 1000 : Date.now(),
    expiresAt: Number.isFinite(expiresAtSeconds) ? expiresAtSeconds * 1000 : Date.now(),
    usedAt: Date.now()
  });
}

// complete-legacy-login：华为兼容登录的最后一步，用票据把华为身份绑定到业务账号。
async function completeLegacyLogin(accessToken, payload, env) {
  const agcUid = await verifiedAgcUid(accessToken);
  const ticket = decryptIdentityTicket(payload.ticket, env);
  if (String(ticket.kind) !== 'LEGACY_LOGIN' || String(ticket.agcUid) !== agcUid || !ticket.legacyUid) {
    throw new Error('兼容账号迁移凭证与当前用户不匹配。');
  }
  await assertMigrationTicketAvailable(ticket, 'LEGACY_LOGIN', env);
  const legacyUid = String(ticket.legacyUid);
  const existingLegacy = await identityBinding('HUAWEI_ACCOUNT', legacyUid, env);
  const oldProfile = await one(collection(env, 'UserProfile').query().equalTo('uid', legacyUid));
  const canonicalUid = existingLegacy && existingLegacy.canonicalUid
    ? String(existingLegacy.canonicalUid)
    : oldProfile ? legacyUid : agcUid;
  const existingAgc = await identityBinding('AGC', agcUid, env);
  if (existingAgc && String(existingAgc.canonicalUid || '') !== canonicalUid) {
    throw new Error('当前 AGC 认证身份已经属于另一个食刻账号，不能自动合并。');
  }
  if (payload.registerOnly === true) {
    const profile = await one(collection(env, 'UserProfile').query().equalTo('uid', canonicalUid));
    if (profile) throw accessError('该华为账号已有食刻账号，请返回登录。', 'ACCOUNT_ALREADY_EXISTS');
  }
  await ensureIdentityBinding('HUAWEI_ACCOUNT', legacyUid, canonicalUid, env);
  await ensureIdentityBinding('AGC', agcUid, canonicalUid, env);
  await recordMigrationTicket(ticket, 'LEGACY_LOGIN', legacyUid, agcUid, canonicalUid, env);
  return { success: true };
}

// start-email-binding：为当前华为账号签发邮箱绑定票据。
async function startEmailBinding(accessToken, env) {
  const agcUid = await verifiedAgcUid(accessToken);
  const canonicalUid = await verifiedUid(accessToken, env);
  return {
    success: true,
    ticket: sealIdentityTicket({
      kind: 'EMAIL_BINDING',
      canonicalUid,
      sourceAgcUid: agcUid
    }, env),
    expiresAt: Date.now() + 600000
  };
}

// complete-email-binding：用票据把新建的邮箱身份绑定到当前账号。
async function completeEmailBinding(accessToken, payload, env) {
  const agcUid = await verifiedAgcUid(accessToken);
  const ticket = decryptIdentityTicket(payload.ticket, env);
  if (String(ticket.kind) !== 'EMAIL_BINDING' || !ticket.canonicalUid) {
    throw new Error('邮箱绑定凭证无效。');
  }
  if (String(ticket.sourceAgcUid || '') === agcUid) {
    throw new Error('不能把当前认证身份重复绑定为邮箱身份。');
  }
  await assertMigrationTicketAvailable(ticket, 'EMAIL_BINDING', env);
  const existing = await identityBinding('AGC', agcUid, env);
  if (existing && String(existing.canonicalUid || '') !== String(ticket.canonicalUid)) {
    throw new Error('该邮箱已经绑定到另一个食刻账号，不能自动合并。');
  }
  await ensureIdentityBinding('AGC', agcUid, String(ticket.canonicalUid), env);
  await recordMigrationTicket(ticket, 'EMAIL_BINDING', String(ticket.sourceAgcUid || ''), agcUid,
    String(ticket.canonicalUid), env);
  return { success: true };
}

// 【分区 8：工具】把值转为数组。
function safeArray(value) {
  if (Array.isArray(value)) return value.map((item) => String(item)).slice(0, 8);
  if (typeof value !== 'string' || value.length === 0) return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.map((item) => String(item)) : [];
  } catch (_error) {
    return [];
  }
}

// 历史发布位置取整（只用于旧数据，新发布不再记录坐标）。
function roundedLocation(payload) {
  const latE3 = Number(payload.latE3);
  const lonE3 = Number(payload.lonE3);
  if (!Number.isInteger(latE3) || !Number.isInteger(lonE3) ||
    latE3 < -90000 || latE3 > 90000 || lonE3 < -180000 || lonE3 > 180000) {
    throw new Error('位置参数必须是三位小数舍入后的整数坐标。');
  }
  return { latE3, lonE3 };
}

// 计算 geohash。
function geohash(latitude, longitude, precision = 6) {
  const alphabet = '0123456789bcdefghjkmnpqrstuvwxyz';
  let lat = [-90, 90];
  let lon = [-180, 180];
  let output = '';
  let bit = 0;
  let value = 0;
  let even = true;
  while (output.length < precision) {
    const range = even ? lon : lat;
    const point = even ? longitude : latitude;
    const middle = (range[0] + range[1]) / 2;
    if (point >= middle) {
      value = (value << 1) + 1;
      range[0] = middle;
    } else {
      value <<= 1;
      range[1] = middle;
    }
    even = !even;
    bit += 1;
    if (bit === 5) {
      output += alphabet[value];
      bit = 0;
      value = 0;
    }
  }
  return output;
}

/**
 * 【分区 9：调用 shike-media】shike-service 负责业务授权与 Cloud DB 状态，shike-media 负责所有 Cloud Storage SDK 调用。请求体带 HMAC 签名（SHIKE_MEDIA_INTERNAL_KEY，60 秒有效），防止调用方把媒体云对象当作通用存储代理——尽管两个云对象都经同一个 AGC 网关访问。
 */
async function callMedia(action, payload, env) {
  return measuredDependency('mediaGateway', async () => {
  const body = JSON.stringify({ action, issuedAt: Date.now(), nonce: crypto.randomUUID(), payload });
  const signature = crypto.createHmac('sha256', required(env, 'SHIKE_MEDIA_INTERNAL_KEY')).update(body).digest('hex');
  const result = await cloud.function().call({
    name: 'shike-media',
    data: { method: 'execute', params: [{ body, signature, readRequestId: readRequestScope.getStore() }] }
  });
  let value = result && typeof result.getValue === 'function' ? result.getValue() : result;
  if (value && typeof value === 'object' && Object.prototype.hasOwnProperty.call(value, 'result')) value = value.result;
  if (typeof value === 'string') {
    try { value = JSON.parse(value); } catch (_error) { throw new Error('媒体服务返回格式无效。'); }
  }
  if (!value || typeof value !== 'object' || value.ok !== true || !value.data || typeof value.data !== 'object') {
    const message = value && typeof value === 'object' && typeof value.message === 'string'
      ? value.message : '媒体服务请求失败。';
    const failure = new Error(message);
    failure.code = value && typeof value.code === 'string' && value.code.length > 0
      ? value.code : 'MEDIA_RESPONSE_INVALID';
    throw failure;
  }
  return value.data;
  });
}

/**
 * 对象路径由 Cloud DB 中的非敏感字段推导，因为 AGC Cloud DB 对敏感字段会刻意返回空值。客户端只能上传到服务端授权的 public/approved 路径；云函数在通过 Cloud DB 公开某张卡片或头像之前，仍会确认对应对象确实存在。
 */
// 对象路径：{prefix}/{ownerUid}/{mediaId}.jpg。
function mediaObjectKey(prefix, ownerUid, mediaId) {
  const uid = String(ownerUid || '');
  const id = String(mediaId || '');
  if (!uid || uid.includes('/') || uid.includes('\\') ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
    throw new Error('实拍图记录无效，请重新选择。');
  }
  return `${prefix}/${uid}/${id}.jpg`;
}

// 暂存区路径 private/pending/...。
function pendingObjectKey(ownerUid, mediaId) {
  return mediaObjectKey('private/pending', ownerUid, mediaId);
}

// 公开路径 public/approved/...。
function approvedObjectKey(ownerUid, mediaId) {
  return mediaObjectKey('public/approved', ownerUid, mediaId);
}

// 某图片记录的公开路径。
function approvedObjectKeyForMedia(media) {
  return approvedObjectKey(media && (media.storageUid || media.ownerUid), media && media.id);
}

// 从公开路径中解析 mediaId。
function mediaIdFromApprovedObjectKey(objectKey) {
  const match = /^public\/approved\/[^/]+\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jpg$/i
    .exec(String(objectKey || ''));
  return match ? match[1] : '';
}

/**
 * 已通过的图片通过 App 签名鉴权的云对象读取：它校验数据库记录后把字节写入 App 私有缓存。对象本身从不以 Storage 直链形式暴露，读取权限与设备本地的登录实现无关。get-public-media：游客读取公开图片。
 */


// get-public-media：游客读取公开图片（按公开模式校验权限）。
async function getPublicMedia(_uid, payload, env) {
  if (String(payload.bucketName || '').trim() !== required(env, 'SHIKE_STORAGE_BUCKET')) throw new Error('图片所属存储实例无效。');
  const key = String(payload.cloudPath || ''), mediaId = mediaIdFromApprovedObjectKey(key);
  if (!mediaId) throw new Error('图片路径无效。');
  return require('./shared/image-reader').readLegacy({ ...payload, key, mediaId, mode: 'PUBLIC', viewerUid: '' }, env);
}
// get-revision-media：读取修订中的图片（仅作者）。
async function getRevisionMedia(uid, payload, env) {
  return require('./shared/image-reader').readLegacy({ ...payload, viewerUid: uid, mode: 'REVISION', variant: 'ORIGINAL' }, env);
}

// 旧数据兼容：把暂存区的图片提升为公开图片（委托 shike-media）。
async function promotePendingMedia(media, env) {
  const storageUid = String(media && (media.storageUid || media.ownerUid) || '').trim();
  const pendingKey = pendingObjectKey(storageUid, media && media.id);
  const approvedKey = approvedObjectKey(storageUid, media && media.id);
  await callMedia('promote', { pendingKey, approvedKey }, env);
  media.status = 'APPROVED';
  return approvedKey;
}

// 【分区 10：用户资料】规范化昵称。
function normalizedNickname(value) {
  const nickname = String(value || '').trim();
  if (nickname.length === 0 || nickname.length > 24) {
    throw new Error('昵称需为 1–24 个字符。');
  }
  return nickname;
}

// 由 UID 生成食刻号。
function friendCodeForUid(uid) {
  const digest = crypto.createHash('sha256').update(`shike-friend:${String(uid || '')}`).digest('hex')
    .slice(0, 12).toUpperCase();
  return `SK-${digest.slice(0, 4)}-${digest.slice(4, 8)}-${digest.slice(8, 12)}`;
}

// 资料图片（头像 / 主页背景）的公开路径；没有图片或记录格式无效时返回空串。
function profileMediaPath(record, mediaField, storageField) {
  const mediaId = String(record[mediaField] || '');
  if (!mediaId) return '';
  try {
    return approvedObjectKey(String(record[storageField] || record.uid || ''), mediaId);
  } catch (_error) {
    return '';
  }
}

// 资料的返回视图。
function profileResponse(record, env) {
  const avatarPath = profileMediaPath(record, 'avatarMediaId', 'avatarStorageUid');
  const coverPath = profileMediaPath(record, 'coverMediaId', 'coverStorageUid');
  return {
    uid: String(record.uid || ''),
    nickname: String(record.nicknameValue || record.nickname || '食刻用户'),
    avatarUrl: '',
    avatarPath,
    avatarBucket: avatarPath ? required(env, 'SHIKE_STORAGE_BUCKET') : '',
    coverPath,
    coverBucket: coverPath ? required(env, 'SHIKE_STORAGE_BUCKET') : '',
    friendCode: String(record.friendCode || friendCodeForUid(record.uid)),
    accountStatus: String(record.accountStatus || 'ACTIVE'),
    publishCount: Number(record.publishCount || 0),
    createdAt: Number(record.createdAt || 0),
    updatedAt: Number(record.updatedAt || 0)
  };
}

// 把调用者本人上传的图片绑定为资料图片（mediaCardId 为 profile:uid 或 profile-cover:uid）：校验归属、提升暂存上传、写入关联。
// 返回图片所在的存储 UID。旧的资料图片保留到注销清理时；昵称冲突或并发保存绝不能删除当前仍被引用的图片。
async function claimProfileMedia(uid, mediaId, mediaCardId, label, env) {
  const mediaStore = collection(env, 'CardMedia');
  const media = await one(mediaStore.query().equalTo('id', mediaId));
  if (!media || media.ownerUid !== uid || (media.cardId && media.cardId !== mediaCardId)) {
    throw new Error(`${label}图片不存在、不属于当前用户或已用于其他${label === '头像' ? '卡片' : '内容'}。`);
  }
  const mediaStorageUid = String(media.storageUid || uid).trim();
  if (String(media.status || '') === 'PENDING_UPLOAD') {
    await promotePendingMedia(media, env);
  } else if (String(media.status || '') !== 'APPROVED') {
    throw new Error(`${label}图片状态无效，请重新选择。`);
  }
  if (media.cardId !== mediaCardId) {
    media.cardId = mediaCardId;
    await mediaStore.upsert(media);
  }
  return mediaStorageUid;
}

// upsert-profile：读取或更新资料（readOnly=true 时只读取；首次登录时创建资料）。
async function upsertProfile(uid, payload, env, trustedProfile = false) {
  const users = collection(env, 'UserProfile');
  const existing = await one(users.query().equalTo('uid', uid));
  if (existing && !isAccountActive(existing)) throw accessError('账号已停用或正在注销。', 'ACCOUNT_INACTIVE');
  if (!trustedProfile && payload && payload.readOnly === true) {
    if (existing) return profileResponse(existing, env);
    // AGC Auth 已经校验过调用者的 UID；首次登录时创建食刻资料，不保存邮箱或认证方信息。
    return upsertProfile(uid, { nickname: '食刻用户' }, env, true);
  }
  if (String(env.SHIKE_NICKNAME_MIGRATING || '') === 'true') throw accessError('账号资料正在维护，请稍后重试。', 'FEATURE_NOT_READY');
  if (nicknameAuth.enabled(env)) await nicknameAuth.ready(env);
  const ownedCards = await queryAllRows(() => collection(env, 'FoodCard').query().equalTo('ownerUid', uid));
  const publishCount = ownedCards.filter(readableCardState).length;
  const now = Date.now();
  let nickname = String((existing && existing.nicknameValue) || '').trim();
  let avatarMediaId = String((existing && existing.avatarMediaId) || '').trim();
  let avatarStorageUid = String((existing && existing.avatarStorageUid) || uid).trim();
  let coverMediaId = String((existing && existing.coverMediaId) || '').trim();
  let coverStorageUid = String((existing && existing.coverStorageUid) || uid).trim();

  if (trustedProfile) {
    // 登录不申请账号资料权限；资料一旦存在就保留 App 自己的值，不被之后的登录响应覆盖。
    if (!nickname) {
      const trustedValue = String((payload && payload.nickname) || '').trim();
      nickname = nicknameAuth.enabled(env) ? '食刻' + crypto.createHash('sha256').update(uid).digest('hex').slice(0, 22)
        : trustedValue.length > 0 ? trustedValue.slice(0, 24) : '食刻用户';
    }
  } else {
    nickname = normalizedNickname(payload && payload.nickname);
    const requestedMediaId = String((payload && payload.avatarMediaId) || '').trim();
    if (requestedMediaId.length > 0) {
      avatarStorageUid = await claimProfileMedia(uid, requestedMediaId, `profile:${uid}`, '头像', env);
      avatarMediaId = requestedMediaId;
    }
    const requestedCoverMediaId = String((payload && payload.coverMediaId) || '').trim();
    if (payload && payload.clearCover === true) {
      // 旧的资料图片保留到注销清理时。
      coverMediaId = '';
      coverStorageUid = '';
    } else if (requestedCoverMediaId.length > 0) {
      coverStorageUid = await claimProfileMedia(uid, requestedCoverMediaId, `profile-cover:${uid}`, '主页背景', env);
      coverMediaId = requestedCoverMediaId;
    }
  }

  const record = {
    uid,
    // 这些敏感镜像字段为兼容现有 Cloud DB 结构而保留；对应的非敏感字段只有云函数能读取，因为 App 用户的直连权限已全部关闭。
    nickname,
    avatarUrl: avatarMediaId ? approvedObjectKey(avatarStorageUid || uid, avatarMediaId) : '',
    nicknameValue: nickname,
    avatarMediaId,
    avatarStorageUid: avatarMediaId ? avatarStorageUid : '',
    coverMediaId,
    coverStorageUid: coverMediaId ? coverStorageUid : '',
    friendCode: friendCodeForUid(uid),
    accountStatus: existing ? String(existing.accountStatus || 'ACTIVE') : 'ACTIVE',
    contentSequence: 0,
    publishCount,
    createdAt: existing ? Number(existing.createdAt || now) : now,
    updatedAt: now
  };
  let saved = null;
  const committed = await users.runTransaction({
    apply: async (transaction) => {
      const rows = await transaction.executeQuery(users.query().equalTo('uid', uid).limit(1));
      const current = rows[0];
      if (current && !isAccountActive(current)) throw accessError('账号已停用或正在注销。', 'ACCOUNT_INACTIVE');
      const writeAt = logicalWriteTime(current && current.updatedAt);
      saved = trustedProfile && current ? profileForWrite(current, writeAt) : Object.assign(new UserProfile(), record, {
        accountStatus: current ? String(current.accountStatus || 'ACTIVE') : 'ACTIVE',
        contentSequence: 0, createdAt: current ? Number(current.createdAt || writeAt) : writeAt,
        updatedAt: writeAt
      });
      saved.publishCount = publishCount;
      if (!trustedProfile && current) {
        if (!String(payload && payload.avatarMediaId || '').trim()) {
          saved.avatarMediaId = current.avatarMediaId;
          saved.avatarStorageUid = current.avatarStorageUid;
          saved.avatarUrl = saved.avatarMediaId ? approvedObjectKey(String(saved.avatarStorageUid || uid), String(saved.avatarMediaId)) : '';
        }
        if (!(payload && payload.clearCover === true) && !String(payload && payload.coverMediaId || '').trim()) {
          saved.coverMediaId = current.coverMediaId;
          saved.coverStorageUid = current.coverStorageUid;
        }
      }
      await nicknameAuth.rename(transaction, env, current, saved);
      transaction.executeUpsert([saved]);
      return true;
    }
  });
  if (!committed || !saved) throw new Error('用户资料保存未完成，请重试。');
  return profileResponse(saved, env);
}

// 重新统计作者的发布数。
async function refreshPublishCount(uid, env) {
  try {
    await upsertProfile(uid, {}, env, true);
  } catch (error) {
    // 卡片变更已经提交；不要把它报告为失败，否则会诱发重复发布或重复删除，而这里只是一个派生的发布数。
    console.error(`publish count refresh failed: ${safeLogError(error)}`);
  }
}

// 【分区 11：发布】校验 HTTPS 链接。
function validHttpsUrl(value) {
  try {
    const parsed = new URL(String(value || '').trim());
    if (parsed.protocol !== 'https:' || !parsed.hostname || parsed.username || parsed.password) return '';
    if (String(value || '').trim().length > 2048) return '';
    return parsed.toString();
  } catch (_error) {
    return '';
  }
}

// 校验卡片内容（名称、点评 ≤600 字、评分 1–10、来源链接等）。
function validateCard(payload) {
  const productName = String(payload.productName || '').trim();
  if (productName.length < 2 || productName.length > 100) throw new Error('商品名长度应为 2–100 个字符。');
  const sourceLinkInput = String(payload.sourceLink || '').trim();
  const sourceLink = sourceLinkInput.length === 0 ? '' : validHttpsUrl(sourceLinkInput);
  if (sourceLinkInput.length > 0 && !sourceLink) {
    throw new Error('相关链接必须是有效且不含内嵌账号信息的 HTTPS 地址。');
  }
  if (!VALID_CATEGORY.has(payload.category)) throw new Error('商品分类无效。');
  if (PERSONALIZED.test(String(payload.priceLabel || ''))) throw new Error('个性化优惠不能作为公开商品价。');
  const priceFen = Number(payload.priceFen || 0);
  const originalPriceFen = Number(payload.originalPriceFen || 0);
  if (!Number.isInteger(priceFen) || priceFen < 0 || priceFen > 100000000) throw new Error('商品价格无效。');
  if (!Number.isInteger(originalPriceFen) || originalPriceFen < 0 || originalPriceFen > 100000000) {
    throw new Error('原价无效。');
  }
  const reviewText = String(payload.reviewText || '').trim();
  if (reviewText.length > MAX_CARD_REVIEW_LENGTH) {
    throw new Error('点评最多 ' + MAX_CARD_REVIEW_LENGTH + ' 个字符。');
  }
  const tasteScore = Number(payload.tasteScore);
  if (!Number.isInteger(tasteScore) || tasteScore < 1 || tasteScore > 10) {
    throw new Error('口味评分必须为 1–10 分。');
  }
  return { productName, sourceLink, reviewText, tasteScore };
}

// publish-card：发布卡片（幂等回执 → 字段规范化 → 校验图片 → 一个事务写入卡片、图片关联、店铺计数、资料与回执）。
async function publishCard(uid, payload, env) {
  const receiptSpec = stage1.publishReceiptSpec(uid, payload);
  const replay = await stage1.readPublishReceipt(uid, receiptSpec, env);
  if (replay) return replay;
  const modern = payload.consumptionMode !== undefined;
  const normalized = await stage2.cardFields(payload, uid, env, undefined, !modern);
  const validated = validateCard({ ...payload, ...normalized });
  const point = modern ? { latE3: 0, lonE3: 0 } : roundedLocation(payload);
  const mediaIds = uniqueMediaIds(payload);
  const medias = [];
  for (const mediaId of mediaIds) {
    const media = await one(collection(env, 'CardMedia').query().equalTo('id', mediaId));
    if (!media || media.ownerUid !== uid || media.cardId) {
      const retry = await stage1.readPublishReceipt(uid, receiptSpec, env);
      if (retry) return retry;
      throw new Error('实拍图不存在、不属于当前用户或已被使用。');
    }
    // 创建公开卡片前确认每张图片属于调用者且已上传；兼容分支还会把已上传的旧暂存区对象提升为公开对象。
    await promotePendingMedia(media, env);
    medias.push(media);
  }
  const now = Date.now();
  let cardId = crypto.randomUUID();
  const record = {
    id: cardId,
    ownerUid: uid,
    productName: validated.productName,
    brand: String(payload.brand || '').slice(0, 80),
    priceFen: Number(payload.priceFen || 0),
    priceLabel: String(payload.priceLabel || '').slice(0, 30),
    originalPriceFen: Number(payload.originalPriceFen || 0),
    specification: String(payload.specification || '').slice(0, 100),
    shop: String(payload.shop || '').slice(0, 100),
    sellingPointsJson: JSON.stringify(safeArray(payload.sellingPoints).slice(0, 3)),
    publicOffersJson: JSON.stringify(safeArray(payload.publicOffers).filter((item) => !PERSONALIZED.test(item)).slice(0, 4)),
    reviewText: validated.reviewText,
    tasteScore: validated.tasteScore,
    sourceLink: validated.sourceLink,
    category: payload.category,
    mediaId: medias.length > 0 ? medias[0].id : '',
    latE3: point.latE3,
    lonE3: point.lonE3,
    district: modern ? '' : String(payload.district || '历史发布位置').slice(0, 80),
    geohash: modern ? '' : geohash(point.latE3 / 1000, point.lonE3 / 1000),
    status: 'APPROVED',
    schemaVersion: 2, migrationSource: 'SERVER', consumptionMode: 'UNSPECIFIED', visibility: 'PUBLIC',
    reviewState: 'PENDING_POST_REVIEW', publishedAt: new Date(now), modifiedAt: new Date(now),
    edited: false, lifecycleGeneration: 0,
    createdAt: now,
    updatedAt: now
  };
  Object.assign(record, stage2.storageFields(normalized));
  const mediaStore = collection(env, 'CardMedia');
  const committed = await collection(env, 'FoodCard').runTransaction({
    apply: async (transaction) => {
      const owners = await transaction.executeQuery(collection(env, 'UserProfile').query().equalTo('uid', uid).limit(1));
      if (!isAccountActive(owners[0])) throw accessError('账号已停用或正在注销。', 'ACCOUNT_INACTIVE');
      const receipts = await transaction.executeQuery(collection(env, 'PublishRequestRecord').query()
        .equalTo('requestId', receiptSpec.receiptId).limit(1));
      const existingResult = stage1.checkPublishReceipt(receipts[0], uid, receiptSpec);
      if (existingResult) { cardId = existingResult.cardId; return true; }
      const currentMedias = [];
      for (const media of medias) {
        const rows = await transaction.executeQuery(mediaStore.query().equalTo('id', media.id).limit(1));
        const current = rows[0];
        if (!current || current.ownerUid !== uid || current.cardId ||
          (current.status !== 'PENDING_UPLOAD' && current.status !== 'APPROVED')) {
          throw new Error('实拍图已被使用或状态已变化，请重新选择。');
        }
        currentMedias.push(Object.assign(new CardMedia(), current, { cardId, status: 'APPROVED' }));
      }
      const committedAt = logicalWriteTime(owners[0].updatedAt);
      const currentFields = await stage2.cardFields(payload, uid, env,
        (name, field, value) => stage1.txOne(transaction, env, name, field, value), !modern);
      Object.assign(record, stage2.storageFields(currentFields), { createdAt: committedAt, updatedAt: committedAt,
        publishedAt: new Date(committedAt), modifiedAt: new Date(committedAt) });
      const counters = await stage2.prepareCounterTransition(transaction, null, record, owners[0], env, committedAt);
      stage1.upsertRows(transaction, [Object.assign(new FoodCard(), record), profileForWrite(owners[0], committedAt), ...counters]);
      transaction.executeUpsert([Object.assign(new PublishRequestRecord(), {
        requestId: receiptSpec.receiptId, uid, operationType: 'PUBLISH_CARD', payloadHash: receiptSpec.payloadHash,
        resultEntityId: cardId, status: 'COMMITTED', createdAt: new Date(committedAt),
        expiresAt: new Date(committedAt + 30 * 24 * 60 * 60 * 1000)
      })]);
      if (currentMedias.length > 0) transaction.executeUpsert(currentMedias);
      return true;
    }
  });
  if (!committed) throw new Error('推荐卡保存未完成，请重试。');
  // 产品决定：校验通过的用户内容立即发布。通过资料辅助函数重建，避免发布数更新时因 Cloud DB 查询而意外清空敏感镜像字段。
  await refreshPublishCount(uid, env);
  return { cardId, status: 'APPROVED' };
}

// 互动记录的确定性主键。
function actionId(scope, uid, targetId) {
  return crypto.createHash('sha256').update(`${scope}:${uid}:${targetId}`).digest('hex');
}

// 去重并校验请求中的图片 id（最多 6 张）。
function uniqueMediaIds(payload) {
  const values = Array.isArray(payload.mediaIds) ? payload.mediaIds : [];
  const source = values.length > 0 ? values : (payload.mediaId ? [payload.mediaId] : []);
  const ids = [];
  for (const value of source) {
    const id = String(value || '').trim();
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
      throw new Error('实拍图记录无效，请重新选择。');
    }
    if (ids.includes(id)) throw new Error('同一张实拍图不能重复添加。');
    ids.push(id);
  }
  if (ids.length < 1 || ids.length > MAX_CARD_PHOTOS) {
    throw accessError(`一张卡片必须包含 1–${MAX_CARD_PHOTOS} 张实拍图。`, 'VALIDATION_ERROR');
  }
  return ids;
}

// 【分区 12：卡片读取组装】作者公开资料。
async function publicProfile(uid, env, metrics = null, readContext = null) {
  const fallback = { nickname: '食刻用户', avatarPath: '', avatarBucket: '' };
  if (!uid) return fallback;
  try {
    if (metrics && !readContext) metrics.profileDbQueries += 1;
    const profile = readContext ? readContext.profiles.get(String(uid))
      : await one(collection(env, 'UserProfile').query().equalTo('uid', uid));
    if (!isAccountActive(profile)) return fallback;
    const output = profileResponse(profile, env);
    return {
      nickname: output.nickname || '食刻用户',
      avatarPath: output.avatarPath || '',
      avatarBucket: output.avatarBucket || ''
    };
  } catch (_error) {
    if (metrics) metrics.profileFailures += 1;
    // 资料字段只是附加到公开视图上；资料过期或缺失绝不能导致卡片无法显示。
    return fallback;
  }
}

// 卡片的公开图片列表（含描述符）。
async function publicPhotos(row, env, includePhoto, maxPhotoCount = MAX_CARD_PHOTOS, metrics = null, readContext = null) {
  if (!includePhoto) return [];
  const photoLimit = Math.max(1, Math.min(MAX_CARD_PHOTOS,
    Math.floor(Number(maxPhotoCount) || MAX_CARD_PHOTOS)));
  const primary = readContext && photoLimit === 1 ? readContext.primaryMedia.get(String(row.mediaId || '')) : null;
  // Card.mediaId 是记录的封面；没有关联的旧记录继续走旧的查询路径。
  const usePrimary = primary && primary.status === 'APPROVED' &&
    String(primary.cardId || '') === String(row.id || '') && String(primary.ownerUid || '') === String(row.ownerUid || '');
  if (metrics && !usePrimary) metrics.mediaDbQueries += 1;
  let medias = usePrimary ? [primary] : await collection(env, 'CardMedia').query().equalTo('cardId', String(row.id || ''))
    .orderByAsc('createdAt').limit(photoLimit).get();
  if (medias.length === 0 && row.mediaId && !(readContext && readContext.primaryMedia.has(String(row.mediaId)))) {
    if (metrics) metrics.mediaDbQueries += 1;
    const legacy = await one(collection(env, 'CardMedia').query().equalTo('id', String(row.mediaId)));
    medias = legacy ? [legacy] : [];
  }
  const photos = [];
  for (const media of medias) {
    if (!media || media.status !== 'APPROVED' || String(media.ownerUid || '') !== String(row.ownerUid || '') ||
        String(media.cardId || '') !== String(row.id || '')) continue;
    try {
      photos.push({
        id: String(media.id || ''),
        url: '',
        path: approvedObjectKeyForMedia(media),
        bucket: required(env, 'SHIKE_STORAGE_BUCKET'),
        width: Number(media.width || 0),
        height: Number(media.height || 0)
      });
    } catch (_error) {
      // 只跳过格式错误的那张图，其余轮播仍可使用。
    }
  }
  return photos;
}

// 为一批卡片建立读取上下文（批量读作者、图片、店铺）。
async function createCardReadContext(rows, viewerUid, env, metrics = null) {
  const scope = cardReadScope.getStore();
  const key = String(env.SHIKE_DB_ZONE || process.env.SHIKE_DB_ZONE || 'shike') + ':' + String(viewerUid || '');
  let context = scope && scope.get(key);
  if (!context) {
    context = { policy: contentPolicy(env), profiles: new Map(), profileRequests: new Map(),
      primaryMedia: new Map(), mediaRequests: new Map(), merchantRequests: new Map() };
    if (scope) scope.set(key, context);
    const seeds = scope && scope.get('verified-profiles');
    if (seeds) for (const [uid, profile] of seeds) {
      context.profiles.set(uid, profile); context.profileRequests.set(uid, Promise.resolve(profile));
    }
  }
  const profiles = context.profiles;
  const uids = [...new Set([...rows.map((row) => String(row.ownerUid || '')), String(viewerUid || '')].filter(Boolean))];
  const missing = uids.filter(uid => !context.profileRequests.has(uid));
  for (let start = 0; start < missing.length; start += SOCIAL_PROFILE_QUERY_BATCH_SIZE) {
    const batch = missing.slice(start, start + SOCIAL_PROFILE_QUERY_BATCH_SIZE).filter(uid => !context.profileRequests.has(uid));
    if (!batch.length) continue;
    if (metrics) metrics.profileDbQueries += 1;
    const loading = collection(env, 'UserProfile').query().in('uid', batch).limit(batch.length).get()
      .then(records => new Map(records.map(record => [String(record.uid), record])));
    for (const uid of batch) context.profileRequests.set(uid, loading.then(records => {
      const row = records.get(uid) || null; profiles.set(uid, row); return row;
    }));
    await Promise.all(batch.map(uid => context.profileRequests.get(uid)));
  }
  await Promise.all(uids.map(uid => context.profileRequests.get(uid)));
  context.policy.seedProfiles(profiles.entries());

  return context;
}

// 预先读取首图。
async function preparePrimaryPhotos(readContext, rows, env, metrics = null) {
  const ids = [...new Set(rows.map((row) => String(row.mediaId || '')).filter(Boolean))];
  const missing = ids.filter(id => !readContext.mediaRequests.has(id));
  for (let start = 0; start < missing.length; start += CARD_READ_BATCH_SIZE) {
    const batch = missing.slice(start, start + CARD_READ_BATCH_SIZE).filter(id => !readContext.mediaRequests.has(id));
    if (!batch.length) continue;
    if (metrics) metrics.mediaDbQueries += 1;
    const loading = collection(env, 'CardMedia').query().in('id', batch).limit(batch.length).get()
      .then(records => new Map(records.map(record => [String(record.id), record])));
    for (const id of batch) readContext.mediaRequests.set(id, loading.then(records => {
      const row = records.get(id) || null; readContext.primaryMedia.set(id, row); return row;
    }));
    await Promise.all(batch.map(id => readContext.mediaRequests.get(id)));
  }
  await Promise.all(ids.map(id => readContext.mediaRequests.get(id)));
}

// 按 id 批量读取店铺。
async function readMerchantRowsByIds(ids, env, readContext = null) {
  const requests = readContext ? readContext.merchantRequests : new Map();
  const unique = [...new Set(ids.filter(Boolean).map(String))];
  const missing = unique.filter(id => !requests.has(id));
  for (let start = 0; start < missing.length; start += CARD_READ_BATCH_SIZE) {
    const batch = missing.slice(start, start + CARD_READ_BATCH_SIZE).filter(id => !requests.has(id));
    if (!batch.length) continue;
    const loading = collection(env, 'Merchant').query().in('merchantId', batch).limit(batch.length).get()
      .then(rows => new Map(rows.map(row => [String(row.merchantId), row])));
    for (const id of batch) requests.set(id, loading.then(rows => rows.get(id) || null));
    await Promise.all(batch.map(id => requests.get(id)));
  }
  return new Map(await Promise.all(unique.map(async id => [id, await requests.get(id)])));
}

// 最终组装并再次校验可见性。
async function finalizeCardReads(cards, sourceRows, viewerUid, env, friendsOnly = false) {
  if (cards.length === 0) return cards;
  const ids = cards.map((card) => String(card.id));
  const originals = new Map(sourceRows.map((row) => [String(row.id), row]));
  const current = new Map();
  let owners = null;
  const mediaIds = [...new Set(cards.flatMap((card) => (card.photos || []).map((photo) => String(photo.id))))];
  const currentMedia = new Map();
  for (let start = 0; start < mediaIds.length; start += CARD_READ_BATCH_SIZE) {
    const batch = mediaIds.slice(start, start + CARD_READ_BATCH_SIZE);
    const rows = await collection(env, 'CardMedia').query().in('id', batch).limit(batch.length).get();
    for (const row of rows) currentMedia.set(String(row.id), row);
  }
  // 图片补全之后再刷新卡片数据；绝不复用第一阶段的权威缓存。
  for (let start = 0; start < ids.length; start += CARD_READ_BATCH_SIZE) {
    const batch = ids.slice(start, start + CARD_READ_BATCH_SIZE);
    const rows = await collection(env, 'FoodCard').query().in('id', batch).limit(batch.length).get();
    for (const row of rows) current.set(String(row.id), row);
  }
  if (friendsOnly) {
    owners = new Set([viewerUid]);
    for (const relation of await friendshipRowsFor(viewerUid, env)) {
      if (relation.status === 'ACCEPTED') owners.add(relation.memberAUid === viewerUid ? relation.memberBUid : relation.memberAUid);
    }
  }
  const policy = contentPolicy(env);
  // 批量读取最新的作者状态；不使用第一阶段读取上下文中的数据。
  const authorUids = [...new Set([...current.values()].map(row => String(row.ownerUid || '')).filter(Boolean))];
  const freshAuthors = new Map(authorUids.map(uid => [uid, null]));
  for (let start = 0; start < authorUids.length; start += SOCIAL_PROFILE_QUERY_BATCH_SIZE) {
    const batch = authorUids.slice(start, start + SOCIAL_PROFILE_QUERY_BATCH_SIZE);
    const rows = await collection(env, 'UserProfile').query().in('uid', batch).limit(batch.length).get();
    for (const row of rows) freshAuthors.set(String(row.uid), row);
  }
  policy.seedProfiles(freshAuthors.entries());
  const result = [];
  for (const card of cards) {
    const row = current.get(String(card.id));
    const original = originals.get(String(card.id));
    if (!row || !original || String(row.updatedAt || '') !== String(original.updatedAt || '') ||
        String(row.ownerUid || '') !== String(original.ownerUid || '') ||
        String(row.mediaId || '') !== String(original.mediaId || '') ||
        currentVisibility(row) !== currentVisibility(original) || row.status !== original.status ||
        String(row.reviewState || '') !== String(original.reviewState || '') ||
        (owners && !owners.has(row.ownerUid)) || !await policy.canReadCard(viewerUid, row)) continue;
    const photosCurrent = (card.photos || []).every((photo) => {
      const media = currentMedia.get(String(photo.id));
      try {
        return media && media.status === 'APPROVED' && String(media.ownerUid || '') === String(row.ownerUid || '') &&
          String(media.cardId || '') === String(row.id) && approvedObjectKeyForMedia(media) === photo.path;
      } catch (_error) { return false; }
    });
    if (photosCurrent) {
      for(const photo of card.photos||[]){
        const media=currentMedia.get(String(photo.id)),original=mediaVariant(media);
        Object.assign(photo,{sha256:original.sha256,byteSize:original.byteSize});
        try{const cover=mediaVariant(media,'COVER_480');Object.assign(photo,{coverSha256:cover.sha256,coverByteSize:cover.byteSize,coverWidth:cover.width,coverHeight:cover.height});}catch(_){}
      }
      result.push(card);
    }
  }
  return result;
}

// 卡片预览视图。
function previewCard(row, context, env) {
  const author = context.profiles.get(String(row.ownerUid)) || {};
  const media = context.primaryMedia.get(String(row.mediaId || ''));
  let photo = null;
  if (media && media.status === 'APPROVED' && media.cardId === row.id && media.ownerUid === row.ownerUid) {
    try { photo = { id: String(media.id), url: '', path: approvedObjectKeyForMedia(media),
      bucket: required(env, 'SHIKE_STORAGE_BUCKET'), width: Number(media.width || 0), height: Number(media.height || 0) }; }
    catch (_error) { photo = null; }
  }
  return { ...cardContractFields(row), id: String(row.id), productName: String(row.productName || ''),
    category: String(row.category || 'other'), brand: '', priceFen: Number(row.priceFen || 0),
    priceLabel: String(row.priceLabel || ''), originalPriceFen: 0, specification: '', shop: '',
    sellingPoints: [], publicOffers: [], reviewText: '', tasteScore: 0, sourceLink: '',
    photoUrl: '', photoPath: photo ? photo.path : '', photoBucket: photo ? photo.bucket : '',
    photoWidth: photo ? photo.width : 0, photoHeight: photo ? photo.height : 0,
    photos: photo ? [photo] : [], authorUid: String(row.ownerUid), authorNickname: String(author.nicknameValue || '食刻用户'),
    authorAvatarUrl: '', authorAvatarPath: '', authorAvatarBucket: '',
    district: String(row.district || ''), distanceKm: 0, status: 'APPROVED', createdAt: Number(row.createdAt || 0),
    likeCount: 0, favoriteCount: 0, viewerLiked: false, viewerFavorited: false };
}

// 互动摘要。
async function cardActionSummary(cardId, viewerUid, env) {
  // 服务端 COUNT 查询；旧 LIKE 历史尚未合并或 COUNT 不可用时，回退到精确的关系扫描。
  return cardInteractions.summary(cardId, viewerUid, env);
}

// 组装一张返回给客户端的卡片。
async function publicCard(row, env, distanceKm = 0, includePhoto = false, viewerUid = '', includeActions = false,
  maxPhotoCount = MAX_CARD_PHOTOS, metrics = null, readContext = null, reviewAccess = false) {
  const context = readContext || await createCardReadContext([row], viewerUid, env, metrics);
  if (reviewAccess && viewerUid === row.ownerUid && stage1.editableState(row)) await context.policy.assertAccountActive(viewerUid);
  else await context.policy.assertCardReadable(viewerUid, row);
  const ownerUid = String(row.ownerUid || '');
  const parts = [
    publicPhotos(row, env, includePhoto, maxPhotoCount, metrics, context),
    publicProfile(ownerUid, env, metrics, context)
  ];
  // 即使并行的图片查询失败，也要完成可选资料的计数统计。
  if (metrics) await Promise.allSettled(parts);
  const [photos, author] = await Promise.all(parts);
  const primaryPhoto = photos.length > 0 ? photos[0] : {
    id: '', url: '', path: '', bucket: '', width: 0, height: 0
  };
  const actions = includeActions
    ? await cardActionSummary(String(row.id || ''), viewerUid, env)
    : { likeCount: 0, favoriteCount: 0, viewerLiked: false, viewerFavorited: false };
  return {
    ...cardContractFields(row),
    id: row.id,
    productName: row.productName,
    brand: row.brand || '',
    priceFen: Number(row.priceFen || 0),
    priceLabel: row.priceLabel || '',
    originalPriceFen: Number(row.originalPriceFen || 0),
    specification: row.specification || '',
    shop: row.shop || '',
    sellingPoints: safeArray(row.sellingPointsJson),
    publicOffers: safeArray(row.publicOffersJson),
    reviewText: String(row.reviewText || ''),
    reviewReason: reviewAccess ? String(row.reviewReason || '') : '',
    tasteScore: Number(row.tasteScore || 0),
    sourceLink: row.sourceLink || '',
    category: row.category,
    photoUrl: '',
    photoPath: primaryPhoto.path,
    photoBucket: primaryPhoto.bucket,
    photoWidth: primaryPhoto.width,
    photoHeight: primaryPhoto.height,
    authorUid: ownerUid,
    authorNickname: author.nickname,
    authorAvatarUrl: '',
    authorAvatarPath: author.avatarPath,
    authorAvatarBucket: author.avatarBucket,
    photos,
    viewerIsOwner: !!viewerUid && ownerUid === viewerUid,
    likeCount: actions.likeCount,
    favoriteCount: actions.favoriteCount,
    viewerLiked: actions.viewerLiked,
    dislikeCount: Number(actions.dislikeCount || 0), myReaction: String(actions.myReaction || ''),
    viewerFavorited: actions.viewerFavorited,
    ...(includeActions ? { collectionReady: actions.collectionReady,
      collectionStatus: actions.collectionStatus } : {}),
    district: row.district || '当前位置',
    distanceKm,
    // 状态未知或已退役的旧数据不会被测试模式提升为公开；只有明确为 APPROVED 的行才视为公开。
    status: row.status === 'APPROVED' ? 'APPROVED' : 'REMOVED',
    createdAt: Number(row.createdAt || 0)
  };
}

// 【分区 14：推荐流】普通公开推荐流（首页）：按页读取元数据，多读一条判断是否有下一页，隐藏行的扫描有上限。游标格式 g1.<分类>.<快照时间>.<偏移>。
async function listPublicRecommendations(payload, env, viewerUid = '') {
  const category = String(payload.category || 'all');
  if (category !== 'all' && !VALID_CATEGORY.has(category)) throw new Error('商品分类无效。');
  const requestedSize = Number(payload.pageSize || MAX_PAGE_SIZE);
  const pageSize = Number.isFinite(requestedSize) ? Math.floor(Math.min(MAX_PAGE_SIZE, Math.max(1, requestedSize))) : MAX_PAGE_SIZE;
  let snapshotAt = Date.now();
  let offset = 0;
  const token = String(payload.pageToken || '').trim();
  if (token) {
    const parts = /^g1\.([a-z]+)\.(\d+)\.(\d+)$/.exec(token);
    if (!parts || parts[1] !== category) throw new Error('推荐分页已失效，请刷新列表。');
    snapshotAt = Number(parts[2]);
    offset = Number(parts[3]);
    if (!Number.isSafeInteger(snapshotAt) || snapshotAt < 0 || snapshotAt > Date.now() ||
        !Number.isSafeInteger(offset) || offset < 0) throw new Error('推荐分页参数无效。');
  }
  const page = await scanCardPage(() => {
    let query = collection(env, 'FoodCard').query().equalTo('status', 'APPROVED').lessThanOrEqualTo('createdAt', snapshotAt);
    if (category !== 'all') query = query.equalTo('category', category);
    return query.orderByDesc('createdAt').orderByAsc('id');
  }, viewerUid, env, offset, pageSize, true, 1, pageSize + 1);
  return { cards: page.cards, nextPageToken: page.hasMore ? 'g1.' + category + '.' + snapshotAt + '.' + page.nextOffset : '', district: '',
    coverage: page.hasMore ? (page.scannedCandidateCount >= 200 && page.cards.length < pageSize ? 'PARTIAL_SCAN_LIMIT' : 'PARTIAL_RESULT_LIMIT') : 'COMPLETE',
    scannedCandidateCount: page.scannedCandidateCount, fetchedCandidateCount: page.fetchedCandidateCount };
}

// get-card-detail：卡片详情（作者被停用、卡片下架或删除时拒绝）。
async function cardDetail(uid, payload, env) {
  const row = await one(collection(env, 'FoodCard').query().equalTo('id', String(payload.cardId || '')));
  await contentPolicy(env).assertCardReadable(uid, row);
  const detail = await publicCard(row, env, 0, true, uid, true);
  const current = await finalizeCardReads([detail], [row], uid, env);
  if (!current.length) throw accessError('内容已不可访问或已变化，请刷新。', 'CONTENT_UNAVAILABLE');
  return current[0];
}

// list-my-cards：我的全部卡片。
async function myCards(uid, env) {
  const rows = await collection(env, 'FoodCard').query().equalTo('ownerUid', uid).orderByDesc('createdAt').limit(100).get();
  const cards = [];
  for (const row of rows) {
    const card = await readCardIfAllowed(row, env, 0, true, uid);
    if (card) cards.push(card);
  }
  return { cards };
}

// get-friend-profile：好友主页。
async function friendProfile(uid, payload, env) {
  const page = await stage7.userPage(uid, { userUid: String(payload.friendUid || ''),
    cursor: String(payload.pageToken || ''), pageSize: Number(payload.pageSize || 12) }, env);
  return { profile: { user: { ...page.profile, friendCode: '', avatarUrl: '',
    friendshipState: page.relationshipState === 'FRIEND' ? 'FRIEND' : 'NONE', requestId: '' },
    coverPath: page.profile.coverPath || '', coverBucket: page.profile.coverBucket || '' }, cards: page.cards, nextPageToken: page.nextCursor };
}

// 【分区 15：好友关系】两个 UID 排序后的组合。
function socialPair(uid, otherUid) {
  const first = String(uid || '');
  const second = String(otherUid || '');
  if (!first || !second || first === second) throw new Error('不能把自己添加为好友。');
  return first < second
    ? { memberAUid: first, memberBUid: second }
    : { memberAUid: second, memberBUid: first };
}

// 好友关系行主键。
function socialPairId(prefix, uid, otherUid) {
  const pair = socialPair(uid, otherUid);
  return crypto.createHash('sha256')
    .update(`${prefix}:${pair.memberAUid}:${pair.memberBUid}`)
    .digest('hex');
}

// 读取双方关系。
async function friendshipBetween(uid, otherUid, env) {
  const id = socialPairId('friend', uid, otherUid);
  return one(collection(env, 'Friendship').query().equalTo('id', id));
}

// 断言双方是好友。
async function requireFriend(uid, otherUid, env) {
  await contentPolicy(env).assertAccountActive(uid);
  await contentPolicy(env).assertAccountActive(otherUid);
  const relationship = await friendshipBetween(uid, otherUid, env);
  if (!relationship || String(relationship.status || '') !== 'ACCEPTED') {
    throw new Error('只有互为好友后才能发送私信。');
  }
  return relationship;
}

// 从查看者角度的关系状态。
function relationshipState(row, viewerUid) {
  if (!row) return 'NONE';
  if (String(row.status || '') === 'ACCEPTED') return 'FRIEND';
  if (pendingFriendRequestExpired(row)) return 'NONE';
  if (String(row.status || '') !== 'PENDING') return 'NONE';
  return String(row.requesterUid || '') === viewerUid ? 'OUTGOING' : 'INCOMING';
}

// 待处理的好友申请是否已过期。
function pendingFriendRequestExpired(row, now = Date.now()) {
  return String(row && row.status || '') === 'PENDING'
    && Number(row && row.createdAt || 0) > 0
    && now - Number(row.createdAt || 0) >= FRIEND_REQUEST_TTL_MS;
}

// 把过期的申请标记为过期。
async function expirePendingFriendships(rows, env) {
  const now = Date.now();
  const friendships = collection(env, 'Friendship');
  for (const row of rows) {
    if (!pendingFriendRequestExpired(row, now)) continue;
    const committed = await friendships.runTransaction({
      apply: async (transaction) => {
        const currentRows = await transaction.executeQuery(friendships.query().equalTo('id', String(row.id)).limit(1));
        const current = currentRows[0];
        if (current && pendingFriendRequestExpired(current, now)) {
          transaction.executeUpsert([Object.assign(new Friendship(), current, {
            status: 'EXPIRED', updatedAt: logicalWriteTime(now, current.updatedAt)
          })]);
        }
        return true;
      }
    });
    if (!committed) throw new Error('好友申请过期状态未保存，请重试。');
  }
}

// 社交场景中的用户视图。
function socialUser(record, viewerUid, env, row = null) {
  const profile = profileResponse(record, env);
  return {
    uid: profile.uid,
    friendCode: profile.friendCode,
    nickname: profile.nickname,
    avatarUrl: '',
    avatarPath: profile.avatarPath,
    avatarBucket: profile.avatarBucket,
    publishCount: profile.publishCount,
    friendshipState: relationshipState(row, viewerUid),
    requestId: row ? String(row.id || '') : '',
    friendshipUpdatedAt: row ? Number(row.updatedAt || 0) : 0
  };
}

// 按 UID 读取社交用户视图。
async function socialUserByUid(targetUid, viewerUid, env, row = null) {
  const record = await one(collection(env, 'UserProfile').query().equalTo('uid', String(targetUid || '')));
  if (!record || String(record.accountStatus || 'ACTIVE') !== 'ACTIVE') return null;
  return socialUser(record, viewerUid, env, row);
}

// 解析分页参数。
function socialPage(payload) {
  const requestedSize = Number(payload && payload.pageSize || MAX_SOCIAL_PAGE_SIZE);
  const pageSize = Math.floor(Math.min(MAX_SOCIAL_PAGE_SIZE, Math.max(1, requestedSize)));
  const rawToken = String(payload && payload.pageToken || '').trim();
  const parsedOffset = /^\d+$/.test(rawToken) ? Number(rawToken) : 0;
  const offset = Number.isSafeInteger(parsedOffset) ? Math.max(0, Math.min(parsedOffset, 1000000)) : 0;
  return { pageSize, offset };
}

// 读取查询的全部行（有上限）。
async function queryAllRows(queryFactory) {
  const output = [];
  let offset = 0;
  while (true) {
    const rows = await queryFactory().limit(SOCIAL_QUERY_BATCH_SIZE, offset).get();
    output.push(...rows);
    if (rows.length < SOCIAL_QUERY_BATCH_SIZE) return output;
    offset += rows.length;
  }
}

// 某用户的全部关系行。
async function friendshipRowsFor(uid, env) {
  const friendships = collection(env, 'Friendship');
  const [asMemberA, asMemberB] = await Promise.all([
    queryAllRows(() => friendships.query().equalTo('memberAUid', uid)),
    queryAllRows(() => friendships.query().equalTo('memberBUid', uid))
  ]);
  return uniqueRows([...asMemberA, ...asMemberB]);
}

// 批量读取与若干目标用户的关系。
async function relationshipRowsByTargetUid(uid, targetUids, env) {
  const ids = [];
  const targetById = new Map();
  for (const targetUid of targetUids) {
    const normalized = String(targetUid || '');
    if (!normalized || normalized === uid) continue;
    const id = socialPairId('friend', uid, normalized);
    ids.push(id);
    targetById.set(id, normalized);
  }
  const output = new Map();
  const friendships = collection(env, 'Friendship');
  for (let start = 0; start < ids.length; start += SOCIAL_PROFILE_QUERY_BATCH_SIZE) {
    const idBatch = ids.slice(start, start + SOCIAL_PROFILE_QUERY_BATCH_SIZE);
    if (idBatch.length === 0) continue;
    const rows = await friendships.query().in('id', idBatch).limit(idBatch.length).get();
    for (const row of rows) {
      const targetUid = targetById.get(String(row.id || ''));
      if (targetUid) output.set(targetUid, row);
    }
  }
  return output;
}

// 批量读取社交用户视图。
async function socialUsersByUid(targetUids, viewerUid, env, rowsByUid = new Map()) {
  const normalizedUids = [];
  const seen = new Set();
  for (const value of targetUids) {
    const uid = String(value || '');
    if (uid && !seen.has(uid)) {
      seen.add(uid);
      normalizedUids.push(uid);
    }
  }
  const recordsByUid = new Map();
  const profiles = collection(env, 'UserProfile');
  for (let start = 0; start < normalizedUids.length; start += SOCIAL_PROFILE_QUERY_BATCH_SIZE) {
    const uidBatch = normalizedUids.slice(start, start + SOCIAL_PROFILE_QUERY_BATCH_SIZE);
    if (uidBatch.length === 0) continue;
    const rows = await profiles.query().in('uid', uidBatch).limit(uidBatch.length).get();
    for (const row of rows) recordsByUid.set(String(row.uid || ''), row);
  }
  const output = new Map();
  for (const uid of normalizedUids) {
    const record = recordsByUid.get(uid);
    if (!record || String(record.accountStatus || 'ACTIVE') !== 'ACTIVE') continue;
    output.set(uid, socialUser(record, viewerUid, env, rowsByUid.get(uid) || null));
  }
  return output;
}

// search-users：按食刻号或昵称搜索用户。
async function searchUsers(uid, payload, env) {
  const keyword = String(payload.keyword || '').trim();
  if (keyword.length < 2 || keyword.length > 24) {
    throw new Error('请输入 2–24 个字符的完整昵称或食刻号。');
  }
  const profiles = collection(env, 'UserProfile');
  const normalizedCode = keyword.toUpperCase();
  const rows = normalizedCode.startsWith('SK-')
    ? await profiles.query().equalTo('friendCode', normalizedCode).limit(MAX_SOCIAL_RESULTS).get()
    : await profiles.query().equalTo('nicknameValue', keyword).limit(MAX_SOCIAL_RESULTS).get();
  const candidates = rows.filter((record) => {
    const targetUid = String(record.uid || '');
    return targetUid && targetUid !== uid && String(record.accountStatus || 'ACTIVE') === 'ACTIVE';
  });
  const relationships = await relationshipRowsByTargetUid(
    uid, candidates.map((record) => String(record.uid || '')), env);
  const users = candidates.filter((record) => {
    const relationship = relationships.get(String(record.uid || ''));
    return !relationship || String(relationship.status || '') !== 'BLOCKED';
  }).map((record) => {
    const targetUid = String(record.uid || '');
    return socialUser(record, uid, env, relationships.get(targetUid) || null);
  });
  return { users };
}

// 按主键去重。
function uniqueRows(rows) {
  const output = [];
  const seen = new Set();
  for (const row of rows) {
    const id = String(row && row.id || '');
    if (id && !seen.has(id)) {
      seen.add(id);
      output.push(row);
    }
  }
  return output;
}

// list-friends：好友、收到 / 发出的申请、黑名单。
async function listFriends(uid, payload, env) {
  const page = socialPage(payload);
  let rows = await friendshipRowsFor(uid, env);
  await expirePendingFriendships(rows, env);
  rows = await friendshipRowsFor(uid, env);
  rows.sort((first, second) => Number(second.updatedAt || 0) - Number(first.updatedAt || 0));
  const pageRows = rows.slice(page.offset, page.offset + page.pageSize);
  const relationshipRowsByUid = new Map();
  const otherUids = [];
  for (const row of pageRows) {
    const otherUid = String(row.memberAUid || '') === uid
      ? String(row.memberBUid || '') : String(row.memberAUid || '');
    if (otherUid) {
      otherUids.push(otherUid);
      relationshipRowsByUid.set(otherUid, row);
    }
  }
  const usersByUid = await socialUsersByUid(otherUids, uid, env, relationshipRowsByUid);
  const friends = [];
  const incomingRequests = [];
  const outgoingRequests = [];
  const blockedUsers = [];
  for (const row of pageRows) {
    const otherUid = String(row.memberAUid || '') === uid
      ? String(row.memberBUid || '') : String(row.memberAUid || '');
    const user = usersByUid.get(otherUid);
    if (!user) continue;
    if (String(row.status || '') === 'BLOCKED') {
      if (String(row.requesterUid || '') === uid) blockedUsers.push(user);
      continue;
    }
    if (String(row.status || '') === 'ACCEPTED') {
      friends.push(user);
      continue;
    }
    if (String(row.status || '') !== 'PENDING') continue;
    const request = { id: String(row.id || ''), user, createdAt: Number(row.createdAt || 0) };
    if (String(row.addresseeUid || '') === uid) incomingRequests.push(request);
    else if (String(row.requesterUid || '') === uid) outgoingRequests.push(request);
  }
  friends.sort((a, b) => a.nickname.localeCompare(b.nickname));
  incomingRequests.sort((a, b) => b.createdAt - a.createdAt);
  outgoingRequests.sort((a, b) => b.createdAt - a.createdAt);
  return {
    friends,
    incomingRequests,
    outgoingRequests,
    blockedUsers,
    nextPageToken: page.offset + page.pageSize < rows.length ? String(page.offset + page.pageSize) : ''
  };
}

// 在事务中读取并修改双方关系（双方资料一起校验）。
async function friendshipTransaction(uid, otherUid, env, requireOtherActive, apply) {
  const pair = socialPair(uid, otherUid);
  const id = socialPairId('friend', uid, otherUid);
  const friendships = collection(env, 'Friendship');
  let result = null;
  const committed = await friendships.runTransaction({
    apply: async (transaction) => {
      result = null;
      const profiles = await pairProfiles(transaction, uid, otherUid, env, requireOtherActive);
      const rows = await transaction.executeQuery(friendships.query().equalTo('id', id).limit(1));
      const row = rows[0] || null;
      if (row && (String(row.memberAUid || '') !== pair.memberAUid || String(row.memberBUid || '') !== pair.memberBUid)) {
        throw accessError('好友关系记录无效。', 'INVALID_STATE');
      }
      const now = logicalWriteTime(...profiles.map((profile) => profile.updatedAt), row && row.updatedAt);
      result = await apply(transaction, { pair, id, row, profiles, now, friendships });
      if (result.writeProfiles !== false) {
        transaction.executeUpsert(profiles.map((profile) => profileForWrite(profile, now)));
      }
      return true;
    }
  });
  if (!committed || !result) throw new Error('好友状态变更未完成，请重试。');
  return result;
}

// 校验好友申请版本（防止处理过期的申请）。
function assertFriendRequestVersion(row, payload) {
  if (payload.expectedCreatedAt != null && (!Number.isSafeInteger(Number(payload.expectedCreatedAt)) ||
      Number(payload.expectedCreatedAt) !== Number(row.createdAt))) {
    throw accessError('好友申请已变化，请刷新。', 'CONFLICT');
  }
}

// 会话清理任务 id。
function conversationCleanupId(friendshipId, cutoffAt) {
  return crypto.createHash('sha256').update('friend-cleanup:' + friendshipId + ':' + cutoffAt).digest('hex');
}

// 解除好友 / 拉黑时准备会话清理任务。
async function prepareConversationCleanup(transaction, uid, otherUid, state, env) {
  const conversationId = socialPairId('conversation', uid, otherUid);
  const rows = await transaction.executeQuery(collection(env, 'Conversation').query().equalTo('id', conversationId).limit(1));
  const jobId = conversationCleanupId(state.id, state.now);
  const job = Object.assign(new MaintenanceJob(), {
    jobId, jobType: 'PURGE_CONVERSATION', entityId: state.id, ownerUid: uid,
    generation: state.now, status: 'PENDING', runAfterAt: new Date(state.now),
    attemptCount: 0, cursor: '', lastErrorCode: '',
    checkpointJson: JSON.stringify({ memberAUid: state.pair.memberAUid, memberBUid: state.pair.memberBUid,
      conversationId, cutoffAt: state.now }), createdAt: new Date(state.now), updatedAt: new Date(state.now)
  });
  return { job, conversation: rows[0] || null };
}

// send-friend-request。
async function sendFriendRequest(uid, payload, env) {
  const targetUid = String(payload.targetUid || '');
  const result = await friendshipTransaction(uid, targetUid, env, true, async (transaction, state) => {
    const existing = state.row;
    if (existing && existing.status === 'ACCEPTED') throw new Error('你们已经是好友了。');
    if (existing && existing.status === 'BLOCKED') throw accessError('当前无法向该用户发送好友申请。');
    if (existing && existing.status === 'PENDING' && !pendingFriendRequestExpired(existing, state.now)) {
      if (String(existing.requesterUid || '') === uid) return { writeProfiles: false };
      throw new Error('对方已经向你发送好友申请，请到“收到的申请”中处理。');
    }
    transaction.executeUpsert([Object.assign(new Friendship(), {
      id: state.id, memberAUid: state.pair.memberAUid, memberBUid: state.pair.memberBUid,
      requesterUid: uid, addresseeUid: targetUid, status: 'PENDING', createdAt: state.now, updatedAt: state.now
    })]);
    return { notify: true, requestId: state.id, createdAt: state.now };
  });
  if (result.notify) await sendSocialPush(targetUid, uid, 'FRIEND_REQUEST', result.requestId, env);
  return { success: true };
}

// respond-friend-request：同意或拒绝。
async function respondFriendRequest(uid, payload, env) {
  const requestId = String(payload.requestId || '');
  const initial = await one(collection(env, 'Friendship').query().equalTo('id', requestId));
  if (!initial || String(initial.addresseeUid || '') !== uid) {
    throw new Error('好友申请不存在、已处理或不属于当前用户。');
  }
  const requesterUid = String(initial.requesterUid || '');
  const result = await friendshipTransaction(uid, requesterUid, env, payload.accept === true, async (transaction, state) => {
    const row = state.row;
    if (!row || state.id !== requestId || row.status !== 'PENDING' || String(row.addresseeUid || '') !== uid) {
      throw accessError('好友申请不存在或已处理。', 'CONFLICT');
    }
    assertFriendRequestVersion(row, payload);
    if (payload.accept === true && payload.expectedCreatedAt == null) {
      throw accessError('请更新客户端后刷新申请再处理。', 'CLIENT_UPDATE_REQUIRED');
    }
    if (pendingFriendRequestExpired(row, state.now)) {
      transaction.executeUpsert([Object.assign(new Friendship(), row, { status: 'EXPIRED', updatedAt: state.now })]);
      return { expired: true };
    }
    if (payload.accept === true) {
      const conversationId = socialPairId('conversation', uid, requesterUid);
      await transaction.executeQuery(collection(env, 'Conversation').query().equalTo('id', conversationId).limit(1));
      transaction.executeUpsert([Object.assign(new Friendship(), row, {
        status: 'ACCEPTED', createdAt: state.now, updatedAt: state.now
      })]);
      transaction.executeUpsert([Object.assign(new Conversation(), {
        id: conversationId, memberAUid: state.pair.memberAUid, memberBUid: state.pair.memberBUid,
        lastMessageId: '', lastMessageKind: 'TEXT', lastMessagePreview: encryptPrivateText('', `conversation:${conversationId}:preview`, env),
        lastMessageAt: 0, unreadA: 0, unreadB: 0, createdAt: state.now, updatedAt: state.now
      })]);
      return { notify: true, originalCreatedAt: Number(row.createdAt) };
    }
    transaction.executeDelete([row]);
    return {};
  });
  if (result.expired) throw accessError('这条好友申请已过期。', 'INVALID_STATE');
  if (result.notify) await sendSocialPush(requesterUid, uid, 'FRIEND_ACCEPTED', uid, env);
  return { success: true };
}

// cancel-friend-request。
async function cancelFriendRequest(uid, payload, env) {
  const requestId = String(payload.requestId || '');
  const initial = await one(collection(env, 'Friendship').query().equalTo('id', requestId));
  if (!initial || String(initial.requesterUid || '') !== uid) {
    throw new Error('好友申请不存在、已处理或不属于当前用户。');
  }
  await friendshipTransaction(uid, String(initial.addresseeUid), env, false, async (transaction, state) => {
    const row = state.row;
    if (!row || state.id !== requestId || row.status !== 'PENDING' || row.requesterUid !== uid) {
      throw accessError('好友申请不存在或已处理。', 'CONFLICT');
    }
    assertFriendRequestVersion(row, payload);
    transaction.executeDelete([row]);
    return {};
  });
  return { success: true };
}

// block-user：拉黑（同时解除好友）。
async function blockUser(uid, payload, env) {
  const targetUid = String(payload.targetUid || '');
  const result = await friendshipTransaction(uid, targetUid, env, true, async (transaction, state) => {
    if (state.row && state.row.status === 'BLOCKED') {
      if (state.row.requesterUid === uid) return { writeProfiles: false };
      throw accessError('当前无法屏蔽该用户。');
    }
    const cleanup = await prepareConversationCleanup(transaction, uid, targetUid, state, env);
    transaction.executeUpsert([Object.assign(new Friendship(), {
      id: state.id, memberAUid: state.pair.memberAUid, memberBUid: state.pair.memberBUid,
      requesterUid: uid, addresseeUid: targetUid, status: 'BLOCKED',
      createdAt: state.row ? Number(state.row.createdAt) : state.now, updatedAt: state.now
    })]);
    if (cleanup.conversation) transaction.executeDelete([cleanup.conversation]);
    transaction.executeUpsert([cleanup.job]);
    return { jobId: cleanup.job.jobId };
  });
  if (result.jobId) await bestEffortFriendCleanup(result.jobId, env);
  return { success: true };
}

// unblock-user。
async function unblockUser(uid, payload, env) {
  const targetUid = String(payload.targetUid || '');
  await friendshipTransaction(uid, targetUid, env, false, async (transaction, state) => {
    const row = state.row;
    if (!row || row.status !== 'BLOCKED' || row.requesterUid !== uid) throw accessError('屏蔽关系不存在或无权解除。');
    transaction.executeDelete([row]);
    return {};
  });
  return { success: true };
}

// remove-friend：解除好友（requestId 幂等，之后清理双方私信）。
async function removeFriend(uid, payload, env) {
  const friendUid = String(payload.friendUid || '');
  socialPair(uid, friendUid);
  const requestId = String(payload.requestId || '').trim();
  if (requestId && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(requestId)) {
    throw new Error('解除好友请求标识无效。');
  }
  const expected = payload.expectedFriendshipUpdatedAt == null ? null : Number(payload.expectedFriendshipUpdatedAt);
  if (requestId && (!Number.isSafeInteger(expected) || expected <= 0)) {
    throw accessError('请刷新好友列表后再操作。', 'CONFLICT');
  }
  const receiptId = requestId ? crypto.createHash('sha256').update('friend-remove:' + uid + ':' + requestId).digest('hex') : '';
  const payloadHash = crypto.createHash('sha256').update(JSON.stringify({ friendUid, expected })).digest('hex');
  const receipts = collection(env, 'PublishRequestRecord');
  // 已有回执时：确认是同一用户的同一次“解除好友”，返回之前的结果（幂等）。
  function savedRemoval(receipt) {
    if (receipt.uid !== uid || receipt.operationType !== 'FRIEND_REMOVE' || receipt.payloadHash !== payloadHash || receipt.status !== 'COMMITTED') {
      throw accessError('请求标识已用于其他操作。', 'CONFLICT');
    }
    return { writeProfiles: false, alreadyProcessed: true, jobId: String(receipt.resultEntityId || '') };
  }
  const previous = receiptId && await one(receipts.query().equalTo('requestId', receiptId));
  let result;
  if (previous) {
    result = savedRemoval(previous);
  } else {
    result = await friendshipTransaction(uid, friendUid, env, false, async (transaction, state) => {
      const receiptRows = receiptId ? await transaction.executeQuery(receipts.query().equalTo('requestId', receiptId).limit(1)) : [];
      if (receiptRows.length > 0) return savedRemoval(receiptRows[0]);
      let jobId = '';
      let alreadyRemoved = false;
      if (!state.row || state.row.status !== 'ACCEPTED') {
        if (state.row && state.row.status === 'BLOCKED') throw accessError('屏蔽关系不能作为解除好友操作处理。');
        if (state.row && state.row.status === 'PENDING') throw accessError('好友关系已变化，请刷新。', 'CONFLICT');
        alreadyRemoved = true;
      } else {
        if (expected !== null && expected !== Number(state.row.updatedAt)) throw accessError('好友关系已变化，请刷新。', 'CONFLICT');
        const cleanup = await prepareConversationCleanup(transaction, uid, friendUid, state, env);
        jobId = cleanup.job.jobId;
        transaction.executeDelete([state.row]);
        if (cleanup.conversation) transaction.executeDelete([cleanup.conversation]);
        transaction.executeUpsert([cleanup.job]);
      }
      if (receiptId) transaction.executeUpsert([Object.assign(new PublishRequestRecord(), {
        requestId: receiptId, uid, operationType: 'FRIEND_REMOVE', payloadHash, resultEntityId: jobId,
        status: 'COMMITTED', createdAt: new Date(state.now), expiresAt: new Date(state.now + 30 * 24 * 60 * 60 * 1000)
      })]);
      return { jobId, alreadyRemoved, writeProfiles: !alreadyRemoved || !!receiptId };
    });
  }
  const cleanup = result.jobId ? await bestEffortFriendCleanup(result.jobId, env) : { complete: true };
  return { success: true, alreadyProcessed: result.alreadyProcessed === true || result.alreadyRemoved === true,
    cleanupPending: !cleanup.complete, cleanupJobId: result.jobId || '' };
}

// 执行好友会话清理任务。
async function processFriendCleanup(jobId, env) {
  const jobs = collection(env, 'MaintenanceJob');
  let output = null;
  const committed = await jobs.runTransaction({
    apply: async (transaction) => {
      output = null;
      const rows = await transaction.executeQuery(jobs.query().equalTo('jobId', jobId).limit(1));
      const job = rows[0];
      if (!job || job.jobType !== 'PURGE_CONVERSATION') throw accessError('会话清理任务不存在或类型不支持。', 'NOT_FOUND');
      if (job.status === 'DONE' || job.status === 'CANCELLED') { output = { complete: true, deletedMessages: 0 }; return true; }
      if (!['PENDING', 'RETRY_WAIT'].includes(job.status)) throw accessError('会话清理任务状态无效。', 'INVALID_STATE');
      const runAfterAt = dateMillis(job.runAfterAt);
      if (runAfterAt === null) throw accessError('会话清理调度时间无效。', 'INVALID_STATE');
      if (runAfterAt > Date.now()) { output = { complete: false, retryAt: runAfterAt }; return true; }
      const checkpoint = JSON.parse(String(job.checkpointJson || '{}'));
      const first = String(checkpoint.memberAUid || '');
      const second = String(checkpoint.memberBUid || '');
      const cutoffAt = Number(checkpoint.cutoffAt);
      if (!first || !second || first >= second || !Number.isSafeInteger(cutoffAt) || cutoffAt <= 0 ||
          cutoffAt !== Number(job.generation) || String(job.entityId) !== socialPairId('friend', first, second) ||
          jobId !== conversationCleanupId(String(job.entityId), cutoffAt) ||
          String(checkpoint.conversationId) !== socialPairId('conversation', first, second)) {
        throw accessError('会话清理检查点无效。', 'INVALID_STATE');
      }
      const messages = await transaction.executeQuery(collection(env, 'ChatMessage').query()
        .equalTo('conversationId', String(checkpoint.conversationId)).lessThanOrEqualTo('createdAt', cutoffAt).limit(25));
      const conversations = await transaction.executeQuery(collection(env, 'Conversation').query()
        .equalTo('id', String(checkpoint.conversationId)).limit(1));
      const conversation = conversations[0];
      const complete = messages.length < 25;
      const now = logicalWriteTime(dateMillis(job.updatedAt));
      if (messages.length > 0) transaction.executeDelete(messages);
      if (conversation && Number(conversation.createdAt || 0) <= cutoffAt && Number(conversation.lastMessageAt || 0) <= cutoffAt) {
        transaction.executeDelete([conversation]);
      }
      transaction.executeUpsert([Object.assign(new MaintenanceJob(), job, {
        status: complete ? 'DONE' : 'PENDING', attemptCount: Number(job.attemptCount || 0) + 1,
        runAfterAt: new Date(now), updatedAt: new Date(now), lastErrorCode: ''
      })]);
      output = { complete, deletedMessages: messages.length, jobId };
      return true;
    }
  });
  if (!committed || !output) throw new Error('会话清理未完成。');
  return output;
}

// 尽力执行清理（失败留待后续）。
async function bestEffortFriendCleanup(jobId, env) {
  try {
    return await processFriendCleanup(jobId, env);
  } catch (error) {
    console.error(`friend cleanup failed: ${safeLogError(error)}`);
    try {
      const jobs = collection(env, 'MaintenanceJob');
      await jobs.runTransaction({
        apply: async (transaction) => {
          const rows = await transaction.executeQuery(jobs.query().equalTo('jobId', jobId).limit(1));
          const job = rows[0];
          if (job && job.jobType === 'PURGE_CONVERSATION' && ['PENDING', 'RETRY_WAIT'].includes(job.status)) {
            const now = Date.now();
            transaction.executeUpsert([Object.assign(new MaintenanceJob(), job, {
              status: 'RETRY_WAIT', attemptCount: Number(job.attemptCount || 0) + 1,
              runAfterAt: new Date(now + 60000), updatedAt: new Date(now), lastErrorCode: 'CLEANUP_FAILED'
            })]);
          }
          return true;
        }
      });
    } catch (failure) { console.error(`friend cleanup retry mark failed: ${safeLogError(failure)}`); }
    return { complete: false };
  }
}

// 【分区 16：私信】校验消息类型。
function messageKind(value) {
  const kind = String(value || '');
  if (kind !== 'TEXT' && kind !== 'CARD' && kind !== 'LINK') throw new Error('不支持的消息类型。');
  return kind;
}

// 会话列表中显示的消息摘要。
function messagePreview(kind, text, link) {
  if (kind === 'CARD') return '分享了一张美食推荐';
  if (kind === 'LINK') {
    try { return `商品链接：${new URL(link).hostname}`; } catch (_error) { return '分享了商品链接'; }
  }
  return String(text || '').replace(/\s+/g, ' ').slice(0, 60);
}

// 消息的返回视图（解密正文）。
async function publicMessage(row, viewerUid, env) {
  const messageId = String(row.id || '');
  const output = {
    id: messageId,
    conversationId: String(row.conversationId || ''),
    senderUid: String(row.senderUid || ''),
    recipientUid: String(row.recipientUid || ''),
    mine: String(row.senderUid || '') === viewerUid,
    kind: messageKind(row.kind),
    text: decryptPrivateText(row.text, `message:${messageId}:text`, env),
    link: decryptPrivateText(row.link, `message:${messageId}:link`, env),
    cardId: String(row.cardId || ''),
    createdAt: Number(row.createdAt || 0),
    readAt: Number(row.readAt || 0)
  };
  if (output.kind === 'CARD' && output.cardId) {
    const card = await one(collection(env, 'FoodCard').query().equalTo('id', output.cardId));
    const sharedCard = await readCardIfAllowed(card, env, 0, true, viewerUid, false);
    if (sharedCard) output.sharedCard = sharedCard;
  }
  return output;
}

// send-message：发送私信（只能发给好友；正文加密存储；更新双方会话摘要与未读数；发送通知）。
async function sendMessage(uid, payload, env) {
  const friendUid = String(payload.friendUid || '');
  await requireFriend(uid, friendUid, env);
  const kind = messageKind(payload.kind);
  let text = String(payload.text || '').trim();
  let link = String(payload.link || '').trim();
  let cardId = String(payload.cardId || '').trim();
  if (kind === 'TEXT') {
    if (text.length === 0 || text.length > MAX_MESSAGE_LENGTH) {
      throw new Error(`消息需为 1–${MAX_MESSAGE_LENGTH} 个字符。`);
    }
    link = '';
    cardId = '';
  } else if (kind === 'LINK') {
    if (!validHttpsUrl(link) || link.length > 2048) throw new Error('商品链接必须是有效的 HTTPS 地址。');
    text = text.slice(0, 120);
    cardId = '';
  } else {
    const card = await one(collection(env, 'FoodCard').query().equalTo('id', cardId));
    if (!await contentPolicy(env).canReadCard(uid, card) || !await contentPolicy(env).canReadCard(friendUid, card)) {
      throw accessError('当前双方不能读取这张推荐卡片。');
    }
    text = '';
    link = '';
  }
  const pair = socialPair(uid, friendUid);
  const conversationId = socialPairId('conversation', uid, friendUid);
  const messageId = crypto.randomUUID();
  const storedText = encryptPrivateText(text, `message:${messageId}:text`, env);
  const storedLink = encryptPrivateText(link, `message:${messageId}:link`, env);
  const storedPreview = encryptPrivateText(
    messagePreview(kind, text, link), `conversation:${conversationId}:preview`, env
  );
  const message = {
    id: messageId, conversationId, senderUid: uid, recipientUid: friendUid,
    kind, text: storedText, link: storedLink, cardId, createdAt: 0, readAt: 0
  };
  const conversations = collection(env, 'Conversation');
  const committed = await conversations.runTransaction({
    apply: async (transaction) => {
      const profiles = await pairProfiles(transaction, uid, friendUid, env, true);
      const relationships = await transaction.executeQuery(collection(env, 'Friendship').query()
        .equalTo('id', socialPairId('friend', uid, friendUid)).limit(1));
      const relationship = relationships[0];
      if (!relationship || relationship.status !== 'ACCEPTED' ||
          relationship.memberAUid !== pair.memberAUid || relationship.memberBUid !== pair.memberBUid) {
        throw accessError('好友关系已变化，不能发送消息。', 'CONFLICT');
      }
      const rows = await transaction.executeQuery(conversations.query().equalTo('id', conversationId).limit(1));
      const existing = rows[0] && Number(rows[0].createdAt || 0) >= Number(relationship.createdAt || 0) ? rows[0] : null;
      if (kind === 'CARD') {
        const cardRows = await transaction.executeQuery(collection(env, 'FoodCard').query().equalTo('id', cardId).limit(1));
        const policy = transactionPolicy(transaction, env, profiles);
        await policy.assertCardReadable(uid, cardRows[0]);
        await policy.assertCardReadable(friendUid, cardRows[0]);
      }
      const now = logicalWriteTime(...profiles.map((profile) => profile.updatedAt), relationship.updatedAt,
        existing && existing.lastMessageAt);
      message.createdAt = now;
      const unreadA = Number(existing && existing.unreadA || 0) + (friendUid === pair.memberAUid ? 1 : 0);
      const unreadB = Number(existing && existing.unreadB || 0) + (friendUid === pair.memberBUid ? 1 : 0);
      const conversation = {
        id: conversationId,
        memberAUid: pair.memberAUid,
        memberBUid: pair.memberBUid,
        lastMessageId: message.id,
        lastMessageKind: kind,
        lastMessagePreview: storedPreview,
        lastMessageAt: now,
        unreadA: Math.min(999, unreadA),
        unreadB: Math.min(999, unreadB),
        createdAt: existing ? Number(existing.createdAt || now) : now,
        updatedAt: now
      };
      transaction.executeUpsert([Object.assign(new ChatMessage(), message)]);
      transaction.executeUpsert([Object.assign(new Conversation(), conversation)]);
      transaction.executeUpsert(profiles.map((profile) => profileForWrite(profile, now)));
      return true;
    }
  });
  if (!committed) throw new Error('消息发送未完成，请重试。');
  await sendSocialPush(friendUid, uid, 'DIRECT_MESSAGE', uid, env);
  return { message: await publicMessage(message, uid, env) };
}

// list-conversations：会话列表。
async function listConversations(uid, payload, env) {
  const page = socialPage(payload);
  const conversations = collection(env, 'Conversation');
  const [asMemberA, asMemberB, relationships] = await Promise.all([
    queryAllRows(() => conversations.query().equalTo('memberAUid', uid)),
    queryAllRows(() => conversations.query().equalTo('memberBUid', uid)),
    friendshipRowsFor(uid, env)
  ]);
  const acceptedRowsByUid = new Map();
  for (const relationship of relationships) {
    if (String(relationship.status || '') !== 'ACCEPTED') continue;
    const friendUid = String(relationship.memberAUid || '') === uid
      ? String(relationship.memberBUid || '') : String(relationship.memberAUid || '');
    if (friendUid) acceptedRowsByUid.set(friendUid, relationship);
  }
  const rows = uniqueRows([...asMemberA, ...asMemberB]).filter((row) => {
    const friendUid = String(row.memberAUid || '') === uid
      ? String(row.memberBUid || '') : String(row.memberAUid || '');
    const relationship = acceptedRowsByUid.get(friendUid);
    return !!relationship && Number(row.createdAt || 0) >= Number(relationship.createdAt || 0);
  });
  rows.sort((first, second) => Number(second.lastMessageAt || 0) - Number(first.lastMessageAt || 0));
  const pageRows = rows.slice(page.offset, page.offset + page.pageSize);
  const friendsByUid = await socialUsersByUid(pageRows.map((row) =>
    String(row.memberAUid || '') === uid ? String(row.memberBUid || '') : String(row.memberAUid || '')),
  uid, env, acceptedRowsByUid);
  const output = [];
  for (const row of pageRows) {
    const friendUid = String(row.memberAUid || '') === uid
      ? String(row.memberBUid || '') : String(row.memberAUid || '');
    const friend = friendsByUid.get(friendUid);
    if (!friend) continue;
    output.push({
      id: String(row.id || ''),
      friend,
      lastMessageKind: row.lastMessageKind === 'MEAL_POLL' ? 'TEXT' : String(row.lastMessageKind || 'TEXT'),
      lastMessagePreview: String(row.lastMessageKind || '') === 'CARD' ? '分享了一张美食推荐' : decryptPrivateText(
        row.lastMessagePreview, `conversation:${String(row.id || '')}:preview`, env
      ),
      lastMessageAt: Number(row.lastMessageAt || 0),
      unreadCount: uid === String(row.memberAUid || '')
        ? Number(row.unreadA || 0) : Number(row.unreadB || 0)
    });
  }
  const unreadCount = rows.reduce((sum, row) => sum + (uid === String(row.memberAUid || '')
    ? Number(row.unreadA || 0) : Number(row.unreadB || 0)), 0);
  return {
    conversations: output,
    unreadCount,
    nextPageToken: page.offset + page.pageSize < rows.length ? String(page.offset + page.pageSize) : ''
  };
}

// list-messages：分页读取消息（并清零未读）。
async function listMessages(uid, payload, env) {
  const friendUid = String(payload.friendUid || '');
  const relationship = await requireFriend(uid, friendUid, env);
  const conversationId = socialPairId('conversation', uid, friendUid);
  const requestedSize = Number(payload.pageSize || MAX_MESSAGE_PAGE_SIZE);
  const pageSize = Math.floor(Math.min(MAX_MESSAGE_PAGE_SIZE, Math.max(1, requestedSize)));
  const before = Number(payload.beforeToken || 0);
  let query = collection(env, 'ChatMessage').query().equalTo('conversationId', conversationId)
    .greaterThanOrEqualTo('createdAt', Number(relationship.createdAt || 0));
  if (Number.isFinite(before) && before > 0) query = query.lessThan('createdAt', before);
  const rows = await query.orderByDesc('createdAt').limit(pageSize).get();
  const chronological = rows.slice().reverse();
  const messages = [];
  for (const row of chronological) messages.push(await publicMessage(row, uid, env));
  const unread = rows.filter((row) => String(row.recipientUid || '') === uid && Number(row.readAt || 0) === 0);
  if (unread.length > 0) {
    const messageStore = collection(env, 'ChatMessage');
    const conversations = collection(env, 'Conversation');
    const readAt = Date.now();
    const committed = await conversations.runTransaction({
      apply: async (transaction) => {
        const relationships = await transaction.executeQuery(collection(env, 'Friendship').query()
          .equalTo('id', String(relationship.id)).limit(1));
        const currentRelationship = relationships[0];
        if (!currentRelationship || currentRelationship.status !== 'ACCEPTED' ||
            Number(currentRelationship.createdAt) !== Number(relationship.createdAt)) {
          throw accessError('好友关系已变化，请刷新会话。', 'CONFLICT');
        }
        const currentRows = await transaction.executeQuery(messageStore.query()
          .in('id', unread.map((row) => row.id)).limit(unread.length));
        const conversationRows = await transaction.executeQuery(conversations.query()
          .equalTo('id', conversationId).limit(1));
        const newlyRead = currentRows.filter((row) => Number(row.createdAt || 0) >= Number(currentRelationship.createdAt || 0) &&
          String(row.conversationId || '') === conversationId &&
          String(row.recipientUid || '') === uid && Number(row.readAt || 0) === 0);
        if (newlyRead.length === 0) return true;
        transaction.executeUpsert(newlyRead.map((row) => Object.assign(new ChatMessage(), row, { readAt })));
        if (conversationRows.length > 0) {
          const conversation = conversationRows[0];
          const unreadField = String(conversation.memberAUid || '') === uid ? 'unreadA' :
            String(conversation.memberBUid || '') === uid ? 'unreadB' : '';
          if (unreadField) {
            const updated = Object.assign(new Conversation(), conversation, {
              [unreadField]: Math.max(0, Number(conversation[unreadField] || 0) - newlyRead.length)
            });
            transaction.executeUpsert([updated]);
          }
        }
        return true;
      }
    });
    if (!committed) throw new Error('消息已读状态更新未完成，请重试。');
  }
  return {
    messages,
    nextBeforeToken: rows.length === pageSize && chronological.length > 0
      ? String(chronological[0].createdAt || '') : ''
  };
}

// 【分区 17：群聊】群成员行主键。
function groupMemberId(groupId, memberUid) {
  const normalizedGroupId = String(groupId || '');
  const normalizedMemberUid = String(memberUid || '');
  if (!normalizedGroupId || !normalizedMemberUid) throw new Error('群聊成员信息不完整。');
  return crypto.createHash('sha256')
    .update(`group-member:${normalizedGroupId}:${normalizedMemberUid}`)
    .digest('hex');
}

// 校验群消息类型。
function groupMessageKind(value) {
  const kind = String(value || '');
  if (kind !== 'TEXT' && kind !== 'CARD') throw new Error('群聊仅支持文字和美食卡片。');
  return kind;
}

// 读取群成员。
async function groupMembersFor(groupId, env) {
  return queryAllRows(() => collection(env, 'GroupMember').query().equalTo('groupId', String(groupId || '')));
}

// 断言当前用户是群成员。
async function requireGroupMember(uid, groupId, env) {
  const normalizedGroupId = String(groupId || '');
  const membership = await one(collection(env, 'GroupMember').query()
    .equalTo('id', groupMemberId(normalizedGroupId, uid)));
  if (!membership || String(membership.memberUid || '') !== uid) {
    throw new Error('你不在这个群聊中，或群聊已不存在。');
  }
  const group = await one(collection(env, 'GroupConversation').query().equalTo('id', normalizedGroupId));
  if (!group) throw new Error('群聊不存在或已解散。');
  await contentPolicy(env).assertAccountActive(uid);
  await contentPolicy(env).assertAccountActive(String(group.ownerUid || ''));
  return { group, membership };
}

// 群会话的返回视图。
async function publicGroupConversation(row, membership, env) {
  const groupId = String(row.id || '');
  const lastMessage = row.lastMessageId ? await one(collection(env, 'GroupMessage').query().equalTo('id', String(row.lastMessageId))) : null;
  const lastSender = lastMessage ? await one(collection(env, 'UserProfile').query().equalTo('uid', String(lastMessage.senderUid))) : null;
  const previewAllowed = !!lastMessage && isAccountActive(lastSender);
  return {
    id: groupId,
    name: String(row.name || '群聊'),
    ownerUid: String(row.ownerUid || ''),
    memberCount: Number(row.memberCount || 0),
    lastMessageKind: row.lastMessageKind === 'MEAL_POLL' ? 'TEXT' : String(row.lastMessageKind || 'TEXT'),
    lastMessagePreview: !previewAllowed ? '消息已不可访问' : String(row.lastMessageKind || '') === 'CARD' ? '分享了一张美食推荐' : decryptPrivateText(
      row.lastMessagePreview, `group-conversation:${groupId}:preview`, env
    ),
    lastMessageAt: Number(row.lastMessageAt || 0),
    unreadCount: Number(membership && membership.unreadCount || 0)
  };
}

// create-group-chat：创建群聊（成员必须是好友）。
async function createGroupChat(uid, payload, env) {
  const name = String(payload.name || '').trim();
  if (name.length < 1 || name.length > MAX_GROUP_NAME_LENGTH) {
    throw new Error(`群聊名称需为 1–${MAX_GROUP_NAME_LENGTH} 个字符。`);
  }
  const memberUids = [];
  const seen = new Set([uid]);
  for (const value of Array.isArray(payload.memberUids) ? payload.memberUids : []) {
    const memberUid = String(value || '').trim();
    if (memberUid && !seen.has(memberUid)) {
      seen.add(memberUid);
      memberUids.push(memberUid);
    }
  }
  if (memberUids.length < MIN_GROUP_FRIENDS) {
    throw new Error(`请至少选择 ${MIN_GROUP_FRIENDS} 位好友创建群聊。`);
  }
  if (memberUids.length + 1 > MAX_GROUP_MEMBERS) {
    throw new Error(`一个群聊最多 ${MAX_GROUP_MEMBERS} 位成员。`);
  }
  const relationships = await relationshipRowsByTargetUid(uid, memberUids, env);
  for (const memberUid of memberUids) {
    const row = relationships.get(memberUid);
    if (!row || String(row.status || '') !== 'ACCEPTED') {
      throw new Error('只能邀请当前互为好友的用户加入群聊。');
    }
  }
  const now = Date.now();
  const id = crypto.randomUUID();
  const group = {
    id,
    ownerUid: uid,
    name,
    memberCount: memberUids.length + 1,
    lastMessageId: '',
    lastMessageKind: 'TEXT',
    lastMessagePreview: encryptPrivateText('', `group-conversation:${id}:preview`, env),
    lastMessageAt: now,
    createdAt: now,
    updatedAt: now
  };
  const memberRows = [{
    id: groupMemberId(id, uid), groupId: id, memberUid: uid, role: 'OWNER',
    unreadCount: 0, joinedAt: now, updatedAt: now
  }];
  for (const memberUid of memberUids) {
    memberRows.push({
      id: groupMemberId(id, memberUid), groupId: id, memberUid, role: 'MEMBER',
      unreadCount: 0, joinedAt: now, updatedAt: now
    });
  }
  const committed = await collection(env, 'GroupConversation').runTransaction({
    apply: async (transaction) => {
      const profiles = [];
      for (const memberUid of [uid, ...memberUids].sort()) profiles.push(await stage1.activeProfile(transaction, memberUid, env));
      for (const memberUid of memberUids) {
        const relation = await stage1.txOne(transaction, env, 'Friendship', 'id', socialPairId('friend', uid, memberUid));
        if (!relation || relation.status !== 'ACCEPTED') throw accessError('邀请关系已变化，请刷新。', 'CONFLICT');
      }
      const writeAt = logicalWriteTime(...profiles.map((profile) => profile.updatedAt));
      transaction.executeUpsert(profiles.map((profile) => profileForWrite(profile, writeAt)));
      transaction.executeUpsert([Object.assign(new GroupConversation(), group)]);
      transaction.executeUpsert(memberRows.map((row) => Object.assign(new GroupMember(), row)));
      return true;
    }
  });
  if (!committed) throw new Error('群聊创建未完成，请重试。');
  return { group: await publicGroupConversation(group, { unreadCount: 0 }, env) };
}

// list-group-conversations。
async function listGroupConversations(uid, payload, env) {
  const page = socialPage(payload);
  const memberships = await queryAllRows(() => collection(env, 'GroupMember').query().equalTo('memberUid', uid));
  const membershipsByGroupId = new Map();
  for (const membership of memberships) {
    const groupId = String(membership.groupId || '');
    if (groupId) membershipsByGroupId.set(groupId, membership);
  }
  const groupsById = new Map();
  const groupIds = [...membershipsByGroupId.keys()];
  for (let start = 0; start < groupIds.length; start += SOCIAL_PROFILE_QUERY_BATCH_SIZE) {
    const idBatch = groupIds.slice(start, start + SOCIAL_PROFILE_QUERY_BATCH_SIZE);
    if (idBatch.length === 0) continue;
    const rows = await collection(env, 'GroupConversation').query().in('id', idBatch).limit(idBatch.length).get();
    for (const row of rows) groupsById.set(String(row.id || ''), row);
  }
  const rows = [];
  for (const row of groupsById.values()) {
    const owner = await one(collection(env, 'UserProfile').query().equalTo('uid', String(row.ownerUid || '')));
    if (isAccountActive(owner)) rows.push(row);
  }
  rows.sort((first, second) => Number(second.lastMessageAt || 0) - Number(first.lastMessageAt || 0));
  const pageRows = rows.slice(page.offset, page.offset + page.pageSize);
  const groups = await Promise.all(pageRows.map((row) => publicGroupConversation(
    row, membershipsByGroupId.get(String(row.id || '')), env)));
  const unreadCount = rows.reduce((sum, row) => sum + Number(
    membershipsByGroupId.get(String(row.id || '')) &&
    membershipsByGroupId.get(String(row.id || '')).unreadCount || 0
  ), 0);
  return {
    groups,
    unreadCount,
    nextPageToken: page.offset + page.pageSize < rows.length ? String(page.offset + page.pageSize) : ''
  };
}

// get-group-chat：群资料与成员。
async function getGroupChat(uid, payload, env) {
  const groupId = String(payload.groupId || '');
  const { group } = await requireGroupMember(uid, groupId, env);
  const memberships = await groupMembersFor(groupId, env);
  const usersByUid = await socialUsersByUid(memberships.map((row) => String(row.memberUid || '')), uid, env);
  const members = [];
  for (const membership of memberships) {
    const user = usersByUid.get(String(membership.memberUid || ''));
    if (!user) continue;
    members.push({
      user,
      role: String(membership.role || 'MEMBER'),
      joinedAt: Number(membership.joinedAt || 0)
    });
  }
  members.sort((first, second) => first.role === second.role
    ? first.user.nickname.localeCompare(second.user.nickname)
    : first.role === 'OWNER' ? -1 : 1);
  return { group: await publicGroupConversation(group, { unreadCount: 0 }, env), members };
}

// 群消息的返回视图。
async function publicGroupMessage(row, viewerUid, env, clientVersion = 1) {
  const messageId = String(row.id || '');
  const sender = await socialUserByUid(String(row.senderUid || ''), viewerUid, env);
  const output = {
    id: messageId,
    groupId: String(row.groupId || ''),
    sender,
    mine: String(row.senderUid || '') === viewerUid,
    kind: row.kind === 'MEAL_POLL' ? clientVersion >= 2 ? 'MEAL_POLL' : 'TEXT' : groupMessageKind(row.kind),
    text: row.kind === 'MEAL_POLL' ? '选餐投票，请升级查看' : sender ? decryptPrivateText(row.text, `group-message:${messageId}:text`, env) : '',
    referenceId: row.kind === 'MEAL_POLL' && clientVersion >= 2 ? String(row.referenceId || '') : '',
    cardId: sender ? String(row.cardId || '') : '',
    createdAt: Number(row.createdAt || 0)
  };
  if (output.kind === 'CARD' && output.cardId) {
    const card = await one(collection(env, 'FoodCard').query().equalTo('id', output.cardId));
    const sharedCard = await readCardIfAllowed(card, env, 0, true, viewerUid, false);
    if (sharedCard) output.sharedCard = sharedCard;
  }
  return output;
}

// list-group-messages。
async function listGroupMessages(uid, payload, env) {
  const groupId = String(payload.groupId || '');
  const { membership } = await requireGroupMember(uid, groupId, env);
  const requestedSize = Number(payload.pageSize || MAX_MESSAGE_PAGE_SIZE);
  const pageSize = Math.floor(Math.min(MAX_MESSAGE_PAGE_SIZE, Math.max(1, requestedSize)));
  const before = Number(payload.beforeToken || 0);
  let query = collection(env, 'GroupMessage').query().equalTo('groupId', groupId);
  if (Number.isFinite(before) && before > 0) query = query.lessThan('createdAt', before);
  const rows = await query.orderByDesc('createdAt').limit(pageSize).get();
  const chronological = rows.slice().reverse();
  const messages = [];
  for (const row of chronological) messages.push(await publicGroupMessage(row, uid, env, Number(payload.clientVersion || 1)));
  if (Number(membership.unreadCount || 0) > 0) {
    membership.unreadCount = 0;
    membership.updatedAt = Date.now();
    await collection(env, 'GroupMember').upsert(membership);
  }
  return {
    messages,
    nextBeforeToken: rows.length === pageSize && chronological.length > 0
      ? String(chronological[0].createdAt || '') : ''
  };
}

// send-group-message（正文加密，更新成员未读数，发送通知）。
async function sendGroupMessage(uid, payload, env) {
  const groupId = String(payload.groupId || '');
  await requireGroupMember(uid, groupId, env);
  const kind = groupMessageKind(payload.kind);
  let text = String(payload.text || '').trim();
  let cardId = String(payload.cardId || '').trim();
  if (kind === 'TEXT') {
    if (text.length === 0 || text.length > MAX_MESSAGE_LENGTH) {
      throw new Error(`消息需为 1–${MAX_MESSAGE_LENGTH} 个字符。`);
    }
    cardId = '';
  } else {
    const card = await one(collection(env, 'FoodCard').query().equalTo('id', cardId));
    await contentPolicy(env).assertCardReadable(uid, card);
    text = '';
  }
  const now = Date.now();
  const messageId = crypto.randomUUID();
  const message = {
    id: messageId,
    groupId,
    senderUid: uid,
    kind,
    text: encryptPrivateText(text, `group-message:${messageId}:text`, env),
    cardId,
    createdAt: now
  };
  const storedPreview = encryptPrivateText(
    messagePreview(kind, text, ''), `group-conversation:${groupId}:preview`, env
  );
  const groups = collection(env, 'GroupConversation');
  const members = collection(env, 'GroupMember');
  let recipientUids = [];
  const committed = await groups.runTransaction({
    apply: async (transaction) => {
      const groupRows = await transaction.executeQuery(groups.query().equalTo('id', groupId).limit(1));
      const memberships = await transaction.executeQuery(members.query().equalTo('groupId', groupId)
        .limit(MAX_GROUP_MEMBERS + 1));
      if (groupRows.length === 0 || memberships.length > MAX_GROUP_MEMBERS ||
        !memberships.some((membership) => String(membership.memberUid || '') === uid)) {
        throw new Error('你不在这个群聊中，或群聊已不存在。');
      }
      const senderProfile = await stage1.activeProfile(transaction, uid, env);
      const ownerUid = String(groupRows[0].ownerUid || '');
      const ownerProfile = ownerUid === uid ? senderProfile : await stage1.activeProfile(transaction, ownerUid, env);
      if (kind === 'CARD') {
        const sharedCard = await stage1.txOne(transaction, env, 'FoodCard', 'id', cardId);
        await transactionPolicy(transaction, env, [senderProfile, ownerProfile]).assertCardReadable(uid, sharedCard);
      }
      const group = Object.assign(new GroupConversation(), groupRows[0], {
        lastMessageId: messageId,
        lastMessageKind: kind,
        lastMessagePreview: storedPreview,
        lastMessageAt: now,
        updatedAt: now
      });
      const recipients = memberships.filter((membership) => String(membership.memberUid || '') !== uid);
      const updatedMembers = recipients.map((membership) => Object.assign(new GroupMember(), membership, {
        unreadCount: Math.min(999, Number(membership.unreadCount || 0) + 1),
        updatedAt: now
      }));
      transaction.executeUpsert([Object.assign(new GroupMessage(), message)]);
      const writeAt = logicalWriteTime(senderProfile.updatedAt, ownerProfile.updatedAt);
      transaction.executeUpsert([profileForWrite(senderProfile, writeAt)]);
      if (ownerUid !== uid) transaction.executeUpsert([profileForWrite(ownerProfile, writeAt)]);
      transaction.executeUpsert([group]);
      if (updatedMembers.length > 0) transaction.executeUpsert(updatedMembers);
      recipientUids = recipients.map((membership) => String(membership.memberUid || ''));
      return true;
    }
  });
  if (!committed) throw new Error('群消息发送未完成，请重试。');
  await Promise.all(recipientUids.map((recipientUid) => sendSocialPush(recipientUid, uid,
      'GROUP_MESSAGE', groupId, env)));
  return { message: await publicGroupMessage(message, uid, env) };
}

// leave-group-chat：退出（群主退出时转让或解散）。
async function leaveGroupChat(uid, payload, env) {
  const groupId = String(payload.groupId || '');
  const groups = collection(env, 'GroupConversation');
  const members = collection(env, 'GroupMember');
  const committed = await groups.runTransaction({
    apply: async (transaction) => {
      const groupRows = await transaction.executeQuery(groups.query().equalTo('id', groupId).limit(1));
      const memberships = await transaction.executeQuery(members.query().equalTo('groupId', groupId)
        .limit(MAX_GROUP_MEMBERS + 1));
      const membership = memberships.find((row) => String(row.memberUid || '') === uid);
      if (groupRows.length === 0 || !membership) throw new Error('你不在这个群聊中，或群聊已不存在。');
      if (String(membership.role || '') === 'OWNER') throw new Error('群主请先转让群聊或解散群聊。');
      if (memberships.length <= 2 || memberships.length > MAX_GROUP_MEMBERS) {
        throw new Error('群聊至少保留两位成员。');
      }
      transaction.executeDelete([Object.assign(new GroupMember(), membership)]);
      transaction.executeUpsert([Object.assign(new GroupConversation(), groupRows[0], {
        memberCount: memberships.length - 1,
        updatedAt: Date.now()
      })]);
      return true;
    }
  });
  if (!committed) throw new Error('退出群聊未完成，请重试。');
  return { success: true };
}

// remove-group-member：群主移除成员。
async function removeGroupMember(uid, payload, env) {
  const groupId = String(payload.groupId || '');
  const memberUid = String(payload.memberUid || '');
  if (!memberUid || memberUid === uid) throw new Error('群主不能移除自己。');
  const groups = collection(env, 'GroupConversation');
  const members = collection(env, 'GroupMember');
  const committed = await groups.runTransaction({
    apply: async (transaction) => {
      const groupRows = await transaction.executeQuery(groups.query().equalTo('id', groupId).limit(1));
      const memberships = await transaction.executeQuery(members.query().equalTo('groupId', groupId)
        .limit(MAX_GROUP_MEMBERS + 1));
      const owner = memberships.find((row) => String(row.memberUid || '') === uid);
      if (groupRows.length === 0 || !owner) throw new Error('你不在这个群聊中，或群聊已不存在。');
      if (String(owner.role || '') !== 'OWNER') throw new Error('只有群主可以移除成员。');
      const target = memberships.find((row) => String(row.memberUid || '') === memberUid);
      if (!target) throw new Error('该成员不在当前群聊中。');
      if (memberships.length <= 2 || memberships.length > MAX_GROUP_MEMBERS) {
        throw new Error('群聊至少保留两位成员。');
      }
      transaction.executeDelete([Object.assign(new GroupMember(), target)]);
      transaction.executeUpsert([Object.assign(new GroupConversation(), groupRows[0], {
        memberCount: memberships.length - 1,
        updatedAt: Date.now()
      })]);
      return true;
    }
  });
  if (!committed) throw new Error('移除群成员未完成，请重试。');
  return { success: true };
}

// 【分区 18】delete-own-card：软删除自己的卡片。
async function deleteOwnCard(uid, payload, env) {
  return stage1.softDelete(uid, payload, env);
}

// delete-account-data：开始注销账号（停用账号并创建后台清理任务）。
async function cleanupAccount(uid, env, accessToken = '') {
  const providerUid=accessToken ? await verifiedAgcUid(accessToken) : '';
  const credential=accessToken ? encryptPrivateText(accessToken,'delete-account:'+uid,env) : '';
  const result=await stage1.beginAccountDeletion(uid,env);
  if(credential) await collection(env,'MaintenanceJob').runTransaction({apply:async tx=>{
    const job=await stage1.txOne(tx,env,'MaintenanceJob','jobId',result.jobId);
    if(job && job.jobType==='DELETE_ACCOUNT' && job.entityId===uid && job.status!=='DONE') stage1.upsertRows(tx,[Object.assign(new MaintenanceJob(),job,{authCredentialCiphertext:credential,authProviderUid:providerUid,updatedAt:new Date()})]);
    return true;
  }});
  return result;
}

// 注销专用的身份校验（允许对已停用的绑定重试，用于响应丢失后的重试）。
async function verifiedDeletionUid(accessToken, env) {
  // 只有注销入口可以在“响应丢失后重试”时解析已停用的绑定；它不能创建资料，也不能重新启用账号。
  const providerUid = await verifiedAgcUid(accessToken);
  const binding = await identityBinding('AGC', providerUid, env);
  const canonicalUid = binding ? String(binding.canonicalUid || providerUid) : providerUid;
  forgetIdentity(canonicalUid);
  return canonicalUid;
}

// 【分区 19：子模块装配】把本文件的公共函数作为 ctx 注入各子模块（依赖注入，便于测试）。
const nicknameAuth = require('./nickname-auth').createNicknameAuth({ collection, one, models: OBJECT_TYPES, cloud,
  verifiedIdentity, profileForWrite, profileResponse, identityBindingId, logicalWriteTime,
  requestId: () => readRequestScope.getStore() || '' });

const stage1 = require('./stage1-services').createStage1Services({
  collection, one, transactionPolicy, contentPolicy, profileForWrite, logicalWriteTime,
  validateCard, uniqueMediaIds, promotePendingMedia, refreshPublishCount, actionId, safeArray,
  recoveryPeriod: env => String(env.SHIKE_ENVIRONMENT || '') === 'test' && Number.isSafeInteger(Number(env.SHIKE_TEST_RECOVERY_SECONDS)) && Number(env.SHIKE_TEST_RECOVERY_SECONDS) >= 30 && Number(env.SHIKE_TEST_RECOVERY_SECONDS) <= 86400 ? Number(env.SHIKE_TEST_RECOVERY_SECONDS) * 1000 : 30 * 86400000,
  personalized: PERSONALIZED, models: OBJECT_TYPES, stage2: () => stage2, collections: () => personalCollections, publicCard
});

const stage2 = require('./stage2-services').createStage2Services({
  collection, one, models: OBJECT_TYPES, profileForWrite, logicalWriteTime, contentPolicy
});

const stage3 = require('./stage3-services').createStage3Services({
  collection, one, models: OBJECT_TYPES, contentPolicy, readableCardRows, readCardIfAllowed, finalizeCardReads, createCardReadContext, preparePrimaryPhotos, previewCard, withReadPhase, recordReadReadiness, stage1: () => stage1
});


const stages47Context = { collection, one, models: OBJECT_TYPES, contentPolicy, transactionPolicy, readableCardRows,
  readCardIfAllowed, finalizeCardReads, createCardReadContext, preparePrimaryPhotos, readCardRowsByIds, readMerchantRowsByIds, withReadPhase, recordReadCounts,
  profileForWrite, logicalWriteTime, actionId, socialPairId, friendshipRowsFor, friendshipBetween,
  encryptPrivateText, decryptPrivateText, profileResponse, previewCard, publicPhotos, collections: () => personalCollections,
  stage1: () => stage1, stage2: () => stage2,
  stage3: () => stage3, foodRankings: () => foodRankings
};
const personalCollections = require('./personal-collections').createPersonalCollections(stages47Context);
const cardInteractions = require('./card-interaction-services').createCardInteractionServices(stages47Context);
const stage6 = require('./stage6-services').createStage6Services(stages47Context);
const randomFood = require('./random-food-services').createRandomFoodServices(stages47Context);
const foodRankings = require('./food-ranking-services').createFoodRankingServices(stages47Context);
const stage7 = require('./stage7-services').createStage7Services(stages47Context);

const authenticationCleanup = require('./authentication-cleanup').createAuthenticationCleanup({ decryptPrivateText, verifiedAgcUid });
const contentLifecycleContext = { ...stages47Context, refreshPublishCount,
  legacyReportId: (uid,cardId) => crypto.createHash('sha256').update(uid+':'+cardId).digest('hex'),
  removeMediaFiles: async (media,env) => { const owner=media.storageUid||media.ownerUid; await callMedia('remove',{keys:[pendingObjectKey(owner,media.id),approvedObjectKey(owner,media.id)]},env); },
  deleteAuthentication: (job,binding,env) => authenticationCleanup.remove(job,binding,env),
  processLegacyJob: async (job,env) => job.jobType==='PURGE_CONVERSATION' ? processFriendCleanup(job.jobId,env) : stage1.processMigration({jobId:job.jobId},env)
};
const cardReports = require('./card-report-services').createCardReportServices(contentLifecycleContext);
const lifecycle = require('./lifecycle-services').createLifecycleServices(contentLifecycleContext);
// get-review-media：审核用图片（仅审核员）。
async function getReviewMedia(uid, payload, env) {
  return require('./shared/image-reader').readLegacy({ ...payload, viewerUid: uid, mode: 'REVIEW', variant: 'ORIGINAL' }, env);
}

// 【分区 20：操作表】键 = 客户端操作名，值 = 处理函数（入参 { accessToken, payload }）。verifiedUid(token, env, true) 的第三个参数表示只读（可用身份缓存）。
const operations = {
  // --- 昵称账号 ---
  'get-password-account': async ({ accessToken }, env) => nicknameAuth.status(accessToken, env),
  'configure-password-account': async ({ accessToken, payload }, env) => nicknameAuth.configure(accessToken, payload, env),
  'change-password-account': async ({ accessToken, payload }, env) => nicknameAuth.changePassword(accessToken, payload, env),
  'login-with-nickname': async ({ payload }, env) => nicknameAuth.login(payload, env),
  'logout-nickname': async ({ accessToken }, env) => nicknameAuth.logout(accessToken, env),
  // --- 举报与审核 ---
  'get-card-report-access': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return cardReports.access(uid,env,false); },
  'get-card-report-context': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return cardReports.context(uid,payload,env); },
  'submit-card-report': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return cardReports.submit(uid,payload,env); },
  'list-my-card-reports': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return cardReports.list(uid,payload,env); },
  'get-my-card-report': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return cardReports.detail(uid,payload,env); },
  'list-card-review-reports': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return cardReports.list(uid,payload,env,true); },
  'get-card-review-report': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return cardReports.detail(uid,payload,env,true); },
  'resolve-card-report': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return cardReports.resolve(uid,payload,env); },

  // --- 删除记录 / 审核图片 / 收藏 ---
  'list-deleted-cards': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return lifecycle.deleted(uid,payload,env); },
  'restore-deleted-card': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return lifecycle.restore(uid,payload,env); },
  'get-review-media': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return getReviewMedia(uid,payload,env); },
  'get-card-previews': async ({ accessToken, payload }, env) => { const uid = accessToken ? await verifiedUid(accessToken, env, true) : ''; return personalCollections.previews(uid,payload,env); },
  'list-personal-collection': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env, true); return personalCollections.list(uid,payload,env); },
  'get-personal-collection-migration': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env, true); return personalCollections.status(uid,env); },
  'start-personal-collection-migration': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return personalCollections.start(uid,env); },
  'resume-personal-collection-migration': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return personalCollections.resume(uid,payload,env); },
  // --- 卡片互动 ---
  'get-card-interaction-state': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env, true); return cardInteractions.state(uid, payload, env); },
  'set-card-interaction': async ({ accessToken, payload, readRequestId }, env) => {
    const started = Date.now(); const uid = await verifiedUid(accessToken, env);
    console.info('[CardInteractionCloud] requestId=' + readRequestId + ' stage=authenticated elapsedMs=' + (Date.now() - started));
    return cardInteractions.set(uid, payload, env);
  },
  'get-card-interaction-receipt': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env, true); return cardInteractions.receipt(uid, payload, env); },
  'get-card-interaction-counts': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env, true); return cardInteractions.counts(uid, payload, env); },
  'set-card-favorite': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return personalCollections.set(uid,payload,env,'FAVORITE'); },
  // --- 今日吃什么 ---
  'get-random-food-pool': async ({ accessToken, payload }, env) => { const uid = accessToken ? await verifiedUid(accessToken, env, true) : ''; return randomFood.pool(uid,payload,env); },
  'get-random-food-cards': async ({ accessToken, payload }, env) => { const uid = accessToken ? await verifiedUid(accessToken, env, true) : ''; return randomFood.cards(uid,payload,env); },
  'save-food-choice': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return randomFood.saveChoice(uid,payload,env); },
  'list-food-choices': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return randomFood.history(uid,payload,env); },
  'delete-food-choice': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return randomFood.deleteChoice(uid,payload,env); },
  // --- 群投票 ---
  'get-meal-candidates': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env, true); return stage6.candidates(uid,payload,env); },
  'create-meal-poll': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage6.createPoll(uid,payload,env); },
  'get-meal-poll': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage6.getPoll(uid,payload,env); },
  'add-meal-poll-option': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage6.mutatePoll(uid,payload,env,'ADD'); },
  'vote-meal-poll': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage6.mutatePoll(uid,payload,env,'VOTE'); },
  'close-meal-poll': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage6.mutatePoll(uid,payload,env,'CLOSE'); },
  'cancel-meal-poll': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage6.mutatePoll(uid,payload,env,'CANCEL'); },
  'stop-meal-poll-options': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage6.mutatePoll(uid,payload,env,'STOP'); },
  // --- 用户主页 / 榜单 / 赞踩 ---
  'get-user-page': async ({ accessToken, payload }, env) => { const uid = accessToken ? await verifiedUid(accessToken, env, true) : ''; return stage7.userPage(uid,payload,env); },
  'list-food-rankings': async ({ accessToken, payload }, env) => { const uid = accessToken ? await verifiedUid(accessToken, env, true) : ''; return foodRankings.list(uid,payload,env); },
  'set-card-reaction-v2': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage7.reaction(uid,payload,env); },
  // --- 发现（地图、搜索、店铺推荐）---
  'get-discovery-capabilities': async ({ accessToken }, env) => {
    if (accessToken) await verifiedUid(accessToken, env, true);
    return stage3.capabilities(env);
  },
  'list-map-merchants': async ({ accessToken, payload }, env) => stage3.listMapMerchants(accessToken ? await verifiedUid(accessToken, env, true) : '', payload, env),
  'search-public-cards': async ({ accessToken, payload }, env) => (!accessToken && !payload.cursor)
    ? guestFirstPage('search-public-cards', payload, () => stage3.searchPublicCards('', payload, env))
    : stage3.searchPublicCards(accessToken ? await verifiedUid(accessToken, env, true) : '', payload, env),
  'get-merchant-recommendations': async ({ accessToken, payload }, env) => stage3.getMerchantRecommendations(accessToken ? await verifiedUid(accessToken, env, true) : '', payload, env),
  // --- 店铺 ---
  'get-stage2-capabilities': async ({ accessToken }, env) => { await verifiedUid(accessToken, env); return stage2.capabilities(env); },
  'resolve-merchant': async ({ accessToken, payload }, env) => stage2.resolveMerchant(await verifiedUid(accessToken, env), payload, env),
  'create-user-merchant': async ({ accessToken, payload }, env) => stage2.createUserMerchant(await verifiedUid(accessToken, env), payload, env),
  'update-user-merchant': async ({ accessToken, payload }, env) => stage2.updateUserMerchant(await verifiedUid(accessToken, env), payload, env),
  'get-merchant': async ({ accessToken, payload }, env) => stage2.getMerchant(await verifiedUid(accessToken, env), payload, env),
  // --- 作者修改 ---
  'get-card-edit-context': async ({ accessToken, payload }, env) => stage1.getEditContext(await verifiedUid(accessToken, env), payload, env),
  'get-revision-media': async ({ accessToken, payload }, env) => getRevisionMedia(await verifiedUid(accessToken, env), payload, env),
  'submit-card-revision': async ({ accessToken, payload }, env) => stage1.submitRevision(await verifiedUid(accessToken, env), payload, env),
  'withdraw-card-revision': async ({ accessToken, payload }, env) => stage1.withdrawRevision(await verifiedUid(accessToken, env), payload, env),
  // --- 登录与资料 ---
  'complete-legacy-login': async ({ accessToken, payload }, env) =>
    completeLegacyLogin(accessToken, payload, env),
  'start-email-binding': async ({ accessToken }, env) => startEmailBinding(accessToken, env),
  'complete-email-binding': async ({ accessToken, payload }, env) =>
    completeEmailBinding(accessToken, payload, env),
  'upsert-profile': async ({ accessToken, payload }, env) => upsertProfile(await verifiedUid(accessToken, env), payload, env),
  // --- 卡片 ---
  'get-public-media': async ({ payload, readRequestId }, env) =>
    getPublicMedia('', { ...payload, readRequestId }, env),
  'publish-card': async ({ accessToken, payload }, env) => publishCard(await verifiedUid(accessToken, env), payload, env),
  // 公开推荐流（客户端固定传 scope=all；按发布位置的旧“附近”接口已下线）。
  'list-nearby-cards': async ({ accessToken, payload }, env) => (!accessToken && !payload.pageToken)
    ? guestFirstPage('list-nearby-cards', payload, () => listPublicRecommendations(payload, env, ''))
    : listPublicRecommendations(payload, env, accessToken ? await verifiedUid(accessToken, env, true) : ''),
  'get-friend-profile': async ({ accessToken, payload }, env) =>
    friendProfile(await verifiedUid(accessToken, env, true), payload, env),
  'get-card-detail': async ({ accessToken, payload }, env) =>
    cardDetail(accessToken ? await verifiedUid(accessToken, env, true) : '', payload, env),
  'list-my-cards': async ({ accessToken }, env) => myCards(await verifiedUid(accessToken, env), env),
  // --- 好友 ---
  'search-users': async ({ accessToken, payload }, env) => searchUsers(await verifiedUid(accessToken, env), payload, env),
  'list-friends': async ({ accessToken, payload }, env) =>
    listFriends(await verifiedUid(accessToken, env), payload, env),
  'send-friend-request': async ({ accessToken, payload }, env) =>
    sendFriendRequest(await verifiedUid(accessToken, env), payload, env),
  'respond-friend-request': async ({ accessToken, payload }, env) =>
    respondFriendRequest(await verifiedUid(accessToken, env), payload, env),
  'cancel-friend-request': async ({ accessToken, payload }, env) =>
    cancelFriendRequest(await verifiedUid(accessToken, env), payload, env),
  'block-user': async ({ accessToken, payload }, env) =>
    blockUser(await verifiedUid(accessToken, env), payload, env),
  'unblock-user': async ({ accessToken, payload }, env) =>
    unblockUser(await verifiedUid(accessToken, env), payload, env),
  'remove-friend': async ({ accessToken, payload }, env) => removeFriend(await verifiedUid(accessToken, env), payload, env),
  // --- 私信 ---
  'list-conversations': async ({ accessToken, payload }, env) =>
    listConversations(await verifiedUid(accessToken, env, true), payload, env),
  'list-messages': async ({ accessToken, payload }, env) => listMessages(await verifiedUid(accessToken, env), payload, env),
  'send-message': async ({ accessToken, payload }, env) => sendMessage(await verifiedUid(accessToken, env), payload, env),
  // --- 群聊 ---
  'create-group-chat': async ({ accessToken, payload }, env) =>
    createGroupChat(await verifiedUid(accessToken, env), payload, env),
  'list-group-conversations': async ({ accessToken, payload }, env) =>
    listGroupConversations(await verifiedUid(accessToken, env, true), payload, env),
  'get-group-chat': async ({ accessToken, payload }, env) =>
    getGroupChat(await verifiedUid(accessToken, env, true), payload, env),
  'list-group-messages': async ({ accessToken, payload }, env) =>
    listGroupMessages(await verifiedUid(accessToken, env), payload, env),
  'send-group-message': async ({ accessToken, payload }, env) =>
    sendGroupMessage(await verifiedUid(accessToken, env), payload, env),
  'leave-group-chat': async ({ accessToken, payload }, env) =>
    leaveGroupChat(await verifiedUid(accessToken, env), payload, env),
  'remove-group-member': async ({ accessToken, payload }, env) =>
    removeGroupMember(await verifiedUid(accessToken, env), payload, env),
  // --- 推送与桌面卡片 ---
  'register-push-device': async ({ accessToken, payload }, env) =>
    registerPushDevice(await verifiedUid(accessToken, env), payload, env),
  'unregister-push-device': async ({ accessToken, payload }, env) =>
    unregisterPushDevice(await verifiedUid(accessToken, env), payload, env),
  'sync-service-card-forms': async ({ accessToken, payload }, env) =>
    syncServiceCardForms(await verifiedUid(accessToken, env), payload, env),
  'unregister-service-card-forms': async ({ accessToken, payload }, env) =>
    unregisterServiceCardForms(await verifiedUid(accessToken, env), payload, env),
  'push-service-card-update': async ({ accessToken, payload }, env) =>
    pushServiceCardUpdate(await verifiedUid(accessToken, env), payload, env),
  // --- 删除与注销 ---
  'delete-own-card': async ({ accessToken, payload }, env) => deleteOwnCard(await verifiedUid(accessToken, env), payload, env),
  'delete-account-data': async ({ accessToken }, env) => cleanupAccount(await verifiedDeletionUid(accessToken, env), env, accessToken)
};

// 【分区 21：入口】执行一个操作：建立请求上下文（操作名、游标签名、卡片读取缓存、请求号、读取计量）后调用 operations 表。
async function executeOperation(operation, input, env = process.env) {
  if (!operations[operation]) throw new Error(`未知操作 ${operation}`);
  const safeInput = input && typeof input === 'object' ? input : {};
  const id = requestId(safeInput);
  return runOperation(operation, () => withCursorContext(env, () => cardReadScope.run(new Map(), () => readRequestScope.run(id, () => withReadMetrics(operation, env || {}, () => operations[operation]({
    accessToken: typeof safeInput.accessToken === 'string' ? safeInput.accessToken : '',
    payload: safeInput.payload && typeof safeInput.payload === 'object' ? safeInput.payload : {}
  }, env || {}), id, safeInput.readAttempt === 2 ? 2 : 1)))));
}

// 一次性的维护动作（维护函数 action=public-content）：每批有上限，可以用同一游标重试；把行改为公开与店铺计数对账都是幂等的。
async function normalizePublicContent(env = process.env, cursor = '') {
  if (typeof cursor !== 'string' || cursor.length > 128) throw accessError('迁移游标无效。', 'VALIDATION_ERROR');
  let query = collection(env, 'FoodCard').query();
  if (cursor) query = query.greaterThan('id', cursor);
  const rows = await query.orderByAsc('id').limit(10).get();
  const merchants = new Set(); let changed = 0;
  for (const row of rows) {
    let updated = false;
    const committed = await collection(env, 'FoodCard').runTransaction({ apply: async tx => {
      updated = false;
      const current = await stage1.txOne(tx, env, 'FoodCard', 'id', row.id);
      if (!current) return true;
      if (current.merchantId) merchants.add(String(current.merchantId));
      if (current.visibility !== 'PUBLIC') {
        // 可见性已不再影响内容版本或发布状态。
        tx.executeUpsert([Object.assign(new FoodCard(), current, { visibility: 'PUBLIC' })]);
        updated = true;
      }
      return true;
    } });
    if (!committed) throw accessError('公开整理未保存，请重试同一游标。', 'CONFLICT');
    if (updated) changed++;
  }
  // 即使行本来就是公开的也要对账，这样上一批失败时不会漏掉计数未提交的店铺。
  for (const merchantId of merchants) await stage2.reconcileMerchantPublicCounters({ merchantId }, env);
  const hasMore = rows.length === 10;
  return { scanned: rows.length, changed, merchantsReconciled: merchants.size,
    nextCursor: hasMore ? String(rows[rows.length - 1].id) : '', hasMore };
}

// 供 shike-maintenance 使用的导出：昵称迁移、公开内容整理、卡片 / 赞历史维护、生命周期 tick，以及 executeOperation、safeLogError。
// 维护动作在独立的请求号与读取计量中执行。
function maintenanceRun(name, env, action) {
  const source = env || process.env, id = crypto.randomUUID();
  return readRequestScope.run(id, () => withReadMetrics(name, source, () => action(source), id));
}
module.exports = { migrateNicknameClaims: env => nicknameAuth.migrate(env || process.env), normalizePublicContent,
  maintainCardHistory: (payload, env) => maintenanceRun('card-history-maintenance', env, source => stage1.cardHistoryMaintenance(payload, source)),
  maintainReactionHistory: (payload, env) => maintenanceRun('reaction-history-maintenance', env, source => stage1.reactionHistoryMaintenance(payload, source)),
  runMaintenance: env => maintenanceRun('maintenance-tick', env, source => lifecycle.tick(source)),
  executeOperation, safeLogError };
