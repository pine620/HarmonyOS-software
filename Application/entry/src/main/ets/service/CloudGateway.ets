/**
 * 【文件职责】客户端访问云端的唯一出口（网关）。页面和 Repository 不直接调用云函数，而是调用这里的
 * callPublic / callAuthenticated。
 * 【主要流程】callPublic / callAuthenticated → dispatch（性能打点）→ dispatchRead（读请求交给 ReadScheduler
 * 排队、去重）→ execute（取 Token、组“信封”、选择目标云函数、解析响应、写入后刷新缓存）。
 * 【目标云函数】
 *   - image-read-batch            → 事件函数 shike-image（批量读图）
 *   - exchange-huawei-account     → 云对象 shike-auth（经 cloud_objects 代理）
 *   - prepare/upload/confirm-card-photo、已登录的 get-public-media → 云对象 shike-media（经 cloud_objects 代理）
 *   - 其余业务操作                → 查 CloudRoutes 路由表，调用 shike-content / -social / -account / -governance
 * 【新人注意】
 *   1. 新增业务操作不需要改这里，只要在 CloudRoutes.ets 和云端四处方法表里登记即可（见报告第 5 节）。
 *   2. 写操作成功后，本文件会调用 ReadScheduler.contentChanged() 让旧的读结果失效，页面无需自己清缓存。
 *   3. 领域函数不可用时会自动回落到 shike-service：读操作立即重试，写操作只在“确定没执行过”时才重试。
 */
import { bundleManager } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { ImageDescriptors } from './ImageDescriptors';
import { ImageReadItem, ImageReadRequest } from '../model/ImageModels';
import { CardDetailRequest, CardRevisionResponse } from '../model/CloudContracts';
import { cloudCommon, cloudFunction } from '@kit.CloudFoundationKit';
import { importObject, ShikeAuth, ShikeMedia } from '@shike/cloud-objects';
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

// shike-media 负责的媒体操作：这几个操作不查路由表，直接交给 shike-media 云对象。
type MediaOperation = 'prepare-card-photo' | 'upload-card-photo' | 'confirm-card-photo-upload' | 'get-public-media';
// 记录媒体错误时区分“调用本身抛错”还是“云函数返回了失败响应”。
type MediaErrorSource = 'cloud-call' | 'business-response';
// 日志里标注出错的云对象名：游客读公开图走 shike-service 系，其余媒体操作走 shike-media。
type MediaCloudObjectName = 'shike-media' | 'shike-service';
// 云对象调用协议，与 DevEco 生成的 importObject 代理完全一致：{ method: 方法名, params: [信封] }。
interface ServiceInvocation {
  method: string;
  params: Array<CloudEnvelope>;
}

/**
 * 发给云函数的“信封”。
 * accessToken：AGC 用户 Token（游客为空串），云端据此算出用户身份；
 * readRequestId：逻辑请求号，用于云端日志串联与写操作幂等；readAttempt：第几次尝试（1 或 2）。
 */
interface ReadCloudEnvelope extends CloudEnvelope {
  readRequestId: string;
  readAttempt: number;
}
// 互动写请求中与日志、缓存失效相关的字段，这里只读取不修改。
interface InteractionPatchTrace { reaction?: string; favorited?: boolean; }
interface InteractionRequestTrace { requestId: string; patch?: InteractionPatchTrace; }

// shike-image 事件函数的请求体：批量读图协议字段 + 凭据与请求号。
interface ImageFunctionEnvelope extends ImageReadRequest {
  accessToken: string;
  readRequestId: string;
  readAttempt: number;
}

// SDK 抛出的云函数错误对象中可能包含的字段。
interface CloudHandlerErrorDetail {
  code?: number | string;
  message?: string;
}

// shike-media 模块加载失败后的熔断时长：30 秒内不再请求，直接提示“实拍图服务暂时不可用”。
const MEDIA_CIRCUIT_BREAK_MS: number = 30 * 1000;
const MEDIA_UNAVAILABLE_MESSAGE: string = '实拍图服务暂时不可用，请稍后重试。';

// 实拍图服务（shike-media）暂不可用时抛出的错误类型，页面捕获后显示“稍后重试”。
export class MediaServiceUnavailableError extends Error {
  constructor() {
    super(MEDIA_UNAVAILABLE_MESSAGE);
    this.name = 'MediaServiceUnavailableError';
  }
}

