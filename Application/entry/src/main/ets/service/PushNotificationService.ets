/**
 * 【文件职责】“食刻通知”（系统通知）开关：申请通知权限、获取 Push Token，并通过 register-push-device /
 * unregister-push-device 在云端登记或删除本设备。云端在收到私信、群消息、好友申请等事件时据此发送 Push。
 * 前台收到 IM 类推送时由 EntryAbility 处理（直接刷新聊天），不弹横幅。
 * 【新人注意】开启时先记本地再请求云端；关闭时云端确认删除后才清本地，保证可以重试。
 */
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

// 通知状态：系统是否支持、权限是否已授予、是否已开启等。
export class PushNotificationStatus {
  supported: boolean = false;
  enabled: boolean = false;
  optedIn: boolean = false;
  registered: boolean = false;
}

// 打开通知设置的本地存储。
function storeFor(context: common.Context): preferences.Preferences {
  return preferences.getPreferencesSync(context, { name: STORE_NAME });
}

// 读取字符串值。
function storedString(store: preferences.Preferences, key: string): string {
  const value: preferences.ValueType = store.getSync(key, '');
  return typeof value === 'string' ? value : '';
}

// 本机设备标识（首次使用时随机生成）。
function deviceId(context: common.Context): string {
  const store: preferences.Preferences = storeFor(context);
  const existing: string = storedString(store, DEVICE_ID_KEY);
  if (existing.length > 0) return existing;
  const generated: string = util.generateRandomUUID();
  store.putSync(DEVICE_ID_KEY, generated);
  store.flushSync();
  return generated;
}

// 登记时绑定的账号标识长度校验。
function canBindAppProfile(profileId: string): boolean {
  return profileId.length > 0 && profileId.length <= 64;
}

// 系统通知（静态类）。
export class PushNotificationService {
  // 设备是否支持 Push。
  static isSupported(): boolean {
    return canIUse('SystemCapability.Push.PushService');
  }

  // 读取当前通知状态（权限 + 是否已开启 + 是否已登记）。
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

  // 向云端登记本设备的 Push Token。
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

  // 记录用户已选择开启通知。
  private static recordOptIn(context: common.Context, profileId: string): void {
    const store: preferences.Preferences = storeFor(context);
    // 在发网络请求之前保存用户的明确选择：如果云端成功但响应丢失，用户仍可在“权限与隐私”页重试清理，而不是看到错误的“未开启”。
    store.putSync(OPTED_IN_KEY, true);
    store.putSync(PROFILE_ID_KEY, profileId);
    store.putSync(REGISTERED_KEY, false);
    store.flushSync();
  }

  // 开启通知：申请权限 → 获取 Token → 登记。
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

  // 已开启且有权限时，前台同步一次登记（Token 可能已变化）。
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

  // Push Token 更新时（EntryAbility 回调）重新登记。
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

  // 关闭通知：请求云端删除登记，成功后才清除本地状态。
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
        // 云端确认删除之前不清除本地状态，为“云端成功但响应丢失”的情况保留重试入口。
        throw new Error('云端通知设备暂未移除，请保持登录并稍后重试。');
      }
    }
    await PushNotificationService.clearLocalRegistration(context, profileId);
  }

  // 在调用方已经另外确认云端登记已删除（例如注销账号）之后，清除本地 Push 绑定。
  static async clearLocalStateAfterRemoteRemoval(context: common.Context): Promise<void> {
    if (!PushNotificationService.isSupported()) return;
    const store: preferences.Preferences = storeFor(context);
    const profileId: string = storedString(store, PROFILE_ID_KEY);
    await PushNotificationService.clearLocalRegistration(context, profileId);
  }

  // 清除本地的通知登记信息。
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
