import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { FoodConsumptionMode } from '../model/CloudContracts';

export interface ModeFields {
  savedAt: number;
  dineInSavedAt?: number;
  deliverySavedAt?: number;
  dineInAvg: string;
  orderTotal: string;
  deliveryFee: string;
  platformKey: string;
  platformLabel: string;
  consumedDate: string;
}

const RETENTION: number = 30 * 24 * 60 * 60 * 1000;
const STORE_NAME: string = 'shike_mode_fields';

/** Only incompatible mode fields, not a publication draft, request or photo. */
export class ModeFieldCache {
  static read(context: common.Context, uid: string, cardId: string): ModeFields | undefined {
    if (uid.length === 0) return undefined;
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: STORE_NAME });
    const key: string = uid + ':' + (cardId.length > 0 ? cardId : 'new');
    const raw: preferences.ValueType = store.getSync(key, '');
    if (typeof raw !== 'string' || raw.length === 0 || raw.length > 4096) return undefined;
    try {
      const value: ModeFields = JSON.parse(raw) as ModeFields;
      if (value === null || !Number.isSafeInteger(value.savedAt) || Date.now() - value.savedAt > RETENTION ||
        value.savedAt > Date.now() || typeof value.dineInAvg !== 'string' || typeof value.orderTotal !== 'string' ||
        typeof value.deliveryFee !== 'string' || typeof value.platformKey !== 'string' ||
        typeof value.platformLabel !== 'string' || typeof value.consumedDate !== 'string') {
        store.deleteSync(key); store.flushSync(); return undefined;
      }
      const now: number = Date.now();
      const dineAt: number = value.dineInSavedAt === undefined ? value.savedAt : value.dineInSavedAt;
      const deliveryAt: number = value.deliverySavedAt === undefined ? value.savedAt : value.deliverySavedAt;
      if (!Number.isSafeInteger(dineAt) || dineAt > now || now - dineAt > RETENTION) value.dineInAvg = '';
      if (!Number.isSafeInteger(deliveryAt) || deliveryAt > now || now - deliveryAt > RETENTION) {
        value.orderTotal = ''; value.deliveryFee = ''; value.platformKey = ''; value.platformLabel = ''; value.consumedDate = '';
      }
      return value;
    } catch (_error) { store.deleteSync(key); store.flushSync(); return undefined; }
  }
  static save(context: common.Context, uid: string, cardId: string, fields: ModeFields, mode: FoodConsumptionMode): void {
    if (uid.length === 0 || mode === 'UNSPECIFIED') return;
    const previous: ModeFields | undefined = ModeFieldCache.read(context, uid, cardId);
    const merged: ModeFields = previous === undefined ? { savedAt: 0, dineInSavedAt: 0, deliverySavedAt: 0,
      dineInAvg: '', orderTotal: '', deliveryFee: '', platformKey: '', platformLabel: '', consumedDate: '' } : previous;
    if (merged.dineInSavedAt === undefined) merged.dineInSavedAt = merged.savedAt;
    if (merged.deliverySavedAt === undefined) merged.deliverySavedAt = merged.savedAt;
    if (mode === 'DINE_IN') { merged.dineInAvg = fields.dineInAvg; merged.dineInSavedAt = fields.savedAt; }
    else {
      merged.orderTotal = fields.orderTotal; merged.deliveryFee = fields.deliveryFee; merged.platformKey = fields.platformKey;
      merged.platformLabel = fields.platformLabel; merged.consumedDate = fields.consumedDate; merged.deliverySavedAt = fields.savedAt;
    }
    merged.savedAt = fields.savedAt;
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: STORE_NAME });
    store.putSync(uid + ':' + (cardId.length > 0 ? cardId : 'new'), JSON.stringify(merged));
    store.flushSync();
  }
  static clear(context: common.Context, uid: string, cardId: string): void {
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: STORE_NAME });
    store.deleteSync(uid + ':' + (cardId.length > 0 ? cardId : 'new')); store.flushSync();
  }
  static clearAccount(context: common.Context, uid: string): void {
    if (uid.length === 0) return;
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: STORE_NAME });
    const entries: Record<string, preferences.ValueType> =
      store.getAllSync() as Record<string, preferences.ValueType>;
    for (const key of Object.keys(entries)) {
      if (key.startsWith(uid + ':')) store.deleteSync(key);
    }
    store.flushSync();
  }
}
