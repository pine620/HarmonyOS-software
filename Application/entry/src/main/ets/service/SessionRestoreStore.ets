import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export type SessionProviderHint = 'AUTO' | 'EMAIL' | 'HUAWEI' | 'SIGNED_OUT';

// Only a non-secret provider hint is persisted. Tokens remain owned by AGC or
// in memory; SIGNED_OUT prevents silent login after an explicit user logout.
export class SessionRestoreStore {
  private static tail: Promise<void> = Promise.resolve();
  static async read(context: common.Context): Promise<SessionProviderHint> {
    const options: preferences.Options = { name: 'shike_session_hint' };
    const store: preferences.Preferences = await preferences.getPreferences(context, options);
    const value: preferences.ValueType = await store.get('provider', 'AUTO');
    if (value === 'EMAIL') return 'EMAIL';
    if (value === 'HUAWEI') return 'HUAWEI';
    if (value === 'SIGNED_OUT') return 'SIGNED_OUT';
    return 'AUTO';
  }
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
