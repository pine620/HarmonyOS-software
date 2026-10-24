/**
 * 【文件职责】登录与账号流程的编排者（静态类）。负责“谁在登录、用哪种方式、资料是否已加载”，
 * 并在登录 / 退出 / 换号 / 注销时统一清理本机状态（图片缓存归属、草稿归属、推荐流状态、Push 与桌面卡片登记）。
 * 【支持的登录方式】
 *   - 昵称 + 密码（主方式）：login-with-nickname → 云端签发 AGC Token（只放内存）；
 *   - 邮箱验证码：直接使用 AGC Auth SDK（AuthSessionStore），注册/登录后调用 upsert-profile 读取资料；
 *   - 华为账号（兼容入口）：Account Kit 授权码 → exchange-huawei-account（shike-auth）→ complete-legacy-login 完成迁移。
 * 新账号或旧账号在首次使用前需要设置唯一昵称与密码（configure-password-account）。
 * 【关键机制】intent（操作意图计数）：每次用户发起新的登录类操作都 +1，旧流程在每个 await 之后用 assertIntent 检查，
 * 发现已被新操作取代就中止，防止“连点两次登录”时旧流程覆盖新状态。
 * 【链路位置】EmailLoginPage / ProfileSettingsPage / Index → 本文件 → AuthSessionStore + CloudGateway → shike-account / shike-auth。
 */
import { RandomFoodRoundStore } from './RandomFoodRoundStore';
import { DraftStore } from './DraftStore';
import { common } from '@kit.AbilityKit';
import { authentication } from '@kit.AccountKit';
import util from '@ohos.util';
import {
  AuthSession,
  ChangePasswordRequest,
  NicknameAuthSession,
  NicknamePasswordRequest,
  PasswordAccountStatus,
  PasswordAccountSetupResponse,
  DeleteAccountResponse,
  EmptyRequest,
  ExchangeHuaweiAccountRequest,
  MigrationTicketRequest,
  MigrationTicketResponse,
  OperationResponse,
  UpdateProfileRequest,
  UserProfile
} from '../model/CloudContracts';
import { AuthSessionStore } from './AuthSessionStore';
import { CloudGateway } from './CloudGateway';
import { MediaPriority, ImageRepository } from './ImageRepository';
import { PushNotificationService } from './PushNotificationService';
import { ServiceCardRemoteSyncService } from './ServiceCardRemoteSyncService';
import { DiscoveryFeedState } from './DiscoveryFeedState';
import { SessionRestoreStore, SessionProviderHint } from './SessionRestoreStore';

// 当前会话的登录方式：none 未登录 / email 邮箱原生 / huawei 华为兼容 / nickname 昵称密码。
type AuthMode = 'none' | 'email' | 'huawei' | 'nickname';

// 设置或修改密码后，云端已保存成功但本机切换会话失败时抛出：提示用户用新密码重新登录。
export class PasswordSavedError extends Error {
  constructor() { super('密码已保存，请使用昵称和新密码登录。'); this.name = 'PasswordSavedError'; }
}

// 邮箱已验证（验证码已被 AGC 消耗、原生会话仍保留），但食刻资料加载失败：页面应改用 retryEmailProfile 重试，不能再用旧验证码。
export class EmailProfilePendingError extends Error {
  constructor(detail: string) {
    super(`食刻资料初始化失败：${detail}。邮箱已验证，可直接重试，无需重新获取验证码。`);
    this.name = 'EmailProfilePendingError';
  }
}

// 认证类错误对象中可能包含的字段。
interface AuthErrorDetail {
  code?: number | string;
  message?: string;
}

// 把认证错误转成可读文本（错误码 + 消息），用于界面提示。
function authErrorText(error: Object): string {
  const detail: AuthErrorDetail = error as AuthErrorDetail;
  const code: string = detail.code === undefined ? '' : `错误码：${detail.code}`;
  const message: string = detail.message || '';
  if (code.length > 0 && message.length > 0) return `${code}，${message}`;
  if (code.length > 0) return code;
  if (message.length > 0) return message;
  return '认证服务暂时不可用。';
}

// 取出认证错误的错误码（字符串），没有时返回空串。
function authErrorCode(error: Object): string {
  const detail: AuthErrorDetail = error as AuthErrorDetail;
  return detail.code === undefined ? '' : String(detail.code);
}

// 登录与账号流程编排（静态类，全局唯一）。
export class AuthService {
  // 当前登录用户的资料、登录方式与操作意图计数。
  private static currentProfile: UserProfile | undefined = undefined;
  private static authMode: AuthMode = 'none';
  private static intent: number = 0;
  // 当前操作意图计数（页面用它判断某个登录流程是否仍是最新的）。
  static sessionIntent(): number { return AuthService.intent; }
  // 检查意图：若期间用户已发起新的账号操作，就抛错中止当前流程。
  private static assertIntent(intent: number): void { if (intent !== AuthService.intent) throw new Error('登录操作已被新的账号操作取代。'); }

