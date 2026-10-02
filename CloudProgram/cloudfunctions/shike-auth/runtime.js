'use strict';

const crypto = require('crypto');
const ACCOUNT_TOKEN_URL = 'https://oauth-login.cloud.huawei.com/oauth2/v3/token';
const ACCOUNT_TOKEN_INFO_URL =
  'https://oauth-api.cloud.huawei.com/rest.php?nsp_fmt=JSON&nsp_svc=huawei.oauth2.user.getTokenInfo';

function required(env, name) {
  const value = env[name] || process.env[name];
  if (!value) throw new Error(`登录云对象缺少环境变量 ${name}`);
  return String(value);
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

function decodeJwtPayload(token) {
  const parts = String(token || '').split('.');
  if (parts.length !== 3) throw new Error('华为账号未返回有效的 ID Token。');
  const encoded = parts[1].replace(/-/g, '+').replace(/_/g, '/');
  const padding = '='.repeat((4 - encoded.length % 4) % 4);
  try {
    return JSON.parse(Buffer.from(encoded + padding, 'base64').toString('utf8'));
  } catch (_error) {
    throw new Error('华为账号 ID Token 无法解析。');
  }
}

function validateTokenBinding(idToken, clientId, nonce) {
  // The ID token is received directly from Huawei's TLS token endpoint. Check
  // its application, issuer, nonce, and lifetime bindings before accepting the
  // access token returned in the same response.
  const claims = decodeJwtPayload(idToken);
  const audience = Array.isArray(claims.aud) ? claims.aud.map(String) : [String(claims.aud || '')];
  const nowSeconds = Math.floor(Date.now() / 1000);
  if (claims.iss !== 'https://accounts.huawei.com' || !audience.includes(clientId) ||
    (claims.azp && String(claims.azp) !== clientId) || String(claims.nonce || '') !== nonce ||
    !Number.isFinite(Number(claims.exp)) || Number(claims.exp) <= nowSeconds) {
    throw new Error('华为账号身份凭证绑定校验失败，请重新登录。');
  }
  return claims;
}

async function parseJsonResponse(response, failureMessage) {
  const text = await response.text();
  let body = {};
  try {
    body = text ? JSON.parse(text) : {};
  } catch (_error) {
    throw new Error(failureMessage);
  }
  if (!response.ok) throw new Error(failureMessage);
  return body;
}

async function accountTokenInfo(accessToken, expectedClientId = '') {
  if (!accessToken || String(accessToken).length > 8192) {
    throw new Error('华为账号用户凭证为空或格式不正确。');
  }
  const parameters = new URLSearchParams({
    access_token: String(accessToken),
    open_id: 'OPENID'
  });
  const response = await fetch(ACCOUNT_TOKEN_INFO_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: parameters.toString()
  });
  const result = await parseJsonResponse(response, '华为账号用户凭证校验请求失败。');
  const expiresIn = Number(result.expire_in);
  const uid = String(result.union_id || result.open_id || '');
  if (result.error || Number(result.type) !== 0 || !uid || !Number.isFinite(expiresIn) || expiresIn <= 0 ||
    (expectedClientId && String(result.client_id || '') !== expectedClientId)) {
    throw new Error('华为账号用户凭证无效或已过期，请重新登录。');
  }
  return { uid, expiresIn, scope: String(result.scope || '') };
}

async function clientApiToken(env) {
  const base = env.SHIKE_AGC_AUTH_BASE || process.env.SHIKE_AGC_AUTH_BASE || 'https://connect-drcn.dbankcloud.cn';
  const response = await fetch(`${base}/agc/apigw/oauth2/v1/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      grant_type: 'client_credentials',
      client_id: required(env, 'SHIKE_AGC_CLIENT_ID'),
      client_secret: required(env, 'SHIKE_AGC_CLIENT_SECRET'),
      useJwt: 1
    })
  });
  const body = await response.json();
  if (!response.ok || !body.access_token) throw new Error('AGC 客户端鉴权失败。');
  return String(body.access_token);
}

async function agcAuthRequest(env, path, body, userAccessToken = '') {
  const base = env.SHIKE_AGC_AUTH_BASE || process.env.SHIKE_AGC_AUTH_BASE || 'https://connect-drcn.dbankcloud.cn';
  const apiToken = await clientApiToken(env);
  const headers = {
    'Content-Type': 'application/json',
    client_id: required(env, 'SHIKE_AGC_CLIENT_ID'),
    Authorization: `Bearer ${apiToken}`
  };
  if (userAccessToken) headers.access_token = userAccessToken;
  const response = await fetch(`${base}${path}?productId=${encodeURIComponent(required(env, 'SHIKE_AGC_PROJECT_ID'))}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body)
  });
  const result = await response.json();
  let ret = result.ret;
  if (typeof ret === 'string') {
    try { ret = JSON.parse(ret); } catch (_error) { ret = null; }
  }
  if (!response.ok || !ret || Number(ret.code) !== 0) {
    throw new Error(ret && ret.msg ? String(ret.msg) : 'AGC 认证请求失败。');
  }
  return result;
}

function requireUserAccessToken(accessToken) {
  const value = String(accessToken || '').trim();
  if (!value || value.length > 8192) {
    throw new Error('当前 AGC 登录会话无效，请重新登录后再关联账号。');
  }
  return value;
}

function tokenValue(value) {
  if (typeof value === 'string') {
    try { value = JSON.parse(value); } catch (_error) { return { token: '', validPeriod: 0 }; }
  }
  return value && typeof value === 'object' ? value : { token: '', validPeriod: 0 };
}

