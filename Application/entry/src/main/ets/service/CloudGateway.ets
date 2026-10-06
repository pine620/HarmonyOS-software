import { cloudCommon } from '@kit.CloudFoundationKit';
import { importObject, ShikeAuth, ShikeLocation, ShikeMedia, ShikeService } from '@shike/cloud-objects';
import type { CloudEnvelope } from '@shike/cloud-objects';
import { AuthSessionStore } from './AuthSessionStore';

type MediaOperation = 'prepare-card-photo' | 'upload-card-photo' | 'get-public-media';
type MediaErrorSource = 'cloud-call' | 'business-response';
type MediaCloudObjectName = 'shike-media' | 'shike-service';

interface CloudHandlerErrorDetail {
  code?: number;
  message?: string;
}

const MEDIA_CIRCUIT_BREAK_MS: number = 30 * 1000;
const MEDIA_UNAVAILABLE_MESSAGE: string = '实拍图服务暂时不可用，请稍后重试。';

export class MediaServiceUnavailableError extends Error {
  constructor() {
    super(MEDIA_UNAVAILABLE_MESSAGE);
    this.name = 'MediaServiceUnavailableError';
  }
}

export class CloudBusinessError extends Error {
  code: string;
  constructor(message: string, code: string) { super(message); this.name = 'CloudBusinessError'; this.code = code; }
}

interface ApiResponse<T> {
  ok: boolean;
  code?: string;
  data: T;
  message: string;
}

interface CloudObjectResponse {
  ok: boolean;
  code?: string;
  data: object;
  message: string;
}

function decode<T>(raw: string | object): ApiResponse<T> {
  if (typeof raw === 'string') {
    return JSON.parse(raw) as ApiResponse<T>;
  }
  return raw as ApiResponse<T>;
}

/** Cloud Object calls carry the AGC token in CloudEnvelope for server verification. */
export class CloudGateway {
  private static initialized: boolean = false;
  private static authObject: ShikeAuth | undefined = undefined;
  private static locationObject: ShikeLocation | undefined = undefined;
  private static mediaObject: ShikeMedia | undefined = undefined;
  private static serviceObject: ShikeService | undefined = undefined;
  private static mediaCircuitOpenUntilMs: number = 0;
  private static mediaCircuitGeneration: number = 0;

  static isMediaServiceUnavailable(): boolean {
    return Date.now() < CloudGateway.mediaCircuitOpenUntilMs;
  }

  static retryMediaService(): void {
    CloudGateway.mediaCircuitGeneration += 1;
    CloudGateway.mediaCircuitOpenUntilMs = 0;
  }

  private static mediaOperationFor(name: string): MediaOperation | undefined {
    switch (name) {
      case 'prepare-card-photo': return 'prepare-card-photo';
      case 'upload-card-photo': return 'upload-card-photo';
      case 'get-public-media': return 'get-public-media';
      default: return undefined;
    }
  }

  private static cloudHandlerMessage(error: Object): string {
    if (error instanceof Error) return error.message;
    if (error === null || error === undefined) return '';
    const detail: CloudHandlerErrorDetail = error as CloudHandlerErrorDetail;
    return typeof detail.message === 'string' ? detail.message : '';
  }

  private static cloudHandlerCode(error: Object): string {
    if (error === null || error === undefined) return 'not-provided';
    const detail: CloudHandlerErrorDetail = error as CloudHandlerErrorDetail;
    return typeof detail.code === 'number' ? String(detail.code) : 'not-provided';
  }

  private static logMediaHandlerError(operation: MediaOperation, source: MediaErrorSource,
    cloudObjectName: MediaCloudObjectName, message: string, code: string): void {
    // Extract only the missing module name; never log the request or raw error body.
    const matchedModule: RegExpMatchArray | null = message.match(
      /Cannot find (?:module|package)\s+['"]([^'"\r\n]+)['"]/);
    const missingModule: string = matchedModule !== null && matchedModule.length > 1
      ? matchedModule[1].replace(/[A-Za-z0-9_+=-]{48,}/g, '[redacted]')
        .replace(/[^A-Za-z0-9@./_:+\[\]-]/g, '?').slice(0, 160)
      : 'not-provided';
    let reason: string = 'handler-error';
    if (missingModule !== 'not-provided') reason = 'module-not-found';
    else if (message.includes('Invalid package config') || message.includes('ERR_INVALID_PACKAGE_CONFIG')) reason = 'invalid-package-config';
    else if (message.includes('Cannot read properties') || message.includes('Cannot set properties')) reason = 'invalid-receiver-or-property';
    else if (message.includes('is not a function')) reason = 'not-callable';
    else if (message.includes('is not defined')) reason = 'undefined-name';
    else if (message.includes('SyntaxError')) reason = 'syntax-error';
    console.error('[MediaService] diagnostic; source=' + source + '; cloudObject=' + cloudObjectName +
      '; version=$latest; operation=' + operation + '; code=' + code + '; missingModule=' + missingModule +
      '; reason=' + reason);
  }

