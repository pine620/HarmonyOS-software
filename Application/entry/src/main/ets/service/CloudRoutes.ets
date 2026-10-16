import { INTERACTION_READ_TIMEOUT_MS, INTERACTION_WRITE_TIMEOUT_MS, NICKNAME_AUTH_TIMEOUT_MS } from './CloudTimeouts';

// Pack 3.4 / 4.4 (2026-10-15): one table maps every shike-service operation to its cloud-object method and to the
// domain function that serves it (shike-content / shike-social / shike-account / shike-governance). Generated from
// CloudProgram/cloudfunctions/shike-service/shikeService.ts; keep both in step when adding an operation.
export interface CloudRoute {
  operation: string;
  method: string;
  domainFunction: string;
  timeoutMs: number;
}

// When false (or while a domain function is unreachable) every operation goes to the original shike-service.
export const CLOUD_SERVICE_SPLIT_ENABLED: boolean = true;
export const LEGACY_SERVICE_FUNCTION: string = 'shike-service';

type RouteRow = [string, string, string, number];

const ROUTE_ROWS: Array<RouteRow> = [
  ['get-card-interaction-state', 'getCardInteractionState', 'shike-content', INTERACTION_READ_TIMEOUT_MS],
  ['set-card-interaction', 'setCardInteraction', 'shike-content', INTERACTION_WRITE_TIMEOUT_MS],
  ['get-card-interaction-receipt', 'getCardInteractionReceipt', 'shike-content', INTERACTION_READ_TIMEOUT_MS],
  ['get-card-interaction-counts', 'getCardInteractionCounts', 'shike-content', INTERACTION_READ_TIMEOUT_MS],
  ['get-password-account', 'getPasswordAccount', 'shike-account', NICKNAME_AUTH_TIMEOUT_MS],
  ['configure-password-account', 'configurePasswordAccount', 'shike-account', NICKNAME_AUTH_TIMEOUT_MS],
  ['change-password-account', 'changePasswordAccount', 'shike-account', NICKNAME_AUTH_TIMEOUT_MS],
  ['login-with-nickname', 'loginWithNickname', 'shike-account', NICKNAME_AUTH_TIMEOUT_MS],
  ['logout-nickname', 'logoutNickname', 'shike-account', NICKNAME_AUTH_TIMEOUT_MS],
  ['get-card-report-access', 'getCardReportAccess', 'shike-governance', 0],
  ['get-card-report-context', 'getCardReportContext', 'shike-governance', 0],
  ['submit-card-report', 'submitCardReport', 'shike-governance', 0],
  ['list-my-card-reports', 'listMyCardReports', 'shike-governance', 0],
  ['get-my-card-report', 'getMyCardReport', 'shike-governance', 0],
  ['list-card-review-reports', 'listCardReviewReports', 'shike-governance', 0],
  ['get-card-review-report', 'getCardReviewReport', 'shike-governance', 0],
  ['resolve-card-report', 'resolveCardReport', 'shike-governance', 0],
  ['list-deleted-cards', 'listDeletedCards', 'shike-content', 0],
  ['restore-deleted-card', 'restoreDeletedCard', 'shike-content', 0],
  ['get-review-media', 'getReviewMedia', 'shike-governance', 0],
  ['get-card-previews', 'getCardPreviews', 'shike-content', 0],
  ['list-personal-collection', 'listPersonalCollection', 'shike-content', 0],
  ['get-personal-collection-migration', 'getPersonalCollectionMigration', 'shike-content', 0],
  ['start-personal-collection-migration', 'startPersonalCollectionMigration', 'shike-content', 0],
  ['resume-personal-collection-migration', 'resumePersonalCollectionMigration', 'shike-content', 0],
  ['set-card-favorite', 'setCardFavorite', 'shike-content', 0],
  ['get-meal-candidates', 'getMealCandidates', 'shike-social', 0],
  ['create-meal-poll', 'createMealPoll', 'shike-social', 0],
  ['get-meal-poll', 'getMealPoll', 'shike-social', 0],
  ['add-meal-poll-option', 'addMealPollOption', 'shike-social', 0],
  ['vote-meal-poll', 'voteMealPoll', 'shike-social', 0],
  ['close-meal-poll', 'closeMealPoll', 'shike-social', 0],
  ['cancel-meal-poll', 'cancelMealPoll', 'shike-social', 0],
  ['stop-meal-poll-options', 'stopMealPollOptions', 'shike-social', 0],
  ['get-user-page', 'getUserPage', 'shike-content', 0],
  ['list-food-rankings', 'listFoodRankings', 'shike-content', 0],
  ['set-card-reaction-v2', 'setCardReactionV2', 'shike-content', 0],
  ['get-discovery-capabilities', 'getDiscoveryCapabilities', 'shike-content', 0],
  ['list-map-merchants', 'listMapMerchants', 'shike-content', 0],
  ['search-public-cards', 'searchPublicCards', 'shike-content', 0],
  ['get-merchant-recommendations', 'getMerchantRecommendations', 'shike-content', 0],
  ['get-stage2-capabilities', 'getStage2Capabilities', 'shike-content', 0],
  ['resolve-merchant', 'resolveMerchant', 'shike-content', 0],
  ['create-user-merchant', 'createUserMerchant', 'shike-content', 0],
  ['update-user-merchant', 'updateUserMerchant', 'shike-content', 0],
  ['get-merchant', 'getMerchant', 'shike-content', 0],
  ['get-card-edit-context', 'getCardEditContext', 'shike-content', 0],
  ['get-revision-media', 'getRevisionMedia', 'shike-content', 0],
  ['submit-card-revision', 'submitCardRevision', 'shike-content', 0],
  ['withdraw-card-revision', 'withdrawCardRevision', 'shike-content', 0],
  ['complete-legacy-login', 'completeLegacyLogin', 'shike-account', 0],
  ['start-email-binding', 'startEmailBinding', 'shike-account', 0],
  ['complete-email-binding', 'completeEmailBinding', 'shike-account', 0],
  ['upsert-profile', 'upsertProfile', 'shike-account', 0],
  // prepare/upload are served by shike-media (CloudGateway.invokeMedia); these two rows only mirror shikeService.ts.
  ['prepare-card-photo', 'prepareCardPhoto', 'shike-content', 0],
  ['upload-card-photo', 'uploadCardPhoto', 'shike-content', 0],
  ['get-public-media', 'getPublicMedia', 'shike-content', 0],
  ['publish-card', 'publishCard', 'shike-content', 0],
  ['list-nearby-cards', 'listNearbyCards', 'shike-content', 0],
  ['get-friend-profile', 'getFriendProfile', 'shike-social', 0],
  ['get-card-detail', 'getCardDetail', 'shike-content', 0],
  ['list-my-cards', 'listMyCards', 'shike-content', 0],
  ['search-users', 'searchUsers', 'shike-social', 0],
  ['list-friends', 'listFriends', 'shike-social', 0],
  ['send-friend-request', 'sendFriendRequest', 'shike-social', 0],
  ['respond-friend-request', 'respondFriendRequest', 'shike-social', 0],
  ['cancel-friend-request', 'cancelFriendRequest', 'shike-social', 0],
  ['block-user', 'blockUser', 'shike-social', 0],
  ['unblock-user', 'unblockUser', 'shike-social', 0],
  ['remove-friend', 'removeFriend', 'shike-social', 0],
  ['list-conversations', 'listConversations', 'shike-social', 0],
  ['list-messages', 'listMessages', 'shike-social', 0],
  ['send-message', 'sendMessage', 'shike-social', 0],
  ['create-group-chat', 'createGroupChat', 'shike-social', 0],
  ['list-group-conversations', 'listGroupConversations', 'shike-social', 0],
  ['get-group-chat', 'getGroupChat', 'shike-social', 0],
  ['list-group-messages', 'listGroupMessages', 'shike-social', 0],
  ['send-group-message', 'sendGroupMessage', 'shike-social', 0],
  ['leave-group-chat', 'leaveGroupChat', 'shike-social', 0],
  ['remove-group-member', 'removeGroupMember', 'shike-social', 0],
  ['register-push-device', 'registerPushDevice', 'shike-account', 0],
  ['unregister-push-device', 'unregisterPushDevice', 'shike-account', 0],
  ['sync-service-card-forms', 'syncServiceCardForms', 'shike-account', 0],
  ['unregister-service-card-forms', 'unregisterServiceCardForms', 'shike-account', 0],
  ['push-service-card-update', 'pushServiceCardUpdate', 'shike-account', 0],
  ['delete-own-card', 'deleteOwnCard', 'shike-content', 0],
  ['delete-account-data', 'deleteAccountData', 'shike-account', 0],
  // 今日吃什么
  ['get-random-food-pool', 'getRandomFoodPool', 'shike-content', 0],
  ['get-random-food-cards', 'getRandomFoodCards', 'shike-content', 0],
  ['save-food-choice', 'saveFoodChoice', 'shike-content', 0],
  ['list-food-choices', 'listFoodChoices', 'shike-content', 0],
  ['delete-food-choice', 'deleteFoodChoice', 'shike-content', 0],
];

const ROUTES: Map<string, CloudRoute> = new Map<string, CloudRoute>();
for (const row of ROUTE_ROWS) {
  const route: CloudRoute = { operation: row[0], method: row[1], domainFunction: row[2], timeoutMs: row[3] };
  ROUTES.set(row[0], route);
}

export function cloudRouteFor(operation: string): CloudRoute | undefined {
  // Older installed packages still send the plural spelling.
  return ROUTES.get(operation === 'publish-cards' ? 'publish-card' : operation);
}

export function isReadOnlyOperation(operation: string): boolean {
  return /^(get|list|search)-/.test(operation);
}
