'use strict';

const crypto = require('crypto');
const { mediaVariant } = require('./shared/media-descriptor');
const { AsyncLocalStorage } = require('async_hooks');
const { cloud } = require('@hw-agconnect/cloud-server');
const { createContentPolicy, isAccountActive, readableCardState, currentVisibility, dateMillis, accessError } = require('./shared/content-policy');

const MAX_DISTANCE_KM = 20.0;
const MAX_PAGE_SIZE = 20;
const MAX_PHOTO_BYTES = 2 * 1024 * 1024;
const MAX_CARD_PHOTOS = 6;
const CARD_READ_BATCH_SIZE = 10;
const readMetricsScope = new AsyncLocalStorage();
const readRequestScope = new AsyncLocalStorage();
const readPhaseScope = new AsyncLocalStorage();
const cardReadScope = new AsyncLocalStorage();
const { withCursorContext } = require('./stages47-common');
const { requestId, errorCode, errorResponse, readStage, READ_OPT_VERSION, shouldReadMetrics } = require('./shared/read-errors');
function withReadPhase(phase, action) {
  return readPhaseScope.run(phase, async () => {
    const metrics = readMetricsScope.getStore();
    const started = Date.now();
    if (metrics) metrics.phaseCalls[phase] = (metrics.phaseCalls[phase] || 0) + 1;
    try { return await action(); }
    catch (error) {
      // Keep the innermost failing phase when an outer phase unwinds.
      try { if (error && typeof error === 'object' && !error.readStage) error.readStage = phase; } catch (_) { }
      throw error;
    } finally {
      // Inclusive wall time per phase; nested phases must not be summed as total time.
      if (metrics) metrics.phaseMs[phase] = (metrics.phaseMs[phase] || 0) + Date.now() - started;
    }
  });
}
const NEARBY_CARD_HYDRATION_CONCURRENCY = 4;
const NEARBY_CACHE_TTL_SECONDS = 25;
const NEARBY_CACHE_TIMEOUT_MS = 400;
const NEARBY_CACHE_RETRY_DELAY_MS = 30000;
const NEARBY_CACHE_VERSION = 'v3';
let nearbyRedis = null;
let nearbyRedisConnecting = null;
let nearbyRedisRetryAfter = 0;
const MAX_CARD_COMMENTS = 100;
const MAX_RECEIVED_COMMENT_SCAN = 500;
const MAX_COMMENT_LENGTH = 240;
const MAX_CARD_REVIEW_LENGTH = 600;
const MAX_SOCIAL_RESULTS = 50;
const MAX_FRIEND_RANKING_SIZE = 50;
const MAX_FRIEND_RANKING_QUERY_BATCH = 2;
const MAX_SOCIAL_PAGE_SIZE = 50;
const SOCIAL_QUERY_BATCH_SIZE = 200;
const SOCIAL_PROFILE_QUERY_BATCH_SIZE = 50;
const MAX_MESSAGE_LENGTH = 1000;
const MAX_MESSAGE_PAGE_SIZE = 50;
const MAX_NOTIFICATION_PAGE_SIZE = 50;
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

// Server-side Cloud DB models. Their field types, primary keys and indexes must
// stay aligned with CloudProgram/clouddb/objecttype/*.json.
class CloudDbModel {
  getFieldTypeMap() {
    return new Map(Object.entries(this.constructor.fieldTypes));
  }

  getClassName() {
    return this.constructor.name;
  }

  getPrimaryKeyList() {
    return [...this.constructor.primaryKeys];
  }

  getIndexList() {
    return [...this.constructor.indexes];
  }

  getEncryptedFieldList() {
    return [];
  }
}

class UserProfile extends CloudDbModel {}
UserProfile.fieldTypes = Object.freeze({"uid": "String", "nickname": "String", "avatarUrl": "String", "nicknameValue": "String", "avatarMediaId": "String", "avatarStorageUid": "String", "coverMediaId": "String", "coverStorageUid": "String", "friendCode": "String", "accountStatus": "String", "publishCount": "Integer", "createdAt": "Long", "updatedAt": "Long", "contentSequence": "Long", "deletionJobId": "String"});
UserProfile.primaryKeys = Object.freeze(['uid']);
UserProfile.indexes = Object.freeze(["nicknameValue", "friendCode"]);

class FoodCard extends CloudDbModel {}
// Legacy CloudDB columns remain for deployed-schema compatibility; public reads ignore them.
FoodCard.fieldTypes = Object.freeze({"id": "String", "ownerUid": "String", "productName": "String", "brand": "String", "priceFen": "Integer", "priceLabel": "String", "originalPriceFen": "Integer", "specification": "String", "shop": "String", "sellingPointsJson": "Text", "publicOffersJson": "Text", "reviewText": "Text", "tasteScore": "Integer", "sourceLink": "Text", "category": "String", "mediaId": "String", "latE3": "Integer", "lonE3": "Integer", "district": "String", "geohash": "String", "status": "String", "createdAt": "Long", "updatedAt": "Long", "schemaVersion": "Integer", "migrationSource": "String", "consumptionMode": "String", "visibility": "String", "merchantId": "String", "merchantNameSnapshot": "String", "merchantAddressSnapshot": "Text", "categoryV2": "String", "categoryVersion": "Integer", "itemPriceFen": "Long", "dineInAvgFen": "Long", "orderTotalFen": "Long", "deliveryFeeFen": "Long", "queryPriceFen": "Long", "deliveryPlatformKey": "String", "deliveryPlatformLabelSnapshot": "String", "consumedAt": "Date", "publishedAt": "Date", "modifiedAt": "Date", "edited": "Boolean", "friendVisibilitySince": "Date", "friendVisibilitySequence": "Long", "reviewState": "String", "deletedAt": "Date", "purgeAt": "Date", "lifecycleGeneration": "Long", "searchTextNormalized": "Text", "reviewReason": "String"});
FoodCard.primaryKeys = Object.freeze(['id']);
FoodCard.indexes = Object.freeze(["status,createdAt,id", "status,category,createdAt,id", "ownerUid,createdAt", "ownerUid,status,createdAt", "status,latE3,lonE3,createdAt", "status,createdAt", "ownerUid,status,tasteScore,createdAt", "merchantId,id", "ownerUid,merchantId,id", "status,publishedAt,id", "status,queryPriceFen,publishedAt,id", "status,queryPriceFen,publishedAt,id", "merchantId,status,publishedAt,id", "status,tasteScore,publishedAt,id", "ownerUid,status,createdAt,id"]);

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
Merchant.indexes = Object.freeze(["provider,providerPoiId", "verificationStatus,createdAt,merchantId", "createdByUid,createdAt,merchantId", "mapVisible,latitudeE6,merchantId"]);

const { CardMedia } = require('./shared/image-models');

class Report extends CloudDbModel {}
Report.fieldTypes = Object.freeze({"id": "String", "reporterUid": "String", "cardId": "String", "reason": "String", "status": "String", "createdAt": "Long", "targetType": "String", "targetId": "String", "updatedAt": "Long", "resolutionAction": "String", "resolutionReason": "String", "resolvedByUid": "String", "resolvedAt": "Long"});
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
FriendReport.fieldTypes = Object.freeze({"id": "String", "reporterUid": "String", "cardId": "String", "reason": "String", "status": "String", "createdAt": "Long", "targetType": "String", "targetId": "String", "updatedAt": "Long", "resolutionAction": "String", "resolutionReason": "String", "resolvedByUid": "String", "resolvedAt": "Long"});
FriendReport.primaryKeys = Object.freeze(['id']);
FriendReport.indexes = Object.freeze(["cardId", "reporterUid,createdAt", "status,createdAt,id", "reporterUid,createdAt,id"]);

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
IdentityBinding.indexes = Object.freeze({"provider_providerUid": ["provider", "providerUid"], "canonicalUid": ["canonicalUid"], "canonicalUid_id": ["canonicalUid", "id"]});

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

const OBJECT_TYPES = Object.freeze({
  UserProfile, FoodCard, CardMedia, Report, CardAction, CardComment, CommentReaction,
  TastePreference, FoodList, FoodListItem, PersonalFoodState, MealPoll, MealPollOption, MealPollVote,
  Friendship, FriendReport, Conversation, ChatMessage, GroupConversation, GroupMember, GroupMessage,
  NotificationEvent, PushRegistration, WidgetRegistration,
  IdentityBinding, AuthMigrationTicket,
  CardReaction, PublishRequestRecord, FoodCardRevision, MaintenanceJob, Merchant
});

function required(env, name) {
  const value = env[name] || process.env[name];
  if (!value) throw new Error(`云端部署单元缺少环境变量 ${name}`);
  return value;
}

/**
 * Private-message values must remain queryable by the trusted cloud object,
 * but Cloud DB sensitive fields are not returned by a query and do not
 * support Text. Store authenticated ciphertext in the Administrator-only
 * object instead. The deployment key never reaches the app or Cloud DB.
 */
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

