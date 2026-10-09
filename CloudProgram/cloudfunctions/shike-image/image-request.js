'use strict';

const MAX_REQUEST_BYTES = 65536;
function invalid(reason) {
  return Object.assign(new Error('图片请求体格式无效。'), {
    code: 'VALIDATION_ERROR', validationReason: reason
  });
}
function record(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
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

// SDK calls arrive as HTTP-trigger events with the application data in body.
// Direct objects remain supported for local invocation. Never merge gateway
// fields into the decoded body (especially accessToken and readRequestId).
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
