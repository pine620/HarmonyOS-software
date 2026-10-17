/**
 * 【文件职责】昵称 + 密码登录（主登录方式）：
 *   - 昵称占用 NicknameClaim（以规范化昵称的摘要为主键，保证唯一）、密码凭据 PasswordCredential（scrypt 哈希 + 随机盐）、登录节流 PasswordThrottle；
 *   - 登录成功后用“自有账号认证”换取 AGC Token：cloud.auth().sign() 用 SHIKE_ACCOUNT_SIGNING_PRIVATE_KEY 签发自定义 Token，
 *     再调用 AGC 认证 REST 接口 user-signin（provider=10）得到 AGC Access Token，并写入 IdentityBinding 映射到业务 UID；
 *   - 设置 / 修改密码、退出（撤销 AGC 会话）、旧数据迁移。受 SHIKE_NICKNAME_AUTH_ENABLED / SHIKE_NICKNAME_MIGRATING 控制。
 * 【新人注意】日志中绝不记录密码、Token 或上游响应正文。
 */
'use strict';

const crypto = require('crypto');
const { promisify } = require('util');
const scrypt = promisify(crypto.scrypt);
const { accessError, isAccountActive } = require('./shared/content-policy');
const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const invalidLogin = () => accessError('昵称或密码不正确。', 'INVALID_CREDENTIALS');

// 规范化并校验昵称（2–24 个字），返回显示名与用于唯一性的 key。
function nickname(value) {
  if (typeof value !== 'string' || value.length > 96) throw accessError('请输入 2–24 个字的昵称。', 'INVALID_NICKNAME');
  const display = value.normalize('NFKC').trim();
  if (display.length < 2 || display.length > 24 || !/^[\p{L}\p{N}_.-]+$/u.test(display)) {
    throw accessError('昵称需为 2–24 个字，仅支持文字、数字、下划线、点和短横线。', 'INVALID_NICKNAME');
  }
  return { display, key: hash(display.toLowerCase()) };
}

// 校验密码强度（8–128 位、至少两类字符）。
function validatePassword(value) {
  if (typeof value !== 'string' || value.length < 8 || value.length > 128) {
    throw accessError('密码需为 8–128 个字符。', 'INVALID_PASSWORD');
  }
  if ([/[a-z]/, /[A-Z]/, /[0-9]/, /[^a-zA-Z0-9]/].filter(rule => rule.test(value)).length < 2) {
    throw accessError('密码至少包含两种字符。', 'INVALID_PASSWORD');
  }
}

// scrypt 密码哈希（N=32768）。
async function passwordHash(password, salt) {
  return scrypt(password, salt, 64, { N: 32768, r: 8, p: 1, maxmem: 64 * 1024 * 1024 });
}