function validPushDeviceId(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function validPushToken(value) {
  return value.length >= 20 && value.length <= 4096 && /^\S+$/.test(value);
}

function pushRegistrationId(uid, deviceId) {
  return crypto.createHash('sha256').update(`push:${uid}:${deviceId}`).digest('hex');
}

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

async function unregisterPushDevice(uid, payload, env) {
  const deviceId = String(payload.deviceId || '').trim();
  if (!validPushDeviceId(deviceId)) throw new Error('通知设备标识格式无效。');
  const id = pushRegistrationId(uid, deviceId);
  const registrations = collection(env, 'PushRegistration');
  const row = await one(registrations.query().equalTo('id', id));
  if (row && String(row.ownerUid || '') === uid) await registrations.delete(row);
  return { success: true };
}

function validServiceCardFormId(value) {
  return /^[1-9][0-9]{0,9}$/.test(value) && Number(value) <= MAX_SERVICE_CARD_FORM_ID;
}

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

function widgetRegistrationId(uid, deviceId, formId) {
  return crypto.createHash('sha256').update(`widget:${uid}:${deviceId}:${formId}`).digest('hex');
}

function nonNegativeInteger(value) {
  const numeric = Number(value);
  return Number.isInteger(numeric) && numeric >= 0 ? numeric : 0;
}

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
  // Keep the global account boundary independent from the per-device limit.
  // Query one extra row and fail closed if a malformed or legacy deployment
  // has already exceeded the documented maximum.
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

async function unregisterServiceCardForms(uid, payload, env) {
  const deviceId = String(payload.deviceId || '').trim();
  if (!validPushDeviceId(deviceId)) throw new Error('桌面卡片设备标识格式无效。');
  const registrations = collection(env, 'WidgetRegistration');
  const rows = await registrations.query().equalTo('ownerUid', uid)
    .equalTo('deviceId', deviceId).limit(MAX_SERVICE_CARD_FORM_REGISTRATIONS + 1).get();
  if (rows.length > 0) await registrations.delete(rows);
  return { success: true };
}

function base64Url(value) {
  return Buffer.from(value).toString('base64')
    .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

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

function pushConfigured(config) {
  return config.projectId.length > 0 && config.subAccount.length > 0 &&
    config.keyId.length > 0 && config.privateKeyBase64.length > 0;
}

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

async function sendPushToUser(uid, title, body, routeData, env) {
  const config = pushConfiguration(env);
  if (!pushConfigured(config)) return;
  const tokens = await pushTokensFor(uid, env);
  if (tokens.length === 0) return;
  const target = { token: tokens };
  if (uid.length <= 64) target.profileId = uid;
  const response = await fetch(`https://push-api.cloud.huawei.com/v3/${config.projectId}/messages:send`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${pushJwt(config)}`,
      'push-type': '0'
    },
    body: JSON.stringify({
      payload: {
        notification: {
          category: 'IM',
          title,
          body,
          clickAction: {
            actionType: 0,
            data: routeData
          }
        }
      },
      target
    })
  });
  let result = {};
  try {
    result = JSON.parse(await response.text());
  } catch (_error) {
    throw new Error(`Push Kit 返回了无法解析的响应，HTTP ${response.status}。`);
  }
  if (!response.ok || String(result.code || '') !== '80000000') {
    throw new Error(`Push Kit 发送失败，HTTP ${response.status}，业务码 ${String(result.code || 'unknown')}.`);
  }
}

async function bestEffortPush(uid, title, body, routeData, env) {
  try {
    await sendPushToUser(uid, title, body, routeData, env);
  } catch (error) {
    // A notification transport failure must never roll back the completed
    // friend or message operation. Never log tokens or request bodies.
    console.error(`push notification failed: ${safeLogError(error)}`);
  }
}

const NOTIFICATION_TEXT = Object.freeze({
  FRIEND_REQUEST: { title: '新的好友申请', body: '有人向你发送了食刻好友申请。' },
  FRIEND_ACCEPTED: { title: '好友申请已通过', body: '你们现在可以在食刻互相分享推荐了。' },
  DIRECT_MESSAGE: { title: '新的食刻私信', body: '打开食刻查看好友消息。' },
  GROUP_MESSAGE: { title: '群聊有新消息', body: '打开食刻查看群聊。' },
  CARD_COMMENT: { title: '卡片有新评论', body: '有人评论了你的食刻卡片。' },
  REPLY: { title: '评论有新回复', body: '有人回复了你的评论。' }
});

function notificationId(recipientUid, kind, sourceId) {
  return crypto.createHash('sha256').update(
    `notification:${recipientUid}:${kind}:${sourceId}`).digest('hex');
}

async function emitNotification(recipientUid, actorUid, kind, sourceId, targetId, env) {
  if (!recipientUid || recipientUid === actorUid || !NOTIFICATION_TEXT[kind]) return;
  try {
    const policy = contentPolicy(env);
    await policy.assertAccountActive(recipientUid);
    await policy.assertAccountActive(actorUid);
    const id = notificationId(recipientUid, kind, sourceId);
    const notifications = collection(env, 'NotificationEvent');
    if (await one(notifications.query().equalTo('id', id))) return;
    try {
      await notifications.insert({
        id, recipientUid, actorUid, kind, sourceId, targetId, createdAt: Date.now(), readAt: 0
      });
    } catch (error) {
      // A concurrent retry may have inserted the same deterministic event.
      if (await one(notifications.query().equalTo('id', id))) return;
      throw error;
    }
    const copy = NOTIFICATION_TEXT[kind];
    await bestEffortPush(recipientUid, copy.title, copy.body,
      { shikeRoute: 'notification', shikeNotificationId: id }, env);
  } catch (error) {
    // Completed social writes are authoritative even when reminders fail.
    console.error(`notification event failed: ${safeLogError(error)}`);
  }
}

function publicNotification(row) {
  const copy = NOTIFICATION_TEXT[String(row.kind || '')] ||
    { title: '食刻通知', body: '打开食刻查看最新消息。' };
  return {
    id: String(row.id || ''), kind: String(row.kind || ''),
    title: copy.title, body: copy.body,
    createdAt: Number(row.createdAt || 0), readAt: Number(row.readAt || 0)
  };
}

async function listNotifications(uid, payload, env) {
  const requested = Number(payload.pageSize || MAX_NOTIFICATION_PAGE_SIZE);
  const pageSize = Number.isFinite(requested)
    ? Math.max(1, Math.min(MAX_NOTIFICATION_PAGE_SIZE, Math.floor(requested)))
    : MAX_NOTIFICATION_PAGE_SIZE;
  const token = String(payload.pageToken || '').trim();
  const offset = /^\d+$/.test(token) ? Math.min(Number(token), 1000000) : 0;
  let rows = await queryAllRows(() => collection(env, 'NotificationEvent').query()
    .equalTo('recipientUid', uid));
  if (payload.includeComments === false) rows = rows.filter((row) => row.kind !== 'CARD_COMMENT' && row.kind !== 'REPLY');
  rows.sort((a, b) => Number(b.createdAt || 0) - Number(a.createdAt || 0) ||
    String(b.id || '').localeCompare(String(a.id || '')));
  const items = rows.slice(offset, offset + pageSize).map(publicNotification);
  return {
    items,
    unreadCount: rows.filter((row) => Number(row.readAt || 0) === 0).length,
    nextPageToken: offset + pageSize < rows.length ? String(offset + pageSize) : ''
  };
}

async function ownedNotification(uid, id, env) {
  if (!/^[0-9a-f]{64}$/.test(id)) throw new Error('通知不存在或无权查看。');
  const row = await one(collection(env, 'NotificationEvent').query().equalTo('id', id));
  if (!row || String(row.recipientUid || '') !== uid) throw new Error('通知不存在或无权查看。');
  return row;
}

async function markNotificationRead(uid, payload, env) {
  const row = await ownedNotification(uid, String(payload.notificationId || ''), env);
  if (Number(row.readAt || 0) === 0) {
    row.readAt = Date.now();
    await collection(env, 'NotificationEvent').upsert(row);
  }
  return { success: true };
}

async function markAllNotificationsRead(uid, env) {
  const rows = await queryAllRows(() => collection(env, 'NotificationEvent').query()
    .equalTo('recipientUid', uid));
  const now = Date.now();
  const notifications = collection(env, 'NotificationEvent');
  const unread = [];
  for (const row of rows) {
    if (Number(row.readAt || 0) !== 0) continue;
    row.readAt = now;
    unread.push(row);
  }
  for (let offset = 0; offset < unread.length; offset += SOCIAL_QUERY_BATCH_SIZE) {
    await notifications.upsert(unread.slice(offset, offset + SOCIAL_QUERY_BATCH_SIZE));
  }
  return { success: true };
}

async function openNotification(uid, payload, env) {
  const row = await ownedNotification(uid, String(payload.notificationId || ''), env);
  if (Number(row.readAt || 0) === 0) {
    row.readAt = Date.now();
    await collection(env, 'NotificationEvent').upsert(row);
  }
  const kind = String(row.kind || '');
  const targetId = String(row.targetId || '');
  const actorUid = String(row.actorUid || '');
  if (payload.includeComments === false && (kind === 'CARD_COMMENT' || kind === 'REPLY')) return { route: 'expired', targetId: '' };
  const actor = await one(collection(env, 'UserProfile').query().equalTo('uid', actorUid));
  if (!isAccountActive(actor)) return { route: 'expired', targetId: '' };
  if (kind === 'FRIEND_REQUEST') {
    const request = await one(collection(env, 'Friendship').query().equalTo('id', targetId));
    return request && String(request.addresseeUid || '') === uid &&
      String(request.status || '') === 'PENDING'
      ? { route: 'friends', targetId: '' } : { route: 'expired', targetId: '' };
  }
  if (kind === 'FRIEND_ACCEPTED' || kind === 'DIRECT_MESSAGE') {
    const relationship = await friendshipBetween(uid, actorUid, env);
    return relationship && String(relationship.status || '') === 'ACCEPTED'
      ? { route: 'friend-chat', targetId: actorUid } : { route: 'expired', targetId: '' };
  }
  if (kind === 'GROUP_MESSAGE') {
    const membership = await one(collection(env, 'GroupMember').query()
      .equalTo('id', groupMemberId(targetId, uid)));
    const group = await one(collection(env, 'GroupConversation').query().equalTo('id', targetId));
    return membership && group ? { route: 'group-chat', targetId } : { route: 'expired', targetId: '' };
  }
  if (kind === 'CARD_COMMENT' || kind === 'REPLY') {
    const card = await one(collection(env, 'FoodCard').query().equalTo('id', targetId));
    const comment = await one(collection(env, 'CardComment').query()
      .equalTo('id', String(row.sourceId || '')));
    return card && comment && String(comment.cardId || '') === targetId &&
      String(comment.status || '') === 'ACTIVE' && await contentPolicy(env).canReadCard(uid, card)
      ? { route: 'card', targetId } : { route: 'expired', targetId: '' };
  }
  return { route: 'expired', targetId: '' };
}

function serviceCardCategoryLabel(category) {
  if (category === 'staple') return '米饭';
  if (category === 'bakery') return '汤粉';
  if (category === 'snack') return '炸鸡';
  if (category === 'fresh') return '烧烤';
  if (category === 'drink') return '饮品';
  return '其他';
}

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
    // Identity only: bytes stay in the app's approved-media cache and are bound
    // through Form Kit. A remote change must not display an unrelated old cover.
    photoPath: String(primaryPhoto.path || '').trim(),
    photoBucket: String(primaryPhoto.bucket || '').trim()
  };
}

function serviceCardPushDay(now) {
  return new Date(now).toISOString().slice(0, 10);
}

function serviceCardDailyPushLimit(env) {
  const raw = Number((env && env.SHIKE_SERVICE_CARD_DAILY_PUSH_LIMIT) ||
    process.env.SHIKE_SERVICE_CARD_DAILY_PUSH_LIMIT || DEFAULT_SERVICE_CARD_DAILY_PUSH_LIMIT);
  if (!Number.isInteger(raw)) return DEFAULT_SERVICE_CARD_DAILY_PUSH_LIMIT;
  return Math.max(1, Math.min(5, raw));
}

function serviceCardTestMessage(env) {
  const raw = String((env && env.SHIKE_SERVICE_CARD_TEST_MESSAGE) ||
    process.env.SHIKE_SERVICE_CARD_TEST_MESSAGE || '').trim().toLowerCase();
  return raw === 'true';
}

function nextServiceCardVersion(row, now) {
  const previous = nonNegativeInteger(row.updateVersion);
  return Math.max(now, previous + 1);
}

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
  const response = await fetch(`https://push-api.cloud.huawei.com/v3/${config.projectId}/messages:send`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${pushJwt(config)}`,
      'push-type': '1'
    },
    body: JSON.stringify(body)
  });
  let result = {};
  try {
    result = JSON.parse(await response.text());
  } catch (_error) {
    throw new Error(`Push Kit 卡片更新返回了无法解析的响应，HTTP ${response.status}。`);
  }
  if (!response.ok || String(result.code || '') !== '80000000') {
    throw new Error(`Push Kit 卡片更新失败，HTTP ${response.status}，业务码 ${String(result.code || 'unknown')}。`);
  }
  return true;
}

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
    // A metadata lookup failure may clear the cover but must not suppress text updates.
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
    // Persist the version and the attempted-send count before the network
    // request. A lost Push API response must never cause a duplicate version.
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
      // A remote card refresh is optional and must not change the selected
      // local recommendation. Never log its token or request body.
      console.error(`service-card remote update failed: ${safeLogError(error)}`);
    }
  }
  return result;
}

// Administrators are configured only in the deployed service environment;
// the mobile client never sends or decides a privileged role.
function isAdministrator(uid, env) {
  const configured = String((env && env.SHIKE_ADMIN_UIDS) || process.env.SHIKE_ADMIN_UIDS || '');
  if (uid.length === 0 || configured.length === 0) return false;
  return configured.split(',').map((item) => item.trim()).includes(uid);
}

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

function parseBody(event) {
  if (!event) return { accessToken: '', payload: {} };
  let candidate = event;
  if (event.request && event.request.body !== undefined) candidate = event.request.body;
  else if (event.body !== undefined) candidate = event.body;
  else if (event.data !== undefined) candidate = event.data;
  if (typeof candidate === 'string') candidate = JSON.parse(candidate);
  return {
    accessToken: typeof candidate.accessToken === 'string' ? candidate.accessToken : '',
    readRequestId: candidate.readRequestId,
    readAttempt: candidate.readAttempt === 2 ? 2 : 1,
    payload: candidate.payload && typeof candidate.payload === 'object' ? candidate.payload : {}
  };
}

function collection(env, name) {
  const zoneName = env.SHIKE_DB_ZONE || process.env.SHIKE_DB_ZONE || 'shike';
  const objectType = OBJECT_TYPES[name];
  if (!objectType) throw new Error(`未知云数据库对象类型 ${name}`);
  const target = cloud.database({ zoneName }).collection(objectType);
  const metrics = readMetricsScope.getStore();
  if (!metrics) return target;
  return new Proxy(target, { get(object, property) {
    if (property === 'query') return (...args) => measuredQuery(object.query(...args), name, metrics);
    // Count transaction invocations, leaving the SDK transaction and callback intact.
    if (property === 'runTransaction') return (...args) => measuredDependency('transaction', () => object.runTransaction(...args));
    const value = Reflect.get(object, property, object);
    if (property === 'constructor') return value;
    return typeof value === 'function' ? value.bind(object) : value;
  } });
}

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

function recordReadCounts(values) {
  const metrics = readMetricsScope.getStore();
  if (!metrics) return;
  for (const key of ['scannedCandidateCount', 'consumedCandidateCount', 'fetchedCandidateCount',
    'eligibleCandidateCount', 'candidatePoolCount', 'sourceReferenceCount']) {
    if (Number.isSafeInteger(values[key]) && values[key] >= 0) metrics.counts[key] = values[key];
  }
}

function recordReadReadiness(feature, enabled, reason, facts = {}) {
  const metrics = readMetricsScope.getStore();
  if (!metrics || !['search', 'map'].includes(feature)) return;
  const reasons = ['VALIDATION_REQUIRED', 'HISTORY_OR_INDEX_REQUIRED', 'COORDINATE_REQUIRED', ''];
  metrics.readiness[feature] = { enabled: enabled === true, reason: reasons.includes(reason) ? reason : 'UNKNOWN' };
  for (const key of ['searchVerified', 'mapVerified', 'cardCoverageComplete', 'reactionCoverageComplete',
    'indexedQueryReady', 'indexVerified', 'mapCoordinateConfigured', 'mixedCoordinateDetected']) {
    if (typeof facts[key] === 'boolean') metrics.readiness[feature][key] = facts[key];
  }
}

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
      // Logical SDK calls only: transaction internals, Storage bytes and SDK retries are not measured.
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

async function one(query) {
  const rows = await query.limit(1).get();
  return rows.length > 0 ? rows[0] : null;
}

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

function contentPolicy(env) {
  return createContentPolicy((name) => collection(env, name), one);
}

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

function profileForWrite(row, now) {
  // Cloud DB may omit sensitive mirrors on read. Restore them from the
  // existing non-sensitive server-only fields during a profile update.
  const nickname = String(row.nicknameValue || row.nickname || '食刻用户');
  const avatarMediaId = String(row.avatarMediaId || '');
  return Object.assign(new UserProfile(), row, {
    nickname, nicknameValue: nickname,
    avatarUrl: avatarMediaId ? approvedObjectKey(String(row.avatarStorageUid || row.uid), avatarMediaId) : '',
    // Keep the deployed legacy column; it no longer controls content reads.
    contentSequence: 0, updatedAt: now
  });
}

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

function transactionPolicy(transaction, env, profiles = []) {
  return createContentPolicy((name) => collection(env, name), async (query) => {
    const rows = await transaction.executeQuery(query.limit(1));
    return rows[0] || null;
  }, { profiles });
}

async function readableCardRows(rows, _viewerUid, _env, _publicOnly = false, _readContext = null) {
  return rows.filter(readableCardState);
}

async function readCardIfAllowed(row, env, distanceKm = 0, includePhoto = true, viewerUid = '',
  includeThread = false, maxPhotoCount = MAX_CARD_PHOTOS, metrics = null, readContext = null) {
  try {
    return await publicCard(row, env, distanceKm, includePhoto, viewerUid, includeThread, maxPhotoCount, metrics, readContext);
  } catch (error) {
    if (error && error.code === 'CONTENT_ACCESS_DENIED') return null;
    throw error;
  }
}