  private static isMediaHandlerLoadError(message: string): boolean {
    return message.includes('Call handler error') &&
      (message.includes('Cannot find module') || message.includes('Cannot find package') ||
        message.includes('Invalid package config') || message.includes('ERR_INVALID_PACKAGE_CONFIG'));
  }

  private static openMediaCircuit(operation: MediaOperation, generation: number): MediaServiceUnavailableError {
    if (generation === CloudGateway.mediaCircuitGeneration) {
      const wasOpen: boolean = CloudGateway.isMediaServiceUnavailable();
      CloudGateway.mediaCircuitOpenUntilMs = Date.now() + MEDIA_CIRCUIT_BREAK_MS;
      if (!wasOpen) console.error('[MediaService] handler initialization failed; operation=' + operation + '.');
    }
    return new MediaServiceUnavailableError();
  }

  private static async invokeMedia(operation: MediaOperation, envelope: CloudEnvelope,
    generation: number): Promise<CloudObjectResponse> {
    try {
      switch (operation) {
        case 'prepare-card-photo': return await (CloudGateway.mediaObject as ShikeMedia).prepareCardPhoto(envelope);
        case 'upload-card-photo': return await (CloudGateway.mediaObject as ShikeMedia).uploadCardPhoto(envelope);
        case 'get-public-media': return await (CloudGateway.mediaObject as ShikeMedia).getPublicMedia(envelope);
      }
      throw new Error('当前未开放媒体接口。');
    } catch (error) {
      const message: string = CloudGateway.cloudHandlerMessage(error as Object);
      if (message.includes('Call handler error')) {
        CloudGateway.logMediaHandlerError(operation, 'cloud-call', 'shike-media', message,
          CloudGateway.cloudHandlerCode(error as Object));
      }
      if (CloudGateway.isMediaHandlerLoadError(message)) {
        throw CloudGateway.openMediaCircuit(operation, generation);
      }
      if (message.includes('Call handler error')) {
        console.error('[MediaService] handler error; operation=' + operation + '.');
        throw new Error('实拍图服务处理请求失败，请稍后重试。');
      }
      if (error instanceof Error) throw error;
      throw new Error(message.length > 0 ? message : '云端请求失败，请稍后重试。');
    }
  }

  private static initialize(): void {
    if (CloudGateway.initialized) return;
    cloudCommon.init({
      region: cloudCommon.CloudRegion.CHINA,
      functionOptions: { timeout: 70000 },
      // Cloud Foundation requires an auth provider before it can construct an
      // invokable Cloud Object handler. Cloud Object HTTP triggers use the
      // platform app signature; application tokens stay in CloudEnvelope for
      // the function to verify. In particular, do not put the server-issued
      // Huawei migration token in this framework-level credential.
      authProvider: {
        getAccessToken: async (_isForceRefresh: boolean): Promise<string> => ''
      }
    });
    CloudGateway.authObject = importObject(ShikeAuth);
    CloudGateway.locationObject = importObject(ShikeLocation);
    CloudGateway.mediaObject = importObject(ShikeMedia);
    CloudGateway.serviceObject = importObject(ShikeService);
    CloudGateway.initialized = true;
  }

  static hasSession(): boolean {
    return AuthSessionStore.hasCachedSession();
  }

  static async callPublic<T>(name: string, payload: object): Promise<T> {
    return CloudGateway.execute<T>(name, payload, false);
  }

  static async callAuthenticated<T>(name: string, payload: object): Promise<T> {
    return CloudGateway.execute<T>(name, payload, true);
  }

