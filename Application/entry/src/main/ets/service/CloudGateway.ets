import { bundleManager } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { ImageDescriptors } from './ImageDescriptors';
import { ImageReadItem, ImageReadRequest } from '../model/ImageModels';
import { CardDetailRequest, CardRevisionResponse } from '../model/CloudContracts';
import { cloudCommon, cloudFunction } from '@kit.CloudFoundationKit';
import { importObject, ShikeAuth, ShikeLocation, ShikeMedia } from '@shike/cloud-objects';
import type { CloudEnvelope } from '@shike/cloud-objects';
import { CLOUD_FUNCTION_VERSION } from './CloudFunctionVersion';
import { CLIENT_DIRECT_UPLOAD_ENABLED } from './ImageReadConfig';
import { CLOUD_SERVICE_SPLIT_ENABLED, CloudRoute, LEGACY_SERVICE_FUNCTION, cloudRouteFor, isReadOnlyOperation } from './CloudRoutes';
import { FeaturePerformanceTrace, FeatureTraceName } from './FeaturePerformanceTrace';
import { AuthSessionStore } from './AuthSessionStore';
import { registerHomeSnapshotPrefetch } from './HomeSnapshotReader';
import { CloudBusinessError, ReadCancelledError, cloudReadError } from './CloudReadErrors';
import { ReadRequestOptions, ReadScheduler } from './ReadScheduler';
export { CloudBusinessError } from './CloudReadErrors';

type MediaOperation = 'prepare-card-photo' | 'upload-card-photo' | 'confirm-card-photo-upload' | 'get-public-media';
type MediaErrorSource = 'cloud-call' | 'business-response';
type MediaCloudObjectName = 'shike-media' | 'shike-service';
interface ServiceInvocation {
  method: string;
  params: Array<CloudEnvelope>;
}

interface ReadCloudEnvelope extends CloudEnvelope {
  readRequestId: string;
  readAttempt: number;
}
interface InteractionPatchTrace { reaction?: string; favorited?: boolean; }
interface InteractionRequestTrace { requestId: string; patch?: InteractionPatchTrace; }

interface ImageFunctionEnvelope extends ImageReadRequest {
  accessToken: string;
  readRequestId: string;
  readAttempt: number;
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
  buildId?: string;
  policyHash?: string;
  protocolVersion?: string;
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
  buildId?: string;
  policyHash?: string;
  protocolVersion?: string;
  data: object;
  message: string;
}

interface ReadCardIdentity { id: string; }
interface ReadCandidateIdentity { card: ReadCardIdentity; }
interface ReadPreviewSummaryItem { accessible: boolean; }
interface ReadPageSummary {
  nextPageToken?: string;
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
  private static appBuildId: string = 'unavailable';
  private static initialized: boolean = false;
  private static authObject: ShikeAuth | undefined = undefined;
  private static locationObject: ShikeLocation | undefined = undefined;
  private static mediaObject: ShikeMedia | undefined = undefined;
  private static mediaCircuitOpenUntilMs: number = 0;

  static isMediaServiceUnavailable(): boolean {
    return Date.now() < CloudGateway.mediaCircuitOpenUntilMs;
  }

  private static mediaOperationFor(name: string): MediaOperation | undefined {
    switch (name) {
      case 'prepare-card-photo': return 'prepare-card-photo';
      case 'upload-card-photo': return 'upload-card-photo';
      case 'confirm-card-photo-upload': return 'confirm-card-photo-upload';
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
      '; version=' + CLOUD_FUNCTION_VERSION + '; operation=' + operation + '; code=' + code + '; missingModule=' + missingModule +
      '; reason=' + reason);
  }

  private static isMediaHandlerLoadError(message: string): boolean {
    return message.includes('Call handler error') &&
      (message.includes('Cannot find module') || message.includes('Cannot find package') ||
        message.includes('Invalid package config') || message.includes('ERR_INVALID_PACKAGE_CONFIG'));
  }

