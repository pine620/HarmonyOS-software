type CloudEnvelope = {
  accessToken: string;
  payload: object;
};

type CloudResponse = {
  ok: boolean;
  code?: string;
  functionVersion?: string;
  data: object;
  message: string;
};

type RuntimeModule = {
  executeOperation(operation: string, input: CloudEnvelope, env?: NodeJS.ProcessEnv): Promise<object>;
  safeLogError(error: unknown): string;
};

type AuthOperationError = Error & { code?: string };

interface ReleaseInfo { buildId: string; policyHash: string; protocolVersion: string; }
const releaseInfo = require('./shared/release-info') as { buildInfo: ReleaseInfo };
const runtime = require('./runtime') as RuntimeModule;

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

export class ShikeAuth {
  exchangeHuaweiAccount(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('exchange-huawei-account', input);
  }

}
