'use strict';

const crypto = require('crypto');
const { cloud } = require('@hw-agconnect/cloud-server');

const MAX_DISTANCE_KM = 20.0;
const MAX_PAGE_SIZE = 20;
const MAX_PHOTO_BYTES = 2 * 1024 * 1024;
const MAX_CARD_PHOTOS = 6;
const NEARBY_CARD_HYDRATION_CONCURRENCY = 4;
const NEARBY_CACHE_TTL_SECONDS = 25;
const NEARBY_CACHE_TIMEOUT_MS = 400;
const NEARBY_CACHE_RETRY_DELAY_MS = 30000;
const NEARBY_CACHE_VERSION = 'v2';
let nearbyRedis = null;
let nearbyRedisConnecting = null;
let nearbyRedisRetryAfter = 0;
const MAX_CARD_COMMENTS = 100;
const MAX_RECEIVED_COMMENT_SCAN = 500;
const MAX_COMMENT_LENGTH = 240;
const MAX_CARD_REVIEW_LENGTH = 600;
const MAX_SOCIAL_RESULTS = 50;
const MAX_FRIEND_RANKING_SIZE = 50;
const MAX_FRIEND_RANKING_QUERY_BATCH = 10;
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
  updatedAt: 'Long'
});
UserProfile.primaryKeys = Object.freeze(['uid']);
UserProfile.indexes = Object.freeze(['nicknameValue', 'friendCode']);

class FoodCard extends CloudDbModel {}
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
  updatedAt: 'Long'
});
FoodCard.primaryKeys = Object.freeze(['id']);
FoodCard.indexes = Object.freeze([
  'ownerUid,createdAt',
  'ownerUid,status,createdAt',
  'status,latE3,lonE3,createdAt',
  'status,createdAt',
  'status,createdAt,id',
  'status,category,createdAt,id'
]);

class CardMedia extends CloudDbModel {}
CardMedia.fieldTypes = Object.freeze({
  id: 'String',
  cardId: 'String',
  ownerUid: 'String',
  storageUid: 'String',
  objectKey: 'String',
  sha256: 'String',
  preparedSha256: 'String',
  mimeType: 'String',
  byteSize: 'Integer',
  width: 'Integer',
  height: 'Integer',
  status: 'String',
  createdAt: 'Long'
});
CardMedia.primaryKeys = Object.freeze(['id']);
CardMedia.indexes = Object.freeze(['cardId', 'cardId,createdAt', 'ownerUid,createdAt']);

class Report extends CloudDbModel {}
Report.fieldTypes = Object.freeze({
  id: 'String',
  reporterUid: 'String',
  cardId: 'String',
  reason: 'String',
  status: 'String',
  createdAt: 'Long'
});
Report.primaryKeys = Object.freeze(['id']);
Report.indexes = Object.freeze(['cardId', 'reporterUid,createdAt']);

class CardAction extends CloudDbModel {}
CardAction.fieldTypes = Object.freeze({
  id: 'String',
  actorUid: 'String',
  cardId: 'String',
  kind: 'String',
  createdAt: 'Long'
});
CardAction.primaryKeys = Object.freeze(['id']);
CardAction.indexes = Object.freeze(['cardId', 'actorUid,createdAt']);

class CardComment extends CloudDbModel {}
CardComment.fieldTypes = Object.freeze({
  id: 'String',
  cardId: 'String',
  authorUid: 'String',
  parentId: 'String',
  replyToNickname: 'String',
  replyToUid: 'String',
  content: 'Text',
  status: 'String',
  createdAt: 'Long',
  updatedAt: 'Long'
});
CardComment.primaryKeys = Object.freeze(['id']);
CardComment.indexes = Object.freeze(['cardId,createdAt', 'authorUid,createdAt', 'parentId,createdAt',
  'replyToUid,createdAt']);

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
FriendReport.fieldTypes = Object.freeze({
  id: 'String',
  reporterUid: 'String',
  targetUid: 'String',
  reason: 'String',
  status: 'String',
  createdAt: 'Long'
});
FriendReport.primaryKeys = Object.freeze(['id']);
FriendReport.indexes = Object.freeze(['targetUid', 'reporterUid']);

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
IdentityBinding.indexes = Object.freeze(['provider,providerUid', 'canonicalUid']);

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

const OBJECT_TYPES = Object.freeze({
  UserProfile, FoodCard, CardMedia, Report, CardAction, CardComment, CommentReaction,
  Friendship, FriendReport, Conversation, ChatMessage, GroupConversation, GroupMember, GroupMessage,
  NotificationEvent, PushRegistration, WidgetRegistration,
  IdentityBinding, AuthMigrationTicket
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
  const rows = await queryAllRows(() => collection(env, 'NotificationEvent').query()
    .equalTo('recipientUid', uid));
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
      String(comment.status || '') === 'ACTIVE' && String(card.status || '') === 'APPROVED'
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
  const priceFen = nonNegativeInteger(card.priceFen);
  const tasteScore = Number(card.tasteScore);
  return {
    cardId: String(card.id || ''),
    productName: String(card.productName || '').trim().slice(0, 36) || '附近值得一试',
    scoreText: `${Number.isInteger(tasteScore) ? tasteScore : 0}/10 好味评分`,
    priceText: priceFen > 0 ? `¥${(priceFen / 100).toFixed(2)}` : '价格待补充',
    locationText: String(card.district || '').trim().slice(0, 24) || '20 km 内',
    categoryText: serviceCardCategoryLabel(String(card.category || '')),
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
  if (!card || card.status !== 'APPROVED') throw new Error('该卡片不再公开，无法同步到桌面。');
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
  return `${name}${code}: ${redacted}`;
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
    payload: candidate.payload && typeof candidate.payload === 'object' ? candidate.payload : {}
  };
}

function collection(env, name) {
  const zoneName = env.SHIKE_DB_ZONE || process.env.SHIKE_DB_ZONE || 'shike';
  const objectType = OBJECT_TYPES[name];
  if (!objectType) throw new Error(`未知云数据库对象类型 ${name}`);
  return cloud.database({ zoneName }).collection(objectType);
}

async function one(query) {
  const rows = await query.limit(1).get();
  return rows.length > 0 ? rows[0] : null;
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
    const verified = await cloud.auth().verifyAccessToken({
      accessToken: String(accessToken),
      checkRevoked: true
    });
    const uid = String(verified.getSub() || '');
    if (!uid) throw new Error('AGC 访问凭证未包含用户标识。');
    return uid;
  } catch (_error) {
    // Account Kit access tokens are intentionally not accepted here.
    throw new Error('登录凭证无效或已撤销，请重新登录。');
  }
}

