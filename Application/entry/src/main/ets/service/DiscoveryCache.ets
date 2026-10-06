import { DiscoveryCardPage, PublicCardQuery } from '../model/DiscoveryModels';

interface DiscoveryCacheEntry { key: string; page: DiscoveryCardPage; expiresAt: number; }
/** Short-lived data only. Every page opening rechecks server capabilities. */
export class DiscoveryCache {
  private static entries: Array<DiscoveryCacheEntry> = [];
  static key(uid: string, query: PublicCardQuery): string { return uid + ':' + JSON.stringify(query); }
  static read(uid: string, query: PublicCardQuery): DiscoveryCardPage | undefined {
    const key: string = DiscoveryCache.key(uid, query);
    const entry: DiscoveryCacheEntry | undefined = DiscoveryCache.entries.find((value: DiscoveryCacheEntry): boolean => value.key === key && value.expiresAt > Date.now());
    return entry === undefined ? undefined : entry.page;
  }
  static save(uid: string, query: PublicCardQuery, page: DiscoveryCardPage): void {
    const key: string = DiscoveryCache.key(uid, query);
    DiscoveryCache.entries = DiscoveryCache.entries.filter((entry: DiscoveryCacheEntry): boolean => entry.key !== key && entry.expiresAt > Date.now());
    const entry: DiscoveryCacheEntry = { key, page, expiresAt: Date.now() + 30000 };
    DiscoveryCache.entries.push(entry);
    if (DiscoveryCache.entries.length > 6) DiscoveryCache.entries.shift();
  }
  static clear(): void { DiscoveryCache.entries = []; }
}