function base64Url(value) {
  return Buffer.from(value).toString('base64')
    .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function identityTicketKey(env) {
  return crypto.createHash('sha256').update(required(env, 'SHIKE_IDENTITY_TICKET_KEY')).digest();
}

/**
 * The migration ticket is opaque to the client. Its legacy and AGC UIDs are
 * encrypted with the deployment-only key and authenticated by AES-GCM.
 */
function issueIdentityTicket(legacyUid, agcUid, env) {
  const now = Math.floor(Date.now() / 1000);
  const plaintext = JSON.stringify({
    version: 1,
    kind: 'LEGACY_LOGIN',
    legacyUid: String(legacyUid),
    agcUid: String(agcUid),
    issuedAt: now,
    expiresAt: now + 600,
    ticketId: crypto.randomUUID()
  });
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', identityTicketKey(env), iv);
  const ciphertext = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return `v1.${base64Url(iv)}.${base64Url(ciphertext)}.${base64Url(tag)}`;
}

async function obtainHuaweiAccountIdentity(payload, env) {
  const authorizationCode = String(payload.authorizationCode || '');
  const nonce = String(payload.nonce || '');
  if (!authorizationCode || authorizationCode.length > 4096 || !nonce || nonce.length > 255) {
    throw new Error('缺少有效的一次性华为账号授权码。');
  }
  const clientId = required(env, 'SHIKE_ACCOUNT_CLIENT_ID');
  const parameters = new URLSearchParams({
    grant_type: 'authorization_code',
    code: authorizationCode,
    client_id: clientId,
    client_secret: required(env, 'SHIKE_ACCOUNT_CLIENT_SECRET')
  });
  const redirectUri = String(env.SHIKE_ACCOUNT_REDIRECT_URI || process.env.SHIKE_ACCOUNT_REDIRECT_URI || '').trim();
  if (redirectUri) parameters.set('redirect_uri', redirectUri);
  const response = await fetch(ACCOUNT_TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: parameters.toString()
  });
  const result = await parseJsonResponse(response, '华为账号一次性授权码交换失败，请重新登录。');
  if (!result.access_token || !result.id_token) {
    throw new Error('华为账号未返回完整的用户级凭证。');
  }
  validateTokenBinding(String(result.id_token), clientId, nonce);
  const tokenInfo = await accountTokenInfo(String(result.access_token), clientId);
  return {
    accessToken: String(result.access_token),
    legacyUid: tokenInfo.uid,
    expiresIn: tokenInfo.expiresIn
  };
}

async function obtainUserCredential(payload, env) {
  const huaweiAccount = await obtainHuaweiAccountIdentity(payload, env);
  const agcResult = await agcAuthRequest(env, '/agc/apigw/oauth2/third/v1/user-signin', {
    provider: 1,
    token: huaweiAccount.accessToken,
    extraData: '',
    autoCreateUser: 1,
    useJwt: 1
  });
  const accessToken = tokenValue(agcResult.accessToken);
  const userInfo = Array.isArray(agcResult.userInfo) ? agcResult.userInfo[0] : agcResult.userInfo;
  if (!accessToken.token || !userInfo || !userInfo.uid) {
    throw new Error('AGC 未返回完整的用户会话。');
  }
  const validitySeconds = Math.max(1, Math.min(Number(accessToken.validPeriod || 3600), huaweiAccount.expiresIn));
  return {
    accessToken: String(accessToken.token),
    expiresAt: Date.now() + validitySeconds * 1000,
    migrationTicket: issueIdentityTicket(huaweiAccount.legacyUid, String(userInfo.uid), env),
    profile: {
      // The client uses upsert-profile after consuming the ticket. Do not
      // expose either provider UID in this public auth response.
      uid: '',
      nickname: '华为账号用户',
      avatarUrl: '',
      accountStatus: 'ACTIVE',
      publishCount: 0,
      createdAt: Date.now(),
      updatedAt: Date.now()
    }
  };
}

async function linkHuaweiAccount(accessToken, payload, env) {
  const huaweiAccount = await obtainHuaweiAccountIdentity(payload, env);
  const result = await agcAuthRequest(env, '/agc/apigw/oauth2/third/v1/user-link', {
    provider: 1,
    token: huaweiAccount.accessToken,
    extraData: ''
  }, requireUserAccessToken(accessToken));
  const userInfo = Array.isArray(result.providerUserInfo) ? result.providerUserInfo[0] : result.providerUserInfo;
  if (!userInfo || !userInfo.uid) {
    throw new Error('AGC 未确认华为账号关联结果。');
  }
  return { success: true };
}

const operations = {
  'exchange-huawei-account': async ({ accessToken, payload }, env) => {
    const input = payload || {};
    const operation = String(input.operation || 'SIGN_IN');
    if (operation === 'LINK_HUAWEI') return linkHuaweiAccount(accessToken, input, env);
    if (operation !== 'SIGN_IN') throw new Error('未知账号关联操作。');
    return obtainUserCredential(input, env);
  }
};

async function executeOperation(operation, input, env = process.env) {
  if (!operations[operation]) throw new Error(`未知登录操作 ${operation}`);
  const safeInput = input && typeof input === 'object' ? input : { accessToken: '', payload: {} };
  return operations[operation]({
    accessToken: typeof safeInput.accessToken === 'string' ? safeInput.accessToken : '',
    payload: safeInput.payload && typeof safeInput.payload === 'object' ? safeInput.payload : {}
  }, env || {});
}

module.exports = { executeOperation, safeLogError };