  // 当前已加载的用户资料；未登录为 undefined。
  static profile(): UserProfile | undefined {
    return AuthService.currentProfile;
  }

  // 当前是否为昵称密码会话。
  static isNicknameSession(): boolean { return AuthService.authMode === 'nickname'; }

  // 当前是否为邮箱原生会话（以 AuthSessionStore 的判断为准）。
  static isEmailSession(): boolean {
    return AuthService.authMode === 'email' && AuthSessionStore.isNativeEmailSession();
  }

  // 发送邮箱验证码（注册/登录或找回密码）。
  static async requestEmailCode(context: common.Context, rawEmail: string, resetPassword: boolean = false): Promise<void> {
    AuthSessionStore.initialize(context);
    await AuthSessionStore.requestEmailVerifyCode(rawEmail, resetPassword);
  }

  /**
   * 昵称 + 密码登录：先退出任何旧会话，再调用 login-with-nickname 取得云端签发的 AGC Token，
   * 保存为 legacy Token 后加载资料；任何一步失败都会清理本机会话。
   */
  static async nicknameLogin(context: common.Context, nickname: string, password: string): Promise<UserProfile> {
    const intent: number = ++AuthService.intent;
    AuthSessionStore.initialize(context);
    await SessionRestoreStore.save(context, 'SIGNED_OUT');
    await AuthSessionStore.signOut();
    AuthService.assertIntent(intent);
    AuthService.clearLocalSession();
    const request: NicknamePasswordRequest = { nickname: nickname.trim(), password };
    const session: NicknameAuthSession = await CloudGateway.callPublic<NicknameAuthSession>('login-with-nickname', request);
    AuthService.assertIntent(intent);
    AuthService.validateNicknameSession(session);
    AuthSessionStore.setLegacyAccessToken(session.accessToken, session.expiresAt);
    AuthService.authMode = 'nickname';
    await SessionRestoreStore.save(context, 'NICKNAME');
    AuthService.assertIntent(intent);
    AppStorage.setOrCreate('sessionRestoreMessage', '');
    try { return await AuthService.loadProfile(context, intent); }
    catch (error) {
      if (intent === AuthService.intent) AuthService.clearLocalSession();
      if (error instanceof Error) throw error;
      throw new Error(AuthService.credentialError(error as Object, '登录资料加载失败，请重试。'));
    }
  }

  // 校验昵称登录返回的会话：必须有 Token 且到期时间在未来。
  private static validateNicknameSession(session: NicknameAuthSession): void {
    if (session === undefined || session === null || typeof session.accessToken !== 'string' || session.accessToken.length === 0 ||
      !Number.isFinite(session.expiresAt) || session.expiresAt <= Date.now()) {
      throw new Error('服务端未返回有效的昵称登录凭证，请更新登录服务后重试。');
    }
  }

  // 用户取消登录：意图 +1（中止进行中的流程），退出并清理本机会话。
  static async cancelAuthentication(context: common.Context): Promise<void> {
    AuthService.intent++;
    await SessionRestoreStore.save(context, 'SIGNED_OUT');
    try { await AuthSessionStore.signOut(); }
    finally { AuthService.clearLocalSession(); }
  }

  // 查询当前账号是否已设置昵称密码（未设置的账号恢复会话后会被要求先设置）。
  static async passwordAccountStatus(): Promise<PasswordAccountStatus> {
    const request: EmptyRequest = {};
    return CloudGateway.callAuthenticated<PasswordAccountStatus>('get-password-account', request);
  }

  // 为当前账号设置唯一昵称与密码（首次设置）；成功后切换为昵称会话。
  static async configurePasswordAccount(context: common.Context, nickname: string, password: string): Promise<UserProfile> {
    const intent: number = AuthService.intent;
    AuthSessionStore.validateNewPassword(password);
    const request: NicknamePasswordRequest = { nickname: nickname.trim(), password };
    const expectedUid: string = AuthService.currentProfile?.uid || '';
    const result: PasswordAccountSetupResponse = await CloudGateway.callAuthenticated<PasswordAccountSetupResponse>('configure-password-account', request);
    return AuthService.finishPasswordUpdate(context, result, expectedUid, intent);
  }

  // 修改密码：本地先做格式与一致性检查，再调用 change-password-account；成功后切换为新签发的昵称会话。
  static async changePassword(context: common.Context, currentPassword: string, newPassword: string): Promise<UserProfile> {
    const intent: number = AuthService.intent;
    const expectedUid: string = AuthService.currentProfile?.uid || '';
    if (expectedUid.length === 0) throw new Error('请先登录后更改密码。');
    if (currentPassword.length === 0) throw new Error('请输入当前密码。');
    AuthSessionStore.validateNewPassword(newPassword);
    if (currentPassword === newPassword) throw new Error('新密码不能与当前密码相同。');
    await AuthService.ensureSession(context);
    AuthService.assertIntent(intent);
    if (AuthService.currentProfile?.uid !== expectedUid) throw new Error('当前账号已变化，请重新登录后更改密码。');
    await DraftStore.flushActive();
    AuthService.assertIntent(intent);
    const request: ChangePasswordRequest = { currentPassword, newPassword, expectedUid };
    const result: PasswordAccountSetupResponse = await CloudGateway.callAuthenticated<PasswordAccountSetupResponse>('change-password-account', request);
    return AuthService.finishPasswordUpdate(context, result, expectedUid, intent);
  }

