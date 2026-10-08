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
  requestId(input: object): string;
  errorResponse(error: unknown, operation: string, requestId: string): CloudResponse;
}
const readErrors = require('./read-errors') as ReadErrorsModule;

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
    return { ok: true, data, message: '', requestId, operation, functionVersion: 'stages89-20261007-v1' };
  } catch (error) {
    const response: CloudResponse = readErrors.errorResponse(error, operation, requestId);
    console.error(`${operation} requestId=${requestId} code=${response.code} stage=${response.stage} failed: ${runtime.safeLogError(error)}`);
    return response;
  }
}

export class ShikeService {
  getStage89Capabilities(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-stage89-capabilities', input);
  }
  listModerationQueue(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-moderation-queue', input);
  }
  getModerationDetail(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-moderation-detail', input);
  }
  decideModeration(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('decide-moderation', input);
  }
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
  listLifecycleJobs(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-lifecycle-jobs', input);
  }
  getLifecycleJob(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-lifecycle-job', input);
  }
  retryLifecycleJob(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('retry-lifecycle-job', input);
  }
  confirmAuthCleanup(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('confirm-auth-cleanup', input);
  }
  getReviewMedia(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-review-media', input);
  }
  runLifecycleJob(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('run-lifecycle-job', input);
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
  getTastePreference(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-taste-preference', input);
  }
  updateTastePreference(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('update-taste-preference', input);
  }
  clearTastePreference(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('clear-taste-preference', input);
  }
  listPersonalizedRecommendations(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-personalized-recommendations', input);
  }
  listFoodLists(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-food-lists', input);
  }
  createFoodList(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('create-food-list', input);
  }
  updateFoodList(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('update-food-list', input);
  }
  deleteFoodList(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('delete-food-list', input);
  }
  listFoodListItems(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-food-list-items', input);
  }
  addFoodListItem(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('add-food-list-item', input);
  }
  removeFoodListItem(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('remove-food-list-item', input);
  }
  reorderFoodListItems(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('reorder-food-list-items', input);
  }
  getPersonalFoodState(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-personal-food-state', input);
  }
  updatePersonalFoodState(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('update-personal-food-state', input);
  }
  getMealCandidates(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-meal-candidates', input);
  }
  recordMealChoice(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('record-meal-choice', input);
  }
  listMealChoiceHistory(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-meal-choice-history', input);
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
  getUserPage(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-user-page', input);
  }
  listMerchantRankings(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-merchant-rankings', input);
  }
  listFormerFriendContentGrants(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-former-friend-content-grants', input);
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

  listModerationMerchants(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-moderation-merchants', input);
  }

  moderateMerchant(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('moderate-merchant', input);
  }

  reconcileMerchantCounters(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('reconcile-merchant-counters', input);
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

  listModerationRevisions(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-moderation-revisions', input);
  }

  moderateCardRevision(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('moderate-card-revision', input);
  }

  startMigrationJob(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('start-migration-job', input);
  }

  processMigrationJob(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('process-migration-job', input);
  }

  getMigrationStatus(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-migration-status', input);
  }

  listMaintenanceJobs(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-maintenance-jobs', input);
  }

  getMaintenanceJob(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-maintenance-job', input);
  }

  retryMaintenanceJob(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('retry-maintenance-job', input);
  }

  validateLifecycleJob(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('validate-lifecycle-job', input);
  }

  setCardVisibility(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('set-card-visibility', input);
  }

  revokeFriendContentAccess(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('revoke-friend-content-access', input);
  }

  processFriendCleanupJob(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('process-friend-cleanup-job', input);
  }

  listModerationCards(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-moderation-cards', input);
  }

  moderateCard(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('moderate-card', input);
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

  listFriendRankings(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-friend-rankings', input);
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

  listReceivedComments(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-received-comments', input);
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

  listNotifications(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-notifications', input);
  }

  markNotificationRead(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('mark-notification-read', input);
  }

  markAllNotificationsRead(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('mark-all-notifications-read', input);
  }

  openNotification(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('open-notification', input);
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

  createCardComment(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('create-card-comment', input);
  }

  deleteCardComment(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('delete-card-comment', input);
  }

  toggleCommentReaction(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('toggle-comment-reaction', input);
  }

  deleteOwnCard(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('delete-own-card', input);
  }

  deleteAccountData(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('delete-account-data', input);
  }
}
