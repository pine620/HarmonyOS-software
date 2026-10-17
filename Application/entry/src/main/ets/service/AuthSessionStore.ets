import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import agconnect from '@hw-agconnect/api-ohos';
import '@hw-agconnect/core-ohos';
import auth, {
  AuthUser, EmailCredentialInfo, EmailVerifyCode, SignInParam, TokenResult, VerifyCodeAction, VerifyCodeParam
} from '@hw-agconnect/auth';

/**
 * 【文件职责】客户端唯一的“业务凭据”来源，管理三类会话的 Token：
 *   1. 邮箱原生会话：由 AGC Auth SDK（@hw-agconnect/auth）管理登录态，本类只缓存它签发的 Access Token；
 *   2. 华为账号 / 昵称密码会话（代码里称 legacy）：Token 由云端签发，只保存在内存（legacyAccessToken）；
 *   3. 游客：没有 Token。
 * CloudGateway 每次请求都向本类要当前 Token，既放进请求信封，也提供给 Cloud Foundation 的 authProvider。
 * 【会话代次 sessionGeneration】每次登录、退出、换号、注销都 +1，并写入 AppStorage 'authSessionRevision'。
 * 各处在请求发起时记下代次，返回时比较——不一致就丢弃结果，这是“换号后旧数据不串号”的核心机制。
 * 【历史说明】邮箱会话已从已废弃的 @hw-agconnect/auth-ohos 迁到 @hw-agconnect/auth，对外接口不变；新 SDK 使用自己的
 * 会话存储，所以用旧 SDK 登录过的邮箱用户需要重新登录一次（AuthService.restore 会提示）。华为 / 昵称会话从未使用 SDK，不受影响。
 * 【新人注意】Token 一律只放内存，不落盘；initialize() 只能在用户同意隐私协议之后调用。
 */
export class AuthSessionStore {
  // 会话代次与当前业务 UID（canonical UID，由 AuthService 在资料加载后设置）。
  private static sessionGeneration: number = 0;
  private static businessOwner: string = '';
  // 正在进行的原生 Token 刷新请求（用于合并并发刷新）及其所属代次、是否为强制刷新。
  private static nativeTokenRequest: Promise<string> | undefined = undefined;
  private static nativeTokenGeneration: number = 0;
  private static nativeTokenForced: boolean = false;
  // 当前会话代次：任何“登录状态变化”都会让它 +1。
  static generation(): number { return AuthSessionStore.sessionGeneration; }
  // 当前业务 UID；空串表示未登录。
  static owner(): string { return AuthSessionStore.businessOwner; }
  // 设置当前业务 UID；变化时会话代次 +1，并通知监听 authSessionRevision 的页面。
  static setBusinessOwner(uid: string): void {
    if (uid !== AuthSessionStore.businessOwner) { AuthSessionStore.businessOwner = uid; AuthSessionStore.sessionGeneration++; AppStorage.setOrCreate('authSessionRevision', AuthSessionStore.sessionGeneration); }
  }

  // SDK 是否已初始化、当前是否为邮箱原生会话、原生 Token 缓存及到期时间、云端签发的 legacy Token 及到期时间。
  private static initialized: boolean = false;
  private static nativeEmailSession: boolean = false;
  private static cachedAccessToken: string = '';
  private static cachedExpiresAt: number = 0;
  private static legacyAccessToken: string = '';
  private static legacyExpiresAt: number = 0;

  // 初始化 AGC SDK（读取 rawfile/agconnect-services.json）。只执行一次。
  static initialize(context: common.Context): void {
    if (AuthSessionStore.initialized) return;
    // AGC 初始化必须在用户同意隐私之后才调用。api-ohos 仍需初始化（Remote Config 读外卖平台列表要用），认证使用新版 auth SDK。
    agconnect.instance().init(context);
    const raw: Uint8Array = context.resourceManager.getRawFileContentSync('agconnect-services.json');
    const json: string = util.TextDecoder.create('utf-8').decodeToString(raw);
    auth.init(context, json);
    AuthSessionStore.initialized = true;
  }