  /**
   * 设置/修改密码成功后的统一收尾：校验返回的账号与当前一致，退出旧会话，保存新 Token 并切换为昵称会话；
   * 新旧资料是同一账号时沿用已加载的头像/背景地址，避免闪烁。切换失败时抛出 PasswordSavedError 提示用新密码登录。
   */
  private static async finishPasswordUpdate(context: common.Context, result: PasswordAccountSetupResponse,
    expectedUid: string, intent: number): Promise<UserProfile> {
    AuthService.assertIntent(intent);
    const previousProfile: UserProfile | undefined = AuthService.currentProfile;
    try {
      AuthService.validateNicknameSession(result);
      const savedProfile: UserProfile = result.profile;
      if (savedProfile === undefined || savedProfile === null || expectedUid.length === 0 || savedProfile.uid !== expectedUid) {
        throw new Error('保存后返回的账号身份不一致，请重新验证。');
      }
      await SessionRestoreStore.save(context, 'SIGNED_OUT');
      AuthService.assertIntent(intent);
      await AuthSessionStore.signOut();
      AuthService.assertIntent(intent);
      AuthService.clearLocalSession();
      AuthSessionStore.setLegacyAccessToken(result.accessToken, result.expiresAt);
      AuthService.authMode = 'nickname';
      await SessionRestoreStore.save(context, 'NICKNAME');
      AuthService.assertIntent(intent);
    } catch (error) {
      if (intent !== AuthService.intent) throw new Error('登录操作已被新的账号操作取代。');
      AuthService.clearLocalSession();
      throw new PasswordSavedError();
    }
    const profile: UserProfile = result.profile;
    if (previousProfile !== undefined && previousProfile.uid === profile.uid) {
      if (profile.avatarPath === previousProfile.avatarPath && profile.avatarBucket === previousProfile.avatarBucket) {
        profile.avatarUrl = previousProfile.avatarUrl;
      }
      if (profile.coverPath === previousProfile.coverPath && profile.coverBucket === previousProfile.coverBucket) {
        profile.coverUrl = previousProfile.coverUrl;
      }
    }
    AuthService.currentProfile = profile;
    AuthSessionStore.setBusinessOwner(profile.uid);
    ImageRepository.setCacheOwner(profile.uid);
    DraftStore.activateOwner(profile.uid);
    AppStorage.setOrCreate('sessionRestoreMessage', '');
    return profile;
  }

  // 用邮箱验证码注册新账号（已注册的邮箱提示改用验证码登录），成功后加载资料。
  static async registerVerifiedEmail(context: common.Context, email: string, code: string): Promise<UserProfile> {
    const intent: number = ++AuthService.intent;
    AuthSessionStore.initialize(context);
    AuthService.clearLocalSession();
    await SessionRestoreStore.save(context, 'SIGNED_OUT');
    try { await AuthSessionStore.registerEmail(email, code); }
    catch (error) {
      if (authErrorCode(error as Object) === '203818130') throw new Error('该邮箱已注册，请使用验证码登录。');
      throw new Error(AuthService.credentialError(error as Object, '邮箱验证失败，请重试。'));
    }
    AuthService.assertIntent(intent);
    AuthService.authMode = 'email';
    await SessionRestoreStore.save(context, 'EMAIL');
    try {
      return await AuthService.loadProfile(context, intent);
    } catch (error) {
      throw new EmailProfilePendingError(authErrorText(error as Object));
    }
  }

  // 邮箱已验证但资料加载失败后的重试：沿用当前原生邮箱会话，只重新加载资料，不再消耗验证码。
  static async retryEmailProfile(context: common.Context): Promise<UserProfile> {
    const intent: number = ++AuthService.intent;
    if (!AuthService.isEmailSession()) throw new Error('邮箱验证已失效，请重新获取验证码。');
    try {
      return await AuthService.loadProfile(context, intent);
    } catch (error) {
      throw new EmailProfilePendingError(authErrorText(error as Object));
    }
  }