// Offsets count consumed database rows, including denied rows. A bounded scan
// continues past hidden content and returns a continuation when its budget ends.
async function scanCardPage(queryFactory, viewerUid, env, offset, pageSize, publicOnly = false, photoCount = 1) {
  const cards = [];
  const sourceRows = [];
  let cursor = offset;
  let scanned = 0;
  const finish = async (hasMore) => ({ cards: await finalizeCardReads(cards, sourceRows, viewerUid, env), nextOffset: cursor, hasMore });
  while (scanned < 200 && cards.length < pageSize) {
    const limit = Math.min(50, 200 - scanned);
    const rows = await queryFactory().limit(limit, cursor).get();
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

function identityBindingId(provider, providerUid) {
  return crypto.createHash('sha256')
    .update(`shike-identity:${String(provider)}:${String(providerUid)}`)
    .digest('hex');
}

async function identityBinding(provider, providerUid, env) {
  return one(collection(env, 'IdentityBinding').query()
    .equalTo('id', identityBindingId(provider, providerUid)));
}

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

async function verifiedAgcUid(accessToken) {
  if (!accessToken || String(accessToken).length > 8192) {
    throw new Error('未登录或登录状态已失效。');
  }
  try {
    const verified = await measuredDependency('authVerify', () => cloud.auth().verifyAccessToken({
      accessToken: String(accessToken),
      checkRevoked: true
    }));
    const uid = String(verified.getSub() || '');
    if (!uid) throw new Error('AGC 访问凭证未包含用户标识。');
    return uid;
  } catch (_error) {
    // Account Kit access tokens are intentionally not accepted here.
    throw new Error('登录凭证无效或已撤销，请重新登录。');
  }
}

async function verifiedIdentity(accessToken, env, readOnly = false) {
  return withReadPhase('authentication', async () => {
    const providerUid = await verifiedAgcUid(accessToken);
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
    // The binding above is already validated. Ordinary mutations must not
    // re-query and rewrite an unchanged identity on every button press.
    if (!readOnly && !binding) await ensureIdentityBinding('AGC', providerUid, canonicalUid, env);
    return { providerUid, canonicalUid };
  });
}

async function verifiedUid(accessToken, env, readOnly = false) {
  const identity = await verifiedIdentity(accessToken, env, readOnly);
  return identity.canonicalUid;
}

function fromBase64Url(value) {
  const encoded = String(value || '').replace(/-/g, '+').replace(/_/g, '/');
  const padding = '='.repeat((4 - encoded.length % 4) % 4);
  return Buffer.from(encoded + padding, 'base64');
}

function identityTicketKey(env) {
  return crypto.createHash('sha256').update(required(env, 'SHIKE_IDENTITY_TICKET_KEY')).digest();
}

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

async function assertMigrationTicketAvailable(ticket, kind, env) {
  if (String(ticket.kind || '') !== kind) throw new Error('迁移凭证用途不匹配。');
  const existing = await one(collection(env, 'AuthMigrationTicket').query()
    .equalTo('id', String(ticket.ticketId)));
  if (existing) throw new Error('迁移凭证已使用或正在处理。');
}

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
  await ensureIdentityBinding('HUAWEI_ACCOUNT', legacyUid, canonicalUid, env);
  await ensureIdentityBinding('AGC', agcUid, canonicalUid, env);
  await recordMigrationTicket(ticket, 'LEGACY_LOGIN', legacyUid, agcUid, canonicalUid, env);
  return { success: true };
}

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

function roundedLocation(payload) {
  const latE3 = Number(payload.latE3);
  const lonE3 = Number(payload.lonE3);
  if (!Number.isInteger(latE3) || !Number.isInteger(lonE3) ||
    latE3 < -90000 || latE3 > 90000 || lonE3 < -180000 || lonE3 > 180000) {
    throw new Error('位置参数必须是三位小数舍入后的整数坐标。');
  }
  return { latE3, lonE3 };
}

function haversineKm(aLatE3, aLonE3, bLatE3, bLonE3) {
  const rad = Math.PI / 180;
  const lat1 = aLatE3 / 1000 * rad;
  const lat2 = bLatE3 / 1000 * rad;
  const dLat = lat2 - lat1;
  const dLon = (bLonE3 - aLonE3) / 1000 * rad;
  const value = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 6371.0088 * 2 * Math.atan2(Math.sqrt(value), Math.sqrt(1 - value));
}

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
 * shike-service owns business authorization and Cloud DB state; shike-media
 * owns every Cloud Storage SDK call. The HMAC body prevents a caller from
 * using the media Cloud Object as a general-purpose storage proxy, even
 * though both Cloud Objects are reached through the same AGC gateway.
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
 * Object keys are derived from non-sensitive Cloud DB fields because AGC
 * Cloud DB intentionally returns an empty value for sensitive fields. Clients
 * upload only to their server-authorized public/approved path. The cloud
 * function still verifies that the expected object exists before it exposes a
 * card or avatar through Cloud DB.
 */
function mediaObjectKey(prefix, ownerUid, mediaId) {
  const uid = String(ownerUid || '');
  const id = String(mediaId || '');
  if (!uid || uid.includes('/') || uid.includes('\\') ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
    throw new Error('实拍图记录无效，请重新选择。');
  }
  return `${prefix}/${uid}/${id}.jpg`;
}

function pendingObjectKey(ownerUid, mediaId) {
  return mediaObjectKey('private/pending', ownerUid, mediaId);
}

function approvedObjectKey(ownerUid, mediaId) {
  return mediaObjectKey('public/approved', ownerUid, mediaId);
}

function approvedObjectKeyForMedia(media) {
  return approvedObjectKey(media && (media.storageUid || media.ownerUid), media && media.id);
}

function mediaIdFromApprovedObjectKey(objectKey) {
  const match = /^public\/approved\/[^/]+\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jpg$/i
    .exec(String(objectKey || ''));
  return match ? match[1] : '';
}

/**
 * Approved media is read through the app-signed Cloud Object, which
 * validates the database record and writes bytes into the app-private cache.
 * The object itself is never exposed as a direct Storage URL, so read access
 * stays independent of the device's local login implementation.
 */


async function getPublicMedia(_uid, payload, env) {
  if (String(payload.bucketName || '').trim() !== required(env, 'SHIKE_STORAGE_BUCKET')) throw new Error('图片所属存储实例无效。');
  const key = String(payload.cloudPath || ''), mediaId = mediaIdFromApprovedObjectKey(key);
  if (!mediaId) throw new Error('图片路径无效。');
  return require('./shared/image-reader').readLegacy({ ...payload, key, mediaId, mode: 'PUBLIC', viewerUid: '' }, env);
}
async function getRevisionMedia(uid, payload, env) {
  return require('./shared/image-reader').readLegacy({ ...payload, viewerUid: uid, mode: 'REVISION', variant: 'ORIGINAL' }, env);
}

async function promotePendingMedia(media, env) {
  const storageUid = String(media && (media.storageUid || media.ownerUid) || '').trim();
  const pendingKey = pendingObjectKey(storageUid, media && media.id);
  const approvedKey = approvedObjectKey(storageUid, media && media.id);
  await callMedia('promote', { pendingKey, approvedKey }, env);
  media.status = 'APPROVED';
  return approvedKey;
}

async function deleteObject(env, key) {
  if (!key) return;
  await callMedia('remove', { keys: [key] }, env);
}

function normalizedNickname(value) {
  const nickname = String(value || '').trim();
  if (nickname.length === 0 || nickname.length > 24) {
    throw new Error('昵称需为 1–24 个字符。');
  }
  return nickname;
}

function friendCodeForUid(uid) {
  const digest = crypto.createHash('sha256').update(`shike-friend:${String(uid || '')}`).digest('hex')
    .slice(0, 12).toUpperCase();
  return `SK-${digest.slice(0, 4)}-${digest.slice(4, 8)}-${digest.slice(8, 12)}`;
}

function profileResponse(record, env) {
  const avatarMediaId = String(record.avatarMediaId || '');
  const avatarStorageUid = String(record.avatarStorageUid || record.uid || '');
  const coverMediaId = String(record.coverMediaId || '');
  const coverStorageUid = String(record.coverStorageUid || record.uid || '');
  let avatarPath = '';
  if (avatarMediaId) {
    try {
      avatarPath = approvedObjectKey(avatarStorageUid, avatarMediaId);
    } catch (_error) {
      avatarPath = '';
    }
  }
  let coverPath = '';
  if (coverMediaId) {
    try {
      coverPath = approvedObjectKey(coverStorageUid, coverMediaId);
    } catch (_error) {
      coverPath = '';
    }
  }
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

async function upsertProfile(uid, payload, env, trustedProfile = false) {
  const users = collection(env, 'UserProfile');
  const existing = await one(users.query().equalTo('uid', uid));
  if (existing && !isAccountActive(existing)) throw accessError('账号已停用或正在注销。', 'ACCOUNT_INACTIVE');
  if (!trustedProfile && payload && payload.readOnly === true) {
    if (existing) return profileResponse(existing, env);
    // AGC Auth has already verified the caller's UID. Create the local app
    // profile on first sign-in without storing email or provider details.
    return upsertProfile(uid, { nickname: '食刻用户' }, env, true);
  }
  const ownedCards = await queryAllRows(() => collection(env, 'FoodCard').query().equalTo('ownerUid', uid));
  const publishCount = ownedCards.filter(readableCardState).length;
  const now = Date.now();
  let nickname = String((existing && existing.nicknameValue) || '').trim();
  let avatarMediaId = String((existing && existing.avatarMediaId) || '').trim();
  let avatarStorageUid = String((existing && existing.avatarStorageUid) || uid).trim();
  let coverMediaId = String((existing && existing.coverMediaId) || '').trim();
  let coverStorageUid = String((existing && existing.coverStorageUid) || uid).trim();

  if (trustedProfile) {
    // Login does not request account profile scopes. Preserve app-owned values
    // once they exist instead of overwriting them with a later login response.
    if (!nickname) {
      const trustedValue = String((payload && payload.nickname) || '').trim();
      nickname = trustedValue.length > 0 ? trustedValue.slice(0, 24) : '食刻用户';
    }
  } else {
    nickname = normalizedNickname(payload && payload.nickname);
    const requestedMediaId = String((payload && payload.avatarMediaId) || '').trim();
    if (requestedMediaId.length > 0) {
      const mediaStore = collection(env, 'CardMedia');
      const media = await one(mediaStore.query().equalTo('id', requestedMediaId));
      const profileMediaCardId = `profile:${uid}`;
      if (!media || media.ownerUid !== uid || (media.cardId && media.cardId !== profileMediaCardId)) {
        throw new Error('头像图片不存在、不属于当前用户或已用于其他卡片。');
      }
      // Confirms and promotes the caller-owned pending upload before the image
      // is referenced by a profile.
      const mediaStorageUid = String(media.storageUid || uid).trim();
      if (String(media.status || '') === 'PENDING_UPLOAD') {
        await promotePendingMedia(media, env);
      } else if (String(media.status || '') !== 'APPROVED') {
        throw new Error('头像图片状态无效，请重新选择。');
      }
      if (media.cardId !== profileMediaCardId) {
        media.cardId = profileMediaCardId;
        await mediaStore.upsert(media);
      }
      if (avatarMediaId && avatarMediaId !== requestedMediaId) {
        const previousMedia = await one(mediaStore.query().equalTo('id', avatarMediaId));
        if (previousMedia && previousMedia.ownerUid === uid && previousMedia.cardId === `profile:${uid}`) {
          try {
            await deleteObject(env, approvedObjectKeyForMedia(previousMedia));
            await mediaStore.delete(previousMedia);
          } catch (_error) {
            // The new avatar remains valid if best-effort cleanup of an old
            // profile-only object is delayed; account cleanup covers it later.
          }
        }
      }
      avatarMediaId = requestedMediaId;
      avatarStorageUid = mediaStorageUid;
    }
    const requestedCoverMediaId = String((payload && payload.coverMediaId) || '').trim();
    const coverMediaCardId = `profile-cover:${uid}`;
    if (payload && payload.clearCover === true) {
      if (coverMediaId.length > 0) {
        const previousCover = await one(collection(env, 'CardMedia').query().equalTo('id', coverMediaId));
        if (previousCover && previousCover.ownerUid === uid && previousCover.cardId === coverMediaCardId) {
          try {
            await deleteObject(env, approvedObjectKeyForMedia(previousCover));
            await collection(env, 'CardMedia').delete(previousCover);
          } catch (_error) {
            // The profile is reset even if cleanup of the old object must be retried later.
          }
        }
      }
      coverMediaId = '';
      coverStorageUid = '';
    } else if (requestedCoverMediaId.length > 0) {
      const mediaStore = collection(env, 'CardMedia');
      const media = await one(mediaStore.query().equalTo('id', requestedCoverMediaId));
      if (!media || media.ownerUid !== uid || (media.cardId && media.cardId !== coverMediaCardId)) {
        throw new Error('主页背景图片不存在、不属于当前用户或已用于其他内容。');
      }
      const mediaStorageUid = String(media.storageUid || uid).trim();
      if (String(media.status || '') === 'PENDING_UPLOAD') {
        await promotePendingMedia(media, env);
      } else if (String(media.status || '') !== 'APPROVED') {
        throw new Error('主页背景图片状态无效，请重新选择。');
      }
      if (media.cardId !== coverMediaCardId) {
        media.cardId = coverMediaCardId;
        await mediaStore.upsert(media);
      }
      if (coverMediaId && coverMediaId !== requestedCoverMediaId) {
        const previousCover = await one(mediaStore.query().equalTo('id', coverMediaId));
        if (previousCover && previousCover.ownerUid === uid && previousCover.cardId === coverMediaCardId) {
          try {
            await deleteObject(env, approvedObjectKeyForMedia(previousCover));
            await mediaStore.delete(previousCover);
          } catch (_error) {
            // A successfully saved replacement must not fail because old media cleanup is delayed.
          }
        }
      }
      coverMediaId = requestedCoverMediaId;
      coverStorageUid = mediaStorageUid;
    }
  }

  const record = {
    uid,
    // These sensitive mirrors remain compatible with the existing Cloud DB
    // schema. The non-sensitive counterparts are only readable by the cloud
    // function because direct Cloud DB permissions are disabled for app users.
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
      transaction.executeUpsert([saved]);
      return true;
    }
  });
  if (!committed || !saved) throw new Error('用户资料保存未完成，请重试。');
  return profileResponse(saved, env);
}

async function refreshPublishCount(uid, env) {
  try {
    await upsertProfile(uid, {}, env, true);
  } catch (error) {
    // The card change has already committed. Do not report it as failed and
    // invite a duplicate publish or delete retry for a derived profile count.
    console.error(`publish count refresh failed: ${safeLogError(error)}`);
  }
}

async function prepareCardPhoto(uid, storageUid, payload, env) {
  if (payload.mimeType !== 'image/jpeg') throw new Error('实拍图必须处理为 JPEG。');
  if (!Number.isInteger(payload.byteSize) || payload.byteSize <= 0 || payload.byteSize > MAX_PHOTO_BYTES) {
    throw new Error('实拍图不得超过 2MB。');
  }
  if (!Number.isInteger(payload.width) || !Number.isInteger(payload.height) ||
    payload.width < 1 || payload.height < 1 || Math.max(payload.width, payload.height) > 1600) {
    throw new Error('实拍图长边不得超过 1600px。');
  }
  if (!/^[a-f0-9]{64}$/i.test(String(payload.sha256 || ''))) throw new Error('实拍图摘要无效。');
  const mediaId = crypto.randomUUID();
  const objectKey = approvedObjectKey(storageUid, mediaId);
  const media = {
    id: mediaId,
    cardId: '',
    ownerUid: uid,
    storageUid,
    objectKey,
    sha256: String(payload.sha256),
    preparedSha256: String(payload.sha256),
    mimeType: 'image/jpeg',
    byteSize: payload.byteSize,
    width: payload.width,
    height: payload.height,
    status: 'PENDING_UPLOAD',
    createdAt: Date.now()
  };
  await collection(env, 'CardMedia').insert(media);
  return { mediaId, cloudPath: objectKey, bucketName: required(env, 'SHIKE_STORAGE_BUCKET') };
}

function uploadBytesFromBase64(value) {
  const encoded = String(value || '');
  const maximumLength = Math.ceil(MAX_PHOTO_BYTES / 3) * 4 + 4;
  if (encoded.length === 0 || encoded.length > maximumLength || encoded.length % 4 !== 0 ||
    !/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)) {
    throw new Error('上传图片内容不是有效的 Base64 数据。');
  }
  const bytes = Buffer.from(encoded, 'base64');
  if (bytes.length === 0 || bytes.length > MAX_PHOTO_BYTES ||
    bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[2] !== 0xff ||
    bytes[bytes.length - 2] !== 0xff || bytes[bytes.length - 1] !== 0xd9) {
    throw new Error('上传图片必须是有效的 JPEG，且不得超过 2MB。');
  }
  return bytes;
}

