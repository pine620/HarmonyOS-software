import { common } from '@kit.AbilityKit';
import agconnect from '@hw-agconnect/api-ohos';
import '@hw-agconnect/core-ohos';
import '@hw-agconnect/auth-ohos';
import {
  AGConnectAuth,
  AGConnectAuthCredential,
  AGConnectUser,
  EmailAuthProvider,
  EmailUser,
  EmailUserBuilder,
  TokenResult,
  VerifyCodeSettings,
  VerifyCodeAction,
  VerifyCodeSettingBuilder
} from '@hw-agconnect/auth-ohos';

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

  private static auth: AGConnectAuth | undefined = undefined;
  private static initialized: boolean = false;
  private static nativeEmailSession: boolean = false;
  private static cachedAccessToken: string = '';
  private static cachedExpiresAt: number = 0;
  private static legacyAccessToken: string = '';
  private static legacyExpiresAt: number = 0;

  static initialize(context: common.Context): void {
    if (AuthSessionStore.initialized) return;
    // AGC initialization is intentionally called only after privacy consent.
    agconnect.instance().init(context);
    AuthSessionStore.auth = agconnect.auth();
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

  static async requestEmailVerifyCode(rawEmail: string): Promise<void> {
    const auth: AGConnectAuth = AuthSessionStore.requireAuth();
    const email: string = AuthSessionStore.normalizeEmail(rawEmail);
    const settings: VerifyCodeSettings = new VerifyCodeSettingBuilder()
      .setAction(VerifyCodeAction.REGISTER_LOGIN)
      .setLang('zh_CN')
      .setSendInterval(60)
      .build();
    await auth.requestEmailVerifyCode(email, settings);
  }

  static async registerEmail(rawEmail: string, verifyCode: string): Promise<void> {
    AuthSessionStore.sessionGeneration++; AppStorage.setOrCreate('authSessionRevision', AuthSessionStore.sessionGeneration);
    const auth: AGConnectAuth = AuthSessionStore.requireAuth();
    const email: string = AuthSessionStore.normalizeEmail(rawEmail);
    const code: string = verifyCode.trim();
    if (code.length === 0) {
      throw new Error('请输入邮箱验证码。');
    }
    // Registration must start from a neutral AGC Auth state. This matters
    // after a prior partial attempt: AGC may already have restored a user
    // even though the app-owned profile initialization did not finish.
    const existingUser: AGConnectUser | null = await auth.getCurrentUser();
    if (existingUser !== null) {
      await auth.signOut();
    }
    // Password is intentionally omitted. AGC supports code-only email
    // registration/login, so the app never collects or persists a password.
    const emailUser: EmailUser = new EmailUserBuilder()
      .setEmail(email)
      .setVerifyCode(code)
      .build();
    await auth.createEmailUser(emailUser);
    AuthSessionStore.nativeEmailSession = true;
    AuthSessionStore.clearLegacyAccessToken();
    AuthSessionStore.invalidateCachedToken();
  }

  static async signInWithEmail(rawEmail: string, verifyCode: string): Promise<void> {
    AuthSessionStore.sessionGeneration++; AppStorage.setOrCreate('authSessionRevision', AuthSessionStore.sessionGeneration);
    const auth: AGConnectAuth = AuthSessionStore.requireAuth();
    const email: string = AuthSessionStore.normalizeEmail(rawEmail);
    const code: string = verifyCode.trim();
    if (code.length === 0) {
      throw new Error('请输入邮箱验证码。');
    }
    const existingUser: AGConnectUser | null = await auth.getCurrentUser();
    if (existingUser !== null) {
      await auth.signOut();
    }
    const credential: AGConnectAuthCredential =
      EmailAuthProvider.credentialWithVerifyCode(email, code);
    await auth.signIn(credential);
    AuthSessionStore.nativeEmailSession = true;
    AuthSessionStore.clearLegacyAccessToken();
    AuthSessionStore.invalidateCachedToken();
  }

  static async getCurrentUser(): Promise<AGConnectUser | null> {
    if (!AuthSessionStore.initialized || AuthSessionStore.auth === undefined) {
      return null;
    }
    return AuthSessionStore.auth.getCurrentUser();
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
    if (AuthSessionStore.initialized && AuthSessionStore.auth !== undefined) {
      const user: AGConnectUser | null = await AuthSessionStore.auth.getCurrentUser();
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
    const auth: AGConnectAuth = AuthSessionStore.requireAuth();
    const user: AGConnectUser | null = await auth.getCurrentUser();
    if (user === null) {
      throw new Error('当前没有可重新认证的邮箱会话。');
    }
    const email: string = AuthSessionStore.normalizeEmail(rawEmail);
    const code: string = verifyCode.trim();
    if (code.length === 0) {
      throw new Error('请输入邮箱验证码后再注销。');
    }
    const credential: AGConnectAuthCredential =
      EmailAuthProvider.credentialWithVerifyCode(email, code);
    await user.userReauthenticate(credential);
    AuthSessionStore.invalidateCachedToken();
  }

  static async signOut(): Promise<void> {
    AuthSessionStore.sessionGeneration++; AppStorage.setOrCreate('authSessionRevision', AuthSessionStore.sessionGeneration);
    try {
      if (AuthSessionStore.auth !== undefined) {
        const user: AGConnectUser | null = await AuthSessionStore.auth.getCurrentUser();
        if (user !== null) {
          await AuthSessionStore.auth.signOut();
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
    const auth: AGConnectAuth = AuthSessionStore.requireAuth();
    const user: AGConnectUser | null = await auth.getCurrentUser();
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

  private static requireAuth(): AGConnectAuth {
    if (!AuthSessionStore.initialized || AuthSessionStore.auth === undefined) {
      throw new Error('认证服务尚未初始化，请先同意隐私协议。');
    }
    return AuthSessionStore.auth;
  }

  private static normalizeExpiry(expiresAt: number): number {
    if (expiresAt <= 0) return 0;
    return expiresAt < 100000000000 ? expiresAt * 1000 : expiresAt;
  }
}