  // 把云端认证错误码翻译成中文提示；未知错误码附在提示末尾，方便反馈问题。
  static credentialError(error: Object, fallback: string): string {
    const code: string = authErrorCode(error);
    switch (code) {
      case 'CURRENT_PASSWORD_INCORRECT': return '当前密码不正确。';
      case 'PASSWORD_UNCHANGED': return '新密码不能与当前密码相同。';
      case 'PASSWORD_NOT_SET': return '当前账号尚未设置密码，请通过绑定的邮箱或华为账号先设置。';
      case 'PASSWORD_STATE_CHANGED': return '密码已被更改，请重新登录后再操作。';
      case 'ACCOUNT_MISMATCH': return '当前账号已变化，请重新登录后更改密码。';
      case 'NICKNAME_TAKEN': return '该昵称已被使用，请换一个。';
      case 'INVALID_NICKNAME': return '昵称需为 2–24 个字，仅支持文字、数字、下划线、点和短横线。';
      case 'INVALID_PASSWORD': return '密码需为 8–128 个字符，至少包含两种字符，且不能与昵称相同。';
      case 'INVALID_CREDENTIALS': return '昵称或密码不正确。';
      case 'AUTH_RATE_LIMITED': return '尝试次数过多，请 15 分钟后再试。';
      case 'REAUTH_REQUIRED': return '验证已过期，请返回登录，重新验证邮箱或华为账号。';
      case 'FEATURE_NOT_READY': return '昵称登录尚未启用或迁移尚未完成，请完成云端配置后重试。';
      case 'AUTH_CONFIGURATION_REQUIRED': return '昵称登录签名配置无效，请核对云端配置。';
      case 'AUTH_UPSTREAM_HTTP': case 'AUTH_UPSTREAM_RESPONSE': case 'AUTH_UPSTREAM_TIMEOUT':
      case 'AUTH_UPSTREAM_NETWORK': case 'AUTH_AGC_CLIENT_REJECTED': case 'AUTH_AGC_SIGN_IN_REJECTED':
      case 'AUTH_AGC_TOKEN_INVALID':
        return `${(error as AuthErrorDetail).message || fallback}（${code}）`;
      case 'AUTH_UPSTREAM_FAILED': return 'AGC 会话交换失败，请更新云端登录服务后查看具体错误。';
    }
    if (code.length > 0 && /^[A-Za-z0-9_-]{1,40}$/.test(code)) return `${fallback}（${code}）`;
    if (error instanceof Error && code.length === 0) return error.message || fallback;
    return fallback;
  }

  // 邮箱验证码登录或注册：register=true 时先尝试注册，邮箱已存在（203818130）则改为登录。
  static async emailLogin(
    context: common.Context,
    rawEmail: string,
    verifyCode: string,
    register: boolean
  ): Promise<UserProfile> {
    const intent: number = ++AuthService.intent;
    AppStorage.setOrCreate('sessionRestoreMessage', '');
    AuthSessionStore.initialize(context);
    await SessionRestoreStore.save(context, 'SIGNED_OUT');
    AuthService.assertIntent(intent);
    AuthService.clearLocalSession();
    try {
      if (register) {
        try {
          await AuthSessionStore.registerEmail(rawEmail, verifyCode);
        } catch (error) {
          // 邮箱已存在时 AGC 会拒绝注册；REGISTER_LOGIN 类型的验证码同样可用于登录，所以直接改为登录，不会产生重复身份。
          if (authErrorCode(error as Object) !== '203818130') {
            throw new Error(authErrorText(error as Object));
          }
          await AuthSessionStore.signInWithEmail(rawEmail, verifyCode);
        }
      } else {
        await AuthSessionStore.signInWithEmail(rawEmail, verifyCode);
      }
    } catch (error) {
      throw new Error(`邮箱认证失败：${authErrorText(error as Object)}`);
    }
    AuthService.assertIntent(intent);
    AuthService.authMode = 'email';
    await SessionRestoreStore.save(context, 'EMAIL');
    try {
      return await AuthService.loadProfile(context, intent);
    } catch (error) {
      throw new EmailProfilePendingError(authErrorText(error as Object));
    }
  }

