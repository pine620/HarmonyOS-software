import { common } from '@kit.AbilityKit';
import { PublicCardsRequest, NearbyCardsResponse, UserProfile } from '../model/CloudContracts';
import { CardRepository } from '../repository/CardRepository';
import { AuthService } from './AuthService';
import { CloudGateway } from './CloudGateway';
import { NearbyPerformanceTrace } from './NearbyPerformanceTrace';
import { PrivacyStore } from './PrivacyStore';
import { MediaRequestGuard } from './PhotoUploadService';

const NEARBY_SNAPSHOT_FRESH_MS: number = 45 * 1000;
const NEARBY_SNAPSHOT_STALE_MS: number = 5 * 60 * 1000;
const NEARBY_PREFETCH_CACHE_TTL_MS: number = 45 * 1000;
const NEARBY_PAGE_SIZE: number = 20;
const NEARBY_PRELOAD_PRIMARY_PHOTO_COUNT: number = 2;

interface NextPageCacheEntry {
  requestKey: string;
  response: NearbyCardsResponse;
  expiresAt: number;
}

interface NearbyRequestScope {
  uid: string;
  category: string;
  generation: number;
}

/** A short-lived public feed snapshot shared by app startup and the page. */
export interface NearbySnapshot {
  category: string;
  response: NearbyCardsResponse;
  fetchedAt: number;
  stale?: boolean;
}

function recoverableListFailure(error: Error): boolean {
  return /network|timeout|timed out|网络连接|连接失败|请求超时|3007009/i.test(error.message);
}

/**
 * Prepares all public recommendations after privacy consent. It never
 * requests location permission, persists coordinates, or schedules
 * periodic or background work.
 */
export class NearbyPreloadService {
  private static repository: CardRepository = new CardRepository();
  private static snapshotCache: NearbySnapshot | undefined = undefined;
  private static snapshotCacheExpiryTimer: number | undefined = undefined;
  private static snapshotRequest: Promise<NearbySnapshot> | undefined = undefined;
  private static nextPageCache: NextPageCacheEntry | undefined = undefined;
  private static nextPageCacheExpiryTimer: number | undefined = undefined;
  private static nextPageRequest: Promise<NearbyCardsResponse> | undefined = undefined;
  private static nextPageRequestKey: string = '';
  private static warmRequest: Promise<void> | undefined = undefined;
  private static cacheGeneration: number = 0;
  private static scopeGeneration: number = 0;
  private static cacheOwner: string = '';
  private static cacheCategory: string = 'all';

  static invalidate(): void {
    NearbyPreloadService.cacheGeneration += 1;
    NearbyPreloadService.scopeGeneration += 1;
    NearbyPreloadService.warmRequest = undefined;
    NearbyPreloadService.clearSnapshotCache();
    NearbyPreloadService.snapshotRequest = undefined;
    NearbyPreloadService.clearNextPageCache();
    NearbyPreloadService.nextPageRequest = undefined;
    NearbyPreloadService.nextPageRequestKey = '';
  }

  static clear(): void {
    NearbyPreloadService.invalidate();
    NearbyPreloadService.cacheOwner = '';
  }

  private static viewerScopeId(): string {
    const profile: UserProfile | undefined = AuthService.profile();
    return profile !== undefined && CloudGateway.hasSession() ? profile.uid : 'guest';
  }

  private static captureScope(category: string = NearbyPreloadService.cacheCategory): NearbyRequestScope {
    const uid: string = NearbyPreloadService.viewerScopeId();
    if (NearbyPreloadService.cacheOwner !== uid || NearbyPreloadService.cacheCategory !== category) {
      NearbyPreloadService.clear();
      NearbyPreloadService.cacheOwner = uid;
      NearbyPreloadService.cacheCategory = category;
    }
    return { uid, category, generation: NearbyPreloadService.scopeGeneration };
  }

  private static isCurrentScope(scope: NearbyRequestScope): boolean {
    return scope.generation === NearbyPreloadService.scopeGeneration &&
      scope.uid === NearbyPreloadService.viewerScopeId() && scope.category === NearbyPreloadService.cacheCategory;
  }

