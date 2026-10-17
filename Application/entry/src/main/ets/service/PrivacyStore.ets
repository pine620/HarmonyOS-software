/**
 * 【文件职责】隐私同意状态（Preferences）。同意之前 App 不初始化 AGC SDK，也不发任何云请求。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const STORE_NAME = 'shike_privacy';
// 同意键带版本号：历史上附近预加载曾在进程内存中保留取整后的坐标（最长 90 秒），为此升级了隐私说明，老用户必须看到新的说明并重新同意。
const CONSENT_KEY = 'privacy_consent_v4';

// 隐私同意存储（静态类）。
export class PrivacyStore {
  // 是否已同意当前版本的隐私说明。
  static async hasConsent(context: common.Context): Promise<boolean> {
    const store = await preferences.getPreferences(context, { name: STORE_NAME });
    const value = await store.get(CONSENT_KEY, false);
    return typeof value === 'boolean' ? value : false;
  }

  // 保存用户的同意/撤回。
  static async setConsent(context: common.Context, accepted: boolean): Promise<void> {
    const store = await preferences.getPreferences(context, { name: STORE_NAME });
    await store.put(CONSENT_KEY, accepted);
    await store.flush();
  }
}
