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

export class ServiceCardRemoteSyncStatus {
  supported: boolean = false;
  optedIn: boolean = false;
  registered: boolean = false;
  formCount: number = 0;
}

function storeFor(context: common.Context): preferences.Preferences {
  return preferences.getPreferencesSync(context, { name: STORE_NAME });
}

function storedString(store: preferences.Preferences, key: string): string {
  const value: preferences.ValueType = store.getSync(key, '');
  return typeof value === 'string' ? value : '';
}

function installationId(context: common.Context): string {
  const store: preferences.Preferences = storeFor(context);
  const existing: string = storedString(store, DEVICE_ID_KEY);
  if (existing.length > 0) return existing;
  const generated: string = util.generateRandomUUID();
  store.putSync(DEVICE_ID_KEY, generated);
  store.flushSync();
  return generated;
}

function nonEmptyToken(token: string): string {
  const value: string = token.trim();
  if (value.length === 0) throw new Error('Push Kit 未返回可用于桌面卡片同步的设备令牌。');
  return value;
}

export class ServiceCardRemoteSyncService {
  static isSupported(): boolean {
    return canIUse('SystemCapability.Push.PushService');
  }

  static status(context: common.Context): ServiceCardRemoteSyncStatus {
    const status: ServiceCardRemoteSyncStatus = new ServiceCardRemoteSyncStatus();
    status.supported = ServiceCardRemoteSyncService.isSupported();
    const store: preferences.Preferences = storeFor(context);
    status.optedIn = store.getSync(OPTED_IN_KEY, false) === true;
    status.formCount = ServiceCardStore.formIds(context).length;
    status.registered = status.optedIn && status.formCount > 0 && store.getSync(REGISTERED_KEY, false) === true;
    return status;
  }

  private static recordOptIn(context: common.Context): void {
    const store: preferences.Preferences = storeFor(context);
    // Keep the explicit choice before the network call. If the response is
    // lost after a server-side success, the user retains a visible retry and
    // removal path instead of receiving a false disabled state.
    store.putSync(OPTED_IN_KEY, true);
    store.putSync(REGISTERED_KEY, false);
    store.flushSync();
  }

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

  static async enable(context: common.Context): Promise<ServiceCardFormSyncResponse> {
    if (!ServiceCardRemoteSyncService.isSupported()) {
      throw new Error('当前设备不支持 Push Kit 桌面卡片远程同步。');
    }
    const token: string = nonEmptyToken(await pushService.getToken());
    ServiceCardRemoteSyncService.recordOptIn(context);
    return ServiceCardRemoteSyncService.synchronize(context, token);
  }

  static async syncIfEnabled(context: common.Context): Promise<void> {
    const current: ServiceCardRemoteSyncStatus = ServiceCardRemoteSyncService.status(context);
    if (!current.supported || !current.optedIn || !CloudGateway.hasSession()) return;
    const token: string = nonEmptyToken(await pushService.getToken());
    await ServiceCardRemoteSyncService.synchronize(context, token);
  }

  static async handleTokenUpdate(context: common.Context, token: string): Promise<void> {
    try {
      const current: ServiceCardRemoteSyncStatus = ServiceCardRemoteSyncService.status(context);
      if (!current.supported || !current.optedIn || !CloudGateway.hasSession()) return;
      await ServiceCardRemoteSyncService.synchronize(context, nonEmptyToken(token));
    } catch (_error) {
      console.warn('Service-card Push Token update could not be synchronized.');
    }
  }

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
        // Keep local opt-in state until the server confirms deletion. This
        // protects against a lost successful response and leaves a retry path.
        throw new Error('云端桌面卡片登记暂未移除，请保持登录并稍后重试。');
      }
    }
    ServiceCardRemoteSyncService.clearLocalState(context);
  }

  /** Clears local consent state only after server-side removal is confirmed. */
  static clearLocalStateAfterRemoteRemoval(context: common.Context): void {
    ServiceCardRemoteSyncService.clearLocalState(context);
  }

  private static clearLocalState(context: common.Context): void {
    const store: preferences.Preferences = storeFor(context);
    store.deleteSync(DEVICE_ID_KEY);
    store.putSync(OPTED_IN_KEY, false);
    store.putSync(REGISTERED_KEY, false);
    store.flushSync();
  }
}