  private static openMediaCircuit(operation: MediaOperation): MediaServiceUnavailableError {
    const wasOpen: boolean = CloudGateway.isMediaServiceUnavailable();
    CloudGateway.mediaCircuitOpenUntilMs = Date.now() + MEDIA_CIRCUIT_BREAK_MS;
    if (!wasOpen) console.error('[MediaService] handler initialization failed; operation=' + operation + '.');
    return new MediaServiceUnavailableError();
  }

  private static async invokeMedia(operation: MediaOperation, envelope: CloudEnvelope): Promise<CloudObjectResponse> {
    try {
      switch (operation) {
        case 'prepare-card-photo': return await (CloudGateway.mediaObject as ShikeMedia).prepareCardPhoto(envelope);
        case 'upload-card-photo': return await (CloudGateway.mediaObject as ShikeMedia).uploadCardPhoto(envelope);
        case 'confirm-card-photo-upload': return await (CloudGateway.mediaObject as ShikeMedia).confirmCardPhotoUpload(envelope);
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
        throw CloudGateway.openMediaCircuit(operation);
      }
      if (message.includes('Call handler error')) {
        console.error('[MediaService] handler error; operation=' + operation + '.');
        throw new Error('实拍图服务处理请求失败，请稍后重试。');
      }
      throw cloudReadError(error as Object, operation, '');
    }
  }

  // Domain functions that failed at the transport level are skipped for a while (falls back to shike-service).
  private static unavailableDomains: Map<string, number> = new Map<string, number>();
  private static readonly DOMAIN_RETRY_MS: number = 10 * 60 * 1000;

  private static functionFor(route: CloudRoute): string {
    if (!CLOUD_SERVICE_SPLIT_ENABLED) return LEGACY_SERVICE_FUNCTION;
    const until: number | undefined = CloudGateway.unavailableDomains.get(route.domainFunction);
    if (until !== undefined && Date.now() < until) return LEGACY_SERVICE_FUNCTION;
    return route.domainFunction;
  }

  private static async callRoute(functionName: string, route: CloudRoute, envelope: CloudEnvelope): Promise<CloudObjectResponse> {
    // Same wire protocol as the generated importObject proxy: { method, params: [envelope] }.
    const invocation: ServiceInvocation = { method: route.method, params: [envelope] };
    let parameters: cloudFunction.FunctionParams = { name: functionName, version: CLOUD_FUNCTION_VERSION, data: invocation };
    if (route.timeoutMs > 0) {
      parameters = { name: functionName, version: CLOUD_FUNCTION_VERSION, data: invocation, timeout: route.timeoutMs };
    }
    const response: cloudFunction.FunctionResult = await cloudFunction.call(parameters);
    return decode<object>(response.result as string | object);
  }

  // Pack 3.4 / 4.4: every shike-service operation goes through the route table. A transport failure of a domain
  // function marks it unavailable; reads are retried once on shike-service, writes are not (unknown outcome).
  private static async invokeRoute(route: CloudRoute, envelope: CloudEnvelope): Promise<CloudObjectResponse> {
    const functionName: string = CloudGateway.functionFor(route);
    let response: CloudObjectResponse;
    try {
      response = await CloudGateway.callRoute(functionName, route, envelope);
    } catch (error) {
      if (functionName === LEGACY_SERVICE_FUNCTION) throw error as Error;
      const message: string = CloudGateway.cloudHandlerMessage(error as Object);
      CloudGateway.markDomainUnavailable(route, message);
      // A handler that could not even be loaded never ran the operation, so writes are safe to retry too.
      if (!isReadOnlyOperation(route.operation) && !CloudGateway.isHandlerLoadError(message)) throw error as Error;
      return await CloudGateway.callRoute(LEGACY_SERVICE_FUNCTION, route, envelope);
    }
    // Fix 2026-10-16: the platform may report a broken deployment (e.g. "Cannot find module './service/runtime'")
    // as a normal response instead of a thrown error. Treat it exactly like an unavailable domain function.
    if (functionName !== LEGACY_SERVICE_FUNCTION && response.ok !== true &&
      CloudGateway.isHandlerLoadError(response.message || '')) {
      CloudGateway.markDomainUnavailable(route, response.message || '');
      return await CloudGateway.callRoute(LEGACY_SERVICE_FUNCTION, route, envelope);
    }
    return response;
  }

