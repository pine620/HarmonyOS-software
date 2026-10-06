type CloudEnvelope = {
  accessToken: string;
  payload: object;
};

type CloudResponse = {
  ok: boolean;
  data: object;
  message: string;
  code?: string;
};

interface CodedRuntimeError extends Error {
  code?: string;
}

type RuntimeModule = {
  executeOperation(operation: string, input: CloudEnvelope, env?: NodeJS.ProcessEnv): Promise<object>;
  safeLogError(error: unknown): string;
};

const runtime = require('./runtime') as RuntimeModule;

/**
 * Client-facing cloud object. Every authenticated method still verifies the
 * AGC access token in runtime.js and derives uid server-side.
 */
async function executeCloudOperation(
  operation: string,
  input: CloudEnvelope
): Promise<CloudResponse> {
  try {
    const data = await runtime.executeOperation(operation, input, process.env);
    return { ok: true, data, message: '' };
  } catch (error) {
    console.error(`${operation} failed: ${runtime.safeLogError(error)}`);
    const message = error instanceof Error ? error.message : '云端请求失败。';
    const failure = error instanceof Error ? error as CodedRuntimeError : undefined;
    const code = failure && typeof failure.code === 'string' && failure.code.length > 0 ? failure.code : 'REQUEST_FAILED';
    return { ok: false, data: {}, message, code };
  }
}

export class ShikeService {
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