async function verifiedIdentity(accessToken, env) {
  const providerUid = await verifiedAgcUid(accessToken);
  const binding = await identityBinding('AGC', providerUid, env);
  const canonicalUid = binding && String(binding.status || 'ACTIVE') === 'ACTIVE'
    ? String(binding.canonicalUid || providerUid) : providerUid;
  await ensureIdentityBinding('AGC', providerUid, canonicalUid, env);
  return { providerUid, canonicalUid };
}

async function verifiedUid(accessToken, env) {
  const identity = await verifiedIdentity(accessToken, env);
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
  const body = JSON.stringify({ action, issuedAt: Date.now(), nonce: crypto.randomUUID(), payload });
  const signature = crypto.createHmac('sha256', required(env, 'SHIKE_MEDIA_INTERNAL_KEY')).update(body).digest('hex');
  const result = await cloud.function().call({
    name: 'shike-media',
    data: { method: 'execute', params: [{ body, signature }] }
  });
  let value = result && typeof result.getValue === 'function' ? result.getValue() : result;
  if (value && typeof value === 'object' && Object.prototype.hasOwnProperty.call(value, 'result')) value = value.result;
  if (typeof value === 'string') {
    try { value = JSON.parse(value); } catch (_error) { throw new Error('媒体服务返回格式无效。'); }
  }
  if (!value || typeof value !== 'object' || value.ok !== true || !value.data || typeof value.data !== 'object') {
    const message = value && typeof value === 'object' && typeof value.message === 'string'
      ? value.message : '媒体服务请求失败。';
    throw new Error(message);
  }
  return value.data;
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
async function getPublicMedia(uid, payload, env) {
  const bucketName = String(payload && payload.bucketName || '').trim();
  const objectKey = String(payload && payload.cloudPath || '').trim();
  if (bucketName !== required(env, 'SHIKE_STORAGE_BUCKET')) {
    throw new Error('图片所属云存储实例无效。');
  }
  const mediaId = mediaIdFromApprovedObjectKey(objectKey);
  if (!mediaId) throw new Error('图片路径无效。');
  const media = await one(collection(env, 'CardMedia').query().equalTo('id', mediaId));
  if (!media || media.status !== 'APPROVED' || approvedObjectKeyForMedia(media) !== objectKey) {
    throw new Error('图片不存在、尚未发布或路径不匹配。');
  }
  const mediaOwnerUid = String(media.ownerUid || '');
  if (!uid) {
    const cardId = String(media.cardId || '');
    if (mediaOwnerUid && cardId === `profile:${mediaOwnerUid}`) {
      const profile = await one(collection(env, 'UserProfile').query().equalTo('uid', mediaOwnerUid));
      if (!profile || String(profile.avatarMediaId || '') !== mediaId ||
          String(profile.accountStatus || 'ACTIVE') !== 'ACTIVE') {
        throw new Error('头像不再公开。');
      }
    } else {
      const card = cardId && await one(collection(env, 'FoodCard').query().equalTo('id', cardId));
      if (!card || card.status !== 'APPROVED' || String(card.ownerUid || '') !== mediaOwnerUid) {
        throw new Error('图片所属卡片未公开或已下架。');
      }
    }
  }
  if (mediaOwnerUid && String(media.cardId || '') === `profile-cover:${mediaOwnerUid}` && mediaOwnerUid !== uid) {
    const relationship = await friendshipBetween(uid, mediaOwnerUid, env);
    if (!relationship || String(relationship.status || '') !== 'ACCEPTED') {
      throw new Error('只有好友才能查看该主页背景。');
    }
  }
  const response = await callMedia('read-approved', { key: objectKey }, env);
  const bytes = Buffer.from(String(response.dataBase64 || ''), 'base64');
  if (bytes.length === 0 || bytes.length > MAX_PHOTO_BYTES || bytes.length !== Number(response.byteSize || 0)) {
    throw new Error('图片内容无效或超过允许大小。');
  }
  return {
    mimeType: String(media.mimeType || 'image/jpeg'),
    dataBase64: bytes.toString('base64'),
    byteSize: bytes.length
  };
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
  if (!trustedProfile && payload && payload.readOnly === true) {
    if (existing) return profileResponse(existing, env);
    // AGC Auth has already verified the caller's UID. Create the local app
    // profile on first sign-in without storing email or provider details.
    return upsertProfile(uid, { nickname: '食刻用户' }, env, true);
  }
  const publishCount = await collection(env, 'FoodCard').query().equalTo('ownerUid', uid).countQuery('id');
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
    accountStatus: 'ACTIVE',
    publishCount,
    createdAt: existing ? Number(existing.createdAt || now) : now,
    updatedAt: now
  };
  await users.upsert(record);
  return profileResponse(record, env);
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
    return parsed.toString().slice(0, 2048);
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
  if (reviewText.length < 2 || reviewText.length > MAX_CARD_REVIEW_LENGTH) {
    throw new Error('我的评价需为 2–' + MAX_CARD_REVIEW_LENGTH + ' 个字符。');
  }
  const tasteScore = Number(payload.tasteScore);
  if (!Number.isInteger(tasteScore) || tasteScore < 1 || tasteScore > 10) {
    throw new Error('口味评分必须为 1–10 分。');
  }
  return { productName, sourceLink, reviewText, tasteScore };
}