async function saveApprovedPhoto(env, objectKey, bytes, sha256) {
  await callMedia('write-approved', {
    key: objectKey,
    dataBase64: bytes.toString('base64'),
    sha256
  }, env);
}

async function uploadCardPhoto(uid, payload, env) {
  const mediaId = String(payload && payload.mediaId || '').trim();
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(mediaId)) {
    throw new Error('图片上传标识无效。');
  }
  const declaredSha256 = String(payload && payload.sha256 || '').trim().toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(declaredSha256)) throw new Error('图片摘要无效。');
  const mediaStore = collection(env, 'CardMedia');
  const media = await one(mediaStore.query().equalTo('id', mediaId));
  if (!media || String(media.ownerUid || '') !== uid || String(media.cardId || '')) {
    throw new Error('图片不存在、不属于当前用户或已被使用。');
  }
  if (String(media.status || '') !== 'PENDING_UPLOAD') {
    throw new Error('图片已上传或状态无效，请重新选择。');
  }
  const bytes = uploadBytesFromBase64(payload && payload.dataBase64);
  if (bytes.length !== Number(media.byteSize || 0)) {
    throw new Error('图片长度与准备记录不一致，请重新选择。');
  }
  const actualSha256 = crypto.createHash('sha256').update(bytes).digest('hex');
  if (actualSha256 !== declaredSha256) throw new Error('图片摘要校验失败，请重新选择。');
  const preparedSha256 = String(media.preparedSha256 || '').toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(preparedSha256)) {
    throw new Error('图片准备记录版本已过期，请重新选择。');
  }
  if (actualSha256 !== preparedSha256) {
    throw new Error('图片内容与准备记录不一致，请重新选择。');
  }
  const objectKey = approvedObjectKey(String(media.storageUid || uid), mediaId);
  await saveApprovedPhoto(env, objectKey, bytes, actualSha256);
  return { success: true };
}

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
    // Confirm each caller-owned public upload before creating a public card.
    // The compatibility branch also promotes an already-uploaded legacy
    // private/pending object if one exists.
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
  // Product decision: publish validated user content immediately.
  // Rebuild through the profile helper so sensitive legacy mirrors are never
  // accidentally cleared by a Cloud DB query during a publish-count update.
  await refreshPublishCount(uid, env);
  return { cardId, status: 'APPROVED' };
}

function actionId(scope, uid, targetId) {
  return crypto.createHash('sha256').update(`${scope}:${uid}:${targetId}`).digest('hex');
}

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
    // Profile fields are additive to every public view. A stale profile must
    // never prevent a card or comment from being displayed.
    return fallback;
  }
}

async function publicPhotos(row, env, includePhoto, maxPhotoCount = MAX_CARD_PHOTOS, metrics = null, readContext = null) {
  if (!includePhoto) return [];
  const photoLimit = Math.max(1, Math.min(MAX_CARD_PHOTOS,
    Math.floor(Number(maxPhotoCount) || MAX_CARD_PHOTOS)));
  const primary = readContext && photoLimit === 1 ? readContext.primaryMedia.get(String(row.mediaId || '')) : null;
  // Card.mediaId is the recorded cover. Unlinked/legacy records retain the old query path.
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
      // Skip only the malformed photo and keep the remaining carousel usable.
    }
  }
  return photos;
}

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
  // Refresh cards after media hydration; never reuse the first-phase authority cache.
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
    likeCount: 0, favoriteCount: 0, viewerLiked: false, viewerFavorited: false, comments: [] };
}

async function cardActionSummary(cardId, viewerUid, env) {
  return stage1.reactionSummary(cardId, viewerUid, env);
}

async function commentReactionSummary(commentId, viewerUid, env) {
  const reactions = await collection(env, 'CommentReaction').query().equalTo('commentId', commentId).limit(500).get();
  let likeCount = 0;
  let dislikeCount = 0;
  let viewerReaction = '';
  for (const reaction of reactions) {
    const kind = String(reaction.kind || '');
    if (kind === 'LIKE') likeCount += 1;
    if (kind === 'DISLIKE') dislikeCount += 1;
    if (viewerUid && String(reaction.actorUid || '') === viewerUid && (kind === 'LIKE' || kind === 'DISLIKE')) {
      viewerReaction = kind;
    }
  }
  return { likeCount, dislikeCount, viewerReaction };
}

async function publicComments(cardId, viewerUid, env) {
  const rows = await collection(env, 'CardComment').query().equalTo('cardId', cardId)
    .orderByAsc('createdAt').limit(MAX_CARD_COMMENTS).get();
  const authorUids = [...new Set(rows.map((row) => String(row.authorUid || '')).filter(Boolean))];
  const authorsByUid = new Map();
  const inactiveAuthors = new Set();
  const profiles = collection(env, 'UserProfile');
  for (let start = 0; start < authorUids.length; start += SOCIAL_PROFILE_QUERY_BATCH_SIZE) {
    const batch = authorUids.slice(start, start + SOCIAL_PROFILE_QUERY_BATCH_SIZE);
    try {
      const records = await profiles.query().in('uid', batch).limit(batch.length).get();
      const returnedUids = new Set(records.map((record) => String(record.uid)));
      for (const missingUid of batch) if (!returnedUids.has(missingUid)) inactiveAuthors.add(missingUid);
      for (const record of records) {
        if (!isAccountActive(record)) { inactiveAuthors.add(String(record.uid)); continue; }
        try {
          const profile = profileResponse(record, env);
          authorsByUid.set(String(record.uid || ''), {
            nickname: profile.nickname || '食刻用户',
            avatarPath: profile.avatarPath || '',
            avatarBucket: profile.avatarBucket || ''
          });
        } catch (_error) {
          // Keep the same fallback as publicProfile for malformed profiles.
        }
      }
    } catch (error) {
      // Account status is an authorization boundary; only presentation can fall back.
      throw error;
    }
  }
  const reactionSummariesById = new Map();
  const commentIds = rows.map((row) => String(row.id || '')).filter(Boolean);
  const reactionsStore = collection(env, 'CommentReaction');
  for (let start = 0; start < commentIds.length; start += SOCIAL_PROFILE_QUERY_BATCH_SIZE) {
    const batch = commentIds.slice(start, start + SOCIAL_PROFILE_QUERY_BATCH_SIZE);
    const maxBatchRows = batch.length * 500;
    const reactions = [];
    let offset = 0;
    while (offset < maxBatchRows) {
      const pageSize = Math.min(SOCIAL_QUERY_BATCH_SIZE, maxBatchRows - offset);
      const page = await reactionsStore.query().in('commentId', batch).limit(pageSize, offset).get();
      reactions.push(...page);
      if (page.length < pageSize) break;
      offset += page.length;
    }
    if (reactions.length === maxBatchRows) {
      // An unusually active thread may have more than 500 reactions per
      // comment. Use the original bounded query for exact per-comment counts.
      for (const id of batch) {
        reactionSummariesById.set(id, await commentReactionSummary(id, viewerUid, env));
      }
      continue;
    }
    for (const reaction of reactions) {
      const id = String(reaction.commentId || '');
      let summary = reactionSummariesById.get(id);
      if (!summary) {
        summary = { likeCount: 0, dislikeCount: 0, viewerReaction: '', total: 0 };
        reactionSummariesById.set(id, summary);
      }
      if (summary.total >= 500) continue;
      summary.total += 1;
      const kind = String(reaction.kind || '');
      if (kind === 'LIKE') summary.likeCount += 1;
      if (kind === 'DISLIKE') summary.dislikeCount += 1;
      if (viewerUid && String(reaction.actorUid || '') === viewerUid && (kind === 'LIKE' || kind === 'DISLIKE')) {
        summary.viewerReaction = kind;
      }
    }
  }
  const byId = new Map();
  const ordered = [];
  let commentCount = 0;
  const viewerIsAdministrator = !!viewerUid && isAdministrator(viewerUid, env);
  for (const row of rows) {
    const author = authorsByUid.get(String(row.authorUid || '')) ||
      { nickname: '食刻用户', avatarPath: '', avatarBucket: '' };
    const reactions = reactionSummariesById.get(String(row.id || '')) ||
      { likeCount: 0, dislikeCount: 0, viewerReaction: '' };
    const deleted = String(row.status || 'ACTIVE') === 'DELETED' || inactiveAuthors.has(String(row.authorUid || ''));
    if (!deleted) commentCount += 1;
    const view = {
      id: String(row.id || ''),
      parentId: String(row.parentId || ''),
      replyToNickname: String(row.replyToNickname || ''),
      authorUid: String(row.authorUid || ''),
      authorNickname: author.nickname,
      authorAvatarUrl: '',
      authorAvatarPath: author.avatarPath,
      authorAvatarBucket: author.avatarBucket,
      content: deleted ? '' : String(row.content || ''),
      deleted,
      likeCount: reactions.likeCount,
      dislikeCount: reactions.dislikeCount,
      viewerReaction: reactions.viewerReaction,
      viewerIsAuthor: !!viewerUid && String(row.authorUid || '') === viewerUid,
      viewerCanDelete: !!viewerUid && (String(row.authorUid || '') === viewerUid || viewerIsAdministrator),
      createdAt: Number(row.createdAt || 0),
      replies: []
    };
    byId.set(view.id, view);
    ordered.push(view);
  }
  const roots = [];
  for (const view of ordered) {
    const parent = view.parentId.length > 0 ? byId.get(view.parentId) : undefined;
    if (parent !== undefined) parent.replies.push(view);
    else roots.push(view);
  }
  return { comments: roots, commentCount };
}

async function publicCard(row, env, distanceKm = 0, includePhoto = false, viewerUid = '', includeThread = false,
  maxPhotoCount = MAX_CARD_PHOTOS, metrics = null, readContext = null, reviewAccess = false) {
  const context = readContext || await createCardReadContext([row], viewerUid, env, metrics);
  if (reviewAccess && viewerUid === row.ownerUid && stage1.editableState(row)) await context.policy.assertAccountActive(viewerUid);
  else await context.policy.assertCardReadable(viewerUid, row);
  const ownerUid = String(row.ownerUid || '');
  const parts = [
    publicPhotos(row, env, includePhoto, maxPhotoCount, metrics, context),
    publicProfile(ownerUid, env, metrics, context)
  ];
  // Finish optional-profile accounting even when the parallel media query fails.
  if (metrics) await Promise.allSettled(parts);
  const [photos, author] = await Promise.all(parts);
  const primaryPhoto = photos.length > 0 ? photos[0] : {
    id: '', url: '', path: '', bucket: '', width: 0, height: 0
  };
  const actions = includeThread
    ? await cardActionSummary(String(row.id || ''), viewerUid, env)
    : { likeCount: 0, favoriteCount: 0, viewerLiked: false, viewerFavorited: false };
  const thread = includeThread && includeThread !== 'NO_COMMENTS'
    ? await publicComments(String(row.id || ''), viewerUid, env)
    : { comments: [], commentCount: 0 };
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
    ...(includeThread ? { viewerWanted: actions.viewerWanted, collectionReady: actions.collectionReady,
      collectionStatus: actions.collectionStatus } : {}),
    commentCount: thread.commentCount,
    comments: thread.comments,
    district: row.district || '当前位置',
    distanceKm,
    // Legacy rows with an unknown or retired status are not promoted by the
    // test-mode path. Only explicitly approved rows are treated as public.
    status: row.status === 'APPROVED' ? 'APPROVED' : 'REMOVED',
    createdAt: Number(row.createdAt || 0)
  };
}

function nearbyCacheFlag(env, name) {
  const value = env && env[name] !== undefined ? env[name] : process.env[name];
  return String(value || '').trim().toLowerCase() === 'true';
}

function nearbyCacheConfig(env) {
  if (!nearbyCacheFlag(env, 'SHIKE_NEARBY_CLOUD_CACHE_ENABLED')) return null;
  const host = String((env && env.SHIKE_NEARBY_CACHE_HOST) || process.env.SHIKE_NEARBY_CACHE_HOST || '').trim();
  const port = Number((env && env.SHIKE_NEARBY_CACHE_PORT) || process.env.SHIKE_NEARBY_CACHE_PORT);
  const username = String((env && env.SHIKE_NEARBY_CACHE_USERNAME) || process.env.SHIKE_NEARBY_CACHE_USERNAME || '').trim();
  const password = String((env && env.SHIKE_NEARBY_CACHE_PASSWORD) || process.env.SHIKE_NEARBY_CACHE_PASSWORD || '');
  const keySecret = String((env && env.SHIKE_NEARBY_CACHE_KEY_SECRET) || process.env.SHIKE_NEARBY_CACHE_KEY_SECRET || '');
  if (!host || !Number.isInteger(port) || port < 1 || port > 65535 ||
    !username || !password || keySecret.length < 32) return null;
  return { host, port, username, password, keySecret };
}

function nearbyCacheTimed(promise) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_resolve, reject) => {
      timer = setTimeout(() => reject(new Error('nearby cache timeout')), NEARBY_CACHE_TIMEOUT_MS);
    })
  ]).finally(() => clearTimeout(timer));
}

function nearbyCacheUnavailable() {
  // Concurrent failures share one cooldown; traffic must not keep extending it.
  if (Date.now() >= nearbyRedisRetryAfter) {
    nearbyRedisRetryAfter = Date.now() + NEARBY_CACHE_RETRY_DELAY_MS;
  }
  if (nearbyRedis) nearbyRedis.disconnect();
  nearbyRedis = null;
  nearbyRedisConnecting = null;
}

async function nearbyCacheClient(config) {
  if (Date.now() < nearbyRedisRetryAfter) throw new Error('nearby cache cooldown');
  if (!nearbyRedis) {
    // Load the Redis dependency only when the feature is configured and used.
    const Redis = require('ioredis');
    nearbyRedis = new Redis({
      host: config.host, port: config.port, username: config.username, password: config.password,
      lazyConnect: true, enableReadyCheck: false, enableOfflineQueue: false,
      connectTimeout: NEARBY_CACHE_TIMEOUT_MS, commandTimeout: NEARBY_CACHE_TIMEOUT_MS,
      maxRetriesPerRequest: 0, retryStrategy: () => null,
      autoResendUnfulfilledCommands: false, showFriendlyErrorStack: false
    });
    nearbyRedis.on('error', () => {});
  }
  const client = nearbyRedis;
  if (client.status === 'ready') return client;
  if (!nearbyRedisConnecting) {
    const connecting = client.connect().finally(() => {
      if (nearbyRedisConnecting === connecting) nearbyRedisConnecting = null;
    });
    nearbyRedisConnecting = connecting;
  }
  await nearbyCacheTimed(nearbyRedisConnecting);
  if (nearbyRedis !== client || client.status !== 'ready') throw new Error('nearby cache unavailable');
  return client;
}

