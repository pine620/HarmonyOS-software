import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import agconnect from '@hw-agconnect/api-ohos';
import '@hw-agconnect/core-ohos';
import auth, {
  AuthUser, EmailCredentialInfo, EmailVerifyCode, SignInParam, TokenResult, VerifyCodeAction, VerifyCodeParam
} from '@hw-agconnect/auth';

// Pack 3.1 (2026-10-15): native email sessions now use @hw-agconnect/auth (the maintained AGC Auth SDK for
// HarmonyOS NEXT) instead of the deprecated @hw-agconnect/auth-ohos. The public surface of this store is
// unchanged. The new SDK keeps its own session storage, so an email user signed in with the old SDK is asked
// to sign in once more (AuthService.restore shows the notice). Huawei / nickname sessions are unaffected:
// they never used the SDK and still carry the server-issued token below (legacyAccessToken).
/**
 * The only client-side source of an AGC business credential.
 *
 * The store deliberately keeps access tokens in memory only. AGC Auth owns
 * its protected session state, while CloudGateway asks this store for the
 * current token for both the Cloud Foundation provider and each request
 * envelope.
 */
export class AuthSessionStore {
  private static sessionGeneration: number = 0;
  private static businessOwner: string = '';
  private static nativeTokenRequest: Promise<string> | undefined = undefined;
  private static nativeTokenGeneration: number = 0;
  private static nativeTokenForced: boolean = false;
  static generation(): number { return AuthSessionStore.sessionGeneration; }
  static owner(): string { return AuthSessionStore.businessOwner; }
  static setBusinessOwner(uid: string): void {
    if (uid !== AuthSessionStore.businessOwner) { AuthSessionStore.businessOwner = uid; AuthSessionStore.sessionGeneration++; AppStorage.setOrCreate('authSessionRevision', AuthSessionStore.sessionGeneration); }
  }

  private static initialized: boolean = false;
  private static nativeEmailSession: boolean = false;
  private static cachedAccessToken: string = '';
  private static cachedExpiresAt: number = 0;
  private static legacyAccessToken: string = '';
  private static legacyExpiresAt: number = 0;

  static initialize(context: common.Context): void {
    if (AuthSessionStore.initialized) return;
    // AGC initialization is intentionally called only after privacy consent.
    // api-ohos stays initialised for Remote Config (delivery platforms); auth uses the new SDK.
    agconnect.instance().init(context);
    const raw: Uint8Array = context.resourceManager.getRawFileContentSync('agconnect-services.json');
    const json: string = util.TextDecoder.create('utf-8').decodeToString(raw);
    auth.init(context, json);
    AuthSessionStore.initialized = true;
  }

  static normalizeEmail(rawEmail: string): string {
    const email: string = rawEmail.trim();
    // This is intentionally a conservative client-side usability check. AGC
    // remains the authority for the complete email-address validation rules.
    if (email.length === 0 || email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      throw new Error('请输入有效的邮箱地址。');
    }
    return email;
  }

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

  static validateNewPassword(password: string): void {
    if (password.length < 8 || password.length > 128) throw new Error('密码需为 8–128 个字符。');
    let kinds: number = 0;
    if (/[a-z]/.test(password)) kinds++;
    if (/[A-Z]/.test(password)) kinds++;
    if (/[0-9]/.test(password)) kinds++;
    if (/[^a-zA-Z0-9]/.test(password)) kinds++;
    if (kinds < 2) throw new Error('密码需包含大小写字母、数字或符号中的至少两种。');
  }

  static async registerEmail(rawEmail: string, verifyCode: string): Promise<void> {
    AuthSessionStore.requireAuth();
    const email: string = AuthSessionStore.normalizeEmail(rawEmail);
    const code: string = verifyCode.trim();
    if (code.length === 0) {
      throw new Error('请输入邮箱验证码。');
    }
    await AuthSessionStore.signOut();
    // createUser signs the new user in, like createEmailUser did in the old SDK.
    const credential: EmailCredentialInfo = { kind: 'email', email: email, verifyCode: code };
    await auth.createUser(credential);
    AuthSessionStore.nativeEmailSession = true;
    AuthSessionStore.clearLegacyAccessToken();
    AuthSessionStore.invalidateCachedToken();
  }

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

  static async getCurrentUser(): Promise<AuthUser | null> {
    if (!AuthSessionStore.initialized) {
      return null;
    }
    return auth.getCurrentUser();
  }

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
   * Returns only a credential belonging to the device's native AGC Auth user.
   *
   * This method is kept separate from getAccessToken() because callers that
   * need a device-local AGC user (such as account management) must not treat a
   * Huawei compatibility token as a native email session. CloudGateway uses
   * getAccessToken() for Storage so both login routes present their verified
   * AGC access token to the shared AuthProvider.
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
    // Independent auth channel: token refresh never waits for a read queue slot.
    const request: Promise<string> = AuthSessionStore.fetchNativeAccessToken(forceRefresh, generation);
    AuthSessionStore.nativeTokenRequest = request;
    AuthSessionStore.nativeTokenGeneration = generation;
    AuthSessionStore.nativeTokenForced = forceRefresh;
    try { return await request; }
    finally { if (AuthSessionStore.nativeTokenRequest === request) AuthSessionStore.nativeTokenRequest = undefined; }
  }

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

  static setLegacyAccessToken(accessToken: string, expiresAt: number): void {
    AuthSessionStore.sessionGeneration++; AppStorage.setOrCreate('authSessionRevision', AuthSessionStore.sessionGeneration);
    AuthSessionStore.legacyAccessToken = accessToken;
    AuthSessionStore.legacyExpiresAt = AuthSessionStore.normalizeExpiry(expiresAt);
    AuthSessionStore.invalidateCachedToken();
  }

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
      // Even if the SDK reports a failure, never retain an app-memory token
      // or advertise the old session as active. A later cold-start restore
      // still asks AGC Auth for the authoritative current user.
      AuthSessionStore.nativeEmailSession = false;
      AuthSessionStore.clearLegacyAccessToken();
      AuthSessionStore.invalidateCachedToken();
    }
  }

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

  static hasCachedSession(): boolean {
    return AuthSessionStore.cachedAccessToken.length > 0 || AuthSessionStore.legacyAccessToken.length > 0;
  }

  static isNativeEmailSession(): boolean {
    return AuthSessionStore.nativeEmailSession;
  }

  static clearLegacyAccessToken(): void {
    AuthSessionStore.legacyAccessToken = '';
    AuthSessionStore.legacyExpiresAt = 0;
  }

  static invalidateCachedToken(): void {
    AuthSessionStore.cachedAccessToken = '';
    AuthSessionStore.cachedExpiresAt = 0;
  }

  private static requireAuth(): void {
    if (!AuthSessionStore.initialized) {
      throw new Error('认证服务尚未初始化，请先同意隐私协议。');
    }
  }

  private static normalizeExpiry(expiresAt: number): number {
    if (expiresAt <= 0) return 0;
    return expiresAt < 100000000000 ? expiresAt * 1000 : expiresAt;
  }
}