  /**
   * 华为账号登录（兼容入口）。
   * interactive=true：用户主动登录，会先清除旧会话并弹出华为授权；false：冷启动静默恢复。
   * 流程：Account Kit 取一次性授权码（state/nonce 防重放）→ exchange-huawei-account 换取 AGC Token 与迁移票据
   * → complete-legacy-login 用票据完成账号迁移/绑定 → 加载资料。registerOnly=true 表示只允许新注册。
   */
  static async login(context: common.Context, interactive: boolean = true, registerOnly: boolean = false): Promise<UserProfile> {
    if (interactive) { AuthService.intent++; AppStorage.setOrCreate('sessionRestoreMessage', ''); }
    const intent: number = AuthService.intent;
    AuthSessionStore.initialize(context);
    // 绝不能让邮箱原生会话或已过期的 legacy Token 成为下一次华为账号交换的凭据，所以先清理。
    if (interactive) {
      await SessionRestoreStore.save(context, 'SIGNED_OUT');
      await AuthSessionStore.signOut();
      AuthService.assertIntent(intent);
      AuthService.clearLocalSession();
    }
    const state: string = util.generateRandomUUID();
    const nonce: string = util.generateRandomUUID();
    // 华为账号只是兼容入口：它会被交换成 AGC 会话，本身永远不作为普通业务凭据。
    const request = new authentication.HuaweiIDProvider().createLoginWithHuaweiIDRequest();
    request.forceLogin = interactive;
    request.state = state;
    request.nonce = nonce;
    const controller = new authentication.AuthenticationController(context);
    const raw = await controller.executeRequest(request);
    AuthService.assertIntent(intent);
    const response = raw as authentication.LoginWithHuaweiIDResponse;
    if (response.state !== state) {
      throw new Error('华为账号登录校验失败，请重新发起授权。');
    }
    const credential = response.data;
    const authorizationCode: string = credential?.authorizationCode || '';
    if (authorizationCode.length === 0) {
      throw new Error('华为账号未返回一次性授权码。');
    }
    const exchangeRequest: ExchangeHuaweiAccountRequest = {
      operation: 'SIGN_IN',
      authorizationCode,
      nonce
    };
    let session: AuthSession;
    try {
      session = await CloudGateway.callPublic<AuthSession>('exchange-huawei-account', exchangeRequest);
    } catch (error) {
      throw new Error(`华为账号会话交换失败：${authErrorText(error as Object)}`);
    }
    AuthService.assertIntent(intent);
    if (session.migrationTicket === undefined || session.migrationTicket.length === 0) {
      AuthSessionStore.clearLegacyAccessToken();
      throw new Error('兼容账号迁移凭证缺失，请联系管理员。');
    }
    AuthSessionStore.setLegacyAccessToken(session.accessToken, session.expiresAt);
    try {
      const migrationRequest: MigrationTicketRequest = { ticket: session.migrationTicket, registerOnly };
      const migrationResult: OperationResponse =
        await CloudGateway.callAuthenticated<OperationResponse>('complete-legacy-login', migrationRequest);
      if (!migrationResult.success) {
        throw new Error('兼容账号迁移未完成。');
      }
      AuthService.assertIntent(intent);
      AuthService.authMode = 'huawei';
      await SessionRestoreStore.save(context, 'HUAWEI');
    } catch (error) {
      if (intent === AuthService.intent) AuthSessionStore.clearLegacyAccessToken();
      if (authErrorCode(error as Object) === 'ACCOUNT_ALREADY_EXISTS') {
        throw new Error('该华为账号已有食刻账号，请返回登录。');
      }
      throw new Error(`华为账号迁移失败：${authErrorText(error as Object)}`);
    }
    try {
      return await AuthService.loadProfile(context, intent);
    } catch (error) {
      throw new Error(`食刻资料初始化失败：${authErrorText(error as Object)}`);
    }
  }

  /**
   * 为当前的华为账号关联一个从未使用过的邮箱：邮箱身份由本机 AGC Auth 创建，
   * 云端只收到创建后得到的 AGC Token（验证码不会传给云函数）。绑定失败时删除刚创建的邮箱身份。
   */
  static async linkEmailToHuawei(
    context: common.Context,
    rawEmail: string,
    verifyCode: string
  ): Promise<UserProfile> {
    AuthSessionStore.initialize(context);
    if (AuthService.authMode !== 'huawei') {
      throw new Error('请先使用华为账号登录，再关联邮箱。');
    }
    await AuthService.ensureSession(context);
    const email: string = AuthSessionStore.normalizeEmail(rawEmail);
    const code: string = verifyCode.trim();
    if (code.length === 0) {
      throw new Error('请输入邮箱验证码。');
    }
    let emailCreated: boolean = false;
    let bindingCompleted: boolean = false;
    try {
      const startBindingRequest: EmptyRequest = {} as EmptyRequest;
      const ticketResponse = await CloudGateway.callAuthenticated<MigrationTicketResponse>(
        'start-email-binding', startBindingRequest);
      if (ticketResponse.ticket.length === 0) {
        throw new Error('邮箱关联凭证缺失，请重新操作。');
      }
      // 通过本机 AGC Auth 创建邮箱身份；验证码不会经过云函数。
      await AuthSessionStore.registerEmail(email, code);
      emailCreated = true;
      const completionRequest: MigrationTicketRequest = { ticket: ticketResponse.ticket };
      const result = await CloudGateway.callAuthenticated<OperationResponse>(
        'complete-email-binding', completionRequest);
      if (!result.success) throw new Error('AGC 未完成邮箱关联。');
      bindingCompleted = true;
      AuthService.authMode = 'email';
      return await AuthService.loadProfile(context);
    } catch (error) {
      // 不能留下“已创建但未绑定”的邮箱身份；如果回滚本身也失败，仍以最初的错误为准。
      if (emailCreated && !bindingCompleted) {
        try {
          await AuthSessionStore.deleteUser();
        } catch (_rollbackError) {
          // 后面仍会清理本机会话；整个过程不保存、不记录任何凭据。
        }
      }
      AuthService.clearLocalSession();
      throw new Error(`邮箱关联失败：${authErrorText(error as Object)}`);
    }
  }

