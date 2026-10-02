import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { notificationManager } from '@kit.NotificationKit';
import { pushCommon, pushService } from '@kit.PushKit';
import util from '@ohos.util';
import { OperationResponse, PushDeviceRequest, PushDeviceUnregisterRequest } from '../model/CloudContracts';
import { CloudGateway } from './CloudGateway';

const STORE_NAME: string = 'shike_push';
const DEVICE_ID_KEY: string = 'device_id';
const PROFILE_ID_KEY: string = 'profile_id';
const REGISTERED_KEY: string = 'registered';
const OPTED_IN_KEY: string = 'opted_in';

export class PushNotificationStatus {
  supported: boolean = false;
  enabled: boolean = false;
  optedIn: boolean = false;
  registered: boolean = false;
}

function storeFor(context: common.Context): preferences.Preferences {
  return preferences.getPreferencesSync(context, { name: STORE_NAME });
}

function storedString(store: preferences.Preferences, key: string): string {
  const value: preferences.ValueType = store.getSync(key, '');
  return typeof value === 'string' ? value : '';
}

function deviceId(context: common.Context): string {
  const store: preferences.Preferences = storeFor(context);
  const existing: string = storedString(store, DEVICE_ID_KEY);
  if (existing.length > 0) return existing;
  const generated: string = util.generateRandomUUID();
  store.putSync(DEVICE_ID_KEY, generated);
  store.flushSync();
  return generated;
}

function canBindAppProfile(profileId: string): boolean {
  return profileId.length > 0 && profileId.length <= 64;
}

export class PushNotificationService {
  static isSupported(): boolean {
    return canIUse('SystemCapability.Push.PushService');
  }

  static async status(context: common.Context): Promise<PushNotificationStatus> {
    const status = new PushNotificationStatus();
    status.supported = PushNotificationService.isSupported();
    if (!status.supported) return status;
    status.enabled = await notificationManager.isNotificationEnabled();
    const store: preferences.Preferences = storeFor(context);
    const registered: preferences.ValueType = store.getSync(REGISTERED_KEY, false);
    const optedIn: preferences.ValueType = store.getSync(OPTED_IN_KEY, false);
    status.optedIn = optedIn === true;
    status.registered = status.enabled && registered === true && status.optedIn;
    return status;
  }

  private static async register(context: common.Context, token: string): Promise<void> {
    const request: PushDeviceRequest = {
      deviceId: deviceId(context),
      token
    };
    const result: OperationResponse =
      await CloudGateway.callAuthenticated<OperationResponse>('register-push-device', request);
    if (!result.success) throw new Error('云端未确认通知设备登记。');
    const store: preferences.Preferences = storeFor(context);
    store.putSync(REGISTERED_KEY, true);
    store.flushSync();
  }

  private static recordOptIn(context: common.Context, profileId: string): void {
    const store: preferences.Preferences = storeFor(context);
    // Keep the explicit opt-in before the network call. If a successful
    // server response is lost, the user can still retry cleanup from the
    // privacy page instead of seeing a false disabled state.
    store.putSync(OPTED_IN_KEY, true);
    store.putSync(PROFILE_ID_KEY, profileId);
    store.putSync(REGISTERED_KEY, false);
    store.flushSync();
  }

  static async enable(context: common.UIAbilityContext, profileId: string): Promise<void> {
    if (!PushNotificationService.isSupported()) {
      throw new Error('当前设备不支持 Push Kit 通知服务。');
    }
    if (!(await notificationManager.isNotificationEnabled())) {
      await notificationManager.requestEnableNotification(context);
    }
    if (!(await notificationManager.isNotificationEnabled())) {
      throw new Error('系统通知权限尚未开启。');
    }
    const token: string = await pushService.getToken();
    PushNotificationService.recordOptIn(context, profileId);
    if (canBindAppProfile(profileId)) {
      await pushService.bindAppProfileId(pushCommon.AppProfileType.PROFILE_TYPE_APPLICATION_ACCOUNT, profileId);
    }
    await PushNotificationService.register(context, token);
  }

