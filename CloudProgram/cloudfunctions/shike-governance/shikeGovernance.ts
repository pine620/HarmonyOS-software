/**
 * 【文件职责】云对象 shike-governance 的入口（handler：shikeGovernance.ShikeGovernance）。
 * 负责：治理域 9 个操作：卡片举报、审核与审核用图片。
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
export class ShikeGovernance {
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
  // get-review-media：审核用图片（审核员）。
  getReviewMedia(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('get-review-media', input);
  }
}