  /**
   * 为当前的邮箱原生用户关联华为账号：邮箱会话保持有效，不需要重新创建或重新登录邮箱用户。
   */
  static async linkHuaweiToEmail(context: common.Context): Promise<UserProfile> {
    AuthSessionStore.initialize(context);
    if (!AuthService.isEmailSession()) {
      throw new Error('请先使用邮箱登录，再关联华为账号。');
    }
    await AuthService.ensureSession(context);
    const state: string = util.generateRandomUUID();
    const nonce: string = util.generateRandomUUID();
    const request = new authentication.HuaweiIDProvider().createLoginWithHuaweiIDRequest();
    request.forceLogin = true;
    request.state = state;
    request.nonce = nonce;
    const controller = new authentication.AuthenticationController(context);
    const raw = await controller.executeRequest(request);
    const response = raw as authentication.LoginWithHuaweiIDResponse;
    if (response.state !== state) {
      throw new Error('华为账号登录校验失败，请重新发起授权。');
    }
    const authorizationCode: string = response.data?.authorizationCode || '';
    if (authorizationCode.length === 0) {
      throw new Error('华为账号未返回一次性授权码。');
    }
    const linkRequest: ExchangeHuaweiAccountRequest = {
      operation: 'LINK_HUAWEI',
      authorizationCode,
      nonce
    };
    try {
      const result = await CloudGateway.callAuthenticated<OperationResponse>('exchange-huawei-account', linkRequest);
      if (!result.success) throw new Error('AGC 未完成华为账号关联。');
      return await AuthService.loadProfile(context);
    } catch (error) {
      throw new Error(`华为账号关联失败：${authErrorText(error as Object)}`);
    }
  }

  /**
   * 确保当前会话可用（各 Repository 在写操作前调用）：
   * 有 Token 直接返回；华为会话 Token 过期时静默重新登录一次；其他情况清除本机会话并提示重新登录。
   */
  static async ensureSession(context: common.Context): Promise<void> {
    AuthSessionStore.initialize(context);
    if (AuthService.currentProfile === undefined) {
      throw new Error('登录状态已失效，请重新登录。');
    }
    const accessToken: string = await AuthSessionStore.getAccessToken(false);
    if (accessToken.length > 0) return;
    if (AuthService.authMode === 'huawei') {
      try {
        await AuthService.login(context, false);
        return;
      } catch (_error) {
        throw new Error('会话暂未恢复，请检查网络后重试；系统要求时请继续登录。');
      }
    }
    AuthService.clearLocalSession();
    throw new Error('登录状态已失效，请重新登录。');
  }

  /**
   * 冷启动恢复会话：依据 SessionRestoreStore 记录的上次登录方式决定如何恢复。
   * NICKNAME：内存 Token 已丢失，需要用户重新输入密码；SIGNED_OUT：保持未登录；
   * 邮箱：SDK 中仍有当前用户则加载资料（若尚未设置昵称密码则要求先设置）；HUAWEI：静默华为登录。
   * 网络或资料读取失败不会让 SDK 用户退出，只提示“可重试”。
   */
  static async restore(context: common.Context, allowHuaweiRestore: boolean = true): Promise<UserProfile | undefined> {
    const intent: number = AuthService.intent;
    const hadProfile: boolean = AuthService.currentProfile !== undefined;
    AuthSessionStore.initialize(context);
    AppStorage.setOrCreate('sessionRestoreMessage', '');
    try {
      const hint: SessionProviderHint = await SessionRestoreStore.read(context);
      if (intent !== AuthService.intent) return AuthService.currentProfile;
      if (hint === 'NICKNAME') {
        if (AuthService.authMode === 'nickname' && AuthService.currentProfile !== undefined &&
          (await AuthSessionStore.getAccessToken()).length > 0) return AuthService.currentProfile;
        AuthService.clearLocalSession();
        AppStorage.setOrCreate('sessionRestoreMessage', '请使用昵称和密码登录。');
        return undefined;
      }
      if (hint === 'SIGNED_OUT') { AuthService.clearLocalSession(); return undefined; }
      const currentUser = await AuthSessionStore.getCurrentUser();
      if (intent !== AuthService.intent) return AuthService.currentProfile;
      if (currentUser !== null) {
        AuthService.authMode = 'email';
        await AuthSessionStore.getAccessToken(false);
        const profile: UserProfile = await AuthService.loadProfile(context, intent);
        if (intent !== AuthService.intent) return AuthService.currentProfile;
        const status: PasswordAccountStatus = await AuthService.passwordAccountStatus();
        if (intent !== AuthService.intent) return AuthService.currentProfile;
        if (!status.configured) {
          AuthService.clearLocalSession();
          AppStorage.setOrCreate('sessionRestoreMessage', '请验证账号并设置唯一昵称和密码。');
          return undefined;
        }
        await SessionRestoreStore.save(context, 'EMAIL');
        return profile;
      }
      if (hint === 'EMAIL') {
        // 新版 AGC Auth SDK 看不到旧 SDK 保存的会话：提示用户重新登录一次，然后清除这个提示标记。
        AuthService.clearLocalSession();
        AppStorage.setOrCreate('sessionRestoreMessage', '登录服务已升级，请用邮箱验证码重新登录一次。');
        await SessionRestoreStore.save(context, 'SIGNED_OUT');
        return undefined;
      }
      if (allowHuaweiRestore && hint === 'HUAWEI') {
        const profile: UserProfile = await AuthService.login(context, false);
        const status: PasswordAccountStatus = await AuthService.passwordAccountStatus();
        if (intent !== AuthService.intent) return AuthService.currentProfile;
        if (!status.configured) {
          AuthService.clearLocalSession();
          AppStorage.setOrCreate('sessionRestoreMessage', '请验证账号并设置唯一昵称和密码。');
          return undefined;
        }
        return profile;
      }
      return undefined;
    } catch (error) {
      if (intent !== AuthService.intent) return AuthService.currentProfile;
      if (!hadProfile) AuthService.clearLocalSession();
      const code: string = authErrorCode(error as Object);
      if (code === 'ACCOUNT_INACTIVE' || code === 'AUTH_REQUIRED') {
        AuthService.clearLocalSession();
        AppStorage.setOrCreate('sessionRestoreMessage', '账号需要重新认证，请继续登录。');
      } else {
        // 网络或资料请求失败时不能让 SDK 用户退出登录。
        AppStorage.setOrCreate('sessionRestoreMessage', '会话暂未恢复，可重试或继续登录。');
      }
      return undefined;
    }
  }