function nearbyCacheKey(point, epoch, config) {
  const query = `${NEARBY_CACHE_VERSION}:${point.latE3}:${point.lonE3}:${MAX_DISTANCE_KM}:200:${epoch}`;
  const digest = crypto.createHmac('sha256', config.keySecret).update(query).digest('hex');
  return `shike:nearby:${NEARBY_CACHE_VERSION}:${digest}`;
}

function nearbyCandidate(row) {
  // Candidate IDs are reusable; content and authorization are always read live.
  return { id: String(row.id || '') };
}

function nearbyCachedRows(value) {
  const snapshot = JSON.parse(value);
  if (!snapshot || snapshot.version !== NEARBY_CACHE_VERSION ||
      !Number.isSafeInteger(snapshot.createdAt) || snapshot.createdAt > Date.now() ||
      Date.now() - snapshot.createdAt >= NEARBY_CACHE_TTL_SECONDS * 1000 ||
      !Array.isArray(snapshot.rows) || snapshot.rows.length > 200) throw new Error('invalid nearby snapshot');
  const ids = new Set();
  return snapshot.rows.map((raw) => {
    if (!raw || typeof raw.id !== 'string' || !raw.id || ids.has(raw.id)) throw new Error('invalid nearby candidate');
    ids.add(raw.id);
    return nearbyCandidate(raw);
  });
}

function nearbyPageToken(value) {
  const token = String(value || '');
  const cached = /^c1:(\d{1,12}):(\d{1,3})$/.exec(token);
  const offset = Math.min(200, Math.max(0, Number.parseInt(cached ? cached[2] : token, 10) || 0));
  const epoch = cached ? Number(cached[1]) : null;
  const currentEpoch = Math.floor(Date.now() / (NEARBY_CACHE_TTL_SECONDS * 1000));
  return { offset, epoch: epoch !== null && epoch >= currentEpoch - 1 && epoch <= currentEpoch
    ? epoch : null, requestedSnapshot: cached !== null };
}

function nearbyCacheErrorCategory(error) {
  // Never log Redis errors verbatim: messages can contain endpoints or keys.
  const message = error instanceof Error ? error.message : '';
  const code = error && typeof error.code === 'string' ? error.code : '';
  if (/invalid nearby/.test(message) || error instanceof SyntaxError) return 'invalid_snapshot';
  if (/timeout|timed out/i.test(message) || code === 'ETIMEDOUT') return 'timeout';
  if (/WRONGPASS|NOAUTH|NOPERM/.test(message)) return 'auth';
  if (code === 'MODULE_NOT_FOUND') return 'dependency';
  if (['ECONNREFUSED', 'ECONNRESET', 'ENOTFOUND', 'EPIPE'].includes(code)) return 'connection';
  return 'unavailable';
}

function nearbyCacheMetric(env, metrics, requestStarted) {
  if (!nearbyCacheFlag(env, 'SHIKE_NEARBY_CACHE_METRICS_ENABLED')) return;
  // One line per request permits aggregate count and latency analysis without identifiers.
  console.info(`nearby.cache state=${metrics.state} outcome=${metrics.outcome} error=${metrics.error} ` +
    `page=${metrics.page} candidateDbQueries=${metrics.candidateDbQueries} candidateDbMs=${metrics.candidateDbMs} ` +
    `cacheReadMs=${metrics.cacheReadMs} cacheWriteMs=${metrics.cacheWriteMs} candidates=${metrics.candidates} ` +
    `profileDbQueries=${metrics.profileDbQueries} mediaDbQueries=${metrics.mediaDbQueries} ` +
    `profileFailures=${metrics.profileFailures} hydrationMs=${metrics.hydrationMs} cards=${metrics.cards} ` +
    `totalMs=${Date.now() - requestStarted}`);
}

/** Public homepage pagination has no location, radius or 200-candidate cutoff. */
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
  }, viewerUid, env, offset, pageSize, true);
  return { cards: page.cards, nextPageToken: page.hasMore ? 'g1.' + category + '.' + snapshotAt + '.' + page.nextOffset : '', district: '' };
}

async function listNearby(uid, payload, env) {
  const requestStarted = Date.now();
  const metrics = {
    state: nearbyCacheFlag(env, 'SHIKE_NEARBY_CLOUD_CACHE_ENABLED') ? 'unconfigured' : 'disabled',
    outcome: 'error', error: 'none', page: payload.pageToken ? 'next' : 'first',
    candidateDbQueries: 0, candidateDbMs: 0, cacheReadMs: 0, cacheWriteMs: 0,
    candidates: 0, profileDbQueries: 0, mediaDbQueries: 0, profileFailures: 0,
    hydrationMs: 0, cards: 0
  };
  try {
    const point = roundedLocation(payload);
    const page = nearbyPageToken(payload.pageToken);
    const latDelta = Math.ceil(MAX_DISTANCE_KM / 111.0 * 1000);
    const latitude = point.latE3 / 1000 * Math.PI / 180;
    const lonDelta = Math.ceil(MAX_DISTANCE_KM / Math.max(1, 111.0 * Math.cos(latitude)) * 1000);
    const config = nearbyCacheConfig(env);
    const snapshotExpired = page.requestedSnapshot && page.epoch === null;
    const epoch = page.epoch === null
      ? Math.floor(Date.now() / (NEARBY_CACHE_TTL_SECONDS * 1000)) : page.epoch;
    const key = config ? nearbyCacheKey(point, epoch, config) : '';
    let rows = null;
    let snapshotAvailable = false;
    if (config && snapshotExpired) {
      metrics.state = 'snapshot_expired';
    } else if (config && Date.now() < nearbyRedisRetryAfter) {
      // Skip Redis entirely during cooldown, without renewing the deadline.
      metrics.state = 'cooldown';
    } else if (config) {
      const started = Date.now();
      try {
        const redis = await nearbyCacheClient(config);
        const cached = await nearbyCacheTimed(redis.get(key));
        rows = cached === null ? null : nearbyCachedRows(cached);
        metrics.state = rows === null ? 'miss' : 'hit';
        snapshotAvailable = rows !== null;
      } catch (error) {
        nearbyCacheUnavailable();
        metrics.state = 'fallback';
        metrics.error = nearbyCacheErrorCategory(error);
      } finally {
        metrics.cacheReadMs = Date.now() - started;
      }
    }
    if (rows === null) {
      const started = Date.now();
      metrics.candidateDbQueries += 1;
      try {
        rows = await collection(env, 'FoodCard').query()
          .equalTo('status', 'APPROVED')
          .greaterThanOrEqualTo('latE3', point.latE3 - latDelta)
          .lessThanOrEqualTo('latE3', point.latE3 + latDelta)
          .greaterThanOrEqualTo('lonE3', point.lonE3 - lonDelta)
          .lessThanOrEqualTo('lonE3', point.lonE3 + lonDelta)
          .limit(200).get();
      } finally {
        metrics.candidateDbMs = Date.now() - started;
      }
      const remainingTtl = NEARBY_CACHE_TTL_SECONDS * 1000 - (Date.now() - started);
      if (config && metrics.state === 'miss' && !page.requestedSnapshot && remainingTtl > 0 &&
        rows.every((row) => row.status === 'APPROVED')) {
        const writeStarted = Date.now();
        try {
          const redis = await nearbyCacheClient(config);
          // NX protects a snapshot already referenced by a c1 pagination token.
          const ttlAfterConnect = NEARBY_CACHE_TTL_SECONDS * 1000 - (Date.now() - started);
          const stored = ttlAfterConnect > 0 ? await nearbyCacheTimed(redis.set(key, JSON.stringify({
            version: NEARBY_CACHE_VERSION, createdAt: started, rows: rows.map(nearbyCandidate)
          }), 'PX', ttlAfterConnect, 'NX')) : null;
          snapshotAvailable = stored === 'OK';
          if (!snapshotAvailable) {
            const winner = await nearbyCacheTimed(redis.get(key));
            if (winner !== null) {
              rows = nearbyCachedRows(winner);
              snapshotAvailable = true;
              metrics.state = 'race_hit';
            }
          }
        } catch (error) {
          nearbyCacheUnavailable();
          metrics.state = 'fallback';
          metrics.error = nearbyCacheErrorCategory(error);
        } finally {
          metrics.cacheWriteMs = Date.now() - writeStarted;
        }
      } else if (page.requestedSnapshot && metrics.state === 'miss') {
        metrics.state = 'snapshot_expired';
      }
    }
    const currentRows = new Map();
    const candidateIds = rows.map((row) => String(row.id || '')).filter(Boolean);
    for (let start = 0; start < candidateIds.length; start += SOCIAL_PROFILE_QUERY_BATCH_SIZE) {
      const ids = candidateIds.slice(start, start + SOCIAL_PROFILE_QUERY_BATCH_SIZE);
      const fresh = await collection(env, 'FoodCard').query().in('id', ids).limit(ids.length).get();
      metrics.candidateDbQueries += 1;
      for (const row of fresh) currentRows.set(String(row.id || ''), row);
    }
    rows = candidateIds.map((id) => currentRows.get(id)).filter(Boolean);
    // These legacy coordinates are a publication location, never Merchant
    // coordinates. Stage 3 will query reliable Merchant coordinates instead.
    rows = rows.filter((row) => !row.merchantId && !['DELIVERY', 'DINE_IN'].includes(row.consumptionMode));
    const readContext = await createCardReadContext(rows, uid, env, metrics);
    rows = await readableCardRows(rows, uid, env, true, readContext);
    metrics.candidates = rows.length;
    const matched = rows.map((row) => ({
      row, distanceKm: haversineKm(point.latE3, point.lonE3, row.latE3, row.lonE3)
    })).filter((item) => item.row.status === 'APPROVED' && item.distanceKm <= MAX_DISTANCE_KM)
      .sort((a, b) => a.distanceKm - b.distanceKm || Number(b.row.createdAt) - Number(a.row.createdAt) ||
        String(a.row.id).localeCompare(String(b.row.id)));
    // Only photo-backed candidates occupy nearby recommendation slots.
    const photoMatched = matched.filter((item) => String(item.row.mediaId || '').length > 0);
    const offset = page.offset;
    const requestedSize = Number(payload.pageSize || MAX_PAGE_SIZE);
    const pageSize = Number.isFinite(requestedSize)
      ? Math.floor(Math.min(MAX_PAGE_SIZE, Math.max(1, requestedSize))) : MAX_PAGE_SIZE;
    const slice = photoMatched.slice(offset, offset + pageSize);
    const cards = [];
    const hydrationStarted = Date.now();
    try {
      await preparePrimaryPhotos(readContext, slice.map((item) => item.row), env, metrics);
      for (let start = 0; start < slice.length; start += NEARBY_CARD_HYDRATION_CONCURRENCY) {
        const batch = slice.slice(start, start + NEARBY_CARD_HYDRATION_CONCURRENCY);
        // Settle the already-started queries before emitting failure metrics.
        const results = await Promise.allSettled(batch.map((item) =>
          readCardIfAllowed(item.row, env, Number(item.distanceKm.toFixed(3)), true, uid, false, 1, metrics, readContext)));
        const failure = results.find((result) => result.status === 'rejected');
        if (failure) throw failure.reason;
        cards.push(...results.map((result) => result.value).filter(Boolean));
      }
    } finally {
      metrics.hydrationMs = Date.now() - hydrationStarted;
      metrics.cards = cards.length;
    }
    const finalCards = await finalizeCardReads(cards, slice.map((item) => item.row), uid, env);
    metrics.cards = finalCards.length;
    metrics.outcome = 'success';
    return {
      cards: finalCards,
      nextPageToken: offset + pageSize < photoMatched.length
        ? (snapshotAvailable ? `c1:${epoch}:${offset + pageSize}` : String(offset + pageSize)) : '',
      district: String(payload.district || '')
    };
  } finally {
    // Failed database/hydration calls must not disappear from the baseline.
    nearbyCacheMetric(env, metrics, requestStarted);
  }
}

/**
 * A category-free social ranking. The friendship lookup is the authorization
 * boundary: clients receive only approved, photo-backed cards owned by the
 * caller or by a user with an accepted friendship record. Pending requests
 * and stale/deleted friendship rows never enter the owner set.
 */
async function listFriendRankings(uid, env) {
  const rows = await friendshipRowsFor(uid, env);
  const allowedOwners = new Set([uid]);
  for (const row of rows) {
    if (String(row.status || '') !== 'ACCEPTED') continue;
    const otherUid = String(row.memberAUid || '') === uid
      ? String(row.memberBUid || '') : String(row.memberAUid || '');
    if (otherUid) allowedOwners.add(otherUid);
  }

  const ownerUids = Array.from(allowedOwners);
  const rankedRows = [];
  const rankingContext = { policy: createContentPolicy((name) => collection(env, name), one) };
  const cards = collection(env, 'FoodCard');
  for (let start = 0; start < ownerUids.length; start += MAX_FRIEND_RANKING_QUERY_BATCH) {
    const ownerBatch = ownerUids.slice(start, start + MAX_FRIEND_RANKING_QUERY_BATCH);
    const ownerResults = await Promise.allSettled(ownerBatch.map((ownerUid) => cards.query()
      .equalTo('ownerUid', ownerUid)
      .equalTo('status', 'APPROVED')
      .orderByDesc('tasteScore')
      .orderByDesc('createdAt')
      .limit(MAX_FRIEND_RANKING_SIZE)
      .get()));
    const ownerFailure = ownerResults.find((result) => result.status === 'rejected');
    if (ownerFailure) throw ownerFailure.reason;
    const ownerRows = ownerResults.map((result) => result.value);
    const photoRows = ownerRows.flat().filter((row) => String(row.mediaId || '').length > 0);
    rankedRows.push(...await readableCardRows(photoRows, uid, env, false, rankingContext));
  }
  const topRows = rankedRows
    .sort((first, second) => {
      const scoreDifference = Number(second.tasteScore || 0) - Number(first.tasteScore || 0);
      return scoreDifference !== 0 ? scoreDifference : Number(second.createdAt || 0) - Number(first.createdAt || 0);
    })
    .slice(0, MAX_FRIEND_RANKING_SIZE);
  const output = [];
  const readContext = await createCardReadContext(topRows, uid, env);
  await preparePrimaryPhotos(readContext, topRows, env);
  for (const row of topRows) {
    const card = await readCardIfAllowed(row, env, 0, true, uid, false, 1, null, readContext);
    if (card) output.push(card);
  }
  return { cards: await finalizeCardReads(output, topRows, uid, env, true) };
}

async function cardDetail(uid, payload, env) {
  const row = await one(collection(env, 'FoodCard').query().equalTo('id', String(payload.cardId || '')));
  await contentPolicy(env).assertCardReadable(uid, row);
  const detail = await publicCard(row, env, 0, true, uid, payload.includeComments === false ? 'NO_COMMENTS' : true);
  const current = await finalizeCardReads([detail], [row], uid, env);
  if (!current.length) throw accessError('内容已不可访问或已变化，请刷新。', 'CONTENT_UNAVAILABLE');
  return current[0];
}

