import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

// 上次的登录方式提示：AUTO 未知 / EMAIL / HUAWEI / NICKNAME / SIGNED_OUT（用户主动退出）。
export type SessionProviderHint = 'AUTO' | 'EMAIL' | 'HUAWEI' | 'NICKNAME' | 'SIGNED_OUT';

/**
 * 【文件职责】冷启动时“如何恢复登录”的提示（Preferences: shike_session_hint）。
 * 只保存不含秘密的“登录方式”，Token 由 AGC SDK 管理或只在内存中；SIGNED_OUT 表示用户主动退出过，阻止下次静默登录。
 */
export class SessionRestoreStore {
  // 串行写入队列。
  private static tail: Promise<void> = Promise.resolve();
  // 读取上次的登录方式提示。
  static async read(context: common.Context): Promise<SessionProviderHint> {
    const options: preferences.Options = { name: 'shike_session_hint' };
    const store: preferences.Preferences = await preferences.getPreferences(context, options);
    const value: preferences.ValueType = await store.get('provider', 'AUTO');
    if (value === 'EMAIL') return 'EMAIL';
    if (value === 'NICKNAME') return 'NICKNAME';
    if (value === 'HUAWEI') return 'HUAWEI';
    if (value === 'SIGNED_OUT') return 'SIGNED_OUT';
    return 'AUTO';
  }
  // 保存登录方式提示（串行执行，后写的覆盖先写的）。
  static save(context: common.Context, provider: SessionProviderHint): Promise<void> {
    const operation: Promise<void> = SessionRestoreStore.tail.then(async (): Promise<void> => {
      const options: preferences.Options = { name: 'shike_session_hint' };
      const store: preferences.Preferences = await preferences.getPreferences(context, options);
      await store.put('provider', provider); await store.flush();
    });
    SessionRestoreStore.tail = operation.catch((): void => {});
    return operation;
  }
}