/**
 * 云函数统一响应格式。
 * ok=true 时 data 为业务数据；ok=false 时看 code / message，retryable 表示是否值得重试，
 * retryAfterMs 是服务端建议的等待时间；functionVersion / buildId / policyHash 用于核对线上部署版本。
 */
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

// 与 ApiResponse 相同，只是 data 尚未按具体类型解析。
type CloudObjectResponse = ApiResponse<object>;

// 以下几个结构只用于在日志中统计“返回了多少条、还有没有下一页”，不参与业务逻辑。
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

// 云函数返回值可能是 JSON 字符串，也可能已经是对象，这里统一转成对象。
function decode<T>(raw: string | object): ApiResponse<T> {
  if (typeof raw === 'string') {
    return JSON.parse(raw) as ApiResponse<T>;
  }
  return raw as ApiResponse<T>;
}

/**
 * 云调用网关（静态类，全局唯一）。所有云对象调用都把 AGC Token 放在信封里，由云端自行校验身份。
 */
export class CloudGateway {
  // 本机 App 的包名:版本名:版本号，写进读日志，方便和云端日志对照。
  private static appBuildId: string = 'unavailable';
  // 是否已执行过 cloudCommon.init（懒初始化，只做一次）。
  private static initialized: boolean = false;
  // shike-auth / shike-media 的调用代理（由 cloud_objects 生成），初始化时创建。
  private static authObject: ShikeAuth | undefined = undefined;
  private static mediaObject: ShikeMedia | undefined = undefined;
  // 媒体熔断截止时间（毫秒时间戳），0 表示未熔断。
  private static mediaCircuitOpenUntilMs: number = 0;

  // 媒体服务是否处于熔断期（发布页、图片仓库据此提示用户）。
  static isMediaServiceUnavailable(): boolean {
    return Date.now() < CloudGateway.mediaCircuitOpenUntilMs;
  }

  // 判断操作名是否属于媒体操作；返回 undefined 表示普通业务操作。
  private static mediaOperationFor(name: string): MediaOperation | undefined {
    switch (name) {
      case 'prepare-card-photo': return 'prepare-card-photo';
      case 'upload-card-photo': return 'upload-card-photo';
      case 'confirm-card-photo-upload': return 'confirm-card-photo-upload';
      case 'get-public-media': return 'get-public-media';
      default: return undefined;
    }
  }

  // 从 SDK 错误对象中安全地取出 message（对象形态不确定，不能直接 .message）。
  private static cloudHandlerMessage(error: Object): string {
    if (error instanceof Error) return error.message;
    if (error === null || error === undefined) return '';
    const detail: CloudHandlerErrorDetail = error as CloudHandlerErrorDetail;
    return typeof detail.message === 'string' ? detail.message : '';
  }

  // 从 SDK 错误对象中取出错误码，取不到时记为 not-provided。
  private static cloudHandlerCode(error: Object): string {
    if (error === null || error === undefined) return 'not-provided';
    const detail: CloudHandlerErrorDetail = error as CloudHandlerErrorDetail;
    return detail.code === undefined ? 'not-provided' : String(detail.code);
  }