  // 规范化并粗略校验邮箱地址。
  static normalizeEmail(rawEmail: string): string {
    const email: string = rawEmail.trim();
    // 这里只做保守的格式检查，方便尽早提示用户；邮箱是否合法以 AGC 的完整校验为准。
    if (email.length === 0 || email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      throw new Error('请输入有效的邮箱地址。');
    }
    return email;
  }

  // 发送邮箱验证码：resetPassword=true 用于找回密码，否则用于注册/登录；同一邮箱 60 秒内只能发一次。
  static async requestEmailVerifyCode(rawEmail: string, resetPassword: boolean = false): Promise<void> {
    AuthSessionStore.requireAuth();
    const email: string = AuthSessionStore.normalizeEmail(rawEmail);
    const codeType: EmailVerifyCode = { kind: 'email', email: email };
    const param: VerifyCodeParam = {
      action: resetPassword ? VerifyCodeAction.RESET_PASSWORD : VerifyCodeAction.REGISTER_LOGIN,
      lang: 'zh_CN',
      sendInterval: 60,
      verifyCodeType: codeType
    };
    await auth.requestVerifyCode(param);
  }

  // 本地校验新密码强度：8–128 位，且至少包含大写、小写、数字、符号中的两种（服务端会再次校验）。
  static validateNewPassword(password: string): void {
    if (password.length < 8 || password.length > 128) throw new Error('密码需为 8–128 个字符。');
    let kinds: number = 0;
    if (/[a-z]/.test(password)) kinds++;
    if (/[A-Z]/.test(password)) kinds++;
    if (/[0-9]/.test(password)) kinds++;
    if (/[^a-zA-Z0-9]/.test(password)) kinds++;
    if (kinds < 2) throw new Error('密码需包含大小写字母、数字或符号中的至少两种。');
  }

  // 用邮箱验证码注册新的 AGC 用户（注册成功即登录），之后会话类型为邮箱原生会话。
  static async registerEmail(rawEmail: string, verifyCode: string): Promise<void> {
    AuthSessionStore.requireAuth();
    const email: string = AuthSessionStore.normalizeEmail(rawEmail);
    const code: string = verifyCode.trim();
    if (code.length === 0) {
      throw new Error('请输入邮箱验证码。');
    }
    await AuthSessionStore.signOut();
    // createUser 会让新用户直接处于登录状态（与旧 SDK 的 createEmailUser 行为一致）。
    const credential: EmailCredentialInfo = { kind: 'email', email: email, verifyCode: code };
    await auth.createUser(credential);
    AuthSessionStore.nativeEmailSession = true;
    AuthSessionStore.clearLegacyAccessToken();
    AuthSessionStore.invalidateCachedToken();
  }

  // 用邮箱验证码登录已有 AGC 用户（autoCreateUser=false，不会自动注册）。
  static async signInWithEmail(rawEmail: string, verifyCode: string): Promise<void> {
    AuthSessionStore.requireAuth();
    const email: string = AuthSessionStore.normalizeEmail(rawEmail);
    const code: string = verifyCode.trim();
    if (code.length === 0) {
      throw new Error('请输入邮箱验证码。');
    }
    await AuthSessionStore.signOut();
    const credential: EmailCredentialInfo = { kind: 'email', email: email, verifyCode: code };
    const param: SignInParam = { autoCreateUser: false, credentialInfo: credential };
    await auth.signIn(param);
    AuthSessionStore.nativeEmailSession = true;
    AuthSessionStore.clearLegacyAccessToken();
    AuthSessionStore.invalidateCachedToken();
  }

  // 当前 AGC Auth 原生用户；SDK 未初始化时返回 null。
  static async getCurrentUser(): Promise<AuthUser | null> {
    if (!AuthSessionStore.initialized) {
      return null;
    }
    return auth.getCurrentUser();
  }