// 创建模块：ctx 由 runtime.js 注入。
function createNicknameAuth(ctx) {
  const { collection, one, models, cloud, verifiedIdentity, profileForWrite, profileResponse, identityBindingId } = ctx;
  const model = (name, fields) => Object.assign(new models[name](), fields);
  const read = async (tx, env, name, field, value) => (await tx.executeQuery(collection(env, name).query().equalTo(field, value).limit(1)))[0];
  const enabled = env => String(env.SHIKE_NICKNAME_AUTH_ENABLED || '') === 'true';
  // 构造上游失败错误（只带阶段与错误码）。
  function upstreamFailure(stage, reason, code, message, status = 0, upstreamCode = '') {
    const value = String(upstreamCode);
    const safeCode = /^[A-Za-z0-9_-]{1,24}$/.test(value) ? value : 'not-returned';
    const id = ctx.requestId ? String(ctx.requestId()) : '';
    const safeId = /^[A-Za-z0-9_-]{1,64}$/.test(id) ? id : 'not-provided';
    // 不要记录上游响应正文或消息：其中可能含有签名凭据。
    console.error(`[NicknameAuth] requestId=${safeId} stage=${stage} reason=${reason} status=${status} upstreamCode=${safeCode}`);
    const suffix = safeCode !== 'not-returned' ? `（上游码 ${safeCode}）` : status ? `（HTTP ${status}）` : '';
    return accessError(message + suffix, code);
  }
  // 取 SDK 错误码。
  function sdkErrorCode(error) {
    if (!error) return '';
    if (typeof error.code === 'string' || typeof error.code === 'number') return String(error.code);
    if (typeof error.getCode === 'function') { try { return String(error.getCode()); } catch (_) { } }
    return '';
  }
  // 昵称登录是否就绪（开关与迁移状态）。
  async function ready(env) {
    if (!enabled(env) || String(env.SHIKE_NICKNAME_MIGRATING || '') === 'true') {
      throw accessError('昵称登录正在准备，请稍后重试。', 'FEATURE_NOT_READY');
    }
    const state = await one(collection(env, 'NicknameClaim').query().equalTo('key', 'migration'));
    if (!state || state.ownerUid !== 'READY') throw accessError('昵称资料尚未迁移完成。', 'FEATURE_NOT_READY');
  }

  // 昵称占用以规范化昵称的摘要为主键；所有占用变化与资料 / 凭据写入都在同一个 Cloud DB 事务中完成。
  // 在事务中占用昵称（previousKey 为改名前的昵称）。
  async function claim(tx, env, uid, display, previousKey = '') {
    const name = nickname(display);
    const existing = await read(tx, env, 'NicknameClaim', 'key', name.key);
    if (existing && existing.ownerUid !== uid) throw accessError('该昵称已被使用，请换一个。', 'NICKNAME_TAKEN');
    let previous;
    if (previousKey && previousKey !== name.key) previous = await read(tx, env, 'NicknameClaim', 'key', previousKey);
    tx.executeUpsert([model('NicknameClaim', { key: name.key, ownerUid: uid, nickname: name.display, updatedAt: Date.now() })]);
    if (previous && previous.ownerUid === uid) tx.executeDelete([previous]);
    return name;
  }

  // 在事务中修改昵称。
  async function rename(tx, env, current, saved) {
    const migration = await read(tx, env, 'NicknameClaim', 'key', 'migration');
    if (!migration || migration.ownerUid !== 'READY') return;
    const credential = await read(tx, env, 'PasswordCredential', 'uid', saved.uid);
    const oldName = current ? String(current.nicknameValue || current.nickname || '') : '';
    if (oldName === saved.nicknameValue && !credential) return;
    let previousKey = credential ? credential.nicknameKey : '';
    if (!previousKey && oldName) { try { previousKey = nickname(oldName).key; } catch (_) { } }
    const name = await claim(tx, env, saved.uid, saved.nicknameValue, previousKey);
    saved.nickname = name.display; saved.nicknameValue = name.display;
    if (credential) tx.executeUpsert([model('PasswordCredential', { ...credential, nicknameKey: name.key, updatedAt: Date.now() })]);
  }

  // 固定数量的节流桶，避免为任意昵称不断增加数据库行；在执行 scrypt 或调用上游之前先占用尝试次数（成功的尝试也计入）。
  // 登录节流：同一昵称短时间内尝试过多时拒绝（先占用次数再计算哈希）。
  async function throttle(key, env) {
    const id = 'login:' + parseInt(hash(key).slice(0, 4), 16) % 1024;
    const committed = await collection(env, 'PasswordThrottle').runTransaction({ apply: async tx => {
      const now = Date.now();
      const global = await read(tx, env, 'PasswordThrottle', 'id', 'login:global');
      const local = await read(tx, env, 'PasswordThrottle', 'id', id);
      const rows = [[global, 'login:global', 60000, 120], [local, id, 900000, 12]].map(([row, bucket, period, limit]) => {
        const fresh = !row || now - row.windowAt >= period;
        const count = fresh ? 0 : Number(row.count || 0);
        if (count >= limit) throw accessError('尝试次数过多，请稍后再试。', 'AUTH_RATE_LIMITED');
        return model('PasswordThrottle', { id: bucket, windowAt: fresh ? now : row.windowAt, count: count + 1 });
      });
      tx.executeUpsert(rows); return true;
    } });
    if (!committed) throw accessError('登录请求繁忙，请稍后重试。', 'AUTH_RATE_LIMITED');
  }

  // 确认请求来自刚刚完成验证的会话（设置密码前要求）。
  async function freshProvider(accessToken, env) {
    const identity = await verifiedIdentity(accessToken, env);
    let verified;
    try { verified = await cloud.auth().verifyAccessToken({ accessToken, checkRevoked: true }); }
    catch (_) { throw accessError('请重新验证邮箱或华为账号。', 'REAUTH_REQUIRED'); }
    const provider = verified.getProviderInfo();
    const kind = Number(provider && provider.getSignInProvider());
    const age = Date.now() / 1000 - Number(verified.getAuthTime());
    if (![1, 12].includes(kind) || !Number.isFinite(age) || age < -60 || age > 600 ||
      kind === 12 && verified.isEmailVerified() !== true) {
      throw accessError('请重新验证邮箱或华为账号后设置密码。', 'REAUTH_REQUIRED');
    }
    return identity;
  }

  // 查询当前账号是否已设置昵称密码。
  async function status(accessToken, env) {
    await ready(env);
    const { canonicalUid: uid } = await verifiedIdentity(accessToken, env, true);
    const row = await one(collection(env, 'PasswordCredential').query().equalTo('uid', uid));
    return { configured: !!row };
  }

  // 首次设置昵称与密码。
  async function configure(accessToken, payload, env) {
    await ready(env);
    const name = nickname(payload.nickname);
    validatePassword(payload.password);
    if (payload.password.normalize('NFKC').toLowerCase() === name.display.toLowerCase()) {
      throw accessError('密码不能与昵称相同。', 'INVALID_PASSWORD');
    }
    const { canonicalUid: uid } = await freshProvider(accessToken, env);
    await throttle('setup:' + uid, env);
    const salt = crypto.randomBytes(32).toString('hex');
    const digest = (await passwordHash(payload.password, salt)).toString('hex');
    const generation = crypto.randomUUID();
    const occupied = await one(collection(env, 'NicknameClaim').query().equalTo('key', name.key));
    if (occupied && occupied.ownerUid !== uid) throw accessError('该昵称已被使用，请换一个。', 'NICKNAME_TAKEN');
    // 修改已保存的凭据前，先验证当前确实是密码会话；上游失败时必须保持旧密码与会话不变。
    const session = await exchange(uid, generation, env);
    return commitPassword(uid, name, digest, salt, generation, session, env);
  }

  // 修改密码（校验当前密码）。
  async function changePassword(accessToken, payload, env) {
    await ready(env);
    const { canonicalUid: uid } = await verifiedIdentity(accessToken, env, true);
    if (typeof payload.expectedUid !== 'string' || payload.expectedUid !== uid) {
      throw accessError('当前账号已变化，请重新登录后更改密码。', 'ACCOUNT_MISMATCH');
    }
    if (typeof payload.currentPassword !== 'string' || !payload.currentPassword || payload.currentPassword.length > 128) {
      throw accessError('请输入当前密码。', 'CURRENT_PASSWORD_INCORRECT');
    }
    validatePassword(payload.newPassword);
    if (payload.newPassword === payload.currentPassword) throw accessError('新密码不能与当前密码相同。', 'PASSWORD_UNCHANGED');
    await throttle('change:' + uid, env);
    const old = await one(collection(env, 'PasswordCredential').query().equalTo('uid', uid));
    if (!old) throw accessError('当前账号尚未设置昵称密码，请先通过绑定身份设置。', 'PASSWORD_NOT_SET');
    if (!old.generation) throw accessError('密码凭据状态无效，请通过绑定身份重新设置。', 'INVALID_STATE');
    const proof = await passwordHash(payload.currentPassword, old.salt);
    const expected = Buffer.from(old.passwordHash, 'hex');
    if (proof.length !== expected.length || !crypto.timingSafeEqual(proof, expected)) {
      throw accessError('当前密码不正确。', 'CURRENT_PASSWORD_INCORRECT');
    }
    const profile = await one(collection(env, 'UserProfile').query().equalTo('uid', uid));
    if (!profile || !isAccountActive(profile)) throw accessError('账号不可用。', 'ACCOUNT_INACTIVE');
    if (payload.newPassword.normalize('NFKC').toLowerCase() === String(profile.nicknameValue || profile.nickname || '').normalize('NFKC').toLowerCase()) {
      throw accessError('密码不能与昵称相同。', 'INVALID_PASSWORD');
    }
    const salt = crypto.randomBytes(32).toString('hex');
    const digest = (await passwordHash(payload.newPassword, salt)).toString('hex');
    const generation = crypto.randomUUID();
    const session = await exchange(uid, generation, env);
    return commitPassword(uid, null, digest, salt, generation, session, env, old.generation, payload.newPassword);
  }

  // 在事务中保存新密码并递增凭据代次，然后换取新会话。
  async function commitPassword(uid, name, digest, salt, generation, session, env, expectedGeneration = '', newPassword = '') {
    let saved;
    const committed = await collection(env, 'PasswordCredential').runTransaction({ apply: async tx => {
      const profile = await read(tx, env, 'UserProfile', 'uid', uid);
      const old = await read(tx, env, 'PasswordCredential', 'uid', uid);
      if (!profile || !isAccountActive(profile)) throw accessError('账号不可用。', 'ACCOUNT_INACTIVE');
      if (expectedGeneration && (!old || old.generation !== expectedGeneration)) {
        throw accessError('密码已被更改，请重新登录后再操作。', 'PASSWORD_STATE_CHANGED');
      }
      if (!name && newPassword.normalize('NFKC').toLowerCase() === String(profile.nicknameValue || profile.nickname || '').normalize('NFKC').toLowerCase()) {
        throw accessError('密码不能与昵称相同。', 'INVALID_PASSWORD');
      }
      let oldKey = old ? old.nicknameKey : '';
      if (!oldKey) { try { oldKey = nickname(profile.nicknameValue || profile.nickname).key; } catch (_) { } }
      const oldBinding = old && old.customAgcUid ? await read(tx, env, 'IdentityBinding', 'id', identityBindingId('AGC', old.customAgcUid)) : null;
      if (oldBinding && oldBinding.canonicalUid !== uid) throw accessError('账号身份不一致。', 'INVALID_STATE');
      const bindingId = identityBindingId('AGC', session.providerUid);
      const newBinding = await read(tx, env, 'IdentityBinding', 'id', bindingId);
      if (newBinding && (newBinding.canonicalUid !== uid || newBinding.status !== 'ACTIVE')) throw accessError('账号身份不一致。', 'INVALID_STATE');
      if (old && old.customAgcUid === session.providerUid) throw accessError('认证服务未生成新的密码身份。', 'INVALID_STATE');
      if (name) await claim(tx, env, uid, name.display, oldKey);
      const now = ctx.logicalWriteTime(profile.updatedAt);
      saved = name ? profileForWrite(profile, now) : profile;
      if (name) { saved.nickname = name.display; saved.nicknameValue = name.display; tx.executeUpsert([saved]); }
      tx.executeUpsert([model('PasswordCredential', { uid, nicknameKey: name ? name.key : old.nicknameKey, salt, passwordHash: digest,
        generation, customAgcUid: session.providerUid, createdAt: old ? old.createdAt : now, updatedAt: now })]);
      tx.executeUpsert([model('IdentityBinding', { id: bindingId, provider: 'AGC', providerUid: session.providerUid,
        canonicalUid: uid, status: 'ACTIVE', createdAt: newBinding ? newBinding.createdAt : now, updatedAt: now })]);
      if (oldBinding) tx.executeUpsert([model('IdentityBinding', { ...oldBinding, status: 'DISABLED', updatedAt: now })]);
      return true;
    } });
    if (!committed || !saved) throw accessError('密码保存未完成，请重试。', 'CONFLICT');
    const profile = profileResponse(saved, env);
    return { ...profile, profile, accessToken: session.accessToken, expiresAt: session.expiresAt };
  }

  // 发送 JSON 请求到 AGC 认证服务（带超时）。
  async function jsonRequest(url, headers, body, stage) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 8000);
    let status = 0;
    try {
      const response = await fetch(url, { method: 'POST', headers, body: JSON.stringify(body), signal: controller.signal });
      status = response.status || 0;
      if (!response.ok) throw upstreamFailure(stage, 'HTTP_REJECTED', 'AUTH_UPSTREAM_HTTP', '认证服务请求被拒绝。', status);
      let result;
      try { result = await response.json(); }
      catch (_) { throw upstreamFailure(stage, 'INVALID_JSON', 'AUTH_UPSTREAM_RESPONSE', '认证服务响应格式无效。', status); }
      if (!result || typeof result !== 'object' || Array.isArray(result)) {
        throw upstreamFailure(stage, 'INVALID_BODY', 'AUTH_UPSTREAM_RESPONSE', '认证服务响应格式无效。', status);
      }
      return result;
    } catch (error) {
      if (error && typeof error.code === 'string' && error.code.startsWith('AUTH_')) throw error;
      if (controller.signal.aborted) throw upstreamFailure(stage, 'TIMEOUT', 'AUTH_UPSTREAM_TIMEOUT', '认证服务请求超时，请重试。', status);
      throw upstreamFailure(stage, 'NETWORK', 'AUTH_UPSTREAM_NETWORK', '无法连接认证服务，请稍后重试。', status);
    }
    finally { clearTimeout(timer); }
  }
  // 读取必需配置。
  function setting(env, key) {
    const value = String(env[key] || '').trim();
    if (!value || /^REPLACE_WITH_/i.test(value)) throw accessError('昵称登录服务尚未配置完成。', 'AUTH_CONFIGURATION_REQUIRED');
    return value;
  }
  // 把值转换为对象（非对象返回空对象）。
  function object(value) {
    if (typeof value === 'string') { try { value = JSON.parse(value); } catch (_) { return {}; } }
    return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  }
  // 用自有账号认证换取 AGC Access Token（流程见文件头）。
  async function exchange(uid, generation, env) {
    const customUid = 'shike-password:' + hash(uid) + ':' + generation;
    let token;
    try { token = cloud.auth().sign({ uid: customUid, displayName: '', photoUrl: '',
      privateKey: setting(env, 'SHIKE_ACCOUNT_SIGNING_PRIVATE_KEY').replace(/\\n/g, '\n').trim() }).getToken(); }
    catch (error) { throw upstreamFailure('SIGN_CUSTOM_TOKEN', 'SIGN_FAILED', 'AUTH_CONFIGURATION_REQUIRED', '昵称登录签名配置无效。', 0, sdkErrorCode(error)); }
    if (typeof token !== 'string' || !token) throw accessError('昵称登录未生成签名凭据。', 'AUTH_CONFIGURATION_REQUIRED');
    const base = env.SHIKE_AGC_AUTH_BASE || 'https://connect-drcn.dbankcloud.cn';
    if (!/^https:\/\/connect-drcn\.dbankcloud\.cn$/.test(base)) throw accessError('认证服务域名配置无效。', 'AUTH_CONFIGURATION_REQUIRED');
    const clientId = setting(env, 'SHIKE_AGC_CLIENT_ID');
    const api = await jsonRequest(base + '/agc/apigw/oauth2/v1/token', { 'Content-Type': 'application/json' }, {
      grant_type: 'client_credentials', client_id: clientId, client_secret: setting(env, 'SHIKE_AGC_CLIENT_SECRET'), useJwt: 1
    }, 'AGC_CLIENT_TOKEN');
    if (typeof api.access_token !== 'string' || !api.access_token) {
      throw upstreamFailure('AGC_CLIENT_TOKEN', 'REJECTED', 'AUTH_AGC_CLIENT_REJECTED',
        'AGC 客户端鉴权失败，请核对登录服务配置。', 200, api.error || object(api.ret).code);
    }
    const result = await jsonRequest(base + '/agc/apigw/oauth2/third/v1/user-signin?productId=' + encodeURIComponent(setting(env, 'SHIKE_AGC_PROJECT_ID')),
      { 'Content-Type': 'application/json', client_id: clientId, Authorization: 'Bearer ' + api.access_token },
      { provider: 10, token, autoCreateUser: 1, useJwt: 1 }, 'AGC_USER_SIGN_IN');
    const credential = object(result.accessToken), ret = object(result.ret);
    if (ret.code === undefined || ret.code === null || Number(ret.code) !== 0) {
      throw upstreamFailure('AGC_USER_SIGN_IN', 'REJECTED', 'AUTH_AGC_SIGN_IN_REJECTED',
        'AGC 拒绝自有账号登录，请核对该项目的认证配置。', 200, ret.code);
    }
    if (typeof credential.token !== 'string' || !credential.token ||
      !Number.isFinite(Number(credential.validPeriod)) || Number(credential.validPeriod) <= 0) {
      throw upstreamFailure('AGC_USER_SIGN_IN', 'MISSING_TOKEN', 'AUTH_UPSTREAM_RESPONSE', '认证服务未返回有效的登录凭证。');
    }
    let verified;
    try { verified = await cloud.auth().verifyAccessToken({ accessToken: credential.token, checkRevoked: true }); }
    catch (error) { throw upstreamFailure('VERIFY_ACCESS_TOKEN', 'VERIFY_FAILED', 'AUTH_AGC_TOKEN_INVALID', 'AGC 登录凭证校验失败。', 0, sdkErrorCode(error)); }
    const providerUid = String(verified.getSub() || '');
    const expiry = Number(verified.getExp()) * 1000;
    if (!providerUid || Number(verified.getProviderInfo()?.getSignInProvider()) !== 10 ||
      !Number.isFinite(expiry) || expiry <= Date.now()) {
      throw upstreamFailure('VERIFY_ACCESS_TOKEN', 'INVALID_CLAIMS', 'AUTH_AGC_TOKEN_INVALID', 'AGC 登录凭证类型或有效期无效。');
    }
    // 刻意不返回也不保存 Refresh Token；客户端沿用“外部会话只存内存”的策略。
    return { accessToken: credential.token, expiresAt: Math.min(Date.now() + Number(credential.validPeriod) * 1000,
      expiry), providerUid };
  }

  // 昵称 + 密码登录。
  async function login(payload, env) {
    await ready(env);
    if (typeof payload.nickname !== 'string' || payload.nickname.length > 96 ||
      typeof payload.password !== 'string' || payload.password.length > 128 || !payload.password) throw invalidLogin();
    let name;
    try { name = nickname(payload.nickname); } catch (_) { throw invalidLogin(); }
    await throttle(name.key, env);
    const owner = await one(collection(env, 'NicknameClaim').query().equalTo('key', name.key));
    const row = owner && owner.ownerUid && owner.ownerUid !== 'CONFLICT'
      ? await one(collection(env, 'PasswordCredential').query().equalTo('uid', owner.ownerUid)) : null;
    const digest = await passwordHash(payload.password, row ? row.salt : '0'.repeat(64));
    const expected = Buffer.from(row ? row.passwordHash : '0'.repeat(128), 'hex');
    if (!row || row.nicknameKey !== name.key || expected.length !== digest.length || !crypto.timingSafeEqual(digest, expected)) throw invalidLogin();
    const profile = await one(collection(env, 'UserProfile').query().equalTo('uid', row.uid));
    if (!profile || !isAccountActive(profile)) throw invalidLogin();
    const session = await exchange(row.uid, row.generation, env);
    const committed = await collection(env, 'PasswordCredential').runTransaction({ apply: async tx => {
      const fresh = await read(tx, env, 'PasswordCredential', 'uid', row.uid);
      const current = await read(tx, env, 'UserProfile', 'uid', row.uid);
      const claimRow = await read(tx, env, 'NicknameClaim', 'key', name.key);
      const bindingId = identityBindingId('AGC', session.providerUid);
      const binding = await read(tx, env, 'IdentityBinding', 'id', bindingId);
      if (!fresh || fresh.generation !== row.generation || fresh.nicknameKey !== name.key ||
        !claimRow || claimRow.ownerUid !== row.uid || !current || !isAccountActive(current)) throw invalidLogin();
      if (binding && (binding.canonicalUid !== row.uid || binding.status !== 'ACTIVE')) throw invalidLogin();
      if (fresh.customAgcUid && fresh.customAgcUid !== session.providerUid) throw accessError('认证身份不一致。', 'INVALID_STATE');
      const now = Date.now();
      tx.executeUpsert([model('PasswordCredential', { ...fresh, customAgcUid: session.providerUid, updatedAt: now })]);
      tx.executeUpsert([model('IdentityBinding', { id: bindingId, provider: 'AGC', providerUid: session.providerUid, canonicalUid: row.uid,
          status: 'ACTIVE', createdAt: binding ? binding.createdAt : now, updatedAt: now })]);
      return true;
    } });
    if (!committed) throw accessError('登录未完成，请重试。', 'CONFLICT');
    return { accessToken: session.accessToken, expiresAt: session.expiresAt };
  }

  // 昵称会话退出：撤销该身份的 AGC 会话。
  async function logout(accessToken, env) {
    const identity = await verifiedIdentity(accessToken, env, true);
    const credential = await one(collection(env, 'PasswordCredential').query().equalTo('uid', identity.canonicalUid));
    if (!credential || credential.customAgcUid !== identity.providerUid) throw accessError('请使用昵称登录会话。', 'AUTH_REQUIRED');
    // AGC 的撤销作用于该凭据身份在所有设备上的会话。
    await cloud.auth().revokeRefreshTokens({ uid: identity.providerUid });
    return { success: true };
  }

  // 只由受凭据保护的维护函数调用，并且迁移期间服务端会冻结资料写入。
  // 迁移旧账号的昵称数据（由维护函数调用）。
  async function migrate(env) {
    if (String(env.SHIKE_NICKNAME_MIGRATING || '') !== 'true') throw accessError('请先开启昵称迁移维护开关。', 'CONFIGURATION_REQUIRED');
    const state = await one(collection(env, 'NicknameClaim').query().equalTo('key', 'migration'));
    if (state && state.ownerUid === 'READY') return { complete: true };
    const cursor = state ? state.nickname : '';
    let query = collection(env, 'UserProfile').query();
    if (cursor) query = query.greaterThan('uid', cursor);
    const rows = await query.orderByAsc('uid').limit(40).get();
    const committed = await collection(env, 'NicknameClaim').runTransaction({ apply: async tx => {
      const fresh = await read(tx, env, 'NicknameClaim', 'key', 'migration');
      if ((fresh ? fresh.nickname : '') !== cursor || fresh && fresh.ownerUid === 'READY') throw accessError('迁移进度已变化，请重试。', 'CONFLICT');
      const claims = new Map();
      for (const row of rows) {
        if (!isAccountActive(row)) continue;
        let name; try { name = nickname(row.nicknameValue || row.nickname); } catch (_) { continue; }
        const old = claims.get(name.key) || await read(tx, env, 'NicknameClaim', 'key', name.key);
        claims.set(name.key, model('NicknameClaim', { key: name.key, nickname: name.display,
          ownerUid: old && old.ownerUid !== row.uid ? 'CONFLICT' : row.uid, updatedAt: Date.now() }));
      }
      tx.executeUpsert([...claims.values(), model('NicknameClaim', { key: 'migration', ownerUid: rows.length < 40 ? 'READY' : 'RUNNING',
        nickname: rows.length ? rows[rows.length - 1].uid : cursor, updatedAt: Date.now() })]);
      return true;
    } });
    if (!committed) throw accessError('迁移尚未保存，请重试。', 'CONFLICT');
    return { complete: rows.length < 40, scanned: rows.length };
  }

  return { enabled, ready, rename, status, configure, changePassword, login, logout, migrate };
}

module.exports = { createNicknameAuth, nickname };