  private static isHandlerLoadError(message: string): boolean {
    return message.includes('Call handler error') &&
      (message.includes('Cannot find module') || message.includes('Cannot find package') ||
        message.includes('Invalid package config') || message.includes('ERR_INVALID_PACKAGE_CONFIG') ||
        message.includes('is not a function') || message.includes('SyntaxError'));
  }

  private static markDomainUnavailable(route: CloudRoute, message: string): void {
    CloudGateway.unavailableDomains.set(route.domainFunction, Date.now() + CloudGateway.DOMAIN_RETRY_MS);
    console.warn('[CloudRoute] event=domain-unavailable function=' + route.domainFunction + ' operation=' + route.operation +
      ' loadError=' + CloudGateway.isHandlerLoadError(message));
  }

  private static async invokeNicknameAuth(route: CloudRoute,
    envelope: ReadCloudEnvelope): Promise<CloudObjectResponse> {
    const started: number = Date.now();
    const method: string = route.method;
    console.info('[NicknameAuthClient] requestId=' + envelope.readRequestId + ' method=' + method + ' stage=sent');
    try {
      const decoded: CloudObjectResponse = await CloudGateway.invokeRoute(route, envelope);
      console.info('[NicknameAuthClient] requestId=' + envelope.readRequestId + ' method=' + method +
        ' stage=response code=' + (decoded.code || (decoded.ok ? 'OK' : 'REQUEST_FAILED')) +
        ' elapsedMs=' + (Date.now() - started));
      return decoded;
    } catch (error) {
      const failure: Error = cloudReadError(error as Object, method, envelope.readRequestId);
      const code: string = failure instanceof CloudBusinessError ? failure.code : 'REQUEST_FAILED';
      console.error('[NicknameAuthClient] requestId=' + envelope.readRequestId + ' method=' + method +
        ' stage=cloud-call code=' + code + ' elapsedMs=' + (Date.now() - started));
      throw failure;
    }
  }

