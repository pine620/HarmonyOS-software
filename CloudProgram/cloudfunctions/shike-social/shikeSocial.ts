/**
 * 【文件职责】云对象 shike-social 的入口（handler：shikeSocial.ShikeSocial）。
 * 负责：社交域 27 个操作：好友、私信、群聊、群投票。
 * 每个方法只是把调用转发给 runtime.executeOperation('操作名', 信封)，业务逻辑、身份校验和 Cloud DB 访问都在 runtime.js 中。
 * 本函数运行的 runtime 是 ./service/ 目录下由 npm run prepare:deveco（或打包脚本）从 shike-service 复制来的副本，行为、鉴权与 Cloud DB 访问完全相同，
 * 拆分只是为了让各领域独立扩缩容、分配内存和隔离故障。环境变量必须与 shike-service 完全一致。方法表由 shikeService.ts 生成，增删操作时保持一致。
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

const runtime = require('./service/runtime') as RuntimeModule;
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
export class ShikeSocial {
  // get-meal-candidates：群投票候选。
  getMealCandidates(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-meal-candidates', input);
  }
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
  // get-friend-profile：好友主页。
  getFriendProfile(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-friend-profile', input);
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
}
