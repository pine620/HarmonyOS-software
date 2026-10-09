interface CloudErrorDetail {
  code?: number | string;
  message?: string;
}

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

export class ReadCancelledError extends Error {
  constructor() { super('读取条件或页面已变化，已取消旧请求。'); this.name = 'ReadCancelledError'; }
}

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
