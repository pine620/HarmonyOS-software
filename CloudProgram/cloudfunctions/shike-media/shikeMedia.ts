/**
 * 【文件职责】云对象 shike-media 的入口（handler：shikeMedia.ShikeMedia）：所有 Cloud Storage 读写都集中在这里。
 * 客户端方法：prepareCardPhoto（准备上传）、uploadCardPhoto（Base64 上传）、confirmCardPhotoUpload（直传确认）、getPublicMedia（读公开图片）；
 * 内部方法 execute：只接受 shike-service 用 SHIKE_MEDIA_INTERNAL_KEY 做 HMAC 签名的请求（写公开图片、暂存区提升、删除）。
 * 实现在同目录 runtime.js；客户端通过 Application/cloud_objects 中生成的代理调用。
 */
// 响应格式。
type CloudResponse = {
  ok: boolean;
  data: object;
  message: string;
  code?: string;
  retryable?: boolean;
  retryAfterMs?: number;
  requestId?: string;
  operation?: string;
  stage?: string;
  functionVersion?: string;
};

// runtime.js 导出的接口。
type RuntimeModule = {
  execute(input: object, env?: NodeJS.ProcessEnv): Promise<object>;
  prepareCardPhoto(input: object, env?: NodeJS.ProcessEnv): Promise<object>;
  uploadCardPhoto(input: object, env?: NodeJS.ProcessEnv): Promise<object>;
  confirmCardPhotoUpload(input: object, env?: NodeJS.ProcessEnv): Promise<object>;
  getPublicMedia(input: object, env?: NodeJS.ProcessEnv): Promise<object>;
  safeLogError(error: unknown): string;
};

// 可调用的媒体操作名。
type MediaOperation = 'execute' | 'prepareCardPhoto' | 'uploadCardPhoto' | 'confirmCardPhotoUpload' | 'getPublicMedia';

const runtime = require('./runtime') as RuntimeModule;
// shared/read-errors.js 导出的接口。
interface ReadErrorsModule {
  READ_OPT_VERSION: string;
  requestId(input: object): string;
  errorResponse(error: unknown, operation: string, requestId: string): CloudResponse;
}
const readErrors = require('./shared/read-errors') as ReadErrorsModule;
// 构建信息。
interface ReleaseInfo { buildId: string; policyHash: string; protocolVersion: string; }
const releaseInfo = require('./shared/release-info') as { buildInfo: ReleaseInfo };

/**
 * 云对象调用导出方法时不会保留类实例作为 this，所以把分发逻辑放在模块作用域：无论运行时传入实例还是把方法当普通函数调用都能正常工作。
 */
async function executeMediaOperation(operation: MediaOperation, input: object): Promise<CloudResponse> {
  const requestId: string = readErrors.requestId(input);
  const operationName: string = operation === 'getPublicMedia' ? 'get-public-media' : operation;
  try {
    const request = Object.assign({}, input, { readRequestId: requestId });
    const data = await runtime[operation](request, process.env);
    return { ok: true, data, message: '', requestId, operation: operationName, functionVersion: readErrors.READ_OPT_VERSION, ...releaseInfo.buildInfo };
  } catch (error) {
    const response: CloudResponse = readErrors.errorResponse(error, operationName, requestId);
    console.error(`${operationName} requestId=${requestId} code=${response.code} stage=${response.stage} failed: ${runtime.safeLogError(error)}`);
    return response;
  }
}

/**
 * 媒体云对象类。上传类方法会校验 AGC Token；公开图片能否读取取决于内容状态；execute 只用于服务间的签名存储操作。
 */
export class ShikeMedia {
  // prepare-card-photo：校验 Token 与图片参数，写入 PENDING_UPLOAD 记录，返回目标路径。
  async prepareCardPhoto(input: object): Promise<CloudResponse> {
    return executeMediaOperation('prepareCardPhoto', input);
  }

  // upload-card-photo：Base64 上传并写入公开路径。
  async uploadCardPhoto(input: object): Promise<CloudResponse> {
    return executeMediaOperation('uploadCardPhoto', input);
  }

  // confirm-card-photo-upload：确认客户端直传到暂存区的图片并转为公开图片。
  async confirmCardPhotoUpload(input: object): Promise<CloudResponse> {
    return executeMediaOperation('confirmCardPhotoUpload', input);
  }

  // get-public-media：读取公开图片（登录用户）。
  async getPublicMedia(input: object): Promise<CloudResponse> {
    return executeMediaOperation('getPublicMedia', input);
  }

  // 仅供内部调用：shike-service 传入带 HMAC 签名的信封。
  async execute(input: object): Promise<CloudResponse> {
    return executeMediaOperation('execute', input);
  }
}
