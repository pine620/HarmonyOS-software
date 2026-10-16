// Pack 4.4 (2026-10-15): shike-social serves the social operations of the original shike-service. It runs the same
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

export class ShikeSocial {
  getMealCandidates(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-meal-candidates', input);
  }
  createMealPoll(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('create-meal-poll', input);
  }
  getMealPoll(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-meal-poll', input);
  }
  addMealPollOption(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('add-meal-poll-option', input);
  }
  voteMealPoll(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('vote-meal-poll', input);
  }
  closeMealPoll(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('close-meal-poll', input);
  }
  cancelMealPoll(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('cancel-meal-poll', input);
  }
  stopMealPollOptions(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('stop-meal-poll-options', input);
  }
  getFriendProfile(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-friend-profile', input);
  }
  searchUsers(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('search-users', input);
  }
  listFriends(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-friends', input);
  }
  sendFriendRequest(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('send-friend-request', input);
  }
  respondFriendRequest(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('respond-friend-request', input);
  }
  cancelFriendRequest(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('cancel-friend-request', input);
  }
  blockUser(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('block-user', input);
  }
  unblockUser(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('unblock-user', input);
  }
  removeFriend(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('remove-friend', input);
  }
  listConversations(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-conversations', input);
  }
  listMessages(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-messages', input);
  }
  sendMessage(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('send-message', input);
  }
  createGroupChat(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('create-group-chat', input);
  }
  listGroupConversations(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-group-conversations', input);
  }
  getGroupChat(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-group-chat', input);
  }
  listGroupMessages(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-group-messages', input);
  }
  sendGroupMessage(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('send-group-message', input);
  }
  leaveGroupChat(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('leave-group-chat', input);
  }
  removeGroupMember(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('remove-group-member', input);
  }
}