async function myCards(uid, env) {
  const rows = await collection(env, 'FoodCard').query().equalTo('ownerUid', uid).orderByDesc('createdAt').limit(100).get();
  const cards = [];
  for (const row of rows) {
    const card = await readCardIfAllowed(row, env, 0, true, uid);
    if (card) cards.push(card);
  }
  return { cards };
}

async function friendProfile(uid, payload, env) {
  const page = await stage7.userPage(uid, { userUid: String(payload.friendUid || ''),
    cursor: String(payload.pageToken || ''), pageSize: Number(payload.pageSize || 12) }, env);
  return { profile: { user: { ...page.profile, friendCode: '', avatarUrl: '',
    friendshipState: page.relationshipState === 'FRIEND' ? 'FRIEND' : 'NONE', requestId: '' },
    coverPath: page.profile.coverPath || '', coverBucket: page.profile.coverBucket || '' }, cards: page.cards, nextPageToken: page.nextCursor };
}

async function myFavoriteCards(uid, env) {
  const actions = await collection(env, 'CardAction').query().equalTo('actorUid', uid).equalTo('kind', 'FAVORITE')
    .orderByDesc('createdAt').orderByAsc('id').limit(100).get();
  const cards = [];
  for (const action of actions) {
    const row = await one(collection(env, 'FoodCard').query().equalTo('id', String(action.cardId || '')));
    const card = await readCardIfAllowed(row, env, 0, true, uid);
    if (card) cards.push(card);
  }
  return { cards };
}

async function receivedComments(uid, payload, env) {
  const page = socialPage(payload);
  const offset = Math.min(page.offset, MAX_RECEIVED_COMMENT_SCAN);
  if (offset >= MAX_RECEIVED_COMMENT_SCAN) return { items: [], nextPageToken: '' };
  // Filter self/deleted comments after querying; scanning only offset + pageSize
  // raw rows can produce an empty page while older eligible comments still exist.
  const scanLimit = MAX_RECEIVED_COMMENT_SCAN;
  const ownedCards = await queryAllRows(() => collection(env, 'FoodCard').query().equalTo('ownerUid', uid));
  const cardsById = new Map(ownedCards.map((card) => [String(card.id || ''), card]));
  const commentsById = new Map();
  const cardIds = [...cardsById.keys()].filter(Boolean);
  for (let start = 0; start < cardIds.length; start += SOCIAL_PROFILE_QUERY_BATCH_SIZE) {
    const batch = cardIds.slice(start, start + SOCIAL_PROFILE_QUERY_BATCH_SIZE);
    const rows = await collection(env, 'CardComment').query().in('cardId', batch)
      .orderByDesc('createdAt').limit(scanLimit).get();
    for (const row of rows) {
      if (String(row.authorUid || '') !== uid && String(row.status || 'ACTIVE') === 'ACTIVE') {
        commentsById.set(String(row.id || ''), row);
      }
    }
  }
  // New replies retain the actual recipient UID. Old replyToNickname values are
  // not used for identity checks because nicknames may change or be duplicated.
  const replies = await collection(env, 'CardComment').query().equalTo('replyToUid', uid)
    .orderByDesc('createdAt').limit(scanLimit).get();
  for (const row of replies) {
    if (String(row.authorUid || '') !== uid && String(row.status || 'ACTIVE') === 'ACTIVE') {
      commentsById.set(String(row.id || ''), row);
    }
  }
  const missingCardIds = [...new Set([...commentsById.values()]
    .map((row) => String(row.cardId || '')).filter((cardId) => cardId && !cardsById.has(cardId)))];
  for (let start = 0; start < missingCardIds.length; start += SOCIAL_PROFILE_QUERY_BATCH_SIZE) {
    const batch = missingCardIds.slice(start, start + SOCIAL_PROFILE_QUERY_BATCH_SIZE);
    const rows = await collection(env, 'FoodCard').query().in('id', batch).limit(batch.length).get();
    for (const row of rows) cardsById.set(String(row.id || ''), row);
  }
  const visibleRows = [];
  const readableCards = new Set(await readableCardRows([...cardsById.values()], uid, env));
  for (const row of commentsById.values()) {
    const card = cardsById.get(String(row.cardId || ''));
    if (readableCards.has(card)) visibleRows.push(row);
  }
  visibleRows.sort((a, b) => Number(b.createdAt || 0) - Number(a.createdAt || 0) ||
    String(b.id || '').localeCompare(String(a.id || '')));
  const pageRows = visibleRows.slice(offset, offset + page.pageSize + 1);
  const hasMore = pageRows.length > page.pageSize;
  const selected = pageRows.slice(0, page.pageSize);
  const authorUids = [...new Set(selected.map((row) => String(row.authorUid || '')).filter(Boolean))];
  const authorsByUid = new Map();
  for (let start = 0; start < authorUids.length; start += SOCIAL_PROFILE_QUERY_BATCH_SIZE) {
    const batch = authorUids.slice(start, start + SOCIAL_PROFILE_QUERY_BATCH_SIZE);
    const rows = await collection(env, 'UserProfile').query().in('uid', batch).limit(batch.length).get();
    for (const row of rows) authorsByUid.set(String(row.uid || ''), row);
  }
  const items = selected.filter((row) => isAccountActive(authorsByUid.get(String(row.authorUid || '')))).map((row) => {
    const card = cardsById.get(String(row.cardId || ''));
    const author = authorsByUid.get(String(row.authorUid || ''));
    let authorNickname = String(author && (author.nicknameValue || author.nickname) || '食刻用户');
    let authorAvatarPath = '';
    let authorAvatarBucket = '';
    if (author) {
      try {
        const profile = profileResponse(author, env);
        authorNickname = profile.nickname;
        authorAvatarPath = profile.avatarPath;
        authorAvatarBucket = profile.avatarBucket;
      } catch (_error) {
        // A stale avatar must not hide the commenter's available nickname.
      }
    }
    return {
      id: String(row.id || ''),
      cardId: String(row.cardId || ''),
      cardName: String(card && card.productName || ''),
      authorNickname,
      authorAvatarPath,
      authorAvatarBucket,
      content: String(row.content || ''),
      kind: String(row.replyToUid || '') === uid ? 'REPLY' : 'CARD_COMMENT',
      createdAt: Number(row.createdAt || 0)
    };
  });
  return { items, nextPageToken: hasMore ? String(offset + selected.length) : '' };
}

function socialPair(uid, otherUid) {
  const first = String(uid || '');
  const second = String(otherUid || '');
  if (!first || !second || first === second) throw new Error('不能把自己添加为好友。');
  return first < second
    ? { memberAUid: first, memberBUid: second }
    : { memberAUid: second, memberBUid: first };
}

function socialPairId(prefix, uid, otherUid) {
  const pair = socialPair(uid, otherUid);
  return crypto.createHash('sha256')
    .update(`${prefix}:${pair.memberAUid}:${pair.memberBUid}`)
    .digest('hex');
}

async function friendshipBetween(uid, otherUid, env) {
  const id = socialPairId('friend', uid, otherUid);
  return one(collection(env, 'Friendship').query().equalTo('id', id));
}

async function requireFriend(uid, otherUid, env) {
  await contentPolicy(env).assertAccountActive(uid);
  await contentPolicy(env).assertAccountActive(otherUid);
  const relationship = await friendshipBetween(uid, otherUid, env);
  if (!relationship || String(relationship.status || '') !== 'ACCEPTED') {
    throw new Error('只有互为好友后才能发送私信。');
  }
  return relationship;
}

function relationshipState(row, viewerUid) {
  if (!row) return 'NONE';
  if (String(row.status || '') === 'ACCEPTED') return 'FRIEND';
  if (pendingFriendRequestExpired(row)) return 'NONE';
  if (String(row.status || '') !== 'PENDING') return 'NONE';
  return String(row.requesterUid || '') === viewerUid ? 'OUTGOING' : 'INCOMING';
}

function pendingFriendRequestExpired(row, now = Date.now()) {
  return String(row && row.status || '') === 'PENDING'
    && Number(row && row.createdAt || 0) > 0
    && now - Number(row.createdAt || 0) >= FRIEND_REQUEST_TTL_MS;
}

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

async function socialUserByUid(targetUid, viewerUid, env, row = null) {
  const record = await one(collection(env, 'UserProfile').query().equalTo('uid', String(targetUid || '')));
  if (!record || String(record.accountStatus || 'ACTIVE') !== 'ACTIVE') return null;
  return socialUser(record, viewerUid, env, row);
}

function socialPage(payload) {
  const requestedSize = Number(payload && payload.pageSize || MAX_SOCIAL_PAGE_SIZE);
  const pageSize = Math.floor(Math.min(MAX_SOCIAL_PAGE_SIZE, Math.max(1, requestedSize)));
  const rawToken = String(payload && payload.pageToken || '').trim();
  const parsedOffset = /^\d+$/.test(rawToken) ? Number(rawToken) : 0;
  const offset = Number.isSafeInteger(parsedOffset) ? Math.max(0, Math.min(parsedOffset, 1000000)) : 0;
  return { pageSize, offset };
}

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

async function friendshipRowsFor(uid, env) {
  const friendships = collection(env, 'Friendship');
  const [asMemberA, asMemberB] = await Promise.all([
    queryAllRows(() => friendships.query().equalTo('memberAUid', uid)),
    queryAllRows(() => friendships.query().equalTo('memberBUid', uid))
  ]);
  return uniqueRows([...asMemberA, ...asMemberB]);
}

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

function assertFriendRequestVersion(row, payload) {
  if (payload.expectedCreatedAt != null && (!Number.isSafeInteger(Number(payload.expectedCreatedAt)) ||
      Number(payload.expectedCreatedAt) !== Number(row.createdAt))) {
    throw accessError('好友申请已变化，请刷新。', 'CONFLICT');
  }
}

function conversationCleanupId(friendshipId, cutoffAt) {
  return crypto.createHash('sha256').update('friend-cleanup:' + friendshipId + ':' + cutoffAt).digest('hex');
}

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
  if (result.notify) await emitNotification(targetUid, uid, 'FRIEND_REQUEST', result.requestId + ':' + result.createdAt, result.requestId, env);
  return { success: true };
}

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
  if (result.notify) await emitNotification(requesterUid, uid, 'FRIEND_ACCEPTED', requestId + ':' + result.originalCreatedAt, uid, env);
  return { success: true };
}

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

async function reportUser(uid, payload, env) {
  const targetUid = String(payload.targetUid || '');
  socialPair(uid, targetUid);
  const target = await one(collection(env, 'UserProfile').query().equalTo('uid', targetUid));
  if (!target || String(target.accountStatus || 'ACTIVE') !== 'ACTIVE') throw new Error('没有找到这个食刻用户。');
  const id = crypto.createHash('sha256').update(`friend-report:${uid}:${targetUid}`).digest('hex');
  await collection(env, 'FriendReport').upsert({
    id,
    reporterUid: uid,
    targetUid,
    reason: String(payload.reason || '用户主动举报').trim().slice(0, 100) || '用户主动举报',
    status: 'PENDING',
    createdAt: Date.now()
  });
  return { success: true };
}


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

function messageKind(value) {
  const kind = String(value || '');
  if (kind !== 'TEXT' && kind !== 'CARD' && kind !== 'LINK') throw new Error('不支持的消息类型。');
  return kind;
}

function messagePreview(kind, text, link) {
  if (kind === 'CARD') return '分享了一张美食推荐';
  if (kind === 'LINK') {
    try { return `商品链接：${new URL(link).hostname}`; } catch (_error) { return '分享了商品链接'; }
  }
  return String(text || '').replace(/\s+/g, ' ').slice(0, 60);
}

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
  await emitNotification(friendUid, uid, 'DIRECT_MESSAGE', messageId, uid, env);
  return { message: await publicMessage(message, uid, env) };
}

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

function groupMemberId(groupId, memberUid) {
  const normalizedGroupId = String(groupId || '');
  const normalizedMemberUid = String(memberUid || '');
  if (!normalizedGroupId || !normalizedMemberUid) throw new Error('群聊成员信息不完整。');
  return crypto.createHash('sha256')
    .update(`group-member:${normalizedGroupId}:${normalizedMemberUid}`)
    .digest('hex');
}

function groupMessageKind(value) {
  const kind = String(value || '');
  if (kind !== 'TEXT' && kind !== 'CARD') throw new Error('群聊仅支持文字和美食卡片。');
  return kind;
}

async function groupMembersFor(groupId, env) {
  return queryAllRows(() => collection(env, 'GroupMember').query().equalTo('groupId', String(groupId || '')));
}

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
  await Promise.all(recipientUids.map((recipientUid) => emitNotification(recipientUid, uid,
      'GROUP_MESSAGE', messageId, groupId, env)));
  return { message: await publicGroupMessage(message, uid, env) };
}

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

function cardActionKind(value) {
  const kind = String(value || '');
  if (kind !== 'LIKE' && kind !== 'FAVORITE') throw new Error('不支持的帖子互动类型。');
  return kind;
}

function commentReactionKind(value) {
  const kind = String(value || '');
  if (kind !== 'LIKE' && kind !== 'DISLIKE') throw new Error('不支持的评论互动类型。');
  return kind;
}

async function toggleCardAction(uid, payload, env) {
  const kind = cardActionKind(payload.action);
  return kind === 'LIKE' ? stage1.mutateReaction(uid, payload, env, true) : stage1.toggleFavorite(uid, payload, env);
}

async function createCardComment(uid, payload, env) {
  const cardId = String(payload.cardId || '');
  const content = String(payload.content || '').trim();
  if (!content.length || content.length > MAX_COMMENT_LENGTH) throw new Error('评论长度无效。');
  const commentId = crypto.randomUUID();
  let cardOwner = '';
  let replyToUid = '';
  const committed = await collection(env, 'CardComment').runTransaction({ apply: async (tx) => {
    const profile = await stage1.activeProfile(tx, uid, env);
    const card = await stage1.txOne(tx, env, 'FoodCard', 'id', cardId);
    await transactionPolicy(tx, env, [profile]).assertCardReadable(uid, card);
    const parentId = String(payload.parentCommentId || '');
    const parent = parentId ? await stage1.txOne(tx, env, 'CardComment', 'id', parentId) : null;
    if (parentId && (!parent || parent.cardId !== cardId || parent.status !== 'ACTIVE')) throw accessError('回复目标已失效。');
    replyToUid = parent ? String(parent.authorUid || '') : '';
    const recipient = replyToUid ? await stage1.txOne(tx, env, 'UserProfile', 'uid', replyToUid) : null;
    if (parent && !isAccountActive(recipient)) throw accessError('回复目标账号已停用。');
    const now = logicalWriteTime(profile.updatedAt);
    stage1.upsertRows(tx, [Object.assign(new CardComment(), {
      id: commentId, cardId, authorUid: uid, parentId: parent ? String(parent.parentId || parent.id) : '',
      replyToUid, replyToNickname: recipient ? String(recipient.nicknameValue || recipient.nickname || '食刻用户') : '',
      content, status: 'ACTIVE', createdAt: now, updatedAt: now
    }), Object.assign(new FoodCard(), card), profileForWrite(profile, now)]);
    cardOwner = String(card.ownerUid); return true;
  } });
  if (!committed) throw new Error('评论未保存。');
  const recipients = new Map();
  if (cardOwner !== uid) recipients.set(cardOwner, 'CARD_COMMENT');
  if (replyToUid && replyToUid !== uid) recipients.set(replyToUid, 'REPLY');
  await Promise.all([...recipients.entries()].map(([recipientUid, kind]) => emitNotification(recipientUid, uid, kind, commentId, cardId, env)));
  return { success: true };
}

