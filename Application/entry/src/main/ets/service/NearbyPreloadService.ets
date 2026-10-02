import { common } from '@kit.AbilityKit';
import { NearbyCardsRequest, NearbyCardsResponse, RoundedLocation, UserProfile } from '../model/CloudContracts';
import { CardRepository } from '../repository/CardRepository';
import { AuthService } from './AuthService';
import { CloudGateway } from './CloudGateway';
import { LocationService } from './LocationService';
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
  generation: number;
}

/** A short-lived, memory-only nearby result shared by app startup and the page. */
export interface NearbySnapshot {
  location: RoundedLocation;
  response: NearbyCardsResponse;
  fetchedAt: number;
  stale?: boolean;
}

function recoverableListFailure(error: Error): boolean {
  return /network|timeout|timed out|网络连接|连接失败|请求超时|3007009/i.test(error.message);
}

/**
 * Prepares nearby content after the user has already consented and granted
 * location. It never requests permission, persists a location, or schedules
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
    LocationService.clearCachedRoundedLocation();
  }

  private static captureScope(): NearbyRequestScope {
    const profile: UserProfile | undefined = AuthService.profile();
    if (profile === undefined || !CloudGateway.hasSession()) throw new Error('请先登录后加载附近推荐。');
    if (NearbyPreloadService.cacheOwner !== profile.uid) {
      NearbyPreloadService.clear();
      NearbyPreloadService.cacheOwner = profile.uid;
    }
    return { uid: profile.uid, generation: NearbyPreloadService.scopeGeneration };
  }

  private static isCurrentScope(scope: NearbyRequestScope): boolean {
    const profile: UserProfile | undefined = AuthService.profile();
    return scope.generation === NearbyPreloadService.scopeGeneration &&
      CloudGateway.hasSession() && profile !== undefined && profile.uid === scope.uid;
  }

  private static async ensureEligible(context: common.UIAbilityContext, scope: NearbyRequestScope,
    requireLocation: boolean = true, invalidateOnDenial: boolean = true): Promise<void> {
    if (!NearbyPreloadService.isCurrentScope(scope)) throw new Error('附近请求已失效。');
    const consent: boolean = await PrivacyStore.hasConsent(context);
    const locationAllowed: boolean = !requireLocation || await LocationService.hasFullLocationPermission(context);
    if (!NearbyPreloadService.isCurrentScope(scope)) throw new Error('附近请求已失效。');
    if (!consent || !locationAllowed) {
      if (invalidateOnDenial) NearbyPreloadService.clear();
      throw new Error(!consent ? '请先同意隐私协议。' : '定位权限未完整授权。');
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

  private static staleSnapshotFor(location: RoundedLocation): NearbySnapshot | undefined {
    const cached: NearbySnapshot | undefined = NearbyPreloadService.snapshotCache;
    if (cached === undefined || cached.fetchedAt + NEARBY_SNAPSHOT_STALE_MS <= Date.now() ||
      cached.location.latE3 !== location.latE3 || cached.location.lonE3 !== location.lonE3) return undefined;
    return { location: cached.location, response: cached.response, fetchedAt: cached.fetchedAt, stale: true };
  }

  private static nextPageRequestKeyFor(location: RoundedLocation, pageToken: string): string {
    return location.latE3.toString() + ':' + location.lonE3.toString() + ':' + pageToken;
  }

  private static async requestSnapshot(context: common.UIAbilityContext,
    forceRefresh: boolean, scope: NearbyRequestScope, requestPermission: boolean): Promise<NearbySnapshot> {
    const generation: number = NearbyPreloadService.cacheGeneration;
    const traceTaskId: number = NearbyPerformanceTrace.start('shike.nearby.snapshot_load');
    try {
      const location: RoundedLocation = await LocationService.getPreciseRoundedLocationFast(
        context, forceRefresh, requestPermission);
      await NearbyPreloadService.ensureEligible(context, scope);
      const request: NearbyCardsRequest = {
        latE3: location.latE3,
        lonE3: location.lonE3,
        pageToken: '',
        pageSize: NEARBY_PAGE_SIZE
      };
      let response: NearbyCardsResponse;
      try {
        response = await NearbyPreloadService.repository.listNearbyMetadata(context, request,
          (): boolean => NearbyPreloadService.isCurrentScope(scope));
      } catch (error) {
        await NearbyPreloadService.ensureEligible(context, scope);
        const stale: NearbySnapshot | undefined = !forceRefresh && generation === NearbyPreloadService.cacheGeneration &&
          error instanceof Error && recoverableListFailure(error) ? NearbyPreloadService.staleSnapshotFor(location) : undefined;
        if (stale !== undefined) {
          NearbyPerformanceTrace.record('snapshot', 'stale');
          return stale;
        }
        if (error instanceof Error) throw error;
        throw new Error('附近推荐加载失败。');
      }
      await NearbyPreloadService.ensureEligible(context, scope);
      if (generation !== NearbyPreloadService.cacheGeneration) throw new Error('附近请求已失效。');
      const snapshot: NearbySnapshot = { location, response, fetchedAt: Date.now() };
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
    requestPermission: boolean = true): Promise<NearbySnapshot> {
    const scope: NearbyRequestScope = NearbyPreloadService.captureScope();
    await NearbyPreloadService.ensureEligible(context, scope, false);
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
    if (!NearbyPreloadService.isCurrentScope(scope)) throw new Error('附近请求已失效。');
    NearbyPerformanceTrace.record('snapshot', 'miss');
    const request: Promise<NearbySnapshot> = NearbyPreloadService.requestSnapshot(
      context, forceRefresh, scope, requestPermission);
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
      // An ineligible startup warm-up must not cancel a visible permission prompt.
      await NearbyPreloadService.ensureEligible(context, scope, true, false);
      const snapshot: NearbySnapshot = await NearbyPreloadService.load(context, false, false);
      await NearbyPreloadService.ensureEligible(context, scope);
      await NearbyPreloadService.repository.hydrateNearbyPrimaryPhotoUrls(
        context, snapshot.response.cards, 0, NEARBY_PRELOAD_PRIMARY_PHOTO_COUNT, 'high',
        NearbyPreloadService.createMediaGuard(context));
    } catch (_error) {
      // Preloading is optional. The visible nearby page retains its error path.
    }
  }

  private static async requestNextPage(context: common.UIAbilityContext, location: RoundedLocation,
    pageToken: string, requestKey: string, scope: NearbyRequestScope): Promise<NearbyCardsResponse> {
    const generation: number = NearbyPreloadService.cacheGeneration;
    const traceTaskId: number = NearbyPerformanceTrace.start('shike.nearby.next_page_prefetch');
    try {
      const request: NearbyCardsRequest = {
        latE3: location.latE3,
        lonE3: location.lonE3,
        pageToken,
        pageSize: NEARBY_PAGE_SIZE
      };
      const response: NearbyCardsResponse = await NearbyPreloadService.repository.listNearbyMetadata(context, request,
        (): boolean => NearbyPreloadService.isCurrentScope(scope));
      await NearbyPreloadService.ensureEligible(context, scope);
      if (generation !== NearbyPreloadService.cacheGeneration) throw new Error('附近请求已失效。');
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

  static async loadNextPage(context: common.UIAbilityContext, location: RoundedLocation,
    pageToken: string): Promise<NearbyCardsResponse> {
    const scope: NearbyRequestScope = NearbyPreloadService.captureScope();
    await NearbyPreloadService.ensureEligible(context, scope);
    const requestKey: string = NearbyPreloadService.nextPageRequestKeyFor(location, pageToken);
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
      context, location, pageToken, requestKey, scope);
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

  static prefetchNextPage(context: common.UIAbilityContext, location: RoundedLocation, pageToken: string): void {
    if (pageToken.length === 0) return;
    void NearbyPreloadService.loadNextPage(context, location, pageToken).catch((): void => {});
  }
}
