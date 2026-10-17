'use strict';

/**
 * 【文件职责】shike-service 与四个领域云对象（content / social / account / governance）共用的“执行一个业务操作并包装响应”。
 * 生成请求号 → 调用 runtime.executeOperation → 成功返回 { ok:true, data, 构建信息 }，失败转换为统一错误响应。
 * 所有需要登录的方法都在 runtime.js 中校验 AGC Token 并在服务端推导 uid。
 * 昵称登录相关操作失败时，只把白名单内的错误码原样返回给客户端，其他错误统一提示“认证服务暂时不可用”，避免泄露上游细节。
 * 互动操作额外打印接收 / 响应耗时日志。
 */
const NICKNAME_AUTH_OPERATIONS = ['login-with-nickname', 'configure-password-account', 'change-password-account', 'logout-nickname'];
const NICKNAME_AUTH_SAFE_CODES = ['INVALID_CREDENTIALS', 'INVALID_NICKNAME', 'INVALID_PASSWORD',
  'NICKNAME_TAKEN', 'AUTH_RATE_LIMITED', 'REAUTH_REQUIRED', 'FEATURE_NOT_READY',
  'AUTH_CONFIGURATION_REQUIRED', 'AUTH_UPSTREAM_FAILED', 'AUTH_UPSTREAM_HTTP', 'AUTH_UPSTREAM_RESPONSE',
  'AUTH_UPSTREAM_TIMEOUT', 'AUTH_UPSTREAM_NETWORK', 'AUTH_AGC_CLIENT_REJECTED', 'AUTH_AGC_SIGN_IN_REJECTED',
  'AUTH_AGC_TOKEN_INVALID', 'ACCOUNT_INACTIVE', 'AUTH_REQUIRED', 'CONFLICT', 'ACCOUNT_MISMATCH',
  'CURRENT_PASSWORD_INCORRECT', 'PASSWORD_UNCHANGED', 'PASSWORD_NOT_SET', 'PASSWORD_STATE_CHANGED'];

// 为某个 runtime 创建 executeCloudOperation(operation, input)。
function createOperationExecutor(runtime, readErrors, releaseInfo) {
  return async function executeCloudOperation(operation, input) {
    const requestId = readErrors.requestId(input);
    const interaction = operation.includes('card-interaction');
    const startedAt = Date.now();
    if (interaction) console.info(`[CardInteractionCloud] requestId=${requestId} operation=${operation} stage=received`);
    try {
      const request = Object.assign({}, input, { readRequestId: requestId });
      const data = await runtime.executeOperation(operation, request, process.env);
      if (interaction) console.info(`[CardInteractionCloud] requestId=${requestId} operation=${operation} stage=response elapsedMs=${Date.now() - startedAt}`);
      return { ok: true, data, message: '', requestId, operation, functionVersion: readErrors.READ_OPT_VERSION, ...releaseInfo.buildInfo };
    } catch (error) {
      const response = readErrors.errorResponse(error, operation, requestId);
      if (NICKNAME_AUTH_OPERATIONS.includes(operation)) {
        console.error(`${operation} requestId=${requestId} code=${response.code || 'AUTH_FAILED'}`);
        if (!NICKNAME_AUTH_SAFE_CODES.includes(response.code || '')) response.message = '认证服务暂时不可用，请稍后重试。';
        return response;
      }
      console.error(`${operation} requestId=${requestId} code=${response.code} stage=${response.stage} failed: ${runtime.safeLogError(error)}`);
      return response;
    }
  };
}

module.exports = { createOperationExecutor };