  // 获取当前业务 Token：优先邮箱原生 Token，其次未过期的 legacy Token；都没有返回空串（游客）。
  static async getAccessToken(forceRefresh: boolean = false): Promise<string> {
    const nativeAccessToken: string = await AuthSessionStore.getNativeAccessToken(forceRefresh);
    if (nativeAccessToken.length > 0) {
      return nativeAccessToken;
    }
    if (AuthSessionStore.legacyAccessToken.length > 0 &&
      (AuthSessionStore.legacyExpiresAt === 0 || Date.now() < AuthSessionStore.legacyExpiresAt)) {
      return AuthSessionStore.legacyAccessToken;
    }
    AuthSessionStore.clearLegacyAccessToken();
    return '';
  }

  /**
   * 只返回“本机 AGC Auth 原生用户”（邮箱会话）的 Token。
   * 与 getAccessToken() 分开，是因为账号管理等场景需要确认是真正的邮箱会话，不能把华为兼容 Token 当成邮箱会话。
   * 同一会话代次内的并发调用会共享同一个刷新请求；forceRefresh=true 时强制向 SDK 刷新。
   */
  static async getNativeAccessToken(forceRefresh: boolean = false): Promise<string> {
    const generation: number = AuthSessionStore.sessionGeneration;
    const pending: Promise<string> | undefined = AuthSessionStore.nativeTokenRequest;
    if (pending !== undefined) {
      if (AuthSessionStore.nativeTokenGeneration === generation && (!forceRefresh || AuthSessionStore.nativeTokenForced)) return pending;
      try { await pending; } catch (_error) { }
      if (generation !== AuthSessionStore.sessionGeneration) throw new Error('账号已变化，请重新获取登录凭证。');
      return AuthSessionStore.getNativeAccessToken(forceRefresh);
    }
    // 认证刷新走独立通道：Token 刷新不需要等待读请求队列的槽位。
    const request: Promise<string> = AuthSessionStore.fetchNativeAccessToken(forceRefresh, generation);
    AuthSessionStore.nativeTokenRequest = request;
    AuthSessionStore.nativeTokenGeneration = generation;
    AuthSessionStore.nativeTokenForced = forceRefresh;
    try { return await request; }
    finally { if (AuthSessionStore.nativeTokenRequest === request) AuthSessionStore.nativeTokenRequest = undefined; }
  }

  // 实际向 SDK 取 Token：缓存距离过期超过 60 秒时直接用缓存，否则让 SDK 刷新。取 Token 期间若会话代次变化则抛错。
  private static async fetchNativeAccessToken(forceRefresh: boolean, generation: number): Promise<string> {
    if (AuthSessionStore.initialized) {
      const user: AuthUser | null = await auth.getCurrentUser();
      if (generation !== AuthSessionStore.sessionGeneration) throw new Error('账号已变化，请重新获取登录凭证。');
      if (user !== null) {
        AuthSessionStore.nativeEmailSession = true;
        const now: number = Date.now();
        if (!forceRefresh && AuthSessionStore.cachedAccessToken.length > 0 &&
          AuthSessionStore.cachedExpiresAt > 0 && now + 60000 < AuthSessionStore.cachedExpiresAt) {
          return AuthSessionStore.cachedAccessToken;
        }
        const shouldForceRefresh: boolean = forceRefresh ||
          (AuthSessionStore.cachedExpiresAt > 0 && now + 60000 >= AuthSessionStore.cachedExpiresAt);
        const tokenResult: TokenResult = await user.getToken(shouldForceRefresh);
        if (generation !== AuthSessionStore.sessionGeneration) throw new Error('账号已变化，请重新获取登录凭证。');
        const token: string = tokenResult.getString();
        if (token.length === 0) {
          throw new Error('AGC Auth 未返回有效的访问凭证。');
        }
        AuthSessionStore.cachedAccessToken = token;
        const expirePeriod: number = tokenResult.getExpirePeriod();
        AuthSessionStore.cachedExpiresAt = expirePeriod > 0 ? now + expirePeriod * 1000 : 0;
        return token;
      }
    }
    return '';
  }