async function publishCard(uid, payload, env) {
  const validated = validateCard(payload);
  const point = roundedLocation(payload);
  const mediaIds = uniqueMediaIds(payload);
  const medias = [];
  for (const mediaId of mediaIds) {
    const media = await one(collection(env, 'CardMedia').query().equalTo('id', mediaId));
    if (!media || media.ownerUid !== uid || media.cardId) throw new Error('实拍图不存在、不属于当前用户或已被使用。');
    // Confirm each caller-owned public upload before creating a public card.
    // The compatibility branch also promotes an already-uploaded legacy
    // private/pending object if one exists.
    await promotePendingMedia(media, env);
    medias.push(media);
  }
  const now = Date.now();
  const cardId = crypto.randomUUID();
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
    district: String(payload.district || '当前位置').slice(0, 80),
    geohash: geohash(point.latE3 / 1000, point.lonE3 / 1000),
    status: 'APPROVED',
    createdAt: now,
    updatedAt: now
  };
  const mediaStore = collection(env, 'CardMedia');
  const committed = await collection(env, 'FoodCard').runTransaction({
    apply: async (transaction) => {
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
      transaction.executeUpsert([Object.assign(new FoodCard(), record)]);
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
  if (ids.length > MAX_CARD_PHOTOS) throw new Error(`一张卡片最多上传 ${MAX_CARD_PHOTOS} 张实拍图。`);
  return ids;
}

async function publicProfile(uid, env, metrics = null) {
  const fallback = { nickname: '食刻用户', avatarPath: '', avatarBucket: '' };
  if (!uid) return fallback;
  try {
    if (metrics) metrics.profileDbQueries += 1;
    const profile = await one(collection(env, 'UserProfile').query().equalTo('uid', uid));
    if (!profile) return fallback;
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

async function publicPhotos(row, env, includePhoto, maxPhotoCount = MAX_CARD_PHOTOS, metrics = null) {
  if (!includePhoto) return [];
  const photoLimit = Math.max(1, Math.min(MAX_CARD_PHOTOS,
    Math.floor(Number(maxPhotoCount) || MAX_CARD_PHOTOS)));
  if (metrics) metrics.mediaDbQueries += 1;
  let medias = await collection(env, 'CardMedia').query().equalTo('cardId', String(row.id || ''))
    .orderByAsc('createdAt').limit(photoLimit).get();
  if (medias.length === 0 && row.mediaId) {
    if (metrics) metrics.mediaDbQueries += 1;
    const legacy = await one(collection(env, 'CardMedia').query().equalTo('id', String(row.mediaId)));
    medias = legacy ? [legacy] : [];
  }
  const photos = [];
  for (const media of medias) {
    if (!media || media.status !== 'APPROVED') continue;
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

async function cardActionSummary(cardId, viewerUid, env) {
  const actions = await collection(env, 'CardAction').query().equalTo('cardId', cardId).limit(500).get();
  let likeCount = 0;
  let favoriteCount = 0;
  let viewerLiked = false;
  let viewerFavorited = false;
  for (const action of actions) {
    const kind = String(action.kind || '');
    if (kind === 'LIKE') likeCount += 1;
    if (kind === 'FAVORITE') favoriteCount += 1;
    if (viewerUid && String(action.actorUid || '') === viewerUid && kind === 'LIKE') viewerLiked = true;
    if (viewerUid && String(action.actorUid || '') === viewerUid && kind === 'FAVORITE') viewerFavorited = true;
  }
  return { likeCount, favoriteCount, viewerLiked, viewerFavorited };
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
  const profiles = collection(env, 'UserProfile');
  for (let start = 0; start < authorUids.length; start += SOCIAL_PROFILE_QUERY_BATCH_SIZE) {
    const batch = authorUids.slice(start, start + SOCIAL_PROFILE_QUERY_BATCH_SIZE);
    try {
      const records = await profiles.query().in('uid', batch).limit(batch.length).get();
      for (const record of records) {
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
    } catch (_error) {
      // Profile data is optional in the public comment view.
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
    const deleted = String(row.status || 'ACTIVE') === 'DELETED';
    if (!deleted) commentCount += 1;
    const view = {
      id: String(row.id || ''),
      parentId: String(row.parentId || ''),
      replyToNickname: String(row.replyToNickname || ''),
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
  maxPhotoCount = MAX_CARD_PHOTOS, metrics = null) {
  const ownerUid = String(row.ownerUid || '');
  const parts = [
    publicPhotos(row, env, includePhoto, maxPhotoCount, metrics),
    publicProfile(ownerUid, env, metrics)
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
  const thread = includeThread
    ? await publicComments(String(row.id || ''), viewerUid, env)
    : { comments: [], commentCount: 0 };
  return {
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
    tasteScore: Number(row.tasteScore || 0),
    sourceLink: row.sourceLink || '',
    category: row.category,
    photoUrl: '',
    photoPath: primaryPhoto.path,
    photoBucket: primaryPhoto.bucket,
    photoWidth: primaryPhoto.width,
    photoHeight: primaryPhoto.height,
    authorNickname: author.nickname,
    authorAvatarUrl: '',
    authorAvatarPath: author.avatarPath,
    authorAvatarBucket: author.avatarBucket,
    photos,
    viewerIsOwner: !!viewerUid && ownerUid === viewerUid,
    likeCount: actions.likeCount,
    favoriteCount: actions.favoriteCount,
    viewerLiked: actions.viewerLiked,
    viewerFavorited: actions.viewerFavorited,
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
  // Explicit projection prevents a future private FoodCard field from entering Redis.
  return {
    id: row.id, ownerUid: row.ownerUid, productName: row.productName,
    brand: row.brand, priceFen: row.priceFen, priceLabel: row.priceLabel,
    originalPriceFen: row.originalPriceFen, specification: row.specification,
    shop: row.shop, sellingPointsJson: row.sellingPointsJson,
    publicOffersJson: row.publicOffersJson, reviewText: row.reviewText,
    tasteScore: row.tasteScore, sourceLink: row.sourceLink, category: row.category,
    mediaId: row.mediaId, latE3: row.latE3, lonE3: row.lonE3,
    district: row.district, status: row.status, createdAt: row.createdAt
  };
}

function nearbyCachedRows(value) {
  const snapshot = JSON.parse(value);
  if (!snapshot || snapshot.version !== NEARBY_CACHE_VERSION ||
    !Number.isSafeInteger(snapshot.createdAt) || snapshot.createdAt > Date.now() ||
    Date.now() - snapshot.createdAt >= NEARBY_CACHE_TTL_SECONDS * 1000 ||
    !Array.isArray(snapshot.rows) || snapshot.rows.length > 200) throw new Error('invalid nearby snapshot');
  const ids = new Set();
  return snapshot.rows.map((raw) => {
    if (!raw || raw.status !== 'APPROVED' || typeof raw.id !== 'string' || !raw.id ||
      ids.has(raw.id) || typeof raw.ownerUid !== 'string' || !raw.ownerUid ||
      !Number.isInteger(raw.latE3) || Math.abs(raw.latE3) > 90000 ||
      !Number.isInteger(raw.lonE3) || Math.abs(raw.lonE3) > 180000 ||
      typeof raw.mediaId !== 'string' || typeof raw.productName !== 'string' ||
      !VALID_CATEGORY.has(raw.category) || !Number.isSafeInteger(raw.createdAt) || raw.createdAt < 0) {
      throw new Error('invalid nearby candidate');
    }
    const textFields = ['brand', 'priceLabel', 'specification', 'shop', 'sellingPointsJson',
      'publicOffersJson', 'reviewText', 'sourceLink', 'district'];
    const numberFields = ['priceFen', 'originalPriceFen', 'tasteScore'];
    if (textFields.some((field) => raw[field] != null && typeof raw[field] !== 'string') ||
      numberFields.some((field) => raw[field] != null && !Number.isFinite(raw[field]))) {
      throw new Error('invalid nearby candidate');
    }
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
async function listPublicRecommendations(payload, env) {
  const category = String(payload.category || 'all');
  if (category !== 'all' && !VALID_CATEGORY.has(category)) throw new Error('商品分类无效。');
  const requestedSize = Number(payload.pageSize || MAX_PAGE_SIZE);
  const pageSize = Number.isFinite(requestedSize)
    ? Math.floor(Math.min(MAX_PAGE_SIZE, Math.max(1, requestedSize))) : MAX_PAGE_SIZE;
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
  let query = collection(env, 'FoodCard').query().equalTo('status', 'APPROVED')
    .lessThanOrEqualTo('createdAt', snapshotAt);
  if (category !== 'all') query = query.equalTo('category', category);
  const rows = await query.orderByDesc('createdAt').orderByAsc('id').limit(pageSize + 1, offset).get();
  const hasMore = rows.length > pageSize;
  const pageRows = rows.slice(0, pageSize);
  const cards = [];
  for (let start = 0; start < pageRows.length; start += NEARBY_CARD_HYDRATION_CONCURRENCY) {
    const batch = pageRows.slice(start, start + NEARBY_CARD_HYDRATION_CONCURRENCY);
    cards.push(...await Promise.all(batch.map((row) => publicCard(row, env, 0, true, '', false, 1))));
  }
  return {
    cards,
    nextPageToken: hasMore ? `g1.${category}.${snapshotAt}.${offset + pageRows.length}` : '',
    district: ''
  };
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
      for (let start = 0; start < slice.length; start += NEARBY_CARD_HYDRATION_CONCURRENCY) {
        const batch = slice.slice(start, start + NEARBY_CARD_HYDRATION_CONCURRENCY);
        // Settle the already-started queries before emitting failure metrics.
        const results = await Promise.allSettled(batch.map((item) =>
          publicCard(item.row, env, Number(item.distanceKm.toFixed(3)), true, uid, false, 1, metrics)));
        const failure = results.find((result) => result.status === 'rejected');
        if (failure) throw failure.reason;
        cards.push(...results.map((result) => result.value));
      }
    } finally {
      metrics.hydrationMs = Date.now() - hydrationStarted;
      metrics.cards = cards.length;
    }
    metrics.outcome = 'success';
    return {
      cards,
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
  const cards = collection(env, 'FoodCard');
  for (let start = 0; start < ownerUids.length; start += MAX_FRIEND_RANKING_QUERY_BATCH) {
    const ownerBatch = ownerUids.slice(start, start + MAX_FRIEND_RANKING_QUERY_BATCH);
    const ownerRows = await Promise.all(ownerBatch.map((ownerUid) => cards.query()
      .equalTo('ownerUid', ownerUid)
      .equalTo('status', 'APPROVED')
      .orderByDesc('tasteScore')
      .orderByDesc('createdAt')
      .limit(MAX_FRIEND_RANKING_SIZE)
      .get()));
    for (const rows of ownerRows) {
      for (const row of rows) {
        if (String(row.mediaId || '').length > 0) rankedRows.push(row);
      }
    }
  }
  const topRows = rankedRows
    .sort((first, second) => {
      const scoreDifference = Number(second.tasteScore || 0) - Number(first.tasteScore || 0);
      return scoreDifference !== 0 ? scoreDifference : Number(second.createdAt || 0) - Number(first.createdAt || 0);
    })
    .slice(0, MAX_FRIEND_RANKING_SIZE);
  const output = [];
  for (const row of topRows) output.push(await publicCard(row, env, 0, true, uid));
  return { cards: output };
}

async function cardDetail(uid, payload, env) {
  const row = await one(collection(env, 'FoodCard').query().equalTo('id', String(payload.cardId || '')));
  if (!row || (row.status !== 'APPROVED' && (!uid || row.ownerUid !== uid))) {
    throw new Error('卡片不存在、尚未公开或不属于当前用户。');
  }
  return publicCard(row, env, 0, row.status === 'APPROVED', uid, true);
}

async function myCards(uid, env) {
  const rows = await collection(env, 'FoodCard').query().equalTo('ownerUid', uid).orderByDesc('createdAt').limit(100).get();
  const cards = [];
  for (const row of rows) cards.push(await publicCard(row, env, 0, true, uid));
  return { cards };
}

async function friendProfile(uid, payload, env) {
  const friendUid = String(payload.friendUid || '').trim();
  if (!friendUid || friendUid === uid) throw new Error('好友资料无效。');
  const relationship = await friendshipBetween(uid, friendUid, env);
  if (!relationship || String(relationship.status || '') !== 'ACCEPTED') {
    throw new Error('只有互为好友后才能查看好友主页动态。');
  }
  const record = await one(collection(env, 'UserProfile').query().equalTo('uid', friendUid));
  if (!record || String(record.accountStatus || 'ACTIVE') !== 'ACTIVE') {
    throw new Error('该好友资料暂时不可用。');
  }
  const page = socialPage(payload);
  const requestedSize = Number(payload.pageSize || 12);
  const pageSize = Math.floor(Math.min(MAX_PAGE_SIZE, Math.max(1, requestedSize)));
  const rows = await collection(env, 'FoodCard').query().equalTo('ownerUid', friendUid)
    .equalTo('status', 'APPROVED').orderByDesc('createdAt').limit(pageSize + 1, page.offset).get();
  const hasMore = rows.length > pageSize;
  const pageRows = rows.slice(0, pageSize);
  const cards = [];
  for (const row of pageRows) cards.push(await publicCard(row, env, 0, true, uid, false, 1));
  const profile = profileResponse(record, env);
  return {
    profile: {
      user: {
        uid: profile.uid,
        friendCode: profile.friendCode,
        nickname: profile.nickname,
        avatarUrl: '',
        avatarPath: profile.avatarPath,
        avatarBucket: profile.avatarBucket,
        publishCount: profile.publishCount,
        friendshipState: 'FRIEND',
        requestId: ''
      },
      coverPath: profile.coverPath || '',
      coverBucket: profile.coverBucket || ''
    },
    cards,
    nextPageToken: hasMore ? String(page.offset + pageRows.length) : ''
  };
}

async function myFavoriteCards(uid, env) {
  const actions = await collection(env, 'CardAction').query().equalTo('actorUid', uid)
    .orderByDesc('createdAt').limit(100).get();
  const cards = [];
  for (const action of actions) {
    if (String(action.kind || '') !== 'FAVORITE') continue;
    const card = await one(collection(env, 'FoodCard').query().equalTo('id', String(action.cardId || '')));
    if (card && String(card.status || '') === 'APPROVED') {
      cards.push(await publicCard(card, env, 0, true, uid));
    }
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
  const visibleRows = [...commentsById.values()].filter((row) => {
    const card = cardsById.get(String(row.cardId || ''));
    return card && (String(card.status || '') === 'APPROVED' || String(card.ownerUid || '') === uid);
  });
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
  const items = selected.map((row) => {
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
    row.status = 'EXPIRED';
    row.updatedAt = now;
    await friendships.upsert(row);
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
    requestId: row ? String(row.id || '') : ''
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
  const rows = await friendshipRowsFor(uid, env);
  await expirePendingFriendships(rows, env);
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

async function sendFriendRequest(uid, payload, env) {
  const targetUid = String(payload.targetUid || '');
  const target = await one(collection(env, 'UserProfile').query().equalTo('uid', targetUid));
  if (!target || String(target.accountStatus || 'ACTIVE') !== 'ACTIVE') throw new Error('没有找到这个食刻用户。');
  const pair = socialPair(uid, targetUid);
  const id = socialPairId('friend', uid, targetUid);
  const friendships = collection(env, 'Friendship');
  const existing = await one(friendships.query().equalTo('id', id));
  if (existing && String(existing.status || '') === 'ACCEPTED') throw new Error('你们已经是好友了。');
  if (existing && String(existing.status || '') === 'BLOCKED') {
    if (String(existing.requesterUid || '') === uid) throw new Error('你已屏蔽该用户，请先解除屏蔽。');
    throw new Error('当前无法向该用户发送好友申请。');
  }
  if (existing && String(existing.status || '') === 'PENDING') {
    if (pendingFriendRequestExpired(existing)) {
      existing.status = 'EXPIRED';
      existing.updatedAt = Date.now();
      await friendships.upsert(existing);
    } else if (String(existing.requesterUid || '') === uid) {
      return { success: true };
    } else {
      throw new Error('对方已经向你发送好友申请，请到“收到的申请”中处理。');
    }
  }
  const now = Date.now();
  await friendships.upsert({
    id,
    memberAUid: pair.memberAUid,
    memberBUid: pair.memberBUid,
    requesterUid: uid,
    addresseeUid: targetUid,
    status: 'PENDING',
    createdAt: now,
    updatedAt: now
  });
  await emitNotification(targetUid, uid, 'FRIEND_REQUEST', id + ':' + now, id, env);
  return { success: true };
}

async function respondFriendRequest(uid, payload, env) {
  const requestId = String(payload.requestId || '');
  const friendships = collection(env, 'Friendship');
  const row = await one(friendships.query().equalTo('id', requestId));
  if (!row || String(row.addresseeUid || '') !== uid || String(row.status || '') !== 'PENDING') {
    throw new Error('好友申请不存在、已处理或不属于当前用户。');
  }
  if (pendingFriendRequestExpired(row)) {
    row.status = 'EXPIRED';
    row.updatedAt = Date.now();
    await friendships.upsert(row);
    throw new Error('这条好友申请已过期。');
  }
  if (payload.accept === true) {
    row.status = 'ACCEPTED';
    row.updatedAt = Date.now();
    await friendships.upsert(row);
    await emitNotification(String(row.requesterUid || ''), uid,
      'FRIEND_ACCEPTED', requestId + ':' + String(row.createdAt || ''), uid, env);
  } else {
    await friendships.delete(row);
  }
  return { success: true };
}

async function cancelFriendRequest(uid, payload, env) {
  const requestId = String(payload.requestId || '');
  const friendships = collection(env, 'Friendship');
  const row = await one(friendships.query().equalTo('id', requestId));
  if (!row || String(row.requesterUid || '') !== uid || String(row.status || '') !== 'PENDING') {
    throw new Error('好友申请不存在、已处理或不属于当前用户。');
  }
  if (pendingFriendRequestExpired(row)) {
    row.status = 'EXPIRED';
    row.updatedAt = Date.now();
    await friendships.upsert(row);
    throw new Error('这条好友申请已过期。');
  }
  await friendships.delete(row);
  return { success: true };
}

async function blockUser(uid, payload, env) {
  const targetUid = String(payload.targetUid || '');
  const target = await one(collection(env, 'UserProfile').query().equalTo('uid', targetUid));
  if (!target || String(target.accountStatus || 'ACTIVE') !== 'ACTIVE') throw new Error('没有找到这个食刻用户。');
  const pair = socialPair(uid, targetUid);
  const id = socialPairId('friend', uid, targetUid);
  const friendships = collection(env, 'Friendship');
  const existing = await one(friendships.query().equalTo('id', id));
  if (existing && String(existing.status || '') === 'BLOCKED') {
    if (String(existing.requesterUid || '') === uid) return { success: true };
    throw new Error('当前无法屏蔽该用户。');
  }
  await deleteConversation(uid, targetUid, env);
  const now = Date.now();
  await friendships.upsert({
    id,
    memberAUid: pair.memberAUid,
    memberBUid: pair.memberBUid,
    requesterUid: uid,
    addresseeUid: targetUid,
    status: 'BLOCKED',
    createdAt: existing ? Number(existing.createdAt || now) : now,
    updatedAt: now
  });
  return { success: true };
}

async function unblockUser(uid, payload, env) {
  const targetUid = String(payload.targetUid || '');
  const row = await friendshipBetween(uid, targetUid, env);
  if (!row || String(row.status || '') !== 'BLOCKED' || String(row.requesterUid || '') !== uid) {
    throw new Error('屏蔽关系不存在或无权解除。');
  }
  await collection(env, 'Friendship').delete(row);
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

async function deleteAllMatchingRows(env, objectType, queryFactory) {
  const target = collection(env, objectType);
  while (true) {
    const rows = await queryFactory(target).limit(SOCIAL_QUERY_BATCH_SIZE).get();
    if (rows.length === 0) return;
    await target.delete(rows);
    if (rows.length < SOCIAL_QUERY_BATCH_SIZE) return;
  }
}

async function deleteConversation(uid, otherUid, env) {
  const id = socialPairId('conversation', uid, otherUid);
  await deleteAllMatchingRows(env, 'ChatMessage', (messages) => messages.query().equalTo('conversationId', id));
  const conversation = await one(collection(env, 'Conversation').query().equalTo('id', id));
  if (conversation) await collection(env, 'Conversation').delete(conversation);
}

async function deleteGroupConversation(groupId, env) {
  const normalizedGroupId = String(groupId || '');
  if (!normalizedGroupId) return;
  await deleteAllMatchingRows(env, 'GroupMessage', (messages) => messages.query()
    .equalTo('groupId', normalizedGroupId));
  await deleteAllMatchingRows(env, 'GroupMember', (members) => members.query()
    .equalTo('groupId', normalizedGroupId));
  const group = await one(collection(env, 'GroupConversation').query().equalTo('id', normalizedGroupId));
  if (group) await collection(env, 'GroupConversation').delete(group);
}

async function removeFriend(uid, payload, env) {
  const friendUid = String(payload.friendUid || '');
  const row = await requireFriend(uid, friendUid, env);
  // Preserve the relationship if cleanup fails so the user can retry instead
  // of leaving an inaccessible, undeletable conversation behind.
  await deleteConversation(uid, friendUid, env);
  await collection(env, 'Friendship').delete(row);
  return { success: true };
}

function messageKind(value) {
  const kind = String(value || '');
  if (kind !== 'TEXT' && kind !== 'CARD' && kind !== 'LINK') throw new Error('不支持的消息类型。');
  return kind;
}

function messagePreview(kind, text, link, cardTitle) {
  if (kind === 'CARD') return `推荐了：${String(cardTitle || '美食卡片').slice(0, 48)}`;
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
    if (card && String(card.status || '') === 'APPROVED') {
      output.sharedCard = await publicCard(card, env, 0, true, viewerUid, false);
    }
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
  let cardTitle = '';
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
    if (!card || String(card.status || '') !== 'APPROVED') throw new Error('只能发送仍在公开展示的推荐卡片。');
    cardTitle = String(card.productName || '美食卡片');
    text = '';
    link = '';
  }
  const pair = socialPair(uid, friendUid);
  const conversationId = socialPairId('conversation', uid, friendUid);
  const now = Date.now();
  const messageId = crypto.randomUUID();
  const storedText = encryptPrivateText(text, `message:${messageId}:text`, env);
  const storedLink = encryptPrivateText(link, `message:${messageId}:link`, env);
  const storedPreview = encryptPrivateText(
    messagePreview(kind, text, link, cardTitle), `conversation:${conversationId}:preview`, env
  );
  const message = {
    id: messageId, conversationId, senderUid: uid, recipientUid: friendUid,
    kind, text: storedText, link: storedLink, cardId, createdAt: now, readAt: 0
  };
  const conversations = collection(env, 'Conversation');
  const committed = await conversations.runTransaction({
    apply: async (transaction) => {
      const rows = await transaction.executeQuery(conversations.query().equalTo('id', conversationId).limit(1));
      const existing = rows[0];
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
    return acceptedRowsByUid.has(friendUid);
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
      lastMessageKind: String(row.lastMessageKind || 'TEXT'),
      lastMessagePreview: decryptPrivateText(
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
  await requireFriend(uid, friendUid, env);
  const conversationId = socialPairId('conversation', uid, friendUid);
  const requestedSize = Number(payload.pageSize || MAX_MESSAGE_PAGE_SIZE);
  const pageSize = Math.floor(Math.min(MAX_MESSAGE_PAGE_SIZE, Math.max(1, requestedSize)));
  const before = Number(payload.beforeToken || 0);
  let query = collection(env, 'ChatMessage').query().equalTo('conversationId', conversationId);
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
        const currentRows = await transaction.executeQuery(messageStore.query()
          .in('id', unread.map((row) => row.id)).limit(unread.length));
        const conversationRows = await transaction.executeQuery(conversations.query()
          .equalTo('id', conversationId).limit(1));
        const newlyRead = currentRows.filter((row) => String(row.conversationId || '') === conversationId &&
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
  return { group, membership };
}

function publicGroupConversation(row, membership, env) {
  const groupId = String(row.id || '');
  return {
    id: groupId,
    name: String(row.name || '群聊'),
    ownerUid: String(row.ownerUid || ''),
    memberCount: Number(row.memberCount || 0),
    lastMessageKind: String(row.lastMessageKind || 'TEXT'),
    lastMessagePreview: decryptPrivateText(
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
      transaction.executeUpsert([Object.assign(new GroupConversation(), group)]);
      transaction.executeUpsert(memberRows.map((row) => Object.assign(new GroupMember(), row)));
      return true;
    }
  });
  if (!committed) throw new Error('群聊创建未完成，请重试。');
  return { group: publicGroupConversation(group, { unreadCount: 0 }, env) };
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
  const rows = [...groupsById.values()];
  rows.sort((first, second) => Number(second.lastMessageAt || 0) - Number(first.lastMessageAt || 0));
  const pageRows = rows.slice(page.offset, page.offset + page.pageSize);
  const groups = pageRows.map((row) => publicGroupConversation(
    row, membershipsByGroupId.get(String(row.id || '')), env));
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
  return { group: publicGroupConversation(group, { unreadCount: 0 }, env), members };
}

async function publicGroupMessage(row, viewerUid, env) {
  const messageId = String(row.id || '');
  const output = {
    id: messageId,
    groupId: String(row.groupId || ''),
    sender: await socialUserByUid(String(row.senderUid || ''), viewerUid, env),
    mine: String(row.senderUid || '') === viewerUid,
    kind: groupMessageKind(row.kind),
    text: decryptPrivateText(row.text, `group-message:${messageId}:text`, env),
    cardId: String(row.cardId || ''),
    createdAt: Number(row.createdAt || 0)
  };
  if (output.kind === 'CARD' && output.cardId) {
    const card = await one(collection(env, 'FoodCard').query().equalTo('id', output.cardId));
    if (card && String(card.status || '') === 'APPROVED') {
      output.sharedCard = await publicCard(card, env, 0, true, viewerUid, false);
    }
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
  for (const row of chronological) messages.push(await publicGroupMessage(row, uid, env));
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
  let cardTitle = '';
  if (kind === 'TEXT') {
    if (text.length === 0 || text.length > MAX_MESSAGE_LENGTH) {
      throw new Error(`消息需为 1–${MAX_MESSAGE_LENGTH} 个字符。`);
    }
    cardId = '';
  } else {
    const card = await one(collection(env, 'FoodCard').query().equalTo('id', cardId));
    if (!card || String(card.status || '') !== 'APPROVED') throw new Error('只能发送仍在公开展示的推荐卡片。');
    cardTitle = String(card.productName || '美食卡片');
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
    messagePreview(kind, text, '', cardTitle), `group-conversation:${groupId}:preview`, env
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
  const cardId = String(payload.cardId || '');
  const card = await one(collection(env, 'FoodCard').query().equalTo('id', cardId));
  if (!card || card.status !== 'APPROVED') throw new Error('只能互动公开卡片。');
  const kind = cardActionKind(payload.action);
  const id = actionId(`card:${kind}`, uid, cardId);
  const actions = collection(env, 'CardAction');
  const existing = await one(actions.query().equalTo('id', id));
  let active = false;
  if (existing) {
    await actions.delete(existing);
  } else {
    await actions.insert({ id, actorUid: uid, cardId, kind, createdAt: Date.now() });
    active = true;
  }
  return { active, ...(await cardActionSummary(cardId, uid, env)) };
}

async function createCardComment(uid, payload, env) {
  const cardId = String(payload.cardId || '');
  const card = await one(collection(env, 'FoodCard').query().equalTo('id', cardId));
  if (!card || card.status !== 'APPROVED') throw new Error('只能评论公开卡片。');
  const content = String(payload.content || '').trim();
  if (content.length === 0 || content.length > MAX_COMMENT_LENGTH) {
    throw new Error(`评论需为 1–${MAX_COMMENT_LENGTH} 个字符。`);
  }
  let parentId = '';
  let replyToNickname = '';
  let replyToUid = '';
  const requestedParentId = String(payload.parentCommentId || '');
  if (requestedParentId.length > 0) {
    const parent = await one(collection(env, 'CardComment').query().equalTo('id', requestedParentId));
    if (!parent || String(parent.cardId || '') !== cardId || String(parent.status || 'ACTIVE') === 'DELETED') {
      throw new Error('要回复的评论不存在或已删除。');
    }
    // The mobile surface keeps one visible reply level. Replying to a reply
    // stays in its root thread while retaining the recipient nickname.
    parentId = String(parent.parentId || '') || String(parent.id || '');
    replyToUid = String(parent.authorUid || '');
    replyToNickname = (await publicProfile(replyToUid, env)).nickname;
  }
  const now = Date.now();
  const commentId = crypto.randomUUID();
  await collection(env, 'CardComment').insert({
    id: commentId, cardId, authorUid: uid, parentId, replyToNickname, replyToUid,
    content, status: 'ACTIVE', createdAt: now, updatedAt: now
  });
  const recipients = new Map();
  if (String(card.ownerUid || '') !== uid) recipients.set(String(card.ownerUid || ''), 'CARD_COMMENT');
  if (replyToUid && replyToUid !== uid) recipients.set(replyToUid, 'REPLY');
  await Promise.all([...recipients.entries()].map(([recipientUid, notificationKind]) =>
    emitNotification(recipientUid, uid, notificationKind, commentId, cardId, env)));
  return { success: true };
}

async function deleteCardComment(uid, payload, env) {
  const commentId = String(payload.commentId || '');
  const comments = collection(env, 'CardComment');
  const comment = await one(comments.query().equalTo('id', commentId));
  if (!comment || (String(comment.authorUid || '') !== uid && !isAdministrator(uid, env))) {
    throw new Error('评论不存在或无权删除。');
  }
  if (String(comment.status || 'ACTIVE') === 'DELETED') return { success: true };
  comment.content = '';
  comment.status = 'DELETED';
  comment.updatedAt = Date.now();
  await comments.upsert(comment);
  const reactions = await collection(env, 'CommentReaction').query().equalTo('commentId', commentId).get();
  if (reactions.length > 0) await collection(env, 'CommentReaction').delete(reactions);
  return { success: true };
}

async function toggleCommentReaction(uid, payload, env) {
  const commentId = String(payload.commentId || '');
  const comment = await one(collection(env, 'CardComment').query().equalTo('id', commentId));
  if (!comment || String(comment.status || 'ACTIVE') === 'DELETED') throw new Error('评论不存在或已删除。');
  if (String(comment.authorUid || '') === uid) throw new Error('不能给自己的评论投票。');
  const card = await one(collection(env, 'FoodCard').query().equalTo('id', String(comment.cardId || '')));
  if (!card || card.status !== 'APPROVED') throw new Error('只能互动公开卡片中的评论。');
  const kind = commentReactionKind(payload.reaction);
  const id = actionId('comment', uid, commentId);
  const reactions = collection(env, 'CommentReaction');
  const existing = await one(reactions.query().equalTo('id', id));
  let active = false;
  let reaction = '';
  if (existing && String(existing.kind || '') === kind) {
    await reactions.delete(existing);
  } else {
    await reactions.upsert({ id, actorUid: uid, commentId, kind, createdAt: Date.now() });
    active = true;
    reaction = kind;
  }
  const summary = await commentReactionSummary(commentId, uid, env);
  return { active, reaction, likeCount: summary.likeCount, dislikeCount: summary.dislikeCount };
}

async function reportCard(uid, payload, env) {
  const cardId = String(payload.cardId || '');
  const card = await one(collection(env, 'FoodCard').query().equalTo('id', cardId));
  if (!card || card.status !== 'APPROVED') throw new Error('只能举报公开卡片。');
  const id = crypto.createHash('sha256').update(`${uid}:${cardId}`).digest('hex');
  const reports = collection(env, 'Report');
  const existing = await one(reports.query().equalTo('id', id));
  if (!existing) {
    await reports.insert({
      id, reporterUid: uid, cardId, reason: String(payload.reason || '其他').slice(0, 100),
      status: 'PENDING', createdAt: Date.now()
    });
  }
  const distinct = await reports.query().equalTo('cardId', cardId).limit(3).get();
  if (distinct.length >= 3) {
    card.status = 'REMOVED';
    card.updatedAt = Date.now();
    await collection(env, 'FoodCard').upsert(card);
  }
  return { success: true };
}

async function deleteOwnCard(uid, payload, env) {
  const cards = collection(env, 'FoodCard');
  const row = await one(cards.query().equalTo('id', String(payload.cardId || '')));
  if (!row || row.ownerUid !== uid) throw new Error('卡片不存在或无权删除。');
  const mediaStore = collection(env, 'CardMedia');
  let cardMedias = await queryAllRows(() => mediaStore.query().equalTo('cardId', row.id));
  if (cardMedias.length === 0 && row.mediaId) {
    const legacyMedia = await one(mediaStore.query().equalTo('id', row.mediaId));
    cardMedias = legacyMedia ? [legacyMedia] : [];
  }
  for (const media of cardMedias) {
    if (media && media.ownerUid === uid) {
      await deleteObject(env, approvedObjectKeyForMedia(media));
      await mediaStore.delete(media);
    }
  }
  await deleteAllMatchingRows(env, 'Report', (reports) => reports.query().equalTo('cardId', row.id));
  await deleteAllMatchingRows(env, 'CardAction', (actions) => actions.query().equalTo('cardId', row.id));
  const relatedComments = await queryAllRows(() => collection(env, 'CardComment').query().equalTo('cardId', row.id));
  for (const comment of relatedComments) {
    await deleteAllMatchingRows(env, 'CommentReaction', (reactions) => reactions.query()
      .equalTo('commentId', comment.id));
  }
  if (relatedComments.length > 0) await collection(env, 'CardComment').delete(relatedComments);
  await cards.delete(row);
  await refreshPublishCount(uid, env);
  return { success: true };
}

async function cleanupAccount(uid, env) {
  const cards = await queryAllRows(() => collection(env, 'FoodCard').query().equalTo('ownerUid', uid));
  for (const card of cards) await deleteOwnCard(uid, { cardId: card.id }, env);
  const medias = await queryAllRows(() => collection(env, 'CardMedia').query().equalTo('ownerUid', uid));
  for (const media of medias) {
    await deleteObject(env, approvedObjectKeyForMedia(media));
  }
  if (medias.length > 0) await collection(env, 'CardMedia').delete(medias);
  await deleteAllMatchingRows(env, 'Report', (reports) => reports.query().equalTo('reporterUid', uid));
  await deleteAllMatchingRows(env, 'CardAction', (actions) => actions.query().equalTo('actorUid', uid));
  const ownComments = await queryAllRows(() => collection(env, 'CardComment').query().equalTo('authorUid', uid));
  for (const comment of ownComments) {
    await deleteAllMatchingRows(env, 'CommentReaction', (reactions) => reactions.query()
      .equalTo('commentId', comment.id));
  }
  if (ownComments.length > 0) await collection(env, 'CardComment').delete(ownComments);
  await deleteAllMatchingRows(env, 'CommentReaction', (reactions) => reactions.query().equalTo('actorUid', uid));
  const friendships = collection(env, 'Friendship');
  const friendshipRows = await friendshipRowsFor(uid, env);
  for (const row of friendshipRows) {
    const otherUid = String(row.memberAUid || '') === uid
      ? String(row.memberBUid || '') : String(row.memberAUid || '');
    if (otherUid) await deleteConversation(uid, otherUid, env);
  }
  if (friendshipRows.length > 0) await friendships.delete(friendshipRows);
  await deleteAllMatchingRows(env, 'ChatMessage', (messages) => messages.query().equalTo('senderUid', uid));
  await deleteAllMatchingRows(env, 'ChatMessage', (messages) => messages.query().equalTo('recipientUid', uid));
  await deleteAllMatchingRows(env, 'Conversation', (conversations) => conversations.query().equalTo('memberAUid', uid));
  await deleteAllMatchingRows(env, 'Conversation', (conversations) => conversations.query().equalTo('memberBUid', uid));
  const ownedGroups = await queryAllRows(() => collection(env, 'GroupConversation').query().equalTo('ownerUid', uid));
  for (const group of ownedGroups) await deleteGroupConversation(String(group.id || ''), env);
  const groupMemberships = await queryAllRows(() => collection(env, 'GroupMember').query().equalTo('memberUid', uid));
  for (const membership of groupMemberships) {
    const groupId = String(membership.groupId || '');
    const group = await one(collection(env, 'GroupConversation').query().equalTo('id', groupId));
    if (!group) continue;
    const members = await groupMembersFor(groupId, env);
    if (members.length <= 2) {
      await deleteGroupConversation(groupId, env);
      continue;
    }
    await collection(env, 'GroupMember').delete(membership);
    group.memberCount = members.length - 1;
    group.updatedAt = Date.now();
    await collection(env, 'GroupConversation').upsert(group);
  }
  await deleteAllMatchingRows(env, 'GroupMessage', (messages) => messages.query().equalTo('senderUid', uid));
  await deleteAllMatchingRows(env, 'FriendReport', (reports) => reports.query().equalTo('reporterUid', uid));
  await deleteAllMatchingRows(env, 'FriendReport', (reports) => reports.query().equalTo('targetUid', uid));
  await deleteAllMatchingRows(env, 'PushRegistration', (registrations) => registrations.query().equalTo('ownerUid', uid));
  await deleteAllMatchingRows(env, 'WidgetRegistration', (registrations) => registrations.query().equalTo('ownerUid', uid));
  await deleteAllMatchingRows(env, 'NotificationEvent', (notifications) => notifications.query().equalTo('recipientUid', uid));
  await deleteAllMatchingRows(env, 'NotificationEvent', (notifications) => notifications.query().equalTo('actorUid', uid));
  const profile = await one(collection(env, 'UserProfile').query().equalTo('uid', uid));
  if (profile) await collection(env, 'UserProfile').delete(profile);
  await deleteAllMatchingRows(env, 'IdentityBinding', (bindings) => bindings.query().equalTo('canonicalUid', uid));
  await deleteAllMatchingRows(env, 'AuthMigrationTicket', (tickets) => tickets.query().equalTo('canonicalUid', uid));
  return { success: true };
}

const operations = {
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
  'get-public-media': async ({ accessToken, payload }, env) =>
    getPublicMedia(accessToken ? await verifiedUid(accessToken, env) : '', payload, env),
  'publish-card': async ({ accessToken, payload }, env) => publishCard(await verifiedUid(accessToken, env), payload, env),
  'list-nearby-cards': async ({ accessToken, payload }, env) => payload.scope === 'all'
    ? listPublicRecommendations(payload, env) : listNearby(await verifiedUid(accessToken, env), payload, env),
  'list-friend-rankings': async ({ accessToken }, env) => listFriendRankings(await verifiedUid(accessToken, env), env),
  'get-friend-profile': async ({ accessToken, payload }, env) =>
    friendProfile(await verifiedUid(accessToken, env), payload, env),
  'get-card-detail': async ({ accessToken, payload }, env) =>
    cardDetail(accessToken ? await verifiedUid(accessToken, env) : '', payload, env),
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
    listConversations(await verifiedUid(accessToken, env), payload, env),
  'list-messages': async ({ accessToken, payload }, env) => listMessages(await verifiedUid(accessToken, env), payload, env),
  'send-message': async ({ accessToken, payload }, env) => sendMessage(await verifiedUid(accessToken, env), payload, env),
  'create-group-chat': async ({ accessToken, payload }, env) =>
    createGroupChat(await verifiedUid(accessToken, env), payload, env),
  'list-group-conversations': async ({ accessToken, payload }, env) =>
    listGroupConversations(await verifiedUid(accessToken, env), payload, env),
  'get-group-chat': async ({ accessToken, payload }, env) =>
    getGroupChat(await verifiedUid(accessToken, env), payload, env),
  'list-group-messages': async ({ accessToken, payload }, env) =>
    listGroupMessages(await verifiedUid(accessToken, env), payload, env),
  'send-group-message': async ({ accessToken, payload }, env) =>
    sendGroupMessage(await verifiedUid(accessToken, env), payload, env),
  'leave-group-chat': async ({ accessToken, payload }, env) =>
    leaveGroupChat(await verifiedUid(accessToken, env), payload, env),
  'remove-group-member': async ({ accessToken, payload }, env) =>
    removeGroupMember(await verifiedUid(accessToken, env), payload, env),
  'list-notifications': async ({ accessToken, payload }, env) =>
    listNotifications(await verifiedUid(accessToken, env), payload, env),
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
  'delete-account-data': async ({ accessToken }, env) => cleanupAccount(await verifiedUid(accessToken, env), env)
};

function createHandler(operation) {
  if (!operations[operation]) throw new Error(`未知操作 ${operation}`);
  return async function handler(event, context, callback, logger) {
    try {
      const input = parseBody(event);
      const env = context && context.env ? context.env : {};
      const data = await operations[operation](input, env);
      return callback({ ok: true, data, message: '' });
    } catch (error) {
      logger.error(`${operation} failed: ${safeLogError(error)}`);
      return callback({ ok: false, data: {}, message: error && error.message ? error.message : '云端请求失败。' });
    }
  };
}

async function executeOperation(operation, input, env = process.env) {
  if (!operations[operation]) throw new Error(`未知操作 ${operation}`);
  const safeInput = input && typeof input === 'object' ? input : {};
  return operations[operation]({
    accessToken: typeof safeInput.accessToken === 'string' ? safeInput.accessToken : '',
    payload: safeInput.payload && typeof safeInput.payload === 'object' ? safeInput.payload : {}
  }, env || {});
}

module.exports = { createHandler, executeOperation, safeLogError, haversineKm, geohash };