  private static async ensureEligible(context: common.UIAbilityContext, scope: NearbyRequestScope): Promise<void> {
    if (!NearbyPreloadService.isCurrentScope(scope)) throw new Error('推荐请求已失效。');
    const consent: boolean = await PrivacyStore.hasConsent(context);
    if (!NearbyPreloadService.isCurrentScope(scope)) throw new Error('推荐请求已失效。');
    if (!consent) {
      NearbyPreloadService.clear();
      throw new Error('请先同意隐私协议。');
    }
  }

  static createMediaGuard(context: common.UIAbilityContext): MediaRequestGuard {
    const scope: NearbyRequestScope = NearbyPreloadService.captureScope();
    return async (): Promise<boolean> => {
      try {
        await NearbyPreloadService.ensureEligible(context, scope);
        return true;
      } catch (_error) {
        return false;
      }
    };
  }

  private static clearSnapshotCache(): void {
    NearbyPreloadService.snapshotCache = undefined;
    if (NearbyPreloadService.snapshotCacheExpiryTimer !== undefined) {
      clearTimeout(NearbyPreloadService.snapshotCacheExpiryTimer);
      NearbyPreloadService.snapshotCacheExpiryTimer = undefined;
    }
  }

  private static cacheSnapshot(snapshot: NearbySnapshot): void {
    NearbyPreloadService.clearSnapshotCache();
    NearbyPreloadService.snapshotCache = snapshot;
    NearbyPreloadService.snapshotCacheExpiryTimer = setTimeout((): void => {
      if (NearbyPreloadService.snapshotCache === snapshot) {
        NearbyPreloadService.snapshotCache = undefined;
        NearbyPreloadService.snapshotCacheExpiryTimer = undefined;
      }
    }, NEARBY_SNAPSHOT_STALE_MS);
  }

  private static clearNextPageCache(): void {
    NearbyPreloadService.nextPageCache = undefined;
    if (NearbyPreloadService.nextPageCacheExpiryTimer !== undefined) {
      clearTimeout(NearbyPreloadService.nextPageCacheExpiryTimer);
      NearbyPreloadService.nextPageCacheExpiryTimer = undefined;
    }
  }

  private static cacheNextPage(entry: NextPageCacheEntry): void {
    NearbyPreloadService.clearNextPageCache();
    NearbyPreloadService.nextPageCache = entry;
    NearbyPreloadService.nextPageCacheExpiryTimer = setTimeout((): void => {
      if (NearbyPreloadService.nextPageCache === entry) {
        NearbyPreloadService.nextPageCache = undefined;
        NearbyPreloadService.nextPageCacheExpiryTimer = undefined;
      }
    }, NEARBY_PREFETCH_CACHE_TTL_MS);
  }

  private static freshSnapshot(): NearbySnapshot | undefined {
    const cached: NearbySnapshot | undefined = NearbyPreloadService.snapshotCache;
    if (cached === undefined) return undefined;
    if (cached.fetchedAt + NEARBY_SNAPSHOT_FRESH_MS > Date.now()) return cached;
    if (cached.fetchedAt + NEARBY_SNAPSHOT_STALE_MS <= Date.now()) {
      NearbyPreloadService.clearSnapshotCache();
    }
    return undefined;
  }

  private static staleSnapshotFor(category: string): NearbySnapshot | undefined {
    const cached: NearbySnapshot | undefined = NearbyPreloadService.snapshotCache;
    if (cached === undefined || cached.fetchedAt + NEARBY_SNAPSHOT_STALE_MS <= Date.now() ||
      cached.category !== category) return undefined;
    return { category: cached.category, response: cached.response, fetchedAt: cached.fetchedAt, stale: true };
  }

  private static nextPageRequestKeyFor(category: string, pageToken: string): string {
    return category + ':' + pageToken;
  }