  /**
   * 记录 shike-media 的“Call handler error”诊断日志。
   * 只提取缺失的模块名并归类原因（模块缺失、包配置错误、函数不存在……），
   * 绝不记录请求体或原始错误内容，避免泄露 Token 和图片数据。
   */
  private static logMediaHandlerError(operation: MediaOperation, source: MediaErrorSource,
    cloudObjectName: MediaCloudObjectName, message: string, code: string): void {
    // 只提取缺失的模块名；绝不记录请求内容或原始错误正文。
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

  // 打开媒体熔断：之后 30 秒内的媒体请求直接失败，并只在第一次打开时打印一条错误日志。
  private static openMediaCircuit(operation: MediaOperation): MediaServiceUnavailableError {
    const wasOpen: boolean = CloudGateway.isMediaServiceUnavailable();
    CloudGateway.mediaCircuitOpenUntilMs = Date.now() + MEDIA_CIRCUIT_BREAK_MS;
    if (!wasOpen) console.error('[MediaService] handler initialization failed; operation=' + operation + '.');
    return new MediaServiceUnavailableError();
  }

  /**
   * 调用 shike-media 云对象。
   * 成功返回原始响应；部署损坏（模块加载失败）时打开熔断；其他 handler 错误统一转成用户可读的提示。
   * 错误码 3007009（Cloud DB 繁忙）原样抛出，交给上层的重试逻辑处理。
   */
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
      if (CloudGateway.isModuleLoadError(message)) {
        throw CloudGateway.openMediaCircuit(operation);
      }
      if (message.includes('Call handler error')) {
        console.error('[MediaService] handler error; operation=' + operation + '.');
        throw new Error('实拍图服务处理请求失败，请稍后重试。');
      }
      throw cloudReadError(error as Object, operation, '');
    }
  }

  // 领域函数在传输层失败后，会在一段时间内跳过它（改走 shike-service）。值为恢复尝试的时间戳。
  private static unavailableDomains: Map<string, number> = new Map<string, number>();
  private static readonly DOMAIN_RETRY_MS: number = 10 * 60 * 1000;

  // 决定本次调用哪个云函数：总开关关闭或该领域函数仍在“不可用”冷却期时，改用 shike-service。
  private static functionFor(route: CloudRoute): string {
    if (!CLOUD_SERVICE_SPLIT_ENABLED) return LEGACY_SERVICE_FUNCTION;
    const until: number | undefined = CloudGateway.unavailableDomains.get(route.domainFunction);
    if (until !== undefined && Date.now() < until) return LEGACY_SERVICE_FUNCTION;
    return route.domainFunction;
  }

  // 按路由调用一个云函数，并带上该操作单独配置的超时时间（0 表示使用全局 70 秒）。
  private static async callRoute(functionName: string, route: CloudRoute, envelope: CloudEnvelope): Promise<CloudObjectResponse> {
    // 与生成的 importObject 代理使用同一种协议：{ method, params: [信封] }。
    const invocation: ServiceInvocation = { method: route.method, params: [envelope] };
    let parameters: cloudFunction.FunctionParams = { name: functionName, version: CLOUD_FUNCTION_VERSION, data: invocation };
    if (route.timeoutMs > 0) {
      parameters = { name: functionName, version: CLOUD_FUNCTION_VERSION, data: invocation, timeout: route.timeoutMs };
    }
    const response: cloudFunction.FunctionResult = await cloudFunction.call(parameters);
    return decode<object>(response.result as string | object);
  }

  /**
   * 路由调用（带故障回落）：所有 shike-service 系操作都按路由表调用领域函数。
   * 领域函数调用失败时标记为不可用；读操作立即在 shike-service 上重试一次，写操作不重试（结果未知，避免重复写入）。
   */
  private static async invokeRoute(route: CloudRoute, envelope: CloudEnvelope): Promise<CloudObjectResponse> {
    const functionName: string = CloudGateway.functionFor(route);
    let response: CloudObjectResponse;
    try {
      response = await CloudGateway.callRoute(functionName, route, envelope);
    } catch (error) {
      if (functionName === LEGACY_SERVICE_FUNCTION) throw error as Error;
      const message: string = CloudGateway.cloudHandlerMessage(error as Object);
      CloudGateway.markDomainUnavailable(route, message);
      // 只有“模块加载失败”能证明业务代码完全没执行；其他失败可能发生在部分写入之后，所以写操作不在 shike-service 上重放（例如 send-message 没有幂等键）。
      if (!isReadOnlyOperation(route.operation) && !CloudGateway.isModuleLoadError(message)) throw error as Error;
      return await CloudGateway.callRoute(LEGACY_SERVICE_FUNCTION, route, envelope);
    }
    // 平台有时把部署损坏（例如 "Cannot find module './service/runtime'"）作为普通失败响应返回而不是抛异常，这里按“领域函数不可用”同样处理。
    if (functionName !== LEGACY_SERVICE_FUNCTION && response.ok !== true &&
      CloudGateway.isHandlerLoadError(response.message || '')) {
      const message: string = response.message || '';
      CloudGateway.markDomainUnavailable(route, message);
      if (!isReadOnlyOperation(route.operation) && !CloudGateway.isModuleLoadError(message)) return response;
      return await CloudGateway.callRoute(LEGACY_SERVICE_FUNCTION, route, envelope);
    }
    return response;
  }

  // 任意一种“部署损坏”的报错形态：标记领域函数不可用，并允许读操作重试。
  private static isHandlerLoadError(message: string): boolean {
    return CloudGateway.isModuleLoadError(message) || (message.includes('Call handler error') &&
      (message.includes('is not a function') || message.includes('SyntaxError')));
  }

  // handler 模块本身加载失败，说明业务代码没有执行，所以写操作重试也安全。
  private static isModuleLoadError(message: string): boolean {
    return message.includes('Call handler error') &&
      (message.includes('Cannot find module') || message.includes('Cannot find package') ||
        message.includes('Invalid package config') || message.includes('ERR_INVALID_PACKAGE_CONFIG'));
  }

  // 把领域函数标记为 10 分钟内不可用，并打印一条 domain-unavailable 日志，便于排查部署问题。
  private static markDomainUnavailable(route: CloudRoute, message: string): void {
    CloudGateway.unavailableDomains.set(route.domainFunction, Date.now() + CloudGateway.DOMAIN_RETRY_MS);
    console.warn('[CloudRoute] event=domain-unavailable function=' + route.domainFunction + ' operation=' + route.operation +
      ' loadError=' + CloudGateway.isHandlerLoadError(message));
  }

  /**
   * 昵称密码相关操作（查询/设置/修改密码、登录、退出）的调用包装。
   * 与普通路由调用相同，只是额外打印发送/响应耗时日志；日志中不包含昵称或密码。
   */
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

  /**
   * 懒初始化 Cloud Foundation Kit：设置区域（中国）、默认 70 秒超时和 authProvider，
   * 并创建 shike-auth / shike-media 调用代理，最后注册游客首页快照的周期预取。
   */
  private static initialize(): void {
    if (CloudGateway.initialized) return;
    try { const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT); CloudGateway.appBuildId = info.name + ':' + info.versionName + ':' + info.versionCode; } catch (_error) { }
    cloudCommon.init({
      region: cloudCommon.CloudRegion.CHINA,
      functionOptions: { timeout: 70000 },
      /**
       * Cloud Foundation 要求先提供 authProvider，才能构造可调用的云对象。云对象的 HTTP 触发器用平台应用签名鉴权；
       * 业务 Token 放在信封里由云函数自己校验。注意不要把服务端签发的华为迁移 Token 放进这个框架级凭据。
       * 这里只给“邮箱原生会话”提供 AGC Token，好让 Cloud Storage 安全规则识别直传图片的上传者；
       * 华为账号 / 昵称登录的会话返回空串，继续使用函数上传。
       */
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
    CloudGateway.mediaObject = importObject(ShikeMedia, CLOUD_FUNCTION_VERSION);
    CloudGateway.initialized = true;
    registerHomeSnapshotPrefetch();
  }

  // 直接读 Cloud Storage（例如首页快照、公开封面）之前，先确保 SDK 已初始化。
  static ensureReady(): void {
    CloudGateway.initialize();
  }

  // 当前是否有登录会话（已加载资料，或内存里仍有可用的 Token）。
  static hasSession(): boolean {
    return AuthSessionStore.owner().length > 0 || AuthSessionStore.hasCachedSession();
  }

  /**
   * 调用“游客也能用”的操作。
   * 已登录时，读操作会自动带上 Token（例如详情页需要返回“我是否点过赞”）；公开图片读取永远匿名。
   */
  static async callPublic<T>(name: string, payload: object, options: ReadRequestOptions = {}): Promise<T> {
    // 登录身份只用于个人相关的字段，内容本身是公开可读的。
    const publicImage: boolean = name === 'get-public-media' || name === 'image-read-batch' &&
      (payload as ImageReadRequest).items.every((item: ImageReadItem): boolean => item.mode === 'PUBLIC');
    return CloudGateway.dispatch<T>(name, payload, !publicImage && ReadScheduler.allows(name) && CloudGateway.hasSession(), options);
  }

  // 调用必须登录的操作：拿不到 Token 时直接抛出 AUTH_REQUIRED。
  static async callAuthenticated<T>(name: string, payload: object, options: ReadRequestOptions = {}): Promise<T> {
    return CloudGateway.dispatch<T>(name, payload, true, options);
  }

  // 统一入口：对需要性能打点的操作包一层 FeaturePerformanceTrace，然后进入 dispatchRead。
  private static async dispatch<T>(name: string, payload: object, authenticated: boolean,
    options: ReadRequestOptions): Promise<T> {
    const trace: FeatureTraceName | undefined = FeaturePerformanceTrace.traceNameForOperation(name, payload);
    if (trace !== undefined) return FeaturePerformanceTrace.measure<T>(trace, (): Promise<T> => CloudGateway.dispatchRead<T>(name, payload, authenticated, options));
    return CloudGateway.dispatchRead<T>(name, payload, authenticated, options);
  }

  /**
   * 按操作类型选择调度方式：
   *   - set-card-interaction：写操作，直接执行，并沿用调用方给的 requestId 保证幂等；
   *   - 互动状态/回执/计数读取：控制器已经按卡片合并请求，不进入 ReadScheduler，避免被其他读请求挤占槽位；
   *   - 其他 get-/list-/search- 读操作：交给 ReadScheduler 排队、合并、限流与重试；
   *   - 其余写操作：直接执行。
   */
  private static async dispatchRead<T>(name: string, payload: object, authenticated: boolean, options: ReadRequestOptions): Promise<T> {
    if (name === 'set-card-interaction') {
      const request: InteractionRequestTrace = payload as InteractionRequestTrace;
      return CloudGateway.execute<T>(name, payload, authenticated, request.requestId);
    }
    if (['get-card-interaction-state', 'get-card-interaction-receipt', 'get-card-interaction-counts'].includes(name)) {
      // 这几个读请求已在 CardInteractionController 中按卡片合并，不能让排队中的详情 / 图片 / 统计请求占用它们的执行槽位。
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

  // 这些操作的响应里带有图片描述符清单，成功后需要登记到 ImageDescriptors，图片才能被显示。
  private static hasPublicMediaManifest(name: string): boolean {
    return ['get-card-detail', 'get-card-previews', 'list-personal-collection',
      'get-random-food-cards', 'list-food-choices', 'get-meal-candidates', 'get-user-page', 'get-friend-profile', 'list-food-rankings', 'search-public-cards',
      'get-merchant-recommendations', 'list-nearby-cards', 'list-my-cards'].includes(name);
  }

  // 会改变“读到的内容”的写操作：成功后要让相关读缓存失效。
  private static changesReadContent(name: string): boolean {
    switch (name) {
      case 'set-card-interaction':
      case 'set-card-favorite': case 'set-card-reaction-v2':
      case 'start-personal-collection-migration': case 'resume-personal-collection-migration':
      case 'delete-own-card': case 'delete-account-data': case 'publish-card':
      case 'restore-deleted-card':
        return true;
      default: return false;
    }
  }

  // 读成功后打印一行分页摘要日志（条数、是否还有下一页、扫描数量），不记录任何私人内容。
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
    // 条数和逻辑请求号足以把一页数据与云端日志对应起来；绝不记录用户的私人选择。
    console.info('[ReadPage] operation=' + name + ' requestId=' + requestId + ' returnedCount=' + returnedCount +
      ' hasMore=' + String((summary.nextCursor || summary.nextPageToken || '').length > 0) +
      ' coverage=' + (summary.coverage || '') + ' scanned=' + (summary.scannedCandidateCount || 0) +
      ' consumed=' + (summary.consumedCandidateCount || 0) + ' fetched=' + (summary.fetchedCandidateCount || 0));
  }

  /**
   * 真正执行一次云调用（所有路径最终都会到这里）。
   * 步骤：① 准备请求号与会话代次快照 → ② 取 Token → ③ 组信封 → ④ 按操作选择云函数并调用
   * → ⑤ 失败时转换为 CloudBusinessError → ⑥ 成功后按操作类型刷新读缓存、撤销旧图片授权、登记新图片清单。
   * “会话代次”快照用于判断：调用期间用户若已退出或换号，就丢弃结果，不让旧账号的数据进入新界面。
   */
  private static async execute<T>(name: string, payload: object, authenticated: boolean,
    readRequestId: string = '', readAttempt: number = 1): Promise<T> {
    if (['get-password-account', 'configure-password-account', 'change-password-account', 'login-with-nickname', 'logout-nickname'].includes(name) &&
      readRequestId.length === 0) readRequestId = util.generateRandomUUID();
    // 能走到这里的调用都发生在启动时的隐私同意之后。
    const interactionStarted: number = Date.now();
    if (name === 'set-card-interaction') console.info('[CardInteraction] requestId=' + readRequestId + ' stage=gateway_start');
    // ① 记录调用开始时的会话代次与缓存版本，后面用来判断结果是否已过期。
    const mediaOperation: MediaOperation | undefined = CloudGateway.mediaOperationFor(name);
    CloudGateway.initialize();
    const session: number = AuthSessionStore.generation();
    const mediaLifecycle: number = ReadScheduler.lifecycleRevision();
    const mediaData: number = ReadScheduler.dataRevision();
    const imageEpoch: number = ImageDescriptors.epoch();
    // ② 需要登录的操作先取 Token；取不到属于不可重试的认证错误。
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
    // ③ 组装信封。
    const envelope: ReadCloudEnvelope = { accessToken, payload, readRequestId, readAttempt };
    let raw: CloudObjectResponse | undefined = undefined;
    // ④ 按操作名选择目标云函数。
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
    // ⑤ 云端返回失败：媒体部署损坏则熔断，其余转为 CloudBusinessError 抛给调用方。
    if (!decoded.ok) {
      const message: string = decoded.message || '云端请求失败，请稍后重试。';
      if (mediaOperation !== undefined && message.includes('Call handler error')) {
        const cloudObjectName: MediaCloudObjectName = name === 'get-public-media' && !authenticated
          ? 'shike-service' : 'shike-media';
        CloudGateway.logMediaHandlerError(mediaOperation, 'business-response', cloudObjectName, message,
          decoded.code === undefined ? 'not-returned' : decoded.code);
      }
      if (mediaOperation !== undefined && CloudGateway.isModuleLoadError(message)) {
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
    // ⑥ 写操作成功：按操作类型让读缓存失效（会话未变化时才处理）。
    if (session === AuthSessionStore.generation() && CloudGateway.changesReadContent(name)) {
      // 投票不改变任何列表或图片内容；只有收藏变化可能让正在进行的收藏列表读取过期，详情/互动读取自带版本校验。推荐流、榜单和今日吃什么不需要重置。
      if (name === 'set-card-interaction') {
        const request: InteractionRequestTrace = payload as InteractionRequestTrace;
        if (request.patch !== undefined && request.patch.favorited !== undefined) ReadScheduler.contentChanged(['get-card-detail',
          'get-card-interaction-state', 'get-card-interaction-receipt', 'get-card-interaction-counts']);
      } else if (name === 'set-card-favorite') ReadScheduler.contentChanged(['get-card-detail', 'get-card-interaction-state',
        'get-card-interaction-receipt', 'get-card-interaction-counts']);
      else ReadScheduler.contentChanged();
    }
    // 收藏变化时通知“我的收藏”等页面刷新。
    if (session === AuthSessionStore.generation() && name === 'set-card-favorite')
      AppStorage.setOrCreate('favoritesMutationRevision', (AppStorage.get<number>('favoritesMutationRevision') || 0) + 1);
    // 作者修改直接生效（APPROVED）后，内容版本变了：清读缓存、撤销旧图片授权、通知页面刷新。
    if (session === AuthSessionStore.generation() && name === 'submit-card-revision') {
      const result: CardRevisionResponse = decoded.data as CardRevisionResponse;
      if (result.revision.status === 'APPROVED') {
        ReadScheduler.contentChanged();
        // 同时作废旧内容版本的图片授权；磁盘上的图片字节仍可在重新授权后复用。
        ImageDescriptors.revoke();
        AppStorage.setOrCreate('contentMutationRevision', (AppStorage.get<number>('contentMutationRevision') || 0) + 1);
      }
    }
    // 删卡或注销后，撤销本会话内所有图片显示授权。
    if (session === AuthSessionStore.generation() && ['delete-own-card', 'delete-account-data'].includes(name)) ImageDescriptors.revoke();
    // 读成功：打印带构建信息的响应日志，方便与云端日志按 requestId 对照。
    if (ReadScheduler.allows(name) && session === AuthSessionStore.generation() &&
      AppStorage.get<boolean>('stage47AppActive') !== false) {
      const requestId: string = decoded.requestId || readRequestId;
      console.info('[ReadResponse] operation=' + name + ' requestId=' + requestId +
        ' code=OK appBuildId=' + CloudGateway.appBuildId + ' functionVersion=' + (decoded.functionVersion || 'not-returned') + ' policyHash=' + (decoded.policyHash || '') + ' protocol=' + (decoded.protocolVersion || ''));
      CloudGateway.logReadPage(name, decode<object>(raw).data, requestId);
    }
    // 读成功且数据仍是最新的：登记响应中的图片描述符，之后这些图片才允许从缓存或云端显示。
    if (imageEpoch === ImageDescriptors.epoch() && CloudGateway.hasPublicMediaManifest(name) && session === AuthSessionStore.generation() && mediaLifecycle === ReadScheduler.lifecycleRevision() && mediaData === ReadScheduler.dataRevision() &&
      AppStorage.get<boolean>('stage47AppActive') !== false && ReadScheduler.allows(name) && name !== 'get-public-media')
      ImageDescriptors.accept(decoded.data as Object);
    return decoded.data;
  }
}
