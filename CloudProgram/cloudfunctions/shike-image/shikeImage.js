'use strict';
const { readBatch } = require('./shared/image-reader');
const { errorResponse, requestId } = require('./shared/read-errors');
const { buildInfo } = require('./shared/release-info');
const { parseImageEvent } = require('./image-request');

// Inject only the I/O boundary so tests exercise the deployed entry adapter.
function createHandler(read, environment, log) {
  return async (event, context, callback) => {
    const env = environment();
    let input, format = 'unparsed', id = requestId({}), response;
    try {
      if (String(env.SHIKE_IMAGE_READ_ENABLED) !== 'true') throw Object.assign(new Error('图片新协议尚未启用。'), { code: 'NOT_SUPPORTED' });
      const decoded = parseImageEvent(event);
      input = decoded.input; format = decoded.format; id = requestId(input);
      const data = await read({ ...input, readRequestId: id }, env);
      response = { ok: true, data, message: '', requestId: id, operation: 'image-read-batch', functionVersion: buildInfo.buildId, ...buildInfo };
    } catch (error) {
      response = errorResponse(error, 'image-read-batch', id);
      if (!input && response.code === 'VALIDATION_ERROR') response.stage = 'request-decoding';
      const reason = error && error.validationReason;
      const validationReason = ['REQUEST_TOO_LARGE', 'INVALID_JSON', 'OBJECT_REQUIRED', 'INVALID_BASE64'].includes(reason)
        ? reason : response.code === 'VALIDATION_ERROR' ? 'BATCH_VALIDATION' : '';
      // Only bounded shape/diagnostic fields: no body, token, URL or image data.
      log('image.entry.error ' + JSON.stringify({ requestId: id, code: response.code,
        stage: response.stage, inputFormat: format,
        validationReason,
        protocolValid: Boolean(input && input.protocolVersion === 'image-read-v1'),
        count: input && Array.isArray(input.items) ? input.items.length : 0, ...buildInfo }));
    }
    if (typeof callback === 'function') callback(response);
    return response;
  };
}

exports.createHandler = createHandler;
exports.handler = createHandler(readBatch, () => process.env, line => console.warn(line));
