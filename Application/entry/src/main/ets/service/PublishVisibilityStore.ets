import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { FoodVisibility } from '../model/CloudContracts';

export class PublishVisibilityStore {
  static read(context: common.Context, uid: string): FoodVisibility {
    if (uid.length === 0) return 'PUBLIC';
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: 'shike_publish_settings' });
    return store.getSync('visibility_' + uid, 'PUBLIC') === 'FRIENDS' ? 'FRIENDS' : 'PUBLIC';
  }
  static save(context: common.Context, uid: string, visibility: FoodVisibility): void {
    if (uid.length === 0) return;
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: 'shike_publish_settings' });
    store.putSync('visibility_' + uid, visibility);
    store.flushSync();
  }
  static clearAccount(context: common.Context, uid: string): void {
    if (uid.length === 0) return;
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: 'shike_publish_settings' });
    store.deleteSync('visibility_' + uid);
    store.flushSync();
  }
}
