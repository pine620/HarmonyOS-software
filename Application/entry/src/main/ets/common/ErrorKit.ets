/**
 * 【文件职责】把错误对象统一转成给用户看的中文提示。
 */
export interface ErrorDetail {
  code?: number;
  message?: string;
}

// 取错误的提示文字；没有时返回通用提示。
export function errorText(error: ErrorDetail): string {
  const message = typeof error.message === 'string' && error.message.length > 0
    ? error.message : '系统未返回说明';
  return typeof error.code === 'number' ? `${message}（${error.code}）` : message;
}