async function deleteCardComment(uid, payload, env) {
  const committed = await collection(env, 'CardComment').runTransaction({ apply: async (tx) => {
    await stage1.activeProfile(tx, uid, env);
    const comment = await stage1.txOne(tx, env, 'CardComment', 'id', String(payload.commentId || ''));
    if (!comment || (comment.authorUid !== uid && !isAdministrator(uid, env))) throw accessError('评论不存在或无权删除。');
    if (comment.status !== 'DELETED') stage1.upsertRows(tx, [Object.assign(new CardComment(), comment, {
      status: 'DELETED', updatedAt: logicalWriteTime(comment.updatedAt)
    })]);
    return true;
  } });
  if (!committed) throw new Error('评论状态未保存。');
  return { success: true };
}

async function toggleCommentReaction(uid, payload, env) {
  const commentId = String(payload.commentId || '');
  const kind = commentReactionKind(payload.reaction);
  const id = actionId('comment', uid, commentId);
  let reaction = '';
  const committed = await collection(env, 'CommentReaction').runTransaction({ apply: async (tx) => {
    const profile = await stage1.activeProfile(tx, uid, env);
    const comment = await stage1.txOne(tx, env, 'CardComment', 'id', commentId);
    if (!comment || comment.status !== 'ACTIVE' || comment.authorUid === uid) throw accessError('评论不存在或不能互动。');
    const card = await stage1.txOne(tx, env, 'FoodCard', 'id', comment.cardId);
    await transactionPolicy(tx, env, [profile]).assertCardReadable(uid, card);
    const existing = await stage1.txOne(tx, env, 'CommentReaction', 'id', id);
    reaction = existing && existing.kind === kind ? '' : kind;
    if (!reaction) tx.executeDelete([existing]);
    else stage1.upsertRows(tx, [Object.assign(new CommentReaction(), { id, actorUid: uid, commentId, kind, createdAt: Date.now() })]);
    stage1.upsertRows(tx, [Object.assign(new CardComment(), comment), Object.assign(new FoodCard(), card),
      profileForWrite(profile, logicalWriteTime(profile.updatedAt))]);
    return true;
  } });
  if (!committed) throw new Error('评论互动未保存。');
  const summary = await commentReactionSummary(commentId, uid, env);
  return { active: !!reaction, reaction, likeCount: summary.likeCount, dislikeCount: summary.dislikeCount };
}

async function reportCard(uid, payload, env) {
  return moderation.submitReport(uid, payload, env, 'CARD');
}

async function deleteOwnCard(uid, payload, env) {
  return stage1.softDelete(uid, payload, env);
}

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

async function verifiedDeletionUid(accessToken, env) {
  // Only the deletion entry may resolve an inactive binding, for a lost-response
  // retry. It cannot create a profile or re-enable an account.
  const providerUid = await verifiedAgcUid(accessToken);
  const binding = await identityBinding('AGC', providerUid, env);
  return binding ? String(binding.canonicalUid || providerUid) : providerUid;
}

async function assertAdmin(uid, env) {
  await contentPolicy(env).assertAccountActive(uid);
  if (!isAdministrator(uid, env)) throw accessError('403：没有管理员权限。', 'FORBIDDEN');
}

async function listModerationCards(uid, payload, env) {
  await assertAdmin(uid, env);
  const requestedSize = Number(payload.pageSize || MAX_PAGE_SIZE);
  const pageSize = Number.isFinite(requestedSize) ? Math.floor(Math.min(MAX_PAGE_SIZE, Math.max(1, requestedSize))) : MAX_PAGE_SIZE;
  const offset = Number(payload.pageToken || 0);
  if (!Number.isSafeInteger(offset) || offset < 0) throw new Error('审核分页参数无效。');
  const items = [];
  let cursor = offset;
  let scanned = 0;
  let hasMore = true;
  while (scanned < 200 && items.length < pageSize) {
    const limit = Math.min(50, 200 - scanned);
    const rows = await collection(env, 'FoodCard').query().equalTo('status', 'APPROVED')
      .orderByDesc('createdAt').orderByAsc('id').limit(limit, cursor).get();
    if (rows.length === 0) { hasMore = false; break; }
    for (let index = 0; index < rows.length; index += 1) {
      const row = rows[index];
      cursor += 1;
      scanned += 1;
      if (row.reviewState === 'PENDING_POST_REVIEW' && row.deletedAt == null && row.purgeAt == null) {
        items.push({ cardId: String(row.id || ''), ownerUid: String(row.ownerUid || ''),
          productName: String(row.productName || ''), reviewText: String(row.reviewText || ''),
          sourceLink: String(row.sourceLink || ''), visibility: currentVisibility(row),
          reviewState: row.reviewState, modifiedAt: dateMillis(row.modifiedAt),
          createdAt: Number(row.createdAt || 0), photos: await publicPhotos(row, env, true) });
      }
      if (items.length === pageSize) {
        return { items, nextPageToken: index + 1 < rows.length || rows.length === limit ? String(cursor) : '' };
      }
    }
    if (rows.length < limit) { hasMore = false; break; }
  }
  return { items, nextPageToken: hasMore ? String(cursor) : '' };
}

async function moderateCard(uid, payload, env) {
  await assertAdmin(uid, env);
  const cardId = String(payload.cardId || '').trim();
  const action = String(payload.action || '');
  if (!cardId || (action !== 'APPROVE' && action !== 'TAKE_DOWN')) throw new Error('审核操作无效。');
  const cards = collection(env, 'FoodCard');
  let reviewed = null;
  const committed = await cards.runTransaction({
    apply: async (transaction) => {
      const rows = await transaction.executeQuery(cards.query().equalTo('id', cardId).limit(1));
      const row = rows[0];
      if (!row) throw accessError('内容不存在。');
      const owners = await transaction.executeQuery(collection(env, 'UserProfile').query()
        .equalTo('uid', String(row.ownerUid || '')).limit(1));
      if (payload.expectedModifiedAt != null && dateMillis(row.modifiedAt) !== Number(payload.expectedModifiedAt)) {
        throw accessError('内容已变化，请刷新审核列表。', 'CONFLICT');
      }
      if (action === 'APPROVE' && (row.status !== 'APPROVED' || row.reviewState !== 'PENDING_POST_REVIEW' ||
          row.deletedAt != null || row.purgeAt != null || !isAccountActive(owners[0]))) {
        throw accessError('当前内容不能批准。', 'INVALID_STATE');
      }
      const now = Math.max(Date.now(), Number(row.updatedAt || 0) + 1, (dateMillis(row.modifiedAt) || 0) + 1);
      reviewed = Object.assign(new FoodCard(), row, {
        reviewState: action === 'APPROVE' ? 'APPROVED' : 'TAKEN_DOWN',
        status: action === 'APPROVE' ? 'APPROVED' : 'REMOVED',
        publishedAt: new Date(now), modifiedAt: new Date(now), updatedAt: now
      });
      const counters = await stage2.prepareCounterTransition(transaction, row, reviewed, owners[0], env, now);
      stage1.upsertRows(transaction, [reviewed, ...counters]);
      return true;
    }
  });
  if (!committed || !reviewed) throw new Error('审核操作未完成，请重试。');
  return { success: true, cardId, reviewState: reviewed.reviewState,
    publishedAt: dateMillis(reviewed.publishedAt), modifiedAt: dateMillis(reviewed.modifiedAt) };
}

const stage1 = require('./stage1-services').createStage1Services({
  collection, one, transactionPolicy, contentPolicy, profileForWrite, logicalWriteTime,
  assertAdmin, validateCard, uniqueMediaIds, promotePendingMedia, refreshPublishCount, actionId, safeArray,
  recoveryPeriod: env => String(env.SHIKE_ENVIRONMENT || '') === 'test' && Number.isSafeInteger(Number(env.SHIKE_TEST_RECOVERY_SECONDS)) && Number(env.SHIKE_TEST_RECOVERY_SECONDS) >= 30 && Number(env.SHIKE_TEST_RECOVERY_SECONDS) <= 86400 ? Number(env.SHIKE_TEST_RECOVERY_SECONDS) * 1000 : 30 * 86400000,
  personalized: PERSONALIZED, models: OBJECT_TYPES, stage2: () => stage2, collections: () => personalCollections, publicCard
});

const stage2 = require('./stage2-services').createStage2Services({
  collection, one, models: OBJECT_TYPES, profileForWrite, logicalWriteTime, assertAdmin, contentPolicy
});

const stage3 = require('./stage3-services').createStage3Services({
  collection, one, models: OBJECT_TYPES, contentPolicy, readableCardRows, readCardIfAllowed, finalizeCardReads, createCardReadContext, preparePrimaryPhotos, previewCard, withReadPhase, recordReadReadiness, stage1: () => stage1
});


const stages47Context = { collection, one, models: OBJECT_TYPES, contentPolicy, transactionPolicy, readableCardRows,
  readCardIfAllowed, finalizeCardReads, createCardReadContext, preparePrimaryPhotos, readCardRowsByIds, readMerchantRowsByIds, withReadPhase, recordReadCounts,
  profileForWrite, logicalWriteTime, actionId, friendshipRowsFor, friendshipBetween,
  encryptPrivateText, decryptPrivateText, profileResponse, previewCard, collections: () => personalCollections,
  stage1: () => stage1, stage2: () => stage2,
  stage3: () => stage3, stage4: () => stage4, stage5: () => stage5,
  readPublicShareMedia: (card, media, env) => getPublicMedia('', { bucketName: required(env, 'SHIKE_STORAGE_BUCKET'), cloudPath: approvedObjectKeyForMedia(media) }, env)
};
const personalCollections = require('./personal-collections').createPersonalCollections(stages47Context);
const stage4 = require('./stage4-services').createStage4Services(stages47Context);
const stage5 = require('./stage5-services').createStage5Services(stages47Context);
const stage6 = require('./stage6-services').createStage6Services(stages47Context);
const stage7 = require('./stage7-services').createStage7Services(stages47Context);

const authenticationCleanup = require('./authentication-cleanup').createAuthenticationCleanup({ decryptPrivateText, verifiedAgcUid });
const stage8Context = { ...stages47Context, assertAdmin, isAdministrator, publicPhotos, uniqueMediaIds, refreshPublishCount,
  legacyReportId: (uid,cardId) => crypto.createHash('sha256').update(uid+':'+cardId).digest('hex'),
  photoReference: (media,env) => ({ id: media.id, url: '', path: approvedObjectKeyForMedia(media), bucket: required(env,'SHIKE_STORAGE_BUCKET'), width: Number(media.width||0), height: Number(media.height||0) }),
  removeMediaFiles: async (media,env) => { const owner=media.storageUid||media.ownerUid; await callMedia('remove',{keys:[pendingObjectKey(owner,media.id),approvedObjectKey(owner,media.id)]},env); },
  deleteAuthentication: (job,binding,env) => authenticationCleanup.remove(job,binding,env),
  processLegacyJob: async (job,env) => job.jobType==='PURGE_CONVERSATION' ? processFriendCleanup(job.jobId,env) : stage1.processMigration(String(env.SHIKE_MIGRATION_ANCHOR_UID||String(env.SHIKE_ADMIN_UIDS||'').split(',')[0]||''),{jobId:job.jobId},env)
};
const moderation = require('./moderation-services').createModerationServices(stage8Context);
const lifecycle = require('./lifecycle-services').createLifecycleServices(stage8Context);
async function getReviewMedia(uid, payload, env) {
  return require('./shared/image-reader').readLegacy({ ...payload, viewerUid: uid, mode: 'REVIEW', variant: 'ORIGINAL' }, env);
}