  static async syncIfEnabled(context: common.UIAbilityContext, profileId: string): Promise<void> {
    if (!PushNotificationService.isSupported() || !(await notificationManager.isNotificationEnabled())) return;
    const store: preferences.Preferences = storeFor(context);
    if (store.getSync(OPTED_IN_KEY, false) !== true) return;
    const token: string = await pushService.getToken();
    store.putSync(PROFILE_ID_KEY, profileId);
    store.flushSync();
    if (canBindAppProfile(profileId)) {
      await pushService.bindAppProfileId(pushCommon.AppProfileType.PROFILE_TYPE_APPLICATION_ACCOUNT, profileId);
    }
    await PushNotificationService.register(context, token);
  }

  static async handleTokenUpdate(context: common.Context, token: string): Promise<void> {
    try {
      if (!PushNotificationService.isSupported() || !CloudGateway.hasSession() || token.length === 0) return;
      const store: preferences.Preferences = storeFor(context);
      if (store.getSync(OPTED_IN_KEY, false) !== true) return;
      const profileId: string = storedString(store, PROFILE_ID_KEY);
      if (profileId.length === 0) return;
      await PushNotificationService.register(context, token);
    } catch (_error) {
      console.warn('Push token update could not be synchronized.');
    }
  }

  static async disable(context: common.Context): Promise<void> {
    if (!PushNotificationService.isSupported()) return;
    const store: preferences.Preferences = storeFor(context);
    const id: string = storedString(store, DEVICE_ID_KEY);
    const profileId: string = storedString(store, PROFILE_ID_KEY);
    const optedIn: boolean = store.getSync(OPTED_IN_KEY, false) === true;
    const registered: boolean = store.getSync(REGISTERED_KEY, false) === true;
    const needsRemoteRemoval: boolean = id.length > 0 && (optedIn || registered);
    if (needsRemoteRemoval && !CloudGateway.hasSession()) {
      throw new Error('登录状态已失效，无法从云端移除通知设备，请重新登录后重试。');
    }
    if (needsRemoteRemoval) {
      const request: PushDeviceUnregisterRequest = { deviceId: id };
      try {
        const result: OperationResponse =
          await CloudGateway.callAuthenticated<OperationResponse>('unregister-push-device', request);
        if (!result.success) throw new Error('云端未确认通知设备移除。');
      } catch (_error) {
        // Do not clear local opt-in state before server deletion is confirmed.
        // This keeps a retry path for a response lost after server success.
        throw new Error('云端通知设备暂未移除，请保持登录并稍后重试。');
      }
    }
    await PushNotificationService.clearLocalRegistration(context, profileId);
  }

  /**
   * Clears the local Push binding after the caller has independently confirmed
   * that the server-side registration is gone, such as after account deletion.
   */
  static async clearLocalStateAfterRemoteRemoval(context: common.Context): Promise<void> {
    if (!PushNotificationService.isSupported()) return;
    const store: preferences.Preferences = storeFor(context);
    const profileId: string = storedString(store, PROFILE_ID_KEY);
    await PushNotificationService.clearLocalRegistration(context, profileId);
  }

  private static async clearLocalRegistration(context: common.Context, profileId: string): Promise<void> {
    const store: preferences.Preferences = storeFor(context);
    let failure: string = '';
    if (canBindAppProfile(profileId)) {
      try {
        await pushService.unbindAppProfileId(profileId);
      } catch (_error) {
        failure = failure.length > 0 ? `${failure}，账号绑定暂未解除` : '通知账号绑定暂未解除';
      }
    }
    try {
      await pushService.deleteToken();
    } catch (_error) {
      failure = failure.length > 0 ? `${failure}，本机令牌暂未删除` : '本机通知令牌暂未删除';
    }
    store.deleteSync(DEVICE_ID_KEY);
    store.deleteSync(PROFILE_ID_KEY);
    store.putSync(REGISTERED_KEY, false);
    store.putSync(OPTED_IN_KEY, false);
    store.flushSync();
    if (failure.length > 0) throw new Error(`${failure}，请稍后重试。`);
  }
}
