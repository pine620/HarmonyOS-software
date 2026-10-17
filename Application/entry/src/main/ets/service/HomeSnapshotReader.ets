import { cloudResPrefetch, cloudStorage } from '@kit.CloudFoundationKit';
import { http } from '@kit.NetworkKit';
import { NearbyCardsResponse, PublicCardsRequest } from '../model/CloudContracts';
import { HOME_SNAPSHOT_BUCKET, HOME_SNAPSHOT_ENABLED } from './ImageReadConfig';

/**
 * 【文件职责】游客首页快照读取。云端定时器每 5 分钟把游客首页第一页渲染成 public/snapshot/home-v1.json；
 * 游客冷启动时优先从 Cloud Foundation 预取结果读取（每个进程只读一次），否则直接从 Cloud Storage 读取，
 * 因此冷启动首页不需要调用云函数，也不消耗 Cloud DB 读额度。
 * 任何问题（安全规则缺失、定时器没跑、JSON 格式不对、快照超过 15 分钟）都返回 undefined，调用方改用 list-nearby-cards。
 */
// 快照路径、版本号、最长有效期（15 分钟）、读取超时、连续失败次数上限与暂停时长。
const SNAPSHOT_PATH: string = 'public/snapshot/home-v1.json';
const SNAPSHOT_VERSION: string = 'home-snapshot-v1';
const MAX_AGE_MS: number = 15 * 60 * 1000;
const TIMEOUT_MS: number = 4000;
const FAILURES_BEFORE_PAUSE: number = 2;
const PAUSE_MS: number = 10 * 60 * 1000;

// 快照文件格式：版本 + 生成时间 + 与 list-nearby-cards 相同结构的数据。
interface HomeSnapshot {
  version: string;
  generatedAt: number;
  data: NearbyCardsResponse;
}

// 预取函数 shike-prefetch 的返回格式。
interface PrefetchEnvelope {
  ok?: boolean;
  version?: string;
  data?: HomeSnapshot;
}

// 首页快照读取（静态类）。
export class HomeSnapshotReader {
  // 是否已检查过预取结果、连续失败次数与暂停截止时间。
  private static prefetchChecked: boolean = false;
  private static failures: number = 0;
  private static pausedUntil: number = 0;

  // 只有与快照生成时完全相同的“首页第一页”请求才能使用快照。
  static matches(request: PublicCardsRequest): boolean {
    return HOME_SNAPSHOT_ENABLED && request.scope === 'all' && request.category === 'all' &&
      request.pageToken.length === 0 && request.pageSize === 6;
  }

  // 读取快照：先预取结果，再 Cloud Storage；返回可直接使用的推荐列表，或 undefined。
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

  // 校验快照格式与新鲜度（生成时间在 15 分钟内，允许 1 分钟时钟偏差）。
  private static fresh(value: HomeSnapshot | undefined): NearbyCardsResponse | undefined {
    if (value === undefined || value === null || value.version !== SNAPSHOT_VERSION) return undefined;
    if (typeof value.generatedAt !== 'number' || value.data === undefined || value.data === null) return undefined;
    if (!Array.isArray(value.data.cards) || typeof value.data.nextPageToken !== 'string') return undefined;
    const age: number = Date.now() - value.generatedAt;
    if (age < -60000 || age > MAX_AGE_MS) return undefined;
    return value.data;
  }

  // 读取 Cloud Foundation 预取到的快照（每个进程只尝试一次）。
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
        // 没有配置预取或尚未预取到：大多数启动都是这种情况，属于正常。
      }
    }
    return undefined;
  }

  // 直接从 Cloud Storage 下载快照文件（4 秒超时）；连续失败 2 次后暂停 10 分钟。
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

// 游客每个进程注册一次周期预取；已登录用户的页面永远不使用快照。
export function registerHomeSnapshotPrefetch(): void {
  if (!HOME_SNAPSHOT_ENABLED || !canIUse('SystemCapability.DeviceCloudGateway.CloudResPrefetch')) return;
  try {
    cloudResPrefetch.registerPrefetchTask({});
  } catch (error) {
    console.warn('[HomeSnapshot] event=prefetch-register-failed');
  }
}
