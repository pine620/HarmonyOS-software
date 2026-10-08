import { cloudCommon, cloudFunction } from '@kit.CloudFoundationKit';
import { importObject, ShikeAuth, ShikeLocation, ShikeMedia, ShikeService } from '@shike/cloud-objects';
import type { CloudEnvelope } from '@shike/cloud-objects';
import { FeaturePerformanceTrace, FeatureTraceName } from './FeaturePerformanceTrace';
import { AuthSessionStore } from './AuthSessionStore';
import { CloudBusinessError, ReadCancelledError, cloudReadError } from './CloudReadErrors';
import { ReadRequestOptions, ReadScheduler } from './ReadScheduler';
export { CloudBusinessError } from './CloudReadErrors';

type MediaOperation = 'prepare-card-photo' | 'upload-card-photo' | 'get-public-media';
type MediaErrorSource = 'cloud-call' | 'business-response';
type MediaCloudObjectName = 'shike-media' | 'shike-service';
type Stage47ServiceMethod = 'getStage47Capabilities' | 'getTastePreference' | 'updateTastePreference' |
  'clearTastePreference' | 'listPersonalizedRecommendations' | 'listFoodLists' | 'createFoodList' |
  'updateFoodList' | 'deleteFoodList' | 'listFoodListItems' | 'addFoodListItem' | 'removeFoodListItem' |
  'reorderFoodListItems' | 'getPersonalFoodState' | 'updatePersonalFoodState' | 'getMealCandidates' |
  'recordMealChoice' | 'listMealChoiceHistory' | 'createMealPoll' | 'getMealPoll' | 'addMealPollOption' |
  'voteMealPoll' | 'closeMealPoll' | 'cancelMealPoll' | 'stopMealPollOptions' | 'getUserPage' |
  'listMerchantRankings' | 'listFormerFriendContentGrants' | 'setCardReactionV2' |
  'getCardPreviews' | 'listPersonalCollection' | 'getPersonalCollectionMigration' |
  'startPersonalCollectionMigration' | 'resumePersonalCollectionMigration' | 'setCardFavorite' | 'setCardWanted' | 'getStage89Capabilities' | 'listModerationQueue' | 'getModerationDetail' | 'decideModeration' | 'listMyReports' | 'reportMerchant' | 'listOwnReviewRequests' | 'listDeletedCards' | 'restoreDeletedCard' | 'listLifecycleJobs' | 'getLifecycleJob' | 'retryLifecycleJob' | 'confirmAuthCleanup' | 'getReviewMedia' | 'runLifecycleJob';

interface ReadCloudEnvelope extends CloudEnvelope {
  readRequestId: string;
  readAttempt: number;
}

interface Stage47ServiceInvocation {
  method: Stage47ServiceMethod;
  params: Array<CloudEnvelope>;
}

