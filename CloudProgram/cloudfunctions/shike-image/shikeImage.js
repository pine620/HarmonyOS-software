/**
 * 【文件职责】事件函数 shike-image 的入口（handler：shikeImage.handler，functionType=0）：客户端批量读图 image-read-batch。
 * 环境变量 SHIKE_IMAGE_READ_ENABLED 不为 'true' 时直接返回 NOT_SUPPORTED（客户端显示可重试占位）；
 * 请求解析在 image-request.js，读取与权限校验在 shared/image-reader.js。HTTP 触发器保留平台鉴权，不开放匿名访问。
 */
'use strict';
const { readBatch } = require('./shared/image-reader');
const { errorResponse, requestId } = require('./shared/read-errors');
const { buildInfo } = require('./shared/release-info');
const { parseImageEvent } = require('./image-request');

// 只注入 I/O 边界（读取函数、环境变量、日志），让测试能直接覆盖实际部署的入口适配代码。
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
      // 日志只包含有限的结构 / 诊断字段：不含请求体、Token、URL 或图片数据。
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

// 导出 createHandler 供契约测试注入假的读取函数；handler 是平台实际调用的入口。
exports.createHandler = createHandler;
exports.handler = createHandler(readBatch, () => process.env, line => console.warn(line));