  private static async requestSnapshot(context: common.UIAbilityContext,
    forceRefresh: boolean, scope: NearbyRequestScope): Promise<NearbySnapshot> {
    const generation: number = NearbyPreloadService.cacheGeneration;
    const traceTaskId: number = NearbyPerformanceTrace.start('shike.nearby.snapshot_load');
    try {
      await NearbyPreloadService.ensureEligible(context, scope);
      const request: PublicCardsRequest = {
        scope: 'all',
        category: scope.category,
        pageToken: '',
        pageSize: NEARBY_PAGE_SIZE
      };
      let response: NearbyCardsResponse;
      try {
        response = await NearbyPreloadService.repository.listRecommendationsMetadata(request,
          (): boolean => NearbyPreloadService.isCurrentScope(scope));
      } catch (error) {
        await NearbyPreloadService.ensureEligible(context, scope);
        const stale: NearbySnapshot | undefined = !forceRefresh && generation === NearbyPreloadService.cacheGeneration &&
          error instanceof Error && recoverableListFailure(error) ? NearbyPreloadService.staleSnapshotFor(scope.category) : undefined;
        if (stale !== undefined) {
          NearbyPerformanceTrace.record('snapshot', 'stale');
          return stale;
        }
        if (error instanceof Error) throw error;
        throw new Error('推荐加载失败。');
      }
      await NearbyPreloadService.ensureEligible(context, scope);
      if (generation !== NearbyPreloadService.cacheGeneration) throw new Error('推荐请求已失效。');
      const snapshot: NearbySnapshot = { category: scope.category, response, fetchedAt: Date.now() };
      if (generation === NearbyPreloadService.cacheGeneration) {
        NearbyPreloadService.cacheSnapshot(snapshot);
        NearbyPreloadService.clearNextPageCache();
        NearbyPreloadService.nextPageRequest = undefined;
        NearbyPreloadService.nextPageRequestKey = '';
        NearbyPreloadService.cacheGeneration += 1;
      }
      return snapshot;
    } finally {
      NearbyPerformanceTrace.finish('shike.nearby.snapshot_load', traceTaskId);
    }
  }

  static async load(context: common.UIAbilityContext, forceRefresh: boolean = false,
    category: string = 'all'): Promise<NearbySnapshot> {
    const scope: NearbyRequestScope = NearbyPreloadService.captureScope(category);
    await NearbyPreloadService.ensureEligible(context, scope);
    const cached: NearbySnapshot | undefined = NearbyPreloadService.freshSnapshot();
    if (!forceRefresh && cached !== undefined) {
      await NearbyPreloadService.ensureEligible(context, scope);
      NearbyPerformanceTrace.record('snapshot', 'hit');
      return cached;
    }
    const inFlight: Promise<NearbySnapshot> | undefined = NearbyPreloadService.snapshotRequest;
    if (inFlight !== undefined) {
      if (!forceRefresh) {
        const snapshot: NearbySnapshot = await inFlight;
        await NearbyPreloadService.ensureEligible(context, scope);
        NearbyPerformanceTrace.record('snapshot', 'joined');
        return snapshot;
      }
      try {
        await inFlight;
      } catch (_error) {
        // Manual refresh must still make a new request.
      }
    }
    if (!NearbyPreloadService.isCurrentScope(scope)) throw new Error('推荐请求已失效。');
    NearbyPerformanceTrace.record('snapshot', 'miss');
    const request: Promise<NearbySnapshot> = NearbyPreloadService.requestSnapshot(
      context, forceRefresh, scope);
    NearbyPreloadService.snapshotRequest = request;
    try {
      return await request;
    } finally {
      if (NearbyPreloadService.snapshotRequest === request) {
        NearbyPreloadService.snapshotRequest = undefined;
      }
    }
  }

  static async warmIfEligible(context: common.UIAbilityContext): Promise<void> {
    const inFlight: Promise<void> | undefined = NearbyPreloadService.warmRequest;
    if (inFlight !== undefined) {
      await inFlight;
      return;
    }
    const request: Promise<void> = NearbyPreloadService.warmNearbyIfEligible(context);
    NearbyPreloadService.warmRequest = request;
    try {
      await request;
    } finally {
      if (NearbyPreloadService.warmRequest === request) {
        NearbyPreloadService.warmRequest = undefined;
      }
    }
  }

