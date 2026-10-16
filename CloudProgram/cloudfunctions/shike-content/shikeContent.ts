// Pack 4.4 (2026-10-15): shike-content serves the content operations of the original shike-service. It runs the same
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

export class ShikeContent {
  getCardInteractionState(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-card-interaction-state', input);
  }
  setCardInteraction(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('set-card-interaction', input);
  }
  getCardInteractionReceipt(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-card-interaction-receipt', input);
  }
  getCardInteractionCounts(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-card-interaction-counts', input);
  }
  listDeletedCards(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-deleted-cards', input);
  }
  restoreDeletedCard(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('restore-deleted-card', input);
  }
  getCardPreviews(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-card-previews', input);
  }
  listPersonalCollection(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-personal-collection', input);
  }
  getPersonalCollectionMigration(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-personal-collection-migration', input);
  }
  startPersonalCollectionMigration(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('start-personal-collection-migration', input);
  }
  resumePersonalCollectionMigration(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('resume-personal-collection-migration', input);
  }
  setCardFavorite(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('set-card-favorite', input);
  }
  getStage47Capabilities(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-stage47-capabilities', input);
  }
  getUserPage(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-user-page', input);
  }
  listFoodRankings(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-food-rankings', input);
  }
  setCardReactionV2(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('set-card-reaction-v2', input);
  }
  getDiscoveryCapabilities(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-discovery-capabilities', input);
  }
  listMapMerchants(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-map-merchants', input);
  }
  searchPublicCards(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('search-public-cards', input);
  }
  getMerchantRecommendations(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-merchant-recommendations', input);
  }
  getStage2Capabilities(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-stage2-capabilities', input);
  }
  resolveMerchant(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('resolve-merchant', input);
  }
  createUserMerchant(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('create-user-merchant', input);
  }
  updateUserMerchant(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('update-user-merchant', input);
  }
  getMerchant(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-merchant', input);
  }
  getCardEditContext(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-card-edit-context', input);
  }
  getRevisionMedia(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-revision-media', input);
  }
  setCardReaction(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('set-card-reaction', input);
  }
  submitCardRevision(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('submit-card-revision', input);
  }
  getCardRevision(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-card-revision', input);
  }
  withdrawCardRevision(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('withdraw-card-revision', input);
  }
  prepareCardPhoto(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('prepare-card-photo', input);
  }
  uploadCardPhoto(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('upload-card-photo', input);
  }
  getPublicMedia(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-public-media', input);
  }
  publishCard(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('publish-card', input);
  }
  listNearbyCards(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-nearby-cards', input);
  }
  getCardDetail(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-card-detail', input);
  }
  listMyCards(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-my-cards', input);
  }
  listMyFavoriteCards(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-my-favorite-cards', input);
  }
  toggleCardAction(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('toggle-card-action', input);
  }
  deleteOwnCard(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('delete-own-card', input);
  }  getRandomFoodPool(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-random-food-pool', input);
  }
  getRandomFoodCards(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-random-food-cards', input);
  }
  saveFoodChoice(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('save-food-choice', input);
  }
  listFoodChoices(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-food-choices', input);
  }
  deleteFoodChoice(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('delete-food-choice', input);
  }
}
