/**
 * 【文件职责】桌面卡片“远程同步”（可选功能，用户在“权限与隐私”中单独开启）：
 * 把本机 Push Token 与已添加的卡片实例登记到云端（sync-service-card-forms），之后云端可以通过 Push 直接更新桌面卡片内容
 * （push-service-card-update）；关闭时调用 unregister-service-card-forms。
 * 【新人注意】开启状态先记在本地再请求云端；关闭时要等云端确认删除后才清除本地状态，保证响应丢失时用户仍能重试。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { pushService } from '@kit.PushKit';
import util from '@ohos.util';
import {
  OperationResponse, ServiceCardFormSyncRequest, ServiceCardFormSyncResponse,
  ServiceCardFormUnregisterRequest, ServiceCardRemoteUpdateRequest, ServiceCardRemoteUpdateResponse
} from '../model/CloudContracts';
import { CloudGateway } from './CloudGateway';
import { ServiceCardStore } from './ServiceCardStore';

const STORE_NAME: string = 'shike_service_card_remote_sync';
const DEVICE_ID_KEY: string = 'device_id';
const OPTED_IN_KEY: string = 'opted_in';
const REGISTERED_KEY: string = 'registered';

// 远程同步状态：系统是否支持、是否已开启、最近一次结果等。
export class ServiceCardRemoteSyncStatus {
  supported: boolean = false;
  optedIn: boolean = false;
  registered: boolean = false;
  formCount: number = 0;
}

// 打开远程同步的本地存储。
function storeFor(context: common.Context): preferences.Preferences {
  return preferences.getPreferencesSync(context, { name: STORE_NAME });
}

// 读取字符串值。
function storedString(store: preferences.Preferences, key: string): string {
  const value: preferences.ValueType = store.getSync(key, '');
  return typeof value === 'string' ? value : '';
}

// 本机安装标识（首次使用时随机生成，用于区分同一账号的多台设备）。
function installationId(context: common.Context): string {
  const store: preferences.Preferences = storeFor(context);
  const existing: string = storedString(store, DEVICE_ID_KEY);
  if (existing.length > 0) return existing;
  const generated: string = util.generateRandomUUID();
  store.putSync(DEVICE_ID_KEY, generated);
  store.flushSync();
  return generated;
}

// 去掉空白后返回 Token，空 Token 抛错。
function nonEmptyToken(token: string): string {
  const value: string = token.trim();
  if (value.length === 0) throw new Error('Push Kit 未返回可用于桌面卡片同步的设备令牌。');
  return value;
}

// 桌面卡片远程同步（静态类）。
export class ServiceCardRemoteSyncService {
  // 设备是否支持 Push。
  static isSupported(): boolean {
    return canIUse('SystemCapability.Push.PushService');
  }

  // 读取当前开启状态（供设置页显示）。
  static status(context: common.Context): ServiceCardRemoteSyncStatus {
    const status: ServiceCardRemoteSyncStatus = new ServiceCardRemoteSyncStatus();
    status.supported = ServiceCardRemoteSyncService.isSupported();
    const store: preferences.Preferences = storeFor(context);
    status.optedIn = store.getSync(OPTED_IN_KEY, false) === true;
    status.formCount = ServiceCardStore.formIds(context).length;
    status.registered = status.optedIn && status.formCount > 0 && store.getSync(REGISTERED_KEY, false) === true;
    return status;
  }

  // 记录用户已选择开启。
  private static recordOptIn(context: common.Context): void {
    const store: preferences.Preferences = storeFor(context);
    // 在发网络请求之前先保存用户的明确选择：如果云端已成功但响应丢失，用户仍能看到“已开启”并可以重试或关闭，而不是被错误地显示为未开启。
    store.putSync(OPTED_IN_KEY, true);
    store.putSync(REGISTERED_KEY, false);
    store.flushSync();
  }

  // 把 Token 与本机卡片实例 id 列表登记到云端。
  private static async synchronize(context: common.Context, token: string): Promise<ServiceCardFormSyncResponse> {
    const request: ServiceCardFormSyncRequest = {
      deviceId: installationId(context),
      token: nonEmptyToken(token),
      formIds: ServiceCardStore.formIds(context)
    };
    const result: ServiceCardFormSyncResponse =
      await CloudGateway.callAuthenticated<ServiceCardFormSyncResponse>('sync-service-card-forms', request);
    if (!result.success) throw new Error('云端未确认桌面卡片实例登记。');
    const store: preferences.Preferences = storeFor(context);
    store.putSync(REGISTERED_KEY, result.registeredFormCount > 0);
    store.flushSync();
    return result;
  }

  // 开启远程同步：获取 Push Token 并登记。
  static async enable(context: common.Context): Promise<ServiceCardFormSyncResponse> {
    if (!ServiceCardRemoteSyncService.isSupported()) {
      throw new Error('当前设备不支持 Push Kit 桌面卡片远程同步。');
    }
    const token: string = nonEmptyToken(await pushService.getToken());
    ServiceCardRemoteSyncService.recordOptIn(context);
    return ServiceCardRemoteSyncService.synchronize(context, token);
  }

  // 已开启时，前台同步一次（卡片实例或 Token 可能已变化）。
  static async syncIfEnabled(context: common.Context): Promise<void> {
    const current: ServiceCardRemoteSyncStatus = ServiceCardRemoteSyncService.status(context);
    if (!current.supported || !current.optedIn || !CloudGateway.hasSession()) return;
    const token: string = nonEmptyToken(await pushService.getToken());
    await ServiceCardRemoteSyncService.synchronize(context, token);
  }

  // Push Token 更新时（EntryAbility 回调）重新登记。
  static async handleTokenUpdate(context: common.Context, token: string): Promise<void> {
    try {
      const current: ServiceCardRemoteSyncStatus = ServiceCardRemoteSyncService.status(context);
      if (!current.supported || !current.optedIn || !CloudGateway.hasSession()) return;
      await ServiceCardRemoteSyncService.synchronize(context, nonEmptyToken(token));
    } catch (_error) {
      console.warn('Service-card Push Token update could not be synchronized.');
    }
  }

  // 请求云端立即把当前推荐推送到本机桌面卡片（每实例每日次数由服务端限制）。
  static async pushCurrentRecommendation(
    context: common.Context,
    cardId: string
  ): Promise<ServiceCardRemoteUpdateResponse> {
    const current: ServiceCardRemoteSyncStatus = ServiceCardRemoteSyncService.status(context);
    const inactive: ServiceCardRemoteUpdateResponse = {
      success: true,
      registeredFormCount: 0,
      deliveredFormCount: 0,
      rateLimitedFormCount: 0,
      deliveryAvailable: false
    };
    if (!current.supported || !current.optedIn) return inactive;
    if (!CloudGateway.hasSession()) {
      throw new Error('登录状态已失效，请重新登录后同步桌面卡片。');
    }
    const token: string = nonEmptyToken(await pushService.getToken());
    const registration: ServiceCardFormSyncResponse = await ServiceCardRemoteSyncService.synchronize(context, token);
    if (registration.registeredFormCount === 0) return inactive;
    const request: ServiceCardRemoteUpdateRequest = { cardId: cardId.trim() };
    const result: ServiceCardRemoteUpdateResponse =
      await CloudGateway.callAuthenticated<ServiceCardRemoteUpdateResponse>('push-service-card-update', request);
    if (!result.success) throw new Error('云端未确认桌面卡片远程更新。');
    return result;
  }

  // 关闭远程同步：请求云端删除登记，成功后才清除本地状态。
  static async disable(context: common.Context): Promise<void> {
    const store: preferences.Preferences = storeFor(context);
    const id: string = storedString(store, DEVICE_ID_KEY);
    const optedIn: boolean = store.getSync(OPTED_IN_KEY, false) === true;
    const registered: boolean = store.getSync(REGISTERED_KEY, false) === true;
    const needsRemoteRemoval: boolean = id.length > 0 && (optedIn || registered);
    if (needsRemoteRemoval && !CloudGateway.hasSession()) {
      throw new Error('登录状态已失效，无法从云端移除桌面卡片登记，请重新登录后重试。');
    }
    if (needsRemoteRemoval) {
      const request: ServiceCardFormUnregisterRequest = { deviceId: id };
      try {
        const result: OperationResponse =
          await CloudGateway.callAuthenticated<OperationResponse>('unregister-service-card-forms', request);
        if (!result.success) throw new Error('云端未确认桌面卡片登记移除。');
      } catch (_error) {
        // 在云端确认删除之前保留本地的开启状态，防止“云端已删除但响应丢失”时失去重试入口。
        throw new Error('云端桌面卡片登记暂未移除，请保持登录并稍后重试。');
      }
    }
    ServiceCardRemoteSyncService.clearLocalState(context);
  }

  // 只在确认云端已删除登记后（例如注销账号后）清除本地状态。
  static clearLocalStateAfterRemoteRemoval(context: common.Context): void {
    ServiceCardRemoteSyncService.clearLocalState(context);
  }

  // 清除本地开启状态与登记信息。
  private static clearLocalState(context: common.Context): void {
    const store: preferences.Preferences = storeFor(context);
    store.deleteSync(DEVICE_ID_KEY);
    store.putSync(OPTED_IN_KEY, false);
    store.putSync(REGISTERED_KEY, false);
    store.flushSync();
  }
}