  // 保存云端签发的 Token（华为账号 / 昵称登录成功后调用），同时会话代次 +1。
  static setLegacyAccessToken(accessToken: string, expiresAt: number): void {
    AuthSessionStore.sessionGeneration++; AppStorage.setOrCreate('authSessionRevision', AuthSessionStore.sessionGeneration);
    AuthSessionStore.legacyAccessToken = accessToken;
    AuthSessionStore.legacyExpiresAt = AuthSessionStore.normalizeExpiry(expiresAt);
    AuthSessionStore.invalidateCachedToken();
  }

  // 注销账号前的二次验证：要求邮箱用户再输入一次验证码。
  static async reauthenticateEmail(rawEmail: string, verifyCode: string): Promise<void> {
    AuthSessionStore.requireAuth();
    const user: AuthUser | null = await auth.getCurrentUser();
    if (user === null) {
      throw new Error('当前没有可重新认证的邮箱会话。');
    }
    const email: string = AuthSessionStore.normalizeEmail(rawEmail);
    const code: string = verifyCode.trim();
    if (code.length === 0) {
      throw new Error('请输入邮箱验证码后再注销。');
    }
    const credential: EmailCredentialInfo = { kind: 'email', email: email, verifyCode: code };
    const param: SignInParam = { credentialInfo: credential };
    await user.userReauthenticate(param);
    AuthSessionStore.invalidateCachedToken();
  }

  // 退出登录：会话代次 +1，退出 SDK 会话，清空所有内存 Token。
  static async signOut(): Promise<void> {
    AuthSessionStore.sessionGeneration++; AppStorage.setOrCreate('authSessionRevision', AuthSessionStore.sessionGeneration);
    try {
      if (AuthSessionStore.initialized) {
        const user: AuthUser | null = await auth.getCurrentUser();
        if (user !== null) {
          await auth.signOut();
        }
      }
    } finally {
      // 即使 SDK 报告退出失败，也绝不保留内存中的 Token，也不再把旧会话当作有效；之后冷启动恢复时仍以 AGC Auth 的当前用户为准。
      AuthSessionStore.nativeEmailSession = false;
      AuthSessionStore.clearLegacyAccessToken();
      AuthSessionStore.invalidateCachedToken();
    }
  }

  // 删除 AGC 认证用户（注销账号流程的最后一步）。
  static async deleteUser(): Promise<void> {
    AuthSessionStore.sessionGeneration++; AppStorage.setOrCreate('authSessionRevision', AuthSessionStore.sessionGeneration);
    AuthSessionStore.requireAuth();
    const user: AuthUser | null = await auth.getCurrentUser();
    if (user === null) {
      throw new Error('当前没有可注销的 AGC 认证用户。');
    }
    await auth.deleteUser();
    AuthSessionStore.nativeEmailSession = false;
    AuthSessionStore.clearLegacyAccessToken();
    AuthSessionStore.invalidateCachedToken();
  }

  // 内存里是否还有可用的 Token（用于判断“是否已登录”）。
  static hasCachedSession(): boolean {
    return AuthSessionStore.cachedAccessToken.length > 0 || AuthSessionStore.legacyAccessToken.length > 0;
  }

  // 当前是否为邮箱原生会话（决定能否使用客户端直传图片）。
  static isNativeEmailSession(): boolean {
    return AuthSessionStore.nativeEmailSession;
  }

  // 清除云端签发的 legacy Token。
  static clearLegacyAccessToken(): void {
    AuthSessionStore.legacyAccessToken = '';
    AuthSessionStore.legacyExpiresAt = 0;
  }

  // 清除原生 Token 缓存（下次会重新向 SDK 获取）。
  static invalidateCachedToken(): void {
    AuthSessionStore.cachedAccessToken = '';
    AuthSessionStore.cachedExpiresAt = 0;
  }

  // SDK 未初始化时禁止调用认证接口。
  private static requireAuth(): void {
    if (!AuthSessionStore.initialized) {
      throw new Error('认证服务尚未初始化，请先同意隐私协议。');
    }
  }

  // 把到期时间统一成毫秒时间戳（兼容服务端返回秒级时间戳）；0 表示未知。
  private static normalizeExpiry(expiresAt: number): number {
    if (expiresAt <= 0) return 0;
    return expiresAt < 100000000000 ? expiresAt * 1000 : expiresAt;
  }
}
