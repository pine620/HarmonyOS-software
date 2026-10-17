/**
 * 【文件职责】云对象 shike-account 的入口（handler：shikeAccount.ShikeAccount）。
 * 负责：账号域 15 个操作：昵称密码、华为/邮箱绑定、资料、Push 与桌面卡片登记、注销。
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
export class ShikeAccount {
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
  // delete-account-data：注销账号。
  deleteAccountData(input: CloudEnvelope): Promise<CloudResponse> {
    return executeCloudOperation('delete-account-data', input);
  }
}