  // 更新资料（昵称、头像、主页背景等）并刷新本机缓存的资料。
  static async updateProfile(context: common.Context, request: UpdateProfileRequest): Promise<UserProfile> {
    await AuthService.ensureSession(context);
    const profile = await CloudGateway.callAuthenticated<UserProfile>('upsert-profile', request);
    const resolvedProfile = await AuthService.resolveAvatar(context, profile);
    AuthService.currentProfile = resolvedProfile; DraftStore.activateOwner(resolvedProfile.uid);
    return resolvedProfile;
  }

  /**
   * 加载当前账号资料：以 readOnly 方式调用 upsert-profile，得到业务 UID 后设置图片缓存、草稿的归属账号；
   * 头像地址在后台补全，不阻塞登录完成。
   */
  private static async loadProfile(context: common.Context, expectedIntent: number = AuthService.intent): Promise<UserProfile> {
    const intent: number = expectedIntent;
    AuthService.assertIntent(intent);
    const session: number = AuthSessionStore.generation();
    const profileRequest: UpdateProfileRequest = { nickname: '', avatarMediaId: '', readOnly: true };
    const storedProfile: UserProfile = await CloudGateway.callAuthenticated<UserProfile>('upsert-profile', profileRequest);
    AuthService.assertIntent(intent);
    if (session !== AuthSessionStore.generation()) throw new Error('账号状态已变化，请重试。');
    AuthSessionStore.setBusinessOwner(storedProfile.uid);
    ImageRepository.setCacheOwner(storedProfile.uid);
    AuthService.currentProfile = storedProfile; DraftStore.activateOwner(storedProfile.uid);
    void AuthService.resolveAvatar(context, storedProfile, 'low').then((resolved: UserProfile): void => {
      if (AuthService.currentProfile !== storedProfile) return;
      AuthService.currentProfile = resolved; DraftStore.activateOwner(resolved.uid);
      AppStorage.setOrCreate('profileAvatarRevision', (AppStorage.get<number>('profileAvatarRevision') || 0) + 1);
    }).catch((): void => {});
    return storedProfile;
  }

  // 补全头像与主页背景的本地图片地址；临时下载失败不影响登录。
  private static async resolveAvatar(context: common.Context, profile: UserProfile,
    priority: MediaPriority = 'normal'): Promise<UserProfile> {
    if (profile.avatarPath !== undefined && profile.avatarPath.length > 0 &&
      profile.avatarBucket !== undefined && profile.avatarBucket.length > 0) {
      try {
        profile.avatarUrl = await ImageRepository.getDownloadUrl(context, profile.avatarBucket,
          profile.avatarPath, priority);
      } catch (_error) {
        // 临时的图片地址获取失败不应阻塞登录后的资料显示。
        profile.avatarUrl = '';
      }
    }
    if (profile.coverPath !== undefined && profile.coverPath.length > 0 &&
      profile.coverBucket !== undefined && profile.coverBucket.length > 0) {
      try {
        profile.coverUrl = await ImageRepository.getDownloadUrl(context, profile.coverBucket,
          profile.coverPath, priority);
      } catch (_error) {
        profile.coverUrl = '';
      }
    }
    return profile;
  }

  // 清理本机会话状态：推荐流缓存、Token、业务 UID、图片缓存归属、草稿归属、资料与登录方式。
  private static clearLocalSession(): void {
    DiscoveryFeedState.clear();
    AuthSessionStore.clearLegacyAccessToken();
    AuthSessionStore.invalidateCachedToken();
    AuthSessionStore.setBusinessOwner('');
    ImageRepository.setCacheOwner('');
    AuthService.currentProfile = undefined; DraftStore.activateOwner('');
    AuthService.authMode = 'none';
  }

