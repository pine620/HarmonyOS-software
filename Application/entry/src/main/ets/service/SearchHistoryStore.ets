import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { normalizeSearch } from '../model/DiscoveryModels';

export class SearchHistoryStore {
  static read(context: common.Context, uid: string): Array<string> {
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: 'shike_search_history' });
    const raw: preferences.ValueType = store.getSync('search_history_' + uid, '');
    if (typeof raw !== 'string' || raw.length === 0 || raw.length > 16384) return [];
    try {
      const values: Array<string> = JSON.parse(raw) as Array<string>;
      if (!Array.isArray(values)) return [];
      const result: Array<string> = [];
      for (const value of values) {
        if (typeof value !== 'string') continue;
        const normalized: string = normalizeSearch(value);
        if (normalized.length > 0 && normalized.length <= 50 && !result.includes(normalized)) result.push(normalized);
        if (result.length === 20) break;
      }
      return result;
    } catch (_error) { return []; }
  }
  static record(context: common.Context, uid: string, keyword: string): Array<string> {
    const normalized: string = normalizeSearch(keyword);
    if (normalized.length === 0 || normalized.length > 50) return SearchHistoryStore.read(context, uid);
    const values: Array<string> = SearchHistoryStore.read(context, uid).filter((value: string): boolean => value !== normalized);
    values.unshift(normalized);
    const limited: Array<string> = values.slice(0, 20);
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: 'shike_search_history' });
    store.putSync('search_history_' + uid, JSON.stringify(limited)); store.flushSync();
    return limited;
  }
  static clear(context: common.Context, uid: string): void {
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: 'shike_search_history' });
    store.deleteSync('search_history_' + uid); store.flushSync();
  }
}
