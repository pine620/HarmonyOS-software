/**
 * 【文件职责】云调用错误的统一类型与转换。页面判断“能不能重试 / 要不要提示登录”都依据这里的类型。
 *   - CloudBusinessError：云端或 SDK 返回的业务错误，带 code、retryable、requestId 等字段；
 *   - ReadCancelledError：请求已过期（页面离开、换号、内容变更）被主动取消，页面一般静默忽略；
 *   - cloudReadError()：把 SDK 抛出的任意错误归一成上面两类。
 * 常见错误码：3007009 = Cloud DB 繁忙（可重试）；AUTH_REQUIRED = 需要重新登录；CONTENT_ACCESS_DENIED = 无权查看。
 */
interface CloudErrorDetail {
  code?: number | string;
  message?: string;
}

/**
 * 云端业务错误。
 * code：错误码；retryable：是否值得重试；retryAfterMs：建议等待时长；
 * requestId / operation / stage：用于和云端日志对照（stage 表示失败发生在哪个阶段，例如 authentication、cloud-call）。
 */
export class CloudBusinessError extends Error {
  code: string;
  retryable: boolean;
  retryAfterMs: number;
  requestId: string;
  operation: string;
  stage: string;
  constructor(message: string, code: string, retryable: boolean = code === '3007009',
    retryAfterMs: number = 0, requestId: string = '', operation: string = '', stage: string = '') {
    super(message);
    this.name = 'CloudBusinessError'; this.code = code; this.retryable = retryable;
    this.retryAfterMs = retryAfterMs; this.requestId = requestId; this.operation = operation; this.stage = stage;
  }
}

// 请求结果已不再需要（页面切走、换号、读条件变化），属于正常取消而非故障。
export class ReadCancelledError extends Error {
  constructor() { super('读取条件或页面已变化，已取消旧请求。'); this.name = 'ReadCancelledError'; }
}

/**
 * 把任意错误转成 CloudBusinessError / ReadCancelledError：
 * 3007009（数据库繁忙）与网络类错误标记为可重试；有明确错误码的标记为不可重试；没有错误码的普通 Error 原样返回。
 */
export function cloudReadError(error: Object, operation: string, requestId: string): Error {
  if (error === null || error === undefined) return new Error('云端请求失败。');
  if (error instanceof CloudBusinessError || error instanceof ReadCancelledError) return error;
  const detail: CloudErrorDetail = error as CloudErrorDetail;
  const message: string = error instanceof Error ? error.message : detail.message || '云端请求失败。';
  const prefix: RegExpMatchArray | null = message.match(/^(3007009):\s/);
  const code: string = detail.code === undefined ? prefix === null ? 'REQUEST_FAILED' : prefix[1] : String(detail.code);
  if (code === '3007009') return new CloudBusinessError('云数据库暂时繁忙，请稍后重试。', code, true, 2000,
    requestId, operation, 'cloud-call');
  if (['1008210001', '503', 'NETWORK_UNAVAILABLE', 'MEDIA_TIMEOUT'].includes(code)) return new CloudBusinessError(message, code, true, 0, requestId, operation, 'cloud-call');
  if (code !== 'REQUEST_FAILED') return new CloudBusinessError(message, code, false, 0, requestId, operation, 'cloud-call');
  return error instanceof Error ? error : new CloudBusinessError(message, code, false, 0, requestId, operation, 'cloud-call');
}
