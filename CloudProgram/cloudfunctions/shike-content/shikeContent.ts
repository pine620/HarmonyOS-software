/**
 * 【文件职责】云对象 shike-content 的入口（handler：shikeContent.ShikeContent）。
 * 负责：内容域 39 个操作：推荐、搜索、地图、店铺、详情、发布与修改、互动、收藏、榜单、今日吃什么、删除记录。
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
export class ShikeContent {
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
  // list-deleted-cards：删除记录列表。
  listDeletedCards(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-deleted-cards', input);
  }
  // restore-deleted-card：恢复已删除的卡片。
  restoreDeletedCard(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('restore-deleted-card', input);
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
  // get-card-detail：卡片详情。
  getCardDetail(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-card-detail', input);
  }
  // list-my-cards：我的卡片。
  listMyCards(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-my-cards', input);
  }
  // delete-own-card：删除自己的卡片（软删除）。
  deleteOwnCard(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('delete-own-card', input);
  }  getRandomFoodPool(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-random-food-pool', input);
  }
  // get-random-food-cards：今日吃什么翻牌内容。
  getRandomFoodCards(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-random-food-cards', input);
  }
  // save-food-choice：保存选择记录。
  saveFoodChoice(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('save-food-choice', input);
  }
  // list-food-choices：选择记录列表。
  listFoodChoices(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('list-food-choices', input);
  }
  // delete-food-choice：删除选择记录。
  deleteFoodChoice(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('delete-food-choice', input);
  }
}
