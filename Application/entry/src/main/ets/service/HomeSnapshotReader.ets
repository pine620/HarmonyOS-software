import { cloudResPrefetch, cloudStorage } from '@kit.CloudFoundationKit';
import { http } from '@kit.NetworkKit';
import { NearbyCardsResponse, PublicCardsRequest } from '../model/CloudContracts';
import { HOME_SNAPSHOT_BUCKET, HOME_SNAPSHOT_ENABLED } from './ImageReadConfig';

// Pack 4.1 (2026-10-15): a timer renders the guest first page every 5 minutes into
// public/snapshot/home-v1.json. Guests read it from the Cloud Foundation Kit prefetch result (first call of the
// process only) or straight from Cloud Storage, so the cold-start feed needs no cloud function or Cloud DB read.
// Any problem (missing rule, old timer, bad JSON) returns undefined and the caller uses list-nearby-cards.
const SNAPSHOT_PATH: string = 'public/snapshot/home-v1.json';
const SNAPSHOT_VERSION: string = 'home-snapshot-v1';
const MAX_AGE_MS: number = 15 * 60 * 1000;
const TIMEOUT_MS: number = 4000;
const FAILURES_BEFORE_PAUSE: number = 2;
const PAUSE_MS: number = 10 * 60 * 1000;

interface HomeSnapshot {
  version: string;
  generatedAt: number;
  data: NearbyCardsResponse;
}

interface PrefetchEnvelope {
  ok?: boolean;
  version?: string;
  data?: HomeSnapshot;
}

export class HomeSnapshotReader {
  private static prefetchChecked: boolean = false;
  private static failures: number = 0;
  private static pausedUntil: number = 0;

  // Only the exact first page the snapshot was rendered for.
  static matches(request: PublicCardsRequest): boolean {
    return HOME_SNAPSHOT_ENABLED && request.scope === 'all' && request.category === 'all' &&
      request.pageToken.length === 0 && request.pageSize === 6;
  }

  static async read(): Promise<NearbyCardsResponse | undefined> {
    const prefetched: NearbyCardsResponse | undefined = await HomeSnapshotReader.fromPrefetch();
    if (prefetched !== undefined) return prefetched;
    if (Date.now() < HomeSnapshotReader.pausedUntil) return undefined;
    try {
      const snapshot: NearbyCardsResponse | undefined = await HomeSnapshotReader.fromStorage();
      HomeSnapshotReader.failures = 0;
      return snapshot;
    } catch (error) {
      HomeSnapshotReader.failures++;
      if (HomeSnapshotReader.failures >= FAILURES_BEFORE_PAUSE) {
        HomeSnapshotReader.failures = 0;
        HomeSnapshotReader.pausedUntil = Date.now() + PAUSE_MS;
      }
      console.warn('[HomeSnapshot] event=storage-read-failed message=' + (error as Error).message);
      return undefined;
    }
  }

  private static fresh(value: HomeSnapshot | undefined): NearbyCardsResponse | undefined {
    if (value === undefined || value === null || value.version !== SNAPSHOT_VERSION) return undefined;
    if (typeof value.generatedAt !== 'number' || value.data === undefined || value.data === null) return undefined;
    if (!Array.isArray(value.data.cards) || typeof value.data.nextPageToken !== 'string') return undefined;
    const age: number = Date.now() - value.generatedAt;
    if (age < -60000 || age > MAX_AGE_MS) return undefined;
    return value.data;
  }

  private static async fromPrefetch(): Promise<NearbyCardsResponse | undefined> {
    if (HomeSnapshotReader.prefetchChecked) return undefined;
    HomeSnapshotReader.prefetchChecked = true;
    if (!canIUse('SystemCapability.DeviceCloudGateway.CloudResPrefetch')) return undefined;
    const modes: Array<cloudResPrefetch.PrefetchMode> = [cloudResPrefetch.PrefetchMode.PERIODIC_PREFETCH,
      cloudResPrefetch.PrefetchMode.INSTALL_PREFETCH];
    for (const mode of modes) {
      try {
        const result: cloudResPrefetch.PrefetchResult = await cloudResPrefetch.getPrefetchResult(mode);
        const raw: Object = typeof result.result === 'string' ? JSON.parse(result.result as string) as Object : result.result as Object;
        const envelope: PrefetchEnvelope = raw as PrefetchEnvelope;
        const snapshot: HomeSnapshot | undefined = envelope.version === SNAPSHOT_VERSION ? raw as HomeSnapshot
          : (envelope.ok === true ? envelope.data : undefined);
        const data: NearbyCardsResponse | undefined = HomeSnapshotReader.fresh(snapshot);
        if (data !== undefined) {
          console.info('[HomeSnapshot] event=prefetch-hit mode=' + mode);
          return data;
        }
      } catch (_error) {
        // No prefetch configured / not yet fetched: normal on most launches.
      }
    }
    return undefined;
  }

  private static async fromStorage(): Promise<NearbyCardsResponse | undefined> {
    const storage: cloudStorage.StorageBucket = HOME_SNAPSHOT_BUCKET.length > 0 ?
      cloudStorage.bucket(HOME_SNAPSHOT_BUCKET) : cloudStorage.bucket();
    const url: string = await storage.getDownloadURL(SNAPSHOT_PATH);
    if (!url.startsWith('https://')) throw new Error('快照地址无效。');
    const client: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET, expectDataType: http.HttpDataType.STRING,
        connectTimeout: TIMEOUT_MS, readTimeout: TIMEOUT_MS
      };
      const response: http.HttpResponse = await client.request(url, options);
      if (response.responseCode !== 200 || typeof response.result !== 'string') throw new Error('快照读取失败。');
      const data: NearbyCardsResponse | undefined = HomeSnapshotReader.fresh(JSON.parse(response.result as string) as HomeSnapshot);
      if (data === undefined) console.warn('[HomeSnapshot] event=stale-or-invalid');
      return data;
    } finally {
      client.destroy();
    }
  }
}

// Periodic prefetch is registered once per process for guests; logged-in pages never use the snapshot.
export function registerHomeSnapshotPrefetch(): void {
  if (!HOME_SNAPSHOT_ENABLED || !canIUse('SystemCapability.DeviceCloudGateway.CloudResPrefetch')) return;
  try {
    cloudResPrefetch.registerPrefetchTask({});
  } catch (error) {
    console.warn('[HomeSnapshot] event=prefetch-register-failed');
  }
}
