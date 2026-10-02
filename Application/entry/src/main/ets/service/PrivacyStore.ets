import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const STORE_NAME = 'shike_privacy';
// Nearby preloading now keeps a rounded coordinate in process memory for up
// to 90 seconds. Existing users must see the updated disclosure before it is used.
const CONSENT_KEY = 'privacy_consent_v4';

export class PrivacyStore {
  static async hasConsent(context: common.Context): Promise<boolean> {
    const store = await preferences.getPreferences(context, { name: STORE_NAME });
    const value = await store.get(CONSENT_KEY, false);
    return typeof value === 'boolean' ? value : false;
  }

  static async setConsent(context: common.Context, accepted: boolean): Promise<void> {
    const store = await preferences.getPreferences(context, { name: STORE_NAME });
    await store.put(CONSENT_KEY, accepted);
    await store.flush();
  }
}
