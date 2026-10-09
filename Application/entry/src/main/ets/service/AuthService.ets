import { DraftStore } from './DraftStore';
import { common } from '@kit.AbilityKit';
import { authentication } from '@kit.AccountKit';
import util from '@ohos.util';
import {
  AuthSession,
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

type AuthMode = 'none' | 'email' | 'huawei';

interface AuthErrorDetail {
  code?: number | string;
  message?: string;
}

function authErrorText(error: Object): string {
  const detail: AuthErrorDetail = error as AuthErrorDetail;
  const code: string = detail.code === undefined ? '' : `错误码：${detail.code}`;
  const message: string = detail.message || '';
  if (code.length > 0 && message.length > 0) return `${code}，${message}`;
  if (code.length > 0) return code;
  if (message.length > 0) return message;
  return '认证服务暂时不可用。';
}

function authErrorCode(error: Object): string {
  const detail: AuthErrorDetail = error as AuthErrorDetail;
  return detail.code === undefined ? '' : String(detail.code);
}

export class AuthService {
  private static currentProfile: UserProfile | undefined = undefined;
  private static authMode: AuthMode = 'none';
  private static intent: number = 0;
  static sessionIntent(): number { return AuthService.intent; }
  private static assertIntent(intent: number): void { if (intent !== AuthService.intent) throw new Error('登录操作已被新的账号操作取代。'); }

  static profile(): UserProfile | undefined {
    return AuthService.currentProfile;
  }

  static isEmailSession(): boolean {
    return AuthService.authMode === 'email' && AuthSessionStore.isNativeEmailSession();
  }

  static async requestEmailCode(context: common.Context, rawEmail: string): Promise<void> {
    AuthSessionStore.initialize(context);
    await AuthSessionStore.requestEmailVerifyCode(rawEmail);
  }

  static async emailLogin(
    context: common.Context,
    rawEmail: string,
    verifyCode: string,
    register: boolean
  ): Promise<UserProfile> {
    const intent: number = ++AuthService.intent;
    AppStorage.setOrCreate('sessionRestoreMessage', '');
    AuthSessionStore.initialize(context);
    try {
      if (register) {
        try {
          await AuthSessionStore.registerEmail(rawEmail, verifyCode);
        } catch (error) {
          // AGC rejects createEmailUser when this address already exists.
          // REGISTER_LOGIN codes are valid for the corresponding sign-in
          // flow, so continue without creating a duplicate identity.
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
      throw new Error(`食刻资料初始化失败：${authErrorText(error as Object)}`);
    }
  }

  static async login(context: common.Context, interactive: boolean = true): Promise<UserProfile> {
    if (interactive) { AuthService.intent++; AppStorage.setOrCreate('sessionRestoreMessage', ''); }
    const intent: number = AuthService.intent;
    AuthSessionStore.initialize(context);
    // Never let a native email user or an expired legacy AGC token become the
    // credential for the next Huawei compatibility exchange.
    if (interactive) await AuthSessionStore.signOut();
    const state: string = util.generateRandomUUID();
    const nonce: string = util.generateRandomUUID();
    // Huawei ID remains a compatibility entry point. It is exchanged for an
    // AGC session and never becomes a normal business credential itself.
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
      const migrationRequest: MigrationTicketRequest = { ticket: session.migrationTicket };
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
      throw new Error(`华为账号迁移失败：${authErrorText(error as Object)}`);
    }
    try {
      return await AuthService.loadProfile(context, intent);
    } catch (error) {
      throw new Error(`食刻资料初始化失败：${authErrorText(error as Object)}`);
    }
  }

  /**
   * Associates a never-used email provider with the current Huawei-backed
   * food-clock account. The email credential is created by native AGC Auth;
   * the cloud service receives only the resulting AGC access token.
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
      // This creates the provider through native AGC Auth. The verification
      // code never crosses the cloud-function boundary.
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
      // Do not leave a newly created but unbound email identity behind. If
      // rollback itself fails, the original error remains the useful signal.
      if (emailCreated && !bindingCompleted) {
        try {
          await AuthSessionStore.deleteUser();
        } catch (_rollbackError) {
          // The app still clears its local session below; no credential is
          // persisted or logged.
        }
      }
      AuthService.clearLocalSession();
      throw new Error(`邮箱关联失败：${authErrorText(error as Object)}`);
    }
  }

  /**
   * Associates a Huawei credential with the current native AGC email user.
   * The native session remains active, so this operation never forces an
   * email user to be re-created or re-signed-in.
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

  static async restore(context: common.Context, allowHuaweiRestore: boolean = true): Promise<UserProfile | undefined> {
    const intent: number = AuthService.intent;
    AuthSessionStore.initialize(context);
    AppStorage.setOrCreate('sessionRestoreMessage', '');
    try {
      const hint: SessionProviderHint = await SessionRestoreStore.read(context);
      if (intent !== AuthService.intent) return AuthService.currentProfile;
      if (hint === 'SIGNED_OUT') { AuthService.clearLocalSession(); return undefined; }
      const currentUser = await AuthSessionStore.getCurrentUser();
      if (intent !== AuthService.intent) return AuthService.currentProfile;
      if (currentUser !== null) {
        AuthService.authMode = 'email';
        await AuthSessionStore.getAccessToken(false);
        const profile: UserProfile = await AuthService.loadProfile(context, intent);
        if (intent !== AuthService.intent) return AuthService.currentProfile;
        await SessionRestoreStore.save(context, 'EMAIL');
        return profile;
      }
      if (allowHuaweiRestore && hint === 'HUAWEI') return await AuthService.login(context, false);
      return undefined;
    } catch (error) {
      if (intent !== AuthService.intent) return AuthService.currentProfile;
      const code: string = authErrorCode(error as Object);
      if (code === 'ACCOUNT_INACTIVE' || code === 'AUTH_REQUIRED') {
        AuthService.clearLocalSession();
        AppStorage.setOrCreate('sessionRestoreMessage', '账号需要重新认证，请继续登录。');
      } else {
        // A failed network/profile request must not sign the SDK user out.
        AppStorage.setOrCreate('sessionRestoreMessage', '会话暂未恢复，可重试或继续登录。');
      }
      return undefined;
    }
  }

  static async updateProfile(context: common.Context, request: UpdateProfileRequest): Promise<UserProfile> {
    await AuthService.ensureSession(context);
    const profile = await CloudGateway.callAuthenticated<UserProfile>('upsert-profile', request);
    const resolvedProfile = await AuthService.resolveAvatar(context, profile);
    AuthService.currentProfile = resolvedProfile; DraftStore.activateOwner(resolvedProfile.uid);
    return resolvedProfile;
  }

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

  private static async resolveAvatar(context: common.Context, profile: UserProfile,
    priority: MediaPriority = 'normal'): Promise<UserProfile> {
    if (profile.avatarPath !== undefined && profile.avatarPath.length > 0 &&
      profile.avatarBucket !== undefined && profile.avatarBucket.length > 0) {
      try {
        profile.avatarUrl = await ImageRepository.getDownloadUrl(context, profile.avatarBucket,
          profile.avatarPath, priority);
      } catch (_error) {
        // A temporary download URL failure should not block the signed-in profile.
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

  private static clearLocalSession(): void {
    DiscoveryFeedState.clear();
    AuthSessionStore.clearLegacyAccessToken();
    AuthSessionStore.invalidateCachedToken();
    AuthSessionStore.setBusinessOwner('');
    ImageRepository.setCacheOwner('');
    AuthService.currentProfile = undefined; DraftStore.activateOwner('');
    AuthService.authMode = 'none';
  }

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
        await AuthSessionStore.signOut();
      } finally {
        AuthService.clearLocalSession();
      }
    }
  }

  static async revokeHuaweiAuthorization(context: common.Context): Promise<void> {
    const state: string = util.generateRandomUUID();
    const request = new authentication.HuaweiIDProvider().createCancelAuthorizationRequest();
    request.state = state;
    const controller = new authentication.AuthenticationController(context);
    const raw = await controller.executeRequest(request);
    const response = raw as authentication.CancelAuthorizationResponse;
    if (response.state !== state) {
      throw new Error('取消华为账号授权校验失败。');
    }
  }

  static async deleteAccount(
    context: common.Context,
    emailAddress: string = '',
    verifyCode: string = ''
  ): Promise<string> {
    AuthService.intent++;
    const nativeEmailSession: boolean = AuthService.isEmailSession();
    if (nativeEmailSession) {
      await AuthService.ensureSession(context);
      await AuthSessionStore.reauthenticateEmail(emailAddress, verifyCode);
    } else {
      // Destructive legacy-account deletion requires a fresh interactive
      // Huawei authorization before the cloud cleanup starts.
      await AuthService.login(context, true);
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
    try { if (draftOwnerUid.length > 0) await DraftStore.clearAccount(context, draftOwnerUid); } catch (_error) { draftCleanupPending = true; }
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
    // Keep provider identity until the durable server task has cleaned all
    // related records. A client must not delete credentials ahead of that job.
    await SessionRestoreStore.save(context, 'SIGNED_OUT');
    AuthService.clearLocalSession();
    const accountMessage: string = result.cleanupPending
      ? '注销申请已受理，账号已停用，内容已不可访问；云端数据与认证身份待后台清理完成。'
      : '食刻账号注销处理已完成。';
    if (localPushCleanupPending || localServiceCardCleanupPending) {
      return `${accountMessage} 本机通知状态未能完全清理，请在系统设置中检查通知权限。`;
    }
    return draftCleanupPending ? accountMessage + ' 本机草稿文件清理未完成，请清除应用数据。' : accountMessage;
  }
}