  private static async execute<T>(name: string, payload: object, authenticated: boolean): Promise<T> {
    // All callers are reachable only after the startup privacy consent gate.
    const mediaOperation: MediaOperation | undefined = CloudGateway.mediaOperationFor(name);
    CloudGateway.initialize();
    const accessToken: string = authenticated ? await AuthSessionStore.getAccessToken(false) : '';
    if (authenticated && accessToken.length === 0) {
      throw new Error('登录状态已失效，请重新登录。');
    }
    if (mediaOperation !== undefined && CloudGateway.isMediaServiceUnavailable()) {
      throw new MediaServiceUnavailableError();
    }
    const envelope: CloudEnvelope = {
      accessToken,
      payload
    };
    const mediaGeneration: number = CloudGateway.mediaCircuitGeneration;
    let raw: CloudObjectResponse | undefined = undefined;
    switch (name) {
      case 'get-discovery-capabilities':
        raw = await (CloudGateway.serviceObject as ShikeService).getDiscoveryCapabilities(envelope);
        break;
      case 'list-map-merchants':
        raw = await (CloudGateway.serviceObject as ShikeService).listMapMerchants(envelope);
        break;
      case 'search-public-cards':
        raw = await (CloudGateway.serviceObject as ShikeService).searchPublicCards(envelope);
        break;
      case 'get-merchant-recommendations':
        raw = await (CloudGateway.serviceObject as ShikeService).getMerchantRecommendations(envelope);
        break;
      case 'exchange-huawei-account':
        raw = await (CloudGateway.authObject as ShikeAuth).exchangeHuaweiAccount(envelope);
        break;
      case 'complete-legacy-login':
        raw = await (CloudGateway.serviceObject as ShikeService).completeLegacyLogin(envelope);
        break;
      case 'start-email-binding':
        raw = await (CloudGateway.serviceObject as ShikeService).startEmailBinding(envelope);
        break;
      case 'complete-email-binding':
        raw = await (CloudGateway.serviceObject as ShikeService).completeEmailBinding(envelope);
        break;
      case 'check-location':
        raw = await (CloudGateway.locationObject as ShikeLocation).checkLocation(envelope);
        break;
      case 'list-nearby-cards':
        raw = await (CloudGateway.serviceObject as ShikeService).listNearbyCards(envelope);
        break;
      case 'list-friend-rankings':
        raw = await (CloudGateway.serviceObject as ShikeService).listFriendRankings(envelope);
        break;
      case 'get-friend-profile':
        raw = await (CloudGateway.serviceObject as ShikeService).getFriendProfile(envelope);
        break;
      case 'upsert-profile':
        raw = await (CloudGateway.serviceObject as ShikeService).upsertProfile(envelope);
        break;
      case 'prepare-card-photo':
        raw = await CloudGateway.invokeMedia('prepare-card-photo', envelope, mediaGeneration);
        break;
      case 'upload-card-photo':
        raw = await CloudGateway.invokeMedia('upload-card-photo', envelope, mediaGeneration);
        break;
      case 'get-public-media':
        raw = authenticated
          ? await CloudGateway.invokeMedia('get-public-media', envelope, mediaGeneration)
          : await (CloudGateway.serviceObject as ShikeService).getPublicMedia(envelope);
        break;
      case 'publish-card':
      case 'publish-cards':
        // Keep both spellings during rollout for older installed packages.
        raw = await (CloudGateway.serviceObject as ShikeService).publishCard(envelope);
        break;
      case 'get-stage2-capabilities':
        raw = await (CloudGateway.serviceObject as ShikeService).getStage2Capabilities(envelope);
        break;
      case 'resolve-merchant':
        raw = await (CloudGateway.serviceObject as ShikeService).resolveMerchant(envelope);
        break;
      case 'create-user-merchant':
        raw = await (CloudGateway.serviceObject as ShikeService).createUserMerchant(envelope);
        break;
      case 'update-user-merchant':
        raw = await (CloudGateway.serviceObject as ShikeService).updateUserMerchant(envelope);
        break;
      case 'get-merchant':
        raw = await (CloudGateway.serviceObject as ShikeService).getMerchant(envelope);
        break;
      case 'list-moderation-merchants':
        raw = await (CloudGateway.serviceObject as ShikeService).listModerationMerchants(envelope);
        break;
      case 'moderate-merchant':
        raw = await (CloudGateway.serviceObject as ShikeService).moderateMerchant(envelope);
        break;
      case 'reconcile-merchant-counters':
        raw = await (CloudGateway.serviceObject as ShikeService).reconcileMerchantCounters(envelope);
        break;
      case 'get-card-edit-context':
        raw = await (CloudGateway.serviceObject as ShikeService).getCardEditContext(envelope);
        break;
      case 'get-card-detail':
        raw = await (CloudGateway.serviceObject as ShikeService).getCardDetail(envelope);
        break;
      case 'list-my-cards':
        raw = await (CloudGateway.serviceObject as ShikeService).listMyCards(envelope);
        break;
      case 'list-my-favorite-cards':
        raw = await (CloudGateway.serviceObject as ShikeService).listMyFavoriteCards(envelope);
        break;
      case 'list-received-comments':
        throw new Error('评论入口已下线。');
      case 'search-users':
        raw = await (CloudGateway.serviceObject as ShikeService).searchUsers(envelope);
        break;
      case 'list-friends':
        raw = await (CloudGateway.serviceObject as ShikeService).listFriends(envelope);
        break;
      case 'send-friend-request':
        raw = await (CloudGateway.serviceObject as ShikeService).sendFriendRequest(envelope);
        break;
      case 'respond-friend-request':
        raw = await (CloudGateway.serviceObject as ShikeService).respondFriendRequest(envelope);
        break;
      case 'cancel-friend-request':
        raw = await (CloudGateway.serviceObject as ShikeService).cancelFriendRequest(envelope);
        break;
      case 'block-user':
        raw = await (CloudGateway.serviceObject as ShikeService).blockUser(envelope);
        break;
      case 'unblock-user':
        raw = await (CloudGateway.serviceObject as ShikeService).unblockUser(envelope);
        break;
      case 'report-user':
        raw = await (CloudGateway.serviceObject as ShikeService).reportUser(envelope);
        break;
      case 'remove-friend':
        raw = await (CloudGateway.serviceObject as ShikeService).removeFriend(envelope);
        break;
      case 'list-conversations':
        raw = await (CloudGateway.serviceObject as ShikeService).listConversations(envelope);
        break;
      case 'list-messages':
        raw = await (CloudGateway.serviceObject as ShikeService).listMessages(envelope);
        break;
      case 'send-message':
        raw = await (CloudGateway.serviceObject as ShikeService).sendMessage(envelope);
        break;
      case 'create-group-chat':
        raw = await (CloudGateway.serviceObject as ShikeService).createGroupChat(envelope);
        break;
      case 'list-group-conversations':
        raw = await (CloudGateway.serviceObject as ShikeService).listGroupConversations(envelope);
        break;
      case 'get-group-chat':
        raw = await (CloudGateway.serviceObject as ShikeService).getGroupChat(envelope);
        break;
      case 'list-group-messages':
        raw = await (CloudGateway.serviceObject as ShikeService).listGroupMessages(envelope);
        break;
      case 'send-group-message':
        raw = await (CloudGateway.serviceObject as ShikeService).sendGroupMessage(envelope);
        break;
      case 'leave-group-chat':
        raw = await (CloudGateway.serviceObject as ShikeService).leaveGroupChat(envelope);
        break;
      case 'remove-group-member':
        raw = await (CloudGateway.serviceObject as ShikeService).removeGroupMember(envelope);
        break;
      case 'list-notifications':
        raw = await (CloudGateway.serviceObject as ShikeService).listNotifications(envelope);
        break;
      case 'mark-notification-read':
        raw = await (CloudGateway.serviceObject as ShikeService).markNotificationRead(envelope);
        break;
      case 'mark-all-notifications-read':
        raw = await (CloudGateway.serviceObject as ShikeService).markAllNotificationsRead(envelope);
        break;
      case 'open-notification':
        raw = await (CloudGateway.serviceObject as ShikeService).openNotification(envelope);
        break;
      case 'register-push-device':
        raw = await (CloudGateway.serviceObject as ShikeService).registerPushDevice(envelope);
        break;
      case 'unregister-push-device':
        raw = await (CloudGateway.serviceObject as ShikeService).unregisterPushDevice(envelope);
        break;
      case 'sync-service-card-forms':
        raw = await (CloudGateway.serviceObject as ShikeService).syncServiceCardForms(envelope);
        break;
      case 'unregister-service-card-forms':
        raw = await (CloudGateway.serviceObject as ShikeService).unregisterServiceCardForms(envelope);
        break;
      case 'push-service-card-update':
        raw = await (CloudGateway.serviceObject as ShikeService).pushServiceCardUpdate(envelope);
        break;
      case 'report-card':
        raw = await (CloudGateway.serviceObject as ShikeService).reportCard(envelope);
        break;
      case 'toggle-card-action':
        raw = await (CloudGateway.serviceObject as ShikeService).toggleCardAction(envelope);
        break;
      case 'create-card-comment':
        throw new Error('评论入口已下线。');
      case 'delete-card-comment':
        throw new Error('评论入口已下线。');
      case 'toggle-comment-reaction':
        throw new Error('评论入口已下线。');
      case 'set-card-reaction':
        raw = await (CloudGateway.serviceObject as ShikeService).setCardReaction(envelope);
        break;
      case 'submit-card-revision':
        raw = await (CloudGateway.serviceObject as ShikeService).submitCardRevision(envelope);
        break;
      case 'get-card-revision':
        raw = await (CloudGateway.serviceObject as ShikeService).getCardRevision(envelope);
        break;
      case 'withdraw-card-revision':
        raw = await (CloudGateway.serviceObject as ShikeService).withdrawCardRevision(envelope);
        break;
      case 'list-moderation-revisions':
        raw = await (CloudGateway.serviceObject as ShikeService).listModerationRevisions(envelope);
        break;
      case 'moderate-card-revision':
        raw = await (CloudGateway.serviceObject as ShikeService).moderateCardRevision(envelope);
        break;
      case 'start-migration-job':
        raw = await (CloudGateway.serviceObject as ShikeService).startMigrationJob(envelope);
        break;
      case 'process-migration-job':
        raw = await (CloudGateway.serviceObject as ShikeService).processMigrationJob(envelope);
        break;
      case 'get-migration-status':
        raw = await (CloudGateway.serviceObject as ShikeService).getMigrationStatus(envelope);
        break;
      case 'list-maintenance-jobs':
        raw = await (CloudGateway.serviceObject as ShikeService).listMaintenanceJobs(envelope);
        break;
      case 'get-maintenance-job':
        raw = await (CloudGateway.serviceObject as ShikeService).getMaintenanceJob(envelope);
        break;
      case 'retry-maintenance-job':
        raw = await (CloudGateway.serviceObject as ShikeService).retryMaintenanceJob(envelope);
        break;
      case 'validate-lifecycle-job':
        raw = await (CloudGateway.serviceObject as ShikeService).validateLifecycleJob(envelope);
        break;
      case 'get-revision-media':
        raw = await (CloudGateway.serviceObject as ShikeService).getRevisionMedia(envelope);
        break;
      case 'set-card-visibility':
        raw = await (CloudGateway.serviceObject as ShikeService).setCardVisibility(envelope);
        break;
      case 'revoke-friend-content-access':
        raw = await (CloudGateway.serviceObject as ShikeService).revokeFriendContentAccess(envelope);
        break;
      case 'process-friend-cleanup-job':
        raw = await (CloudGateway.serviceObject as ShikeService).processFriendCleanupJob(envelope);
        break;
      case 'delete-own-card':
        raw = await (CloudGateway.serviceObject as ShikeService).deleteOwnCard(envelope);
        break;
      case 'delete-account-data':
        raw = await (CloudGateway.serviceObject as ShikeService).deleteAccountData(envelope);
        break;
    default:
      throw new Error(`当前未开放接口：${name}`);
    }
    if (raw === undefined) {
      throw new Error('云对象未返回结果。');
    }
    const decoded = decode<T>(raw);
    if (!decoded.ok) {
      const message: string = decoded.message || '云端请求失败，请稍后重试。';
      if (mediaOperation !== undefined && message.includes('Call handler error')) {
        const cloudObjectName: MediaCloudObjectName = name === 'get-public-media' && !authenticated
          ? 'shike-service' : 'shike-media';
        CloudGateway.logMediaHandlerError(mediaOperation, 'business-response', cloudObjectName, message,
          decoded.code === undefined ? 'not-returned' : decoded.code);
      }
      if (mediaOperation !== undefined && CloudGateway.isMediaHandlerLoadError(message)) {
        throw CloudGateway.openMediaCircuit(mediaOperation, mediaGeneration);
      }
      if (mediaOperation !== undefined && message.includes('Call handler error')) {
        console.error('[MediaService] handler returned an error; operation=' + mediaOperation + '.');
        throw new Error('实拍图服务处理请求失败，请稍后重试。');
      }
      throw new CloudBusinessError(message, decoded.code === undefined ? 'REQUEST_FAILED' : decoded.code);
    }
    return decoded.data;
  }
}
