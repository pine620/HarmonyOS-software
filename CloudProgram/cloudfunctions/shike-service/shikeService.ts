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

const runtime = require('./runtime') as RuntimeModule;
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
  try {
    const request = Object.assign({}, input, { readRequestId: requestId });
    const data = await runtime.executeOperation(operation, request, process.env);
    return { ok: true, data, message: '', requestId, operation, functionVersion: readErrors.READ_OPT_VERSION, ...releaseInfo.buildInfo };
  } catch (error) {
    const response: CloudResponse = readErrors.errorResponse(error, operation, requestId);
    console.error(`${operation} requestId=${requestId} code=${response.code} stage=${response.stage} failed: ${runtime.safeLogError(error)}`);
    return response;
  }
}

export class ShikeService {
  listMyReports(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-my-reports', input);
  }
  reportMerchant(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('report-merchant', input);
  }
  listOwnReviewRequests(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-own-review-requests', input);
  }
  listDeletedCards(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-deleted-cards', input);
  }
  restoreDeletedCard(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('restore-deleted-card', input);
  }
  getReviewMedia(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-review-media', input);
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
  setCardWanted(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('set-card-wanted', input);
  }
  getStage47Capabilities(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-stage47-capabilities', input);
  }

  getMealCandidates(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-meal-candidates', input);
  }
  getRandomFoodPool(input: CloudEnvelope): Promise<CloudResponse> { return executeCloudOperation('get-random-food-pool', input); }
  getRandomFoodCards(input: CloudEnvelope): Promise<CloudResponse> { return executeCloudOperation('get-random-food-cards', input); }
  saveFoodChoice(input: CloudEnvelope): Promise<CloudResponse> { return executeCloudOperation('save-food-choice', input); }
  listFoodChoices(input: CloudEnvelope): Promise<CloudResponse> { return executeCloudOperation('list-food-choices', input); }
  deleteFoodChoice(input: CloudEnvelope): Promise<CloudResponse> { return executeCloudOperation('delete-food-choice', input); }
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

  getFriendProfile(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-friend-profile', input);
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

  reportUser(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('report-user', input);
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

  reportCard(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('report-card', input);
  }

  toggleCardAction(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('toggle-card-action', input);
  }

  deleteOwnCard(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('delete-own-card', input);
  }

  deleteAccountData(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('delete-account-data', input);
  }
}