  private static async warmNearbyIfEligible(context: common.UIAbilityContext): Promise<void> {
    try {
      const scope: NearbyRequestScope = NearbyPreloadService.captureScope();
      await NearbyPreloadService.ensureEligible(context, scope);
      const snapshot: NearbySnapshot = await NearbyPreloadService.load(context, false, scope.category);
      await NearbyPreloadService.ensureEligible(context, scope);
      await NearbyPreloadService.repository.hydrateNearbyPrimaryPhotoUrls(
        context, snapshot.response.cards, 0, NEARBY_PRELOAD_PRIMARY_PHOTO_COUNT, 'high',
        NearbyPreloadService.createMediaGuard(context));
    } catch (_error) {
      // Preloading is optional. The visible nearby page retains its error path.
    }
  }

  private static async requestNextPage(context: common.UIAbilityContext,
    pageToken: string, requestKey: string, scope: NearbyRequestScope): Promise<NearbyCardsResponse> {
    const generation: number = NearbyPreloadService.cacheGeneration;
    const traceTaskId: number = NearbyPerformanceTrace.start('shike.nearby.next_page_prefetch');
    try {
      const request: PublicCardsRequest = {
        scope: 'all',
        category: scope.category,
        pageToken,
        pageSize: NEARBY_PAGE_SIZE
      };
      const response: NearbyCardsResponse = await NearbyPreloadService.repository.listRecommendationsMetadata(request,
        (): boolean => NearbyPreloadService.isCurrentScope(scope));
      await NearbyPreloadService.ensureEligible(context, scope);
      if (generation !== NearbyPreloadService.cacheGeneration) throw new Error('推荐请求已失效。');
      if (generation === NearbyPreloadService.cacheGeneration) {
        const entry: NextPageCacheEntry = {
          requestKey,
          response,
          expiresAt: Date.now() + NEARBY_PREFETCH_CACHE_TTL_MS
        };
        NearbyPreloadService.cacheNextPage(entry);
      }
      return response;
    } finally {
      NearbyPerformanceTrace.finish('shike.nearby.next_page_prefetch', traceTaskId);
    }
  }

  static async loadNextPage(context: common.UIAbilityContext, category: string,
    pageToken: string): Promise<NearbyCardsResponse> {
    const scope: NearbyRequestScope = NearbyPreloadService.captureScope(category);
    await NearbyPreloadService.ensureEligible(context, scope);
    const requestKey: string = NearbyPreloadService.nextPageRequestKeyFor(category, pageToken);
    const cached: NextPageCacheEntry | undefined = NearbyPreloadService.nextPageCache;
    if (cached !== undefined && cached.requestKey === requestKey && cached.expiresAt > Date.now()) {
      NearbyPerformanceTrace.record('next_page', 'hit');
      return cached.response;
    }
    const inFlight: Promise<NearbyCardsResponse> | undefined = NearbyPreloadService.nextPageRequest;
    if (inFlight !== undefined && NearbyPreloadService.nextPageRequestKey === requestKey) {
      const response: NearbyCardsResponse = await inFlight;
      await NearbyPreloadService.ensureEligible(context, scope);
      NearbyPerformanceTrace.record('next_page', 'joined');
      return response;
    }
    NearbyPerformanceTrace.record('next_page', 'miss');
    const request: Promise<NearbyCardsResponse> = NearbyPreloadService.requestNextPage(
      context, pageToken, requestKey, scope);
    NearbyPreloadService.nextPageRequest = request;
    NearbyPreloadService.nextPageRequestKey = requestKey;
    try {
      return await request;
    } finally {
      if (NearbyPreloadService.nextPageRequest === request) {
        NearbyPreloadService.nextPageRequest = undefined;
        NearbyPreloadService.nextPageRequestKey = '';
      }
    }
  }

  static prefetchNextPage(context: common.UIAbilityContext, category: string, pageToken: string): void {
    if (pageToken.length === 0) return;
    void NearbyPreloadService.loadNextPage(context, category, pageToken).catch((): void => {});
  }
}
