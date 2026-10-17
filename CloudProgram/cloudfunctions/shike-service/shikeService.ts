/**
 * 【文件职责】云对象 shike-service 的入口（handler：shikeService.ShikeService）。
 * 负责：全部 90 个业务操作（维护源码，也是领域函数不可用时的兼容回落入口）。
 * 每个方法只是把调用转发给 runtime.executeOperation('操作名', 信封)，业务逻辑、身份校验和 Cloud DB 访问都在 runtime.js 中。
 */
// 请求信封：AGC 用户 Token + 业务参数 + 逻辑请求号 + 第几次尝试。
type CloudEnvelope = {
  accessToken: string;
  payload: object;
  readRequestId?: string;
  readAttempt?: number;
};

// 统一响应格式（与客户端 CloudGateway 的 ApiResponse 对应）。
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

// runtime.js 导出的接口。
type RuntimeModule = {
  executeOperation(operation: string, input: CloudEnvelope, env?: NodeJS.ProcessEnv): Promise<object>;
  safeLogError(error: unknown): string;
};

const runtime = require('./runtime') as RuntimeModule;
// shared/read-errors.js 导出的接口（错误响应与请求号）。
interface ReadErrorsModule {
  READ_OPT_VERSION: string;
  requestId(input: object): string;
  errorResponse(error: unknown, operation: string, requestId: string): CloudResponse;
}
const readErrors = require('./shared/read-errors') as ReadErrorsModule;
// shared/release-info.js 的构建信息（附在每个响应中）。
interface ReleaseInfo { buildId: string; policyHash: string; protocolVersion: string; }
const releaseInfo = require('./shared/release-info') as { buildInfo: ReleaseInfo };

// shared/cloud-operation.js：执行业务操作并包装响应（请求号、构建信息、昵称登录错误脱敏、互动耗时日志）。
interface CloudOperationModule {
  createOperationExecutor(runtime: RuntimeModule, readErrors: ReadErrorsModule, releaseInfo: { buildInfo: ReleaseInfo }):
    (operation: string, input: CloudEnvelope) => Promise<CloudResponse>;
}
const executeCloudOperation = (require('./shared/cloud-operation') as CloudOperationModule)
  .createOperationExecutor(runtime, readErrors, releaseInfo);

// 云对象类：AGC 按方法名调用（客户端协议 { method, params: [信封] }），方法名必须与客户端 CloudRoutes.ets 一致。
export class ShikeService {
  // get-card-interaction-state：读取“我”对卡片的反应 / 收藏状态。
  getCardInteractionState(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-card-interaction-state', input);
  }
  // set-card-interaction：写入反应 / 收藏（requestId 幂等）。
  setCardInteraction(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('set-card-interaction', input);
  }
  // get-card-interaction-receipt：查询互动写入回执。
  getCardInteractionReceipt(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-card-interaction-receipt', input);
  }
  // get-card-interaction-counts：读取赞 / 踩 / 收藏计数。
  getCardInteractionCounts(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-card-interaction-counts', input);
  }
  // get-password-account：查询是否已设置昵称密码。
  getPasswordAccount(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-password-account', input);
  }
  // configure-password-account：首次设置昵称与密码。
  configurePasswordAccount(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('configure-password-account', input);
  }
  // change-password-account：修改密码。
  changePasswordAccount(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('change-password-account', input);
  }
  // login-with-nickname：昵称 + 密码登录。
  loginWithNickname(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('login-with-nickname', input);
  }
  // logout-nickname：昵称会话退出。
  logoutNickname(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('logout-nickname', input);
  }

  // get-card-report-access：查询举报 / 审核权限。
  getCardReportAccess(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-card-report-access', input);
  }
  // get-card-report-context：读取举报上下文。
  getCardReportContext(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-card-report-context', input);
  }
  // submit-card-report：提交举报。
  submitCardReport(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('submit-card-report', input);
  }
  // list-my-card-reports：我的举报列表。
  listMyCardReports(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-my-card-reports', input);
  }
  // get-my-card-report：我的举报详情。
  getMyCardReport(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-my-card-report', input);
  }
  // list-card-review-reports：审核列表（审核员）。
  listCardReviewReports(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-card-review-reports', input);
  }
  // get-card-review-report：审核详情（审核员）。
  getCardReviewReport(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-card-review-report', input);
  }
  // resolve-card-report：处理举报（审核员）。
  resolveCardReport(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('resolve-card-report', input);
  }

