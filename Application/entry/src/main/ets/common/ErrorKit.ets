export interface ErrorDetail {
  code?: number;
  message?: string;
}

export function errorText(error: ErrorDetail): string {
  const message = typeof error.message === 'string' && error.message.length > 0
    ? error.message : '系统未返回说明';
  return typeof error.code === 'number' ? `${message}（${error.code}）` : message;
}