  private static initialize(): void {
    if (CloudGateway.initialized) return;
    try { const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT); CloudGateway.appBuildId = info.name + ':' + info.versionName + ':' + info.versionCode; } catch (_error) { }
    cloudCommon.init({
      region: cloudCommon.CloudRegion.CHINA,
      functionOptions: { timeout: 70000 },
      // Cloud Foundation requires an auth provider before it can construct an
      // invokable Cloud Object handler. Cloud Object HTTP triggers use the
      // platform app signature; application tokens stay in CloudEnvelope for
      // the function to verify. In particular, do not put the server-issued
      // Huawei migration token in this framework-level credential.
      // Pack 3.3: only a native AGC Auth (email) token is offered, so Cloud Storage rules can recognise the
      // uploader for direct photo uploads. Huawei / nickname sessions get '' and keep the function upload.
      authProvider: {
        getAccessToken: async (isForceRefresh: boolean): Promise<string> => {
          if (!CLIENT_DIRECT_UPLOAD_ENABLED || !AuthSessionStore.isNativeEmailSession()) return '';
          try {
            return await AuthSessionStore.getNativeAccessToken(isForceRefresh);
          } catch (_error) {
            return '';
          }
        }
      }
    });
    CloudGateway.authObject = importObject(ShikeAuth, CLOUD_FUNCTION_VERSION);
    CloudGateway.locationObject = importObject(ShikeLocation, CLOUD_FUNCTION_VERSION);
    CloudGateway.mediaObject = importObject(ShikeMedia, CLOUD_FUNCTION_VERSION);
    CloudGateway.initialized = true;
    registerHomeSnapshotPrefetch();
  }

  // Direct Cloud Storage reads (home snapshot) need cloudCommon.init before the first cloud call.
  static ensureReady(): void {
    CloudGateway.initialize();
  }

  static hasSession(): boolean {
    return AuthSessionStore.owner().length > 0 || AuthSessionStore.hasCachedSession();
  }

  static async callPublic<T>(name: string, payload: object, options: ReadRequestOptions = {}): Promise<T> {
    // Viewer identity is used for personal actions only; content reads are public.
    const publicImage: boolean = name === 'get-public-media' || name === 'image-read-batch' &&
      (payload as ImageReadRequest).items.every((item: ImageReadItem): boolean => item.mode === 'PUBLIC');
    return CloudGateway.dispatch<T>(name, payload, !publicImage && ReadScheduler.allows(name) && CloudGateway.hasSession(), options);
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
    if (name === 'set-card-interaction') {
      const request: InteractionRequestTrace = payload as InteractionRequestTrace;
      return CloudGateway.execute<T>(name, payload, authenticated, request.requestId);
    }
    if (['get-card-interaction-state', 'get-card-interaction-receipt', 'get-card-interaction-counts'].includes(name)) {
      // These reads have per-card coalescing in the controller. Never let an
      // old detail/image/aggregation request occupy their admission slots.
      if (options.mayContinue !== undefined && !await options.mayContinue()) throw new ReadCancelledError();
      const requestId: string = util.generateRandomUUID(true); const started: number = Date.now();
      let received: boolean = false;
      console.info('[CardInteraction] requestId=' + requestId + ' operation=' + name + ' stage=read_start');
      try {
        const result: T = await CloudGateway.execute<T>(name, payload, authenticated, requestId);
        received = true;
        if (options.mayContinue !== undefined && !await options.mayContinue()) throw new ReadCancelledError();
        return result;
      } finally {
        console.info('[CardInteraction] requestId=' + requestId + ' operation=' + name + ' stage=read_end received=' +
          received + ' elapsedMs=' + (Date.now() - started));
      }
    }
    if (!ReadScheduler.allows(name)) return CloudGateway.execute<T>(name, payload, authenticated);
    const value: object = await ReadScheduler.schedule(name, payload, authenticated, options,
      (requestId: string, attempt: number): Promise<object> => CloudGateway.execute<object>(name, payload, authenticated, requestId, attempt));
    if (options.mayContinue !== undefined && !await options.mayContinue()) throw new ReadCancelledError();
    return value as T;
  }

  private static hasPublicMediaManifest(name: string): boolean {
    return ['get-card-detail', 'get-card-previews', 'list-personal-collection',
      'get-random-food-cards', 'list-food-choices', 'get-meal-candidates', 'get-user-page', 'get-friend-profile', 'list-food-rankings', 'search-public-cards',
      'get-merchant-recommendations', 'list-nearby-cards', 'list-my-cards', 'list-my-favorite-cards'].includes(name);
  }

  private static changesReadContent(name: string): boolean {
    switch (name) {
      case 'set-card-interaction':
      case 'set-card-favorite': case 'set-card-reaction-v2':
      case 'start-personal-collection-migration': case 'resume-personal-collection-migration':
      case 'toggle-card-action':
      case 'delete-own-card': case 'delete-account-data': case 'publish-card': case 'publish-cards':
      case 'restore-deleted-card': case 'report-merchant':
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
    if (name !== 'list-nearby-cards' && name !== 'get-meal-candidates') return;
    const summary: ReadPageSummary = data as ReadPageSummary;
    const returnedCount: number = summary.cards !== undefined ? summary.cards.length : (summary.candidates?.length || 0);
    // Counts and the logical request ID are sufficient to correlate a page; never log private food choices.
    console.info('[ReadPage] operation=' + name + ' requestId=' + requestId + ' returnedCount=' + returnedCount +
      ' hasMore=' + String((summary.nextCursor || summary.nextPageToken || '').length > 0) +
      ' coverage=' + (summary.coverage || '') + ' scanned=' + (summary.scannedCandidateCount || 0) +
      ' consumed=' + (summary.consumedCandidateCount || 0) + ' fetched=' + (summary.fetchedCandidateCount || 0));
  }

  private static async execute<T>(name: string, payload: object, authenticated: boolean,
    readRequestId: string = '', readAttempt: number = 1): Promise<T> {
    if (['get-password-account', 'configure-password-account', 'change-password-account', 'login-with-nickname', 'logout-nickname'].includes(name) &&
      readRequestId.length === 0) readRequestId = util.generateRandomUUID();
    // All callers are reachable only after the startup privacy consent gate.
    const interactionStarted: number = Date.now();
    if (name === 'set-card-interaction') console.info('[CardInteraction] requestId=' + readRequestId + ' stage=gateway_start');
    const mediaOperation: MediaOperation | undefined = CloudGateway.mediaOperationFor(name);
    CloudGateway.initialize();
    const session: number = AuthSessionStore.generation();
    const mediaLifecycle: number = ReadScheduler.lifecycleRevision();
    const mediaData: number = ReadScheduler.dataRevision();
    const imageEpoch: number = ImageDescriptors.epoch();
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
      throw new CloudBusinessError('会话需要恢复，请重新登录或重试恢复。', 'AUTH_REQUIRED');
    }
    if (name === 'set-card-interaction') console.info('[CardInteraction] requestId=' + readRequestId + ' stage=auth_ready elapsedMs=' + (Date.now() - interactionStarted));
    if (mediaOperation !== undefined && CloudGateway.isMediaServiceUnavailable()) {
      throw new MediaServiceUnavailableError();
    }
    const envelope: ReadCloudEnvelope = { accessToken, payload, readRequestId, readAttempt };
    let raw: CloudObjectResponse | undefined = undefined;
    switch (name) {
      case 'image-read-batch': {
        const imageRequest: ImageReadRequest = payload as ImageReadRequest;
        const imageEnvelope: ImageFunctionEnvelope = { protocolVersion: imageRequest.protocolVersion, items: imageRequest.items,
          accessToken, readRequestId, readAttempt };
        const parameters: cloudFunction.FunctionParams = { name: 'shike-image', version: CLOUD_FUNCTION_VERSION, data: imageEnvelope };
        const response: cloudFunction.FunctionResult = await cloudFunction.call(parameters);
        raw = decode<object>(response.result as string | object);
        break;
      }
      case 'exchange-huawei-account':
        raw = await (CloudGateway.authObject as ShikeAuth).exchangeHuaweiAccount(envelope);
        break;
      case 'check-location':
        raw = await (CloudGateway.locationObject as ShikeLocation).checkLocation(envelope);
        break;
      case 'prepare-card-photo':
        raw = await CloudGateway.invokeMedia('prepare-card-photo', envelope);
        break;
      case 'upload-card-photo':
        raw = await CloudGateway.invokeMedia('upload-card-photo', envelope);
        break;
      case 'confirm-card-photo-upload':
        raw = await CloudGateway.invokeMedia('confirm-card-photo-upload', envelope);
        break;
      default: {
        if (name === 'get-public-media' && authenticated) {
          raw = await CloudGateway.invokeMedia('get-public-media', envelope);
          break;
        }
        const route: CloudRoute | undefined = cloudRouteFor(name);
        if (route === undefined) throw new Error(`当前未开放接口：${name}`);
        raw = ['get-password-account', 'configure-password-account', 'change-password-account', 'login-with-nickname',
          'logout-nickname'].includes(route.operation)
          ? await CloudGateway.invokeNicknameAuth(route, envelope)
          : await CloudGateway.invokeRoute(route, envelope);
      }
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
        throw CloudGateway.openMediaCircuit(mediaOperation);
      }
      if (mediaOperation !== undefined && message.includes('Call handler error')) {
        console.error('[MediaService] handler returned an error; operation=' + mediaOperation + '.');
        throw new Error('实拍图服务处理请求失败，请稍后重试。');
      }
      const code: string = decoded.code === undefined ? 'REQUEST_FAILED' : decoded.code;
      if (session === AuthSessionStore.generation() && name === 'get-card-detail' &&
        ['CONTENT_ACCESS_DENIED', 'CONTENT_UNAVAILABLE', 'NOT_FOUND'].includes(code)) {
        const request: CardDetailRequest = payload as CardDetailRequest;
        ImageDescriptors.removeCard(request.cardId);
      }
      throw new CloudBusinessError(message, code, decoded.retryable === undefined ? code === '3007009' : decoded.retryable,
        decoded.retryAfterMs || 0, decoded.requestId || readRequestId, decoded.operation || name, decoded.stage || 'business-response');
    }
    if (name === 'set-card-interaction') console.info('[CardInteraction] requestId=' + readRequestId + ' stage=gateway_response elapsedMs=' + (Date.now() - interactionStarted));
    if (session === AuthSessionStore.generation() && CloudGateway.changesReadContent(name)) {
      // A vote changes no list or media content. Only a favorite change can make
      // an in-flight collection read stale; detail/interaction reads carry their
      // own version guards. Feeds, rankings and random food are not reset.
      if (name === 'set-card-interaction') {
        const request: InteractionRequestTrace = payload as InteractionRequestTrace;
        if (request.patch !== undefined && request.patch.favorited !== undefined) ReadScheduler.contentChanged(['get-card-detail',
          'get-card-interaction-state', 'get-card-interaction-receipt', 'get-card-interaction-counts']);
      } else if (name === 'set-card-favorite') ReadScheduler.contentChanged(['get-card-detail', 'get-card-interaction-state',
        'get-card-interaction-receipt', 'get-card-interaction-counts']);
      else ReadScheduler.contentChanged();
    }
    if (session === AuthSessionStore.generation() && name === 'set-card-favorite')
      AppStorage.setOrCreate('favoritesMutationRevision', (AppStorage.get<number>('favoritesMutationRevision') || 0) + 1);
    if (session === AuthSessionStore.generation() && name === 'submit-card-revision') {
      const result: CardRevisionResponse = decoded.data as CardRevisionResponse;
      if (result.revision.status === 'APPROVED') {
        ReadScheduler.contentChanged();
        // Also cancel in-flight image permits from the old content version.
        // Disk bytes remain available for reuse after fresh authorization.
        ImageDescriptors.revoke();
        AppStorage.setOrCreate('contentMutationRevision', (AppStorage.get<number>('contentMutationRevision') || 0) + 1);
      }
    }
    if (session === AuthSessionStore.generation() && ['delete-own-card', 'delete-account-data'].includes(name)) ImageDescriptors.revoke();
    if (ReadScheduler.allows(name) && session === AuthSessionStore.generation() &&
      AppStorage.get<boolean>('stage47AppActive') !== false) {
      const requestId: string = decoded.requestId || readRequestId;
      console.info('[ReadResponse] operation=' + name + ' requestId=' + requestId +
        ' code=OK appBuildId=' + CloudGateway.appBuildId + ' functionVersion=' + (decoded.functionVersion || 'not-returned') + ' policyHash=' + (decoded.policyHash || '') + ' protocol=' + (decoded.protocolVersion || ''));
      CloudGateway.logReadPage(name, decode<object>(raw).data, requestId);
    }
    if (imageEpoch === ImageDescriptors.epoch() && CloudGateway.hasPublicMediaManifest(name) && session === AuthSessionStore.generation() && mediaLifecycle === ReadScheduler.lifecycleRevision() && mediaData === ReadScheduler.dataRevision() &&
      AppStorage.get<boolean>('stage47AppActive') !== false && ReadScheduler.allows(name) && name !== 'get-public-media')
      ImageDescriptors.accept(decoded.data as Object);
    return decoded.data;
  }
}