  // list-deleted-cards：删除记录列表。
  listDeletedCards(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-deleted-cards', input);
  }
  // restore-deleted-card：恢复已删除的卡片。
  restoreDeletedCard(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('restore-deleted-card', input);
  }
  // get-review-media：审核用图片（审核员）。
  getReviewMedia(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-review-media', input);
  }
  // get-card-previews：批量卡片预览。
  getCardPreviews(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-card-previews', input);
  }
  // list-personal-collection：收藏列表。
  listPersonalCollection(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-personal-collection', input);
  }
  // get-personal-collection-migration：旧收藏迁移进度。
  getPersonalCollectionMigration(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-personal-collection-migration', input);
  }
  // start-personal-collection-migration：开始旧收藏迁移。
  startPersonalCollectionMigration(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('start-personal-collection-migration', input);
  }
  // resume-personal-collection-migration：继续旧收藏迁移。
  resumePersonalCollectionMigration(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('resume-personal-collection-migration', input);
  }
  // set-card-favorite：设置 / 取消收藏。
  setCardFavorite(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('set-card-favorite', input);
  }
  // get-meal-candidates：群投票候选。
  getMealCandidates(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-meal-candidates', input);
  }
  // get-random-food-pool：今日吃什么候选池。
  getRandomFoodPool(input: CloudEnvelope): Promise<CloudResponse> { return executeCloudOperation('get-random-food-pool', input); }
  // get-random-food-cards：今日吃什么翻牌内容。
  getRandomFoodCards(input: CloudEnvelope): Promise<CloudResponse> { return executeCloudOperation('get-random-food-cards', input); }
  // save-food-choice：保存选择记录。
  saveFoodChoice(input: CloudEnvelope): Promise<CloudResponse> { return executeCloudOperation('save-food-choice', input); }
  // list-food-choices：选择记录列表。
  listFoodChoices(input: CloudEnvelope): Promise<CloudResponse> { return executeCloudOperation('list-food-choices', input); }
  // delete-food-choice：删除选择记录。
  deleteFoodChoice(input: CloudEnvelope): Promise<CloudResponse> { return executeCloudOperation('delete-food-choice', input); }
  // create-meal-poll：创建群投票。
  createMealPoll(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('create-meal-poll', input);
  }
  // get-meal-poll：读取群投票。
  getMealPoll(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-meal-poll', input);
  }
  // add-meal-poll-option：投票加选项。
  addMealPollOption(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('add-meal-poll-option', input);
  }
  // vote-meal-poll：投票。
  voteMealPoll(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('vote-meal-poll', input);
  }
  // close-meal-poll：截止投票。
  closeMealPoll(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('close-meal-poll', input);
  }
  // cancel-meal-poll：取消投票。
  cancelMealPoll(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('cancel-meal-poll', input);
  }
  // stop-meal-poll-options：停止添加选项。
  stopMealPollOptions(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('stop-meal-poll-options', input);
  }
  // get-user-page：用户主页。
  getUserPage(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-user-page', input);
  }
  // list-food-rankings：榜单。
  listFoodRankings(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-food-rankings', input);
  }

  // set-card-reaction-v2：设置赞 / 踩（v2）。
  setCardReactionV2(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('set-card-reaction-v2', input);
  }
  // get-discovery-capabilities：发现功能开关。
  getDiscoveryCapabilities(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-discovery-capabilities', input);
  }
  // list-map-merchants：地图视野内的店铺。
  listMapMerchants(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-map-merchants', input);
  }
  // search-public-cards：搜索公开卡片。
  searchPublicCards(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('search-public-cards', input);
  }
  // get-merchant-recommendations：店铺推荐卡片。
  getMerchantRecommendations(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-merchant-recommendations', input);
  }
  // get-stage2-capabilities：店铺能力开关。
  getStage2Capabilities(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-stage2-capabilities', input);
  }

  // resolve-merchant：解析官方地点为店铺。
  resolveMerchant(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('resolve-merchant', input);
  }

  // create-user-merchant：创建用户店铺。
  createUserMerchant(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('create-user-merchant', input);
  }