  /**
   * 退出登录：先保存草稿，再关闭桌面卡片远程同步与 Push 登记（需要云端确认），
   * 昵称会话额外通知云端注销该会话，最后退出 SDK 并清理本机状态（finally 保证一定清理）。
   */
  static async logout(context: common.Context): Promise<void> {
    AuthService.intent++; AppStorage.setOrCreate('sessionRestoreMessage', '');
    await SessionRestoreStore.save(context, 'SIGNED_OUT');
    await DraftStore.flushActive();
    DraftStore.flushHandler = undefined;
    try {
      await ServiceCardRemoteSyncService.disable(context);
      await PushNotificationService.disable(context);
    } finally {
      try {
        if (AuthService.authMode === 'nickname') {
          const request: EmptyRequest = {};
          await CloudGateway.callAuthenticated<OperationResponse>('logout-nickname', request);
        }
      } finally {
        try { await AuthSessionStore.signOut(); }
        finally { AuthService.clearLocalSession(); }
      }
    }
  }

  /**
   * 注销账号（不可恢复）。
   * 1. 二次验证：邮箱用户输入验证码重新认证；华为用户重新授权；昵称会话需先换成邮箱/华为方式登录；
   * 2. 确认重新验证的仍是同一个账号；
   * 3. 关闭桌面卡片同步与 Push（失败则记为待清理）；
   * 4. 调用 delete-account-data：云端立即停用账号并创建后台清理任务（数据与认证身份由云端生命周期任务清理）；
   * 5. 清理本机草稿、今日吃什么轮次等，返回给用户的结果说明。
   */
  static async deleteAccount(
    context: common.Context,
    emailAddress: string = '',
    verifyCode: string = ''
  ): Promise<string> {
    if (AuthService.authMode === 'nickname') {
      throw new Error('请退出后，使用此账号绑定的邮箱验证码或华为账号登录，再进行注销。');
    }
    const expectedUid: string = AuthService.currentProfile === undefined ? '' : AuthService.currentProfile.uid;
    AuthService.intent++;
    const nativeEmailSession: boolean = AuthService.isEmailSession();
    if (nativeEmailSession) {
      await AuthService.ensureSession(context);
      await AuthSessionStore.reauthenticateEmail(emailAddress, verifyCode);
    } else {
      // 旧账号（华为）注销属于破坏性操作，云端清理开始前必须重新进行一次交互式华为授权。
      await AuthService.login(context, true);
    }
    if (expectedUid.length === 0 || AuthService.currentProfile === undefined || AuthService.currentProfile.uid !== expectedUid) {
      throw new Error('重新验证的账号与待注销账号不同，已取消注销。');
    }
    let serviceCardCleanupPending: boolean = false;
    try {
      await ServiceCardRemoteSyncService.disable(context);
    } catch (_error) {
      serviceCardCleanupPending = true;
    }
    let pushCleanupPending: boolean = false;
    try {
      await PushNotificationService.disable(context);
    } catch (_error) {
      pushCleanupPending = true;
    }
    const draftOwnerUid: string = AuthService.currentProfile === undefined ? '' : AuthService.currentProfile.uid;
    await DraftStore.flushActive();
    const deletionRequest: EmptyRequest = {};
    const result: DeleteAccountResponse =
      await CloudGateway.callAuthenticated<DeleteAccountResponse>('delete-account-data', deletionRequest);
    if (!result.success) {
      throw new Error('云端未确认注销申请，请稍后重试。');
    }
    let draftCleanupPending: boolean = false;
    try {
      if (draftOwnerUid.length > 0) {
        await DraftStore.clearAccount(context, draftOwnerUid);
      }
    } catch (_error) { draftCleanupPending = true; }
    let roundCleanupPending: boolean = false;
    try {
      if (draftOwnerUid.length > 0) RandomFoodRoundStore.clearAccount(context, draftOwnerUid);
    } catch (_error) { roundCleanupPending = true; }
    DraftStore.flushHandler = undefined;
    let localServiceCardCleanupPending: boolean = false;
    if (serviceCardCleanupPending) {
      try {
        ServiceCardRemoteSyncService.clearLocalStateAfterRemoteRemoval(context);
      } catch (_error) {
        localServiceCardCleanupPending = true;
      }
    }
    let localPushCleanupPending: boolean = false;
    if (pushCleanupPending) {
      try {
        await PushNotificationService.clearLocalStateAfterRemoteRemoval(context);
      } catch (_error) {
        localPushCleanupPending = true;
      }
    }
    // 认证身份要保留到云端持久任务清理完所有相关数据之后再删除；客户端不能抢先删除凭据。
    await SessionRestoreStore.save(context, 'SIGNED_OUT');
    AuthService.clearLocalSession();
    const accountMessage: string = result.cleanupPending
      ? '注销申请已受理，账号已停用，内容已不可访问；云端数据与认证身份待后台清理完成。'
      : '食刻账号注销处理已完成。';
    if (localPushCleanupPending || localServiceCardCleanupPending) {
      return `${accountMessage} 本机通知状态未能完全清理，请在系统设置中检查通知权限。`;
    }
    return draftCleanupPending || roundCleanupPending ? accountMessage + ' 部分本机草稿或推荐进度清理未完成，请清除应用数据。' : accountMessage;
  }
}
