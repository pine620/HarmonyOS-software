/**
 * 【文件职责】云对象 shike-auth 的入口（handler：shikeAuth.ShikeAuth），只有一个方法 exchangeHuaweiAccount：
 * 用华为账号授权码换取 AGC 会话（SIGN_IN），或把华为身份关联到当前邮箱账号（LINK_HUAWEI）。实现在同目录 runtime.js。
 * 客户端通过 Application/cloud_objects 中生成的代理调用；修改导出方法签名后需要重新 Generate Invoke Interface。
 */
// 请求信封。
type CloudEnvelope = {
  accessToken: string;
  payload: object;
};

// 响应格式。
type CloudResponse = {
  ok: boolean;
  code?: string;
  functionVersion?: string;
  data: object;
  message: string;
};

// runtime.js 导出的接口。
type RuntimeModule = {
  executeOperation(operation: string, input: CloudEnvelope, env?: NodeJS.ProcessEnv): Promise<object>;
  safeLogError(error: unknown): string;
};

// 带错误码的认证错误。
type AuthOperationError = Error & { code?: string };

// 构建信息。
interface ReleaseInfo { buildId: string; policyHash: string; protocolVersion: string; }
const releaseInfo = require('./shared/release-info') as { buildInfo: ReleaseInfo };
const runtime = require('./runtime') as RuntimeModule;

// 执行认证操作并包装响应；失败时返回错误码与可读消息（不记录 Token）。
async function executeCloudOperation(operation: string, input: CloudEnvelope): Promise<CloudResponse> {
  try {
    const data = await runtime.executeOperation(operation, input, process.env);
    return { ok: true, data, message: '', functionVersion: releaseInfo.buildInfo.buildId, ...releaseInfo.buildInfo };
  } catch (error) {
    console.error(`${operation} failed: ${runtime.safeLogError(error)}`);
    const message = error instanceof Error ? error.message : '登录服务暂时不可用。';
    const failure: AuthOperationError | undefined = error instanceof Error ? error : undefined;
    const code: string = failure && typeof failure.code === 'string' && failure.code.length > 0
      ? failure.code : 'AUTH_REQUEST_FAILED';
    return { ok: false, code, data: {}, message, functionVersion: releaseInfo.buildInfo.buildId, ...releaseInfo.buildInfo };
  }
}

// 认证云对象类。
export class ShikeAuth {
  // exchange-huawei-account：华为账号登录 / 关联。
  exchangeHuaweiAccount(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('exchange-huawei-account', input);
  }

}