interface CloudHandlerErrorDetail {
  code?: number | string;
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

interface ApiResponse<T> {
  ok: boolean;
  code?: string;
  retryable?: boolean;
  retryAfterMs?: number;
  requestId?: string;
  operation?: string;
  stage?: string;
  functionVersion?: string;
  data: T;
  message: string;
}

interface CloudObjectResponse {
  ok: boolean;
  code?: string;
  retryable?: boolean;
  retryAfterMs?: number;
  requestId?: string;
  operation?: string;
  stage?: string;
  functionVersion?: string;
  data: object;
  message: string;
}

interface ReadCardIdentity { id: string; }
interface ReadCandidateIdentity { card: ReadCardIdentity; }
interface ReadPreviewSummaryItem { accessible: boolean; }
interface ReadPageSummary {
  cards?: Array<ReadCardIdentity>;
  candidates?: Array<ReadCandidateIdentity>;
  items?: Array<ReadPreviewSummaryItem>;
  nextCursor?: string;
  coverage?: string;
  scannedCandidateCount?: number;
  consumedCandidateCount?: number;
  fetchedCandidateCount?: number;
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
    return detail.code === undefined ? 'not-provided' : String(detail.code);
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
      const normalized: Error = cloudReadError(error as Object, operation, '');
      if (normalized instanceof CloudBusinessError && normalized.code === '3007009') throw normalized;
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
      throw cloudReadError(error as Object, operation, '');
    }
  }

  private static async invokeStage47(method: Stage47ServiceMethod,
    envelope: CloudEnvelope): Promise<CloudObjectResponse> {
    // Match the generated importObject protocol while its declarations contain only older methods.
    const invocation: Stage47ServiceInvocation = { method, params: [envelope] };
    const parameters: cloudFunction.FunctionParams = {
      name: 'shike-service',
      version: '$latest',
      data: invocation
    };
    const response: cloudFunction.FunctionResult = await cloudFunction.call(parameters);
    return decode<object>(response.result as string | object);
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

  static async callPublic<T>(name: string, payload: object, options: ReadRequestOptions = {}): Promise<T> {
    return CloudGateway.dispatch<T>(name, payload, false, options);
  }

  static async callAuthenticated<T>(name: string, payload: object, options: ReadRequestOptions = {}): Promise<T> {
    return CloudGateway.dispatch<T>(name, payload, true, options);
  }

  private static async dispatch<T>(name: string, payload: object, authenticated: boolean,
    options: ReadRequestOptions): Promise<T> {
    const trace: FeatureTraceName | undefined = FeaturePerformanceTrace.traceNameForOperation(name, payload);
    if (trace !== undefined) return FeaturePerformanceTrace.measure<T>(trace, (): Promise<T> => CloudGateway.dispatchRead<T>(name, payload, authenticated, options));
    return CloudGateway.dispatchRead<T>(name, payload, authenticated, options);
  }

  private static async dispatchRead<T>(name: string, payload: object, authenticated: boolean, options: ReadRequestOptions): Promise<T> {
    if (!ReadScheduler.allows(name)) return CloudGateway.execute<T>(name, payload, authenticated);
    const value: object = await ReadScheduler.schedule(name, payload, authenticated, options,
      (requestId: string, attempt: number): Promise<object> => CloudGateway.execute<object>(name, payload, authenticated, requestId, attempt));
    if (options.mayContinue !== undefined && !await options.mayContinue()) throw new ReadCancelledError();
    return value as T;
  }

  private static changesReadContent(name: string): boolean {
    switch (name) {
      case 'update-taste-preference': case 'clear-taste-preference':
      case 'create-food-list': case 'update-food-list': case 'delete-food-list':
      case 'add-food-list-item': case 'remove-food-list-item': case 'reorder-food-list-items':
      case 'set-card-favorite': case 'set-card-wanted': case 'set-card-reaction-v2':
      case 'start-personal-collection-migration': case 'resume-personal-collection-migration':
      case 'update-personal-food-state': case 'toggle-card-action':
      case 'set-card-visibility': case 'revoke-friend-content-access':
      case 'block-user': case 'unblock-user': case 'remove-friend': case 'respond-friend-request':
      case 'delete-own-card': case 'delete-account-data': case 'publish-card': case 'publish-cards':
      case 'decide-moderation': case 'restore-deleted-card': case 'report-merchant':
      case 'retry-lifecycle-job': case 'confirm-auth-cleanup':
      case 'moderate-card': case 'moderate-card-revision':
        return true;
      default: return false;
    }
  }

  private static logReadPage(name: string, data: object, requestId: string): void {
    if (name === 'get-card-previews' || name === 'list-personal-collection' || name === 'get-user-page') {
      const preview: ReadPageSummary = data as ReadPageSummary;
      const count: number = preview.items !== undefined ? preview.items.length : (preview.cards?.length || 0);
      const readable: number = preview.items !== undefined ?
        preview.items.filter((item: ReadPreviewSummaryItem): boolean => item.accessible).length : count;
      console.info('[ReadPage] operation=' + name + ' requestId=' + requestId + ' references=' + count +
        ' readable=' + readable + ' hasMore=' + String((preview.nextCursor || '').length > 0));
      return;
    }
    if (name !== 'list-personalized-recommendations' && name !== 'get-meal-candidates') return;
    const summary: ReadPageSummary = data as ReadPageSummary;
    const ids: Array<string> = summary.cards !== undefined
      ? summary.cards.map((card: ReadCardIdentity): string => card.id)
      : summary.candidates === undefined ? [] : summary.candidates.map((item: ReadCandidateIdentity): string => item.card.id);
    console.info('[ReadPage] operation=' + name + ' requestId=' + requestId + ' returnedCount=' + ids.length +
      ' cardIds=' + ids.join(',') + ' hasMore=' + String(summary.nextCursor !== undefined && summary.nextCursor.length > 0) +
      ' coverage=' + (summary.coverage || '') + ' scanned=' + (summary.scannedCandidateCount || 0) +
      ' consumed=' + (summary.consumedCandidateCount || 0) + ' fetched=' + (summary.fetchedCandidateCount || 0));
  }

  private static async execute<T>(name: string, payload: object, authenticated: boolean,
    readRequestId: string = '', readAttempt: number = 1): Promise<T> {
    // All callers are reachable only after the startup privacy consent gate.
    const mediaOperation: MediaOperation | undefined = CloudGateway.mediaOperationFor(name);
    CloudGateway.initialize();
    const session: number = AuthSessionStore.generation();
    let accessToken: string = '';
    if (authenticated) {
      try { accessToken = await AuthSessionStore.getAccessToken(false); }
      catch (error) {
        const failure: Error = cloudReadError(error as Object, name, readRequestId);
        if (failure instanceof CloudBusinessError) { failure.retryable = false; failure.stage = 'authentication'; }
        throw failure;
      }
    }
    if (session !== AuthSessionStore.generation()) throw new ReadCancelledError();
    if (authenticated && accessToken.length === 0) {
      throw new Error('登录状态已失效，请重新登录。');
    }
    if (mediaOperation !== undefined && CloudGateway.isMediaServiceUnavailable()) {
      throw new MediaServiceUnavailableError();
    }
    const envelope: ReadCloudEnvelope = { accessToken, payload, readRequestId, readAttempt };
    const mediaGeneration: number = CloudGateway.mediaCircuitGeneration;
    let raw: CloudObjectResponse | undefined = undefined;
    switch (name) {
      case 'get-card-previews':
        raw = await CloudGateway.invokeStage47('getCardPreviews', envelope); break;
      case 'list-personal-collection':
        raw = await CloudGateway.invokeStage47('listPersonalCollection', envelope); break;
      case 'get-personal-collection-migration':
        raw = await CloudGateway.invokeStage47('getPersonalCollectionMigration', envelope); break;
      case 'start-personal-collection-migration':
        raw = await CloudGateway.invokeStage47('startPersonalCollectionMigration', envelope); break;
      case 'resume-personal-collection-migration':
        raw = await CloudGateway.invokeStage47('resumePersonalCollectionMigration', envelope); break;
      case 'set-card-favorite':
        raw = await CloudGateway.invokeStage47('setCardFavorite', envelope); break;
      case 'set-card-wanted':
        raw = await CloudGateway.invokeStage47('setCardWanted', envelope); break;
      case 'get-stage89-capabilities':
        raw = await CloudGateway.invokeStage47('getStage89Capabilities', envelope); break;
      case 'list-moderation-queue':
        raw = await CloudGateway.invokeStage47('listModerationQueue', envelope); break;
      case 'get-moderation-detail':
        raw = await CloudGateway.invokeStage47('getModerationDetail', envelope); break;
      case 'decide-moderation':
        raw = await CloudGateway.invokeStage47('decideModeration', envelope); break;
      case 'list-my-reports':
        raw = await CloudGateway.invokeStage47('listMyReports', envelope); break;
      case 'report-merchant':
        raw = await CloudGateway.invokeStage47('reportMerchant', envelope); break;
      case 'list-own-review-requests':
        raw = await CloudGateway.invokeStage47('listOwnReviewRequests', envelope); break;
      case 'list-deleted-cards':
        raw = await CloudGateway.invokeStage47('listDeletedCards', envelope); break;
      case 'restore-deleted-card':
        raw = await CloudGateway.invokeStage47('restoreDeletedCard', envelope); break;
      case 'list-lifecycle-jobs':
        raw = await CloudGateway.invokeStage47('listLifecycleJobs', envelope); break;
      case 'get-lifecycle-job':
        raw = await CloudGateway.invokeStage47('getLifecycleJob', envelope); break;
      case 'retry-lifecycle-job':
        raw = await CloudGateway.invokeStage47('retryLifecycleJob', envelope); break;
      case 'confirm-auth-cleanup':
        raw = await CloudGateway.invokeStage47('confirmAuthCleanup', envelope); break;
      case 'get-review-media':
        raw = await CloudGateway.invokeStage47('getReviewMedia', envelope); break;
      case 'run-lifecycle-job':
        raw = await CloudGateway.invokeStage47('runLifecycleJob', envelope); break;
      case 'get-stage47-capabilities':
        raw = await CloudGateway.invokeStage47('getStage47Capabilities', envelope);
        break;
      case 'get-taste-preference':
        raw = await CloudGateway.invokeStage47('getTastePreference', envelope);
        break;
      case 'update-taste-preference':
        raw = await CloudGateway.invokeStage47('updateTastePreference', envelope);
        break;
      case 'clear-taste-preference':
        raw = await CloudGateway.invokeStage47('clearTastePreference', envelope);
        break;
      case 'list-personalized-recommendations':
        raw = await CloudGateway.invokeStage47('listPersonalizedRecommendations', envelope);
        break;
      case 'list-food-lists':
        raw = await CloudGateway.invokeStage47('listFoodLists', envelope);
        break;
      case 'create-food-list':
        raw = await CloudGateway.invokeStage47('createFoodList', envelope);
        break;
      case 'update-food-list':
        raw = await CloudGateway.invokeStage47('updateFoodList', envelope);
        break;
      case 'delete-food-list':
        raw = await CloudGateway.invokeStage47('deleteFoodList', envelope);
        break;
      case 'list-food-list-items':
        raw = await CloudGateway.invokeStage47('listFoodListItems', envelope);
        break;
      case 'add-food-list-item':
        raw = await CloudGateway.invokeStage47('addFoodListItem', envelope);
        break;
      case 'remove-food-list-item':
        raw = await CloudGateway.invokeStage47('removeFoodListItem', envelope);
        break;
      case 'reorder-food-list-items':
        raw = await CloudGateway.invokeStage47('reorderFoodListItems', envelope);
        break;
      case 'get-personal-food-state':
        raw = await CloudGateway.invokeStage47('getPersonalFoodState', envelope);
        break;
      case 'update-personal-food-state':
        raw = await CloudGateway.invokeStage47('updatePersonalFoodState', envelope);
        break;
      case 'get-meal-candidates':
        raw = await CloudGateway.invokeStage47('getMealCandidates', envelope);
        break;
      case 'record-meal-choice':
        raw = await CloudGateway.invokeStage47('recordMealChoice', envelope);
        break;
      case 'list-meal-choice-history':
        raw = await CloudGateway.invokeStage47('listMealChoiceHistory', envelope);
        break;
      case 'create-meal-poll':
        raw = await CloudGateway.invokeStage47('createMealPoll', envelope);
        break;
      case 'get-meal-poll':
        raw = await CloudGateway.invokeStage47('getMealPoll', envelope);
        break;
      case 'add-meal-poll-option':
        raw = await CloudGateway.invokeStage47('addMealPollOption', envelope);
        break;
      case 'vote-meal-poll':
        raw = await CloudGateway.invokeStage47('voteMealPoll', envelope);
        break;
      case 'close-meal-poll':
        raw = await CloudGateway.invokeStage47('closeMealPoll', envelope);
        break;
      case 'cancel-meal-poll':
        raw = await CloudGateway.invokeStage47('cancelMealPoll', envelope);
        break;
      case 'stop-meal-poll-options':
        raw = await CloudGateway.invokeStage47('stopMealPollOptions', envelope);
        break;
      case 'get-user-page':
        raw = await CloudGateway.invokeStage47('getUserPage', envelope);
        break;
      case 'list-merchant-rankings':
        raw = await CloudGateway.invokeStage47('listMerchantRankings', envelope);
        break;
      case 'list-former-friend-content-grants':
        raw = await CloudGateway.invokeStage47('listFormerFriendContentGrants', envelope);
        break;
      case 'set-card-reaction-v2':
        raw = await CloudGateway.invokeStage47('setCardReactionV2', envelope);
        break;
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
      const code: string = decoded.code === undefined ? 'REQUEST_FAILED' : decoded.code;
      throw new CloudBusinessError(message, code, decoded.retryable === undefined ? code === '3007009' : decoded.retryable,
        decoded.retryAfterMs || 0, decoded.requestId || readRequestId, decoded.operation || name, decoded.stage || 'business-response');
    }
    if (session === AuthSessionStore.generation() && CloudGateway.changesReadContent(name)) ReadScheduler.contentChanged();
    if (session === AuthSessionStore.generation() && ['block-user', 'unblock-user', 'remove-friend', 'respond-friend-request'].includes(name))
      AppStorage.setOrCreate('accountContentRevision', (AppStorage.get<number>('accountContentRevision') || 0) + 1);
    if (ReadScheduler.allows(name) && session === AuthSessionStore.generation() &&
      AppStorage.get<boolean>('stage47AppActive') !== false) {
      const requestId: string = decoded.requestId || readRequestId;
      console.info('[ReadResponse] operation=' + name + ' requestId=' + requestId +
        ' code=OK functionVersion=' + (decoded.functionVersion || 'not-returned'));
      CloudGateway.logReadPage(name, decode<object>(raw).data, requestId);
    }
    return decoded.data;
  }
}