  // update-user-merchant：更新用户店铺。
  updateUserMerchant(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('update-user-merchant', input);
  }

  // get-merchant：读取店铺。
  getMerchant(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-merchant', input);
  }




  // get-card-edit-context：读取编辑上下文。
  getCardEditContext(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-card-edit-context', input);
  }

  // get-revision-media：修订中的图片。
  getRevisionMedia(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-revision-media', input);
  }

  // submit-card-revision：提交作者修改。
  submitCardRevision(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('submit-card-revision', input);
  }

  // withdraw-card-revision：撤回作者修改。
  withdrawCardRevision(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('withdraw-card-revision', input);
  }













  // complete-legacy-login：完成华为兼容登录（消费迁移票据）。
  completeLegacyLogin(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('complete-legacy-login', input);
  }

  // start-email-binding：开始绑定邮箱（签发票据）。
  startEmailBinding(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('start-email-binding', input);
  }

  // complete-email-binding：完成绑定邮箱。
  completeEmailBinding(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('complete-email-binding', input);
  }

  // upsert-profile：读取或更新资料。
  upsertProfile(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('upsert-profile', input);
  }



  // get-public-media：游客读取公开图片。
  getPublicMedia(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-public-media', input);
  }

  // publish-card：发布卡片。
  publishCard(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('publish-card', input);
  }

  // list-nearby-cards：推荐流（scope=all）/ 附近卡片。
  listNearbyCards(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-nearby-cards', input);
  }

  // get-friend-profile：好友主页。
  getFriendProfile(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-friend-profile', input);
  }

  // get-card-detail：卡片详情。
  getCardDetail(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-card-detail', input);
  }

  // list-my-cards：我的卡片。
  listMyCards(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-my-cards', input);
  }

  // search-users：搜索用户。
  searchUsers(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('search-users', input);
  }

  // list-friends：好友与申请列表。
  listFriends(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-friends', input);
  }

  // send-friend-request：发送好友申请。
  sendFriendRequest(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('send-friend-request', input);
  }

  // respond-friend-request：处理好友申请。
  respondFriendRequest(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('respond-friend-request', input);
  }

  // cancel-friend-request：撤回好友申请。
  cancelFriendRequest(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('cancel-friend-request', input);
  }

  // block-user：拉黑。
  blockUser(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('block-user', input);
  }

  // unblock-user：解除拉黑。
  unblockUser(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('unblock-user', input);
  }

  // remove-friend：解除好友。
  removeFriend(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('remove-friend', input);
  }

  // list-conversations：私信会话列表。
  listConversations(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-conversations', input);
  }

  // list-messages：私信消息分页。
  listMessages(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-messages', input);
  }

  // send-message：发送私信。
  sendMessage(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('send-message', input);
  }

  // create-group-chat：创建群聊。
  createGroupChat(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('create-group-chat', input);
  }

  // list-group-conversations：群聊列表。
  listGroupConversations(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-group-conversations', input);
  }

  // get-group-chat：群资料与成员。
  getGroupChat(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-group-chat', input);
  }

  // list-group-messages：群消息分页。
  listGroupMessages(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-group-messages', input);
  }

  // send-group-message：发送群消息。
  sendGroupMessage(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('send-group-message', input);
  }

  // leave-group-chat：退出群聊。
  leaveGroupChat(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('leave-group-chat', input);
  }

  // remove-group-member：移除群成员。
  removeGroupMember(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('remove-group-member', input);
  }





  // register-push-device：登记 Push 设备。
  registerPushDevice(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('register-push-device', input);
  }

  // unregister-push-device：删除 Push 设备登记。
  unregisterPushDevice(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('unregister-push-device', input);
  }

  // sync-service-card-forms：登记桌面卡片实例。
  syncServiceCardForms(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('sync-service-card-forms', input);
  }

  // unregister-service-card-forms：删除桌面卡片登记。
  unregisterServiceCardForms(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('unregister-service-card-forms', input);
  }

  // push-service-card-update：推送桌面卡片更新。
  pushServiceCardUpdate(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('push-service-card-update', input);
  }

  // delete-own-card：删除自己的卡片（软删除）。
  deleteOwnCard(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('delete-own-card', input);
  }

  // delete-account-data：注销账号。
  deleteAccountData(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('delete-account-data', input);
  }
}
