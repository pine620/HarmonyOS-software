// Pack 4.4 (2026-10-15): shike-account serves the account operations of the original shike-service. It runs the same
// runtime (copied into ./service by `npm run prepare:deveco`), so behaviour, auth checks and Cloud DB access are
// identical; only scaling, memory and failure isolation are separate. Generated from shike-service/shikeService.ts.
type CloudEnvelope = {
  accessToken: string;
  payload: object;
  readRequestId?: string;
  readAttempt?: number;
};

type CloudResponse = {
  ok: boolean;
  data: object;
  message: string;
  code?: string;
  retryable?: boolean;
  retryAfterMs?: number;
  requestId?: string;
  operation?: string;
  stage?: string;
  functionVersion?: string;
};

type RuntimeModule = {
  executeOperation(operation: string, input: CloudEnvelope, env?: NodeJS.ProcessEnv): Promise<object>;
  safeLogError(error: unknown): string;
};

const runtime = require('./service/runtime') as RuntimeModule;
interface ReadErrorsModule {
  READ_OPT_VERSION: string;
  requestId(input: object): string;
  errorResponse(error: unknown, operation: string, requestId: string): CloudResponse;
}
const readErrors = require('./shared/read-errors') as ReadErrorsModule;
interface ReleaseInfo { buildId: string; policyHash: string; protocolVersion: string; }
const releaseInfo = require('./shared/release-info') as { buildInfo: ReleaseInfo };

/**
 * Client-facing cloud object. Every authenticated method still verifies the
 * AGC access token in runtime.js and derives uid server-side.
 */
async function executeCloudOperation(
  operation: string,
  input: CloudEnvelope
): Promise<CloudResponse> {
  const requestId: string = readErrors.requestId(input);
  const interaction: boolean = operation.includes('card-interaction');
  const startedAt: number = Date.now();
  if (interaction) console.info(`[CardInteractionCloud] requestId=${requestId} operation=${operation} stage=received`);
  try {
    const request = Object.assign({}, input, { readRequestId: requestId });
    const data = await runtime.executeOperation(operation, request, process.env);
    if (interaction) console.info(`[CardInteractionCloud] requestId=${requestId} operation=${operation} stage=response elapsedMs=${Date.now() - startedAt}`);
    return { ok: true, data, message: '', requestId, operation, functionVersion: readErrors.READ_OPT_VERSION, ...releaseInfo.buildInfo };
  } catch (error) {
    const response: CloudResponse = readErrors.errorResponse(error, operation, requestId);
    if (['login-with-nickname', 'configure-password-account', 'change-password-account', 'logout-nickname'].includes(operation)) {
      console.error(`${operation} requestId=${requestId} code=${response.code || 'AUTH_FAILED'}`);
      const safeCodes: string[] = ['INVALID_CREDENTIALS', 'INVALID_NICKNAME', 'INVALID_PASSWORD',
        'NICKNAME_TAKEN', 'AUTH_RATE_LIMITED', 'REAUTH_REQUIRED', 'FEATURE_NOT_READY',
        'AUTH_CONFIGURATION_REQUIRED', 'AUTH_UPSTREAM_FAILED', 'AUTH_UPSTREAM_HTTP', 'AUTH_UPSTREAM_RESPONSE',
        'AUTH_UPSTREAM_TIMEOUT', 'AUTH_UPSTREAM_NETWORK', 'AUTH_AGC_CLIENT_REJECTED', 'AUTH_AGC_SIGN_IN_REJECTED',
        'AUTH_AGC_TOKEN_INVALID', 'ACCOUNT_INACTIVE', 'AUTH_REQUIRED', 'CONFLICT', 'ACCOUNT_MISMATCH',
        'CURRENT_PASSWORD_INCORRECT', 'PASSWORD_UNCHANGED', 'PASSWORD_NOT_SET', 'PASSWORD_STATE_CHANGED'];
      if (!safeCodes.includes(response.code || '')) response.message = '认证服务暂时不可用，请稍后重试。';
      return response;
    }
    console.error(`${operation} requestId=${requestId} code=${response.code} stage=${response.stage} failed: ${runtime.safeLogError(error)}`);
    return response;
  }
}

export class ShikeAccount {
  getPasswordAccount(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-password-account', input);
  }
  configurePasswordAccount(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('configure-password-account', input);
  }
  changePasswordAccount(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('change-password-account', input);
  }
  loginWithNickname(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('login-with-nickname', input);
  }
  logoutNickname(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('logout-nickname', input);
  }
  completeLegacyLogin(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('complete-legacy-login', input);
  }
  startEmailBinding(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('start-email-binding', input);
  }
  completeEmailBinding(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('complete-email-binding', input);
  }
  upsertProfile(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('upsert-profile', input);
  }
  registerPushDevice(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('register-push-device', input);
  }
  unregisterPushDevice(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('unregister-push-device', input);
  }
  syncServiceCardForms(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('sync-service-card-forms', input);
  }
  unregisterServiceCardForms(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('unregister-service-card-forms', input);
  }
  pushServiceCardUpdate(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('push-service-card-update', input);
  }
  deleteAccountData(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('delete-account-data', input);
  }
}
