/**
 * 【文件职责】解析 shike-image 的请求事件：兼容 HTTP 触发器事件（数据在 body 中，可能是 Base64）与本地调用的普通对象，并限制请求大小。
 */
'use strict';

const MAX_REQUEST_BYTES = 65536;
// 构造请求格式错误（带原因代码）。
function invalid(reason) {
  return Object.assign(new Error('图片请求体格式无效。'), {
    code: 'VALIDATION_ERROR', validationReason: reason
  });
}
// 是否为普通对象。
function record(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
// 把字符串解析为 JSON 对象。
function jsonObject(value) {
  if (typeof value === 'string') {
    if (Buffer.byteLength(value, 'utf8') > MAX_REQUEST_BYTES) throw invalid('REQUEST_TOO_LARGE');
    try { value = JSON.parse(value); } catch (_) { throw invalid('INVALID_JSON'); }
  }
  if (!record(value)) throw invalid('OBJECT_REQUIRED');
  let text;
  try { text = JSON.stringify(value); } catch (_) { throw invalid('INVALID_JSON'); }
  if (Buffer.byteLength(text, 'utf8') > MAX_REQUEST_BYTES) throw invalid('REQUEST_TOO_LARGE');
  return value;
}

// SDK 调用以 HTTP 触发器事件的形式到达，业务数据在 body 中；本地调用时也支持直接传对象。绝不把网关字段合并进解码后的 body（尤其是 accessToken 与 readRequestId）。
// 解析事件，返回 { input, format }。
function parseImageEvent(event) {
  if (typeof event === 'string') event = jsonObject(event);
  if (!record(event)) throw invalid('OBJECT_REQUIRED');
  if (!Object.prototype.hasOwnProperty.call(event, 'body')) {
    return { input: jsonObject(event), format: 'direct' };
  }
  let body = event.body;
  let format = typeof body === 'string' ? 'body-json' : 'body-object';
  if (event.isBase64Encoded === true || event.isBase64Encoded === 'true') {
    format = 'body-base64';
    if (typeof body !== 'string' || body.length > Math.ceil(MAX_REQUEST_BYTES / 3) * 4) {
      throw invalid('INVALID_BASE64');
    }
    const bytes = Buffer.from(body, 'base64');
    if (bytes.toString('base64') !== body) throw invalid('INVALID_BASE64');
    body = bytes.toString('utf8');
  }
  return { input: jsonObject(body), format };
}

module.exports = { parseImageEvent };