const operations = {
  'get-stage89-capabilities': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return moderation.capabilities(uid,env,payload); },
  'list-moderation-queue': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return moderation.queue(uid,payload,env); },
  'get-moderation-detail': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return moderation.detail(uid,payload,env); },
  'decide-moderation': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return moderation.decide(uid,payload,env); },
  'list-my-reports': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return moderation.queue(uid,payload,env,true); },
  'report-merchant': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return moderation.submitReport(uid,payload,env,'MERCHANT'); },
  'list-own-review-requests': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return moderation.ownReviewQueue(uid,payload,env); },
  'list-deleted-cards': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return lifecycle.deleted(uid,payload,env); },
  'restore-deleted-card': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return lifecycle.restore(uid,payload,env); },
  'list-lifecycle-jobs': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return lifecycle.jobs(uid,payload,env); },
  'get-lifecycle-job': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return lifecycle.jobDetail(uid,payload,env); },
  'retry-lifecycle-job': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return lifecycle.retry(uid,payload,env); },
  'confirm-auth-cleanup': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return lifecycle.retry(uid,payload,env,true); },
  'get-review-media': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); return getReviewMedia(uid,payload,env); },
  'run-lifecycle-job': async ({accessToken,payload},env) => { const uid=await verifiedUid(accessToken,env,true); await assertAdmin(uid,env); const result=await lifecycle.process(String(payload.jobId||''),env); return {success:true,...result}; },

  'get-card-previews': async ({ accessToken, payload }, env) => { const uid = accessToken ? await verifiedUid(accessToken, env, true) : ''; return personalCollections.previews(uid,payload,env); },
  'list-personal-collection': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env, true); return personalCollections.list(uid,payload,env); },
  'get-personal-collection-migration': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env, true); return personalCollections.status(uid,env); },
  'start-personal-collection-migration': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return personalCollections.start(uid,env); },
  'resume-personal-collection-migration': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return personalCollections.resume(uid,payload,env); },
  'set-card-favorite': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return personalCollections.set(uid,payload,env,'FAVORITE'); },
  'set-card-wanted': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return personalCollections.set(uid,payload,env,'WANT_TO_EAT'); },
  'get-stage47-capabilities': async ({ accessToken, payload }, env) => { const uid = accessToken ? await verifiedUid(accessToken, env, true) : ''; return stage7.capabilities(uid,env); },
  'get-taste-preference': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env, true); return stage4.get(uid,env); },
  'update-taste-preference': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage4.update(uid,payload,env); },
  'clear-taste-preference': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage4.update(uid,payload,env,true); },
  'list-personalized-recommendations': async ({ accessToken, payload }, env) => { const uid = accessToken ? await verifiedUid(accessToken, env, true) : ''; return stage4.recommendations(uid,payload,env); },
  'list-food-lists': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env, true); return stage5.lists(uid,payload,env); },
  'create-food-list': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage5.create(uid,payload,env); },
  'update-food-list': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage5.update(uid,payload,env); },
  'delete-food-list': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage5.update(uid,payload,env,true); },
  'list-food-list-items': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env, true); return stage5.items(uid,payload,env); },
  'add-food-list-item': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage5.item(uid,payload,env); },
  'remove-food-list-item': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage5.item(uid,payload,env,true); },
  'reorder-food-list-items': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage5.reorder(uid,payload,env); },
  'get-personal-food-state': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env, true); return stage5.personal(uid,payload,env); },
  'update-personal-food-state': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage5.updatePersonal(uid,payload,env); },
  'get-meal-candidates': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env, true); return stage6.candidates(uid,payload,env); },
  'create-meal-poll': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage6.createPoll(uid,payload,env); },
  'get-meal-poll': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage6.getPoll(uid,payload,env); },
  'add-meal-poll-option': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage6.mutatePoll(uid,payload,env,'ADD'); },
  'vote-meal-poll': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage6.mutatePoll(uid,payload,env,'VOTE'); },
  'close-meal-poll': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage6.mutatePoll(uid,payload,env,'CLOSE'); },
  'cancel-meal-poll': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage6.mutatePoll(uid,payload,env,'CANCEL'); },
  'stop-meal-poll-options': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage6.mutatePoll(uid,payload,env,'STOP'); },
  'get-user-page': async ({ accessToken, payload }, env) => { const uid = accessToken ? await verifiedUid(accessToken, env, true) : ''; return stage7.userPage(uid,payload,env); },
  'list-merchant-rankings': async ({ accessToken, payload }, env) => { const uid = accessToken ? await verifiedUid(accessToken, env, true) : ''; return stage7.rankings(uid,payload,env); },
  'set-card-reaction-v2': async ({ accessToken, payload }, env) => { const uid = await verifiedUid(accessToken, env); return stage7.reaction(uid,payload,env); },
  'get-discovery-capabilities': async ({ accessToken }, env) => {
    if (accessToken) await verifiedUid(accessToken, env, true);
    return stage3.capabilities(env);
  },
  'list-map-merchants': async ({ accessToken, payload }, env) => stage3.listMapMerchants(accessToken ? await verifiedUid(accessToken, env, true) : '', payload, env),
  'search-public-cards': async ({ accessToken, payload }, env) => stage3.searchPublicCards(accessToken ? await verifiedUid(accessToken, env, true) : '', payload, env),
  'get-merchant-recommendations': async ({ accessToken, payload }, env) => stage3.getMerchantRecommendations(accessToken ? await verifiedUid(accessToken, env, true) : '', payload, env),
  'get-stage2-capabilities': async ({ accessToken }, env) => { await verifiedUid(accessToken, env); return stage2.capabilities(env); },
  'resolve-merchant': async ({ accessToken, payload }, env) => stage2.resolveMerchant(await verifiedUid(accessToken, env), payload, env),
  'create-user-merchant': async ({ accessToken, payload }, env) => stage2.createUserMerchant(await verifiedUid(accessToken, env), payload, env),
  'update-user-merchant': async ({ accessToken, payload }, env) => stage2.updateUserMerchant(await verifiedUid(accessToken, env), payload, env),
  'get-merchant': async ({ accessToken, payload }, env) => stage2.getMerchant(await verifiedUid(accessToken, env), payload, env),
  'list-moderation-merchants': async ({ accessToken, payload }, env) => stage2.listModerationMerchants(await verifiedUid(accessToken, env), payload, env),
  'moderate-merchant': async ({ accessToken, payload }, env) => stage2.moderateMerchant(await verifiedUid(accessToken, env), payload, env),
  'reconcile-merchant-counters': async ({ accessToken, payload }, env) => stage2.reconcileMerchantPublicCounters(await verifiedUid(accessToken, env), payload, env),
  'get-card-edit-context': async ({ accessToken, payload }, env) => stage1.getEditContext(await verifiedUid(accessToken, env), payload, env),
  'get-revision-media': async ({ accessToken, payload }, env) => getRevisionMedia(await verifiedUid(accessToken, env), payload, env),
  'set-card-reaction': async ({ accessToken, payload }, env) => stage1.mutateReaction(await verifiedUid(accessToken, env), payload, env),
  'submit-card-revision': async ({ accessToken, payload }, env) => stage1.submitRevision(await verifiedUid(accessToken, env), payload, env),
  'get-card-revision': async ({ accessToken, payload }, env) => stage1.getRevision(await verifiedUid(accessToken, env), payload, env),
  'withdraw-card-revision': async ({ accessToken, payload }, env) => stage1.decideRevision(await verifiedUid(accessToken, env), payload, env, true),
  'list-moderation-revisions': async ({ accessToken, payload }, env) => stage1.listRevisions(await verifiedUid(accessToken, env), payload, env),
  'moderate-card-revision': async ({ accessToken, payload }, env) => stage1.decideRevision(await verifiedUid(accessToken, env), payload, env),
  'start-migration-job': async ({ accessToken, payload }, env) => stage1.startMigration(await verifiedUid(accessToken, env), payload, env),
  'process-migration-job': async ({ accessToken, payload }, env) => stage1.processMigration(await verifiedUid(accessToken, env), payload, env),
  'get-migration-status': async ({ accessToken }, env) => stage1.migrationStatus(await verifiedUid(accessToken, env, true), env),
  'list-maintenance-jobs': async ({ accessToken, payload }, env) => stage1.listJobs(await verifiedUid(accessToken, env), payload, env),
  'get-maintenance-job': async ({ accessToken, payload }, env) => stage1.getJob(await verifiedUid(accessToken, env), payload, env),
  'retry-maintenance-job': async ({ accessToken, payload }, env) => stage1.retryJob(await verifiedUid(accessToken, env), payload, env),
  'validate-lifecycle-job': async ({ accessToken, payload }, env) => stage1.validateLifecycleJob(await verifiedUid(accessToken, env), payload, env),
  'process-friend-cleanup-job': async ({ accessToken, payload }, env) => {
    await assertAdmin(await verifiedUid(accessToken, env), env);
    const jobId = String(payload.jobId || '');
    if (!/^[0-9a-f]{64}$/.test(jobId)) throw new Error('清理任务标识无效。');
    return processFriendCleanup(jobId, env);
  },
  'list-moderation-cards': async ({ accessToken, payload }, env) =>
    listModerationCards(await verifiedUid(accessToken, env), payload, env),
  'moderate-card': async ({ accessToken, payload }, env) =>
    moderateCard(await verifiedUid(accessToken, env), payload, env),
  'complete-legacy-login': async ({ accessToken, payload }, env) =>
    completeLegacyLogin(accessToken, payload, env),
  'start-email-binding': async ({ accessToken }, env) => startEmailBinding(accessToken, env),
  'complete-email-binding': async ({ accessToken, payload }, env) =>
    completeEmailBinding(accessToken, payload, env),
  'upsert-profile': async ({ accessToken, payload }, env) => upsertProfile(await verifiedUid(accessToken, env), payload, env),
  'prepare-card-photo': async ({ accessToken, payload }, env) => {
    const identity = await verifiedIdentity(accessToken, env);
    return prepareCardPhoto(identity.canonicalUid, identity.providerUid, payload, env);
  },
  'upload-card-photo': async ({ accessToken, payload }, env) =>
    uploadCardPhoto(await verifiedUid(accessToken, env), payload, env),
  'get-public-media': async ({ payload, readRequestId }, env) =>
    getPublicMedia('', { ...payload, readRequestId }, env),
  'publish-card': async ({ accessToken, payload }, env) => publishCard(await verifiedUid(accessToken, env), payload, env),
  'list-nearby-cards': async ({ accessToken, payload }, env) => payload.scope === 'all'
    ? listPublicRecommendations(payload, env, accessToken ? await verifiedUid(accessToken, env, true) : '') : listNearby(await verifiedUid(accessToken, env, true), payload, env),
  'list-friend-rankings': async ({ accessToken }, env) => listFriendRankings(await verifiedUid(accessToken, env, true), env),
  'get-friend-profile': async ({ accessToken, payload }, env) =>
    friendProfile(await verifiedUid(accessToken, env, true), payload, env),
  'get-card-detail': async ({ accessToken, payload }, env) =>
    cardDetail(accessToken ? await verifiedUid(accessToken, env, true) : '', payload, env),
  'list-my-cards': async ({ accessToken }, env) => myCards(await verifiedUid(accessToken, env), env),
  'list-my-favorite-cards': async ({ accessToken }, env) => myFavoriteCards(await verifiedUid(accessToken, env), env),
  'list-received-comments': async ({ accessToken, payload }, env) =>
    receivedComments(await verifiedUid(accessToken, env), payload, env),
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
  'report-user': async ({ accessToken, payload }, env) =>
    reportUser(await verifiedUid(accessToken, env), payload, env),
  'remove-friend': async ({ accessToken, payload }, env) => removeFriend(await verifiedUid(accessToken, env), payload, env),
  'list-conversations': async ({ accessToken, payload }, env) =>
    listConversations(await verifiedUid(accessToken, env, true), payload, env),
  'list-messages': async ({ accessToken, payload }, env) => listMessages(await verifiedUid(accessToken, env), payload, env),
  'send-message': async ({ accessToken, payload }, env) => sendMessage(await verifiedUid(accessToken, env), payload, env),
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
  'list-notifications': async ({ accessToken, payload }, env) =>
    listNotifications(await verifiedUid(accessToken, env, true), payload, env),
  'mark-notification-read': async ({ accessToken, payload }, env) =>
    markNotificationRead(await verifiedUid(accessToken, env), payload, env),
  'mark-all-notifications-read': async ({ accessToken }, env) =>
    markAllNotificationsRead(await verifiedUid(accessToken, env), env),
  'open-notification': async ({ accessToken, payload }, env) =>
    openNotification(await verifiedUid(accessToken, env), payload, env),
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
  'report-card': async ({ accessToken, payload }, env) => reportCard(await verifiedUid(accessToken, env), payload, env),
  'toggle-card-action': async ({ accessToken, payload }, env) => toggleCardAction(await verifiedUid(accessToken, env), payload, env),
  'create-card-comment': async ({ accessToken, payload }, env) => createCardComment(await verifiedUid(accessToken, env), payload, env),
  'delete-card-comment': async ({ accessToken, payload }, env) => deleteCardComment(await verifiedUid(accessToken, env), payload, env),
  'toggle-comment-reaction': async ({ accessToken, payload }, env) => toggleCommentReaction(await verifiedUid(accessToken, env), payload, env),
  'delete-own-card': async ({ accessToken, payload }, env) => deleteOwnCard(await verifiedUid(accessToken, env), payload, env),
  'delete-account-data': async ({ accessToken }, env) => cleanupAccount(await verifiedDeletionUid(accessToken, env), env, accessToken)
};

function createHandler(operation) {
  if (!operations[operation]) throw new Error(`未知操作 ${operation}`);
  return async function handler(event, context, callback, logger) {
    let id = requestId(event);
    try {
      const input = parseBody(event);
      const env = context && context.env ? context.env : {};
      id = requestId(input);
      const data = await withCursorContext(env, () => cardReadScope.run(new Map(), () => readRequestScope.run(id, () => withReadMetrics(operation, env, () => operations[operation](input, env), id, input.readAttempt))));
      return callback({ ok: true, data, message: '', requestId: id, operation, functionVersion: READ_OPT_VERSION, ...require('./shared/release-info').buildInfo });
    } catch (error) {
      logger.error(`${operation} requestId=${id} code=${errorCode(error)} stage=${readStage(error)} failed: ${safeLogError(error)}`);
      return callback(errorResponse(error, operation, id));
    }
  };
}

async function executeOperation(operation, input, env = process.env) {
  if (!operations[operation]) throw new Error(`未知操作 ${operation}`);
  const safeInput = input && typeof input === 'object' ? input : {};
  const id = requestId(safeInput);
  return withCursorContext(env, () => cardReadScope.run(new Map(), () => readRequestScope.run(id, () => withReadMetrics(operation, env || {}, () => operations[operation]({
    accessToken: typeof safeInput.accessToken === 'string' ? safeInput.accessToken : '',
    payload: safeInput.payload && typeof safeInput.payload === 'object' ? safeInput.payload : {}
  }, env || {}), id, safeInput.readAttempt === 2 ? 2 : 1))));
}

// Explicit one-off worker action. Each batch is bounded and can be retried at the
// same cursor: publicizing a row and reconciling a merchant are both idempotent.
async function normalizePublicContent(env = process.env, cursor = '') {
  if (typeof cursor !== 'string' || cursor.length > 128) throw accessError('迁移游标无效。', 'VALIDATION_ERROR');
  const admin = String(env.SHIKE_ADMIN_UIDS || process.env.SHIKE_ADMIN_UIDS || '').split(',').map(value => value.trim()).find(Boolean);
  if (!admin) throw accessError('公开整理需要配置管理员。', 'CONFIGURATION_REQUIRED');
  await assertAdmin(admin, env);
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
        // Visibility no longer contributes to the content version or publication state.
        tx.executeUpsert([Object.assign(new FoodCard(), current, { visibility: 'PUBLIC' })]);
        updated = true;
      }
      return true;
    } });
    if (!committed) throw accessError('公开整理未保存，请重试同一游标。', 'CONFLICT');
    if (updated) changed++;
  }
  // Reconcile even rows that were already public, so a failed previous batch
  // cannot skip a merchant whose counter update was not committed.
  for (const merchantId of merchants) await stage2.reconcileMerchantPublicCounters(admin, { merchantId }, env);
  const hasMore = rows.length === 10;
  return { scanned: rows.length, changed, merchantsReconciled: merchants.size,
    nextCursor: hasMore ? String(rows[rows.length - 1].id) : '', hasMore };
}

module.exports = { normalizePublicContent, runMaintenance: env => {
  const source = env || process.env, id = crypto.randomUUID();
  return readRequestScope.run(id, () => withReadMetrics('maintenance-tick', source, () => lifecycle.tick(source), id));
}, createHandler, executeOperation, safeLogError, haversineKm, geohash,
  readShareCard: (payload, env) => {
    const source = env || process.env, id = crypto.randomUUID();
    return readRequestScope.run(id, () => withReadMetrics('share-card', source, () => stage7.publicShare(payload, source), id));
  },
  readShareMedia: (payload, env) => {
    const source = env || process.env, id = crypto.randomUUID();
    return readRequestScope.run(id, () => withReadMetrics('share-media', source, () => stage7.publicShareMedia(payload, source), id));
  } };
