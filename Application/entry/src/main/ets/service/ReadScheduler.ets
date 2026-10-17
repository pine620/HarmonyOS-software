/**
 * 【文件职责】全局读请求调度器（每个 App 进程一个）。CloudGateway 把所有 get-/list-/search- 读请求和批量读图交给它。
 * 【它解决的问题】免费档 Cloud DB 只有约 10 次/秒、5 万次/天的读额度，页面又经常同时发出很多读请求，所以需要：
 *   1. 合并：同一账号、同一会话、同一操作 + 同一参数的并发请求只真正发一次，其余共享结果；
 *   2. 排队与优先级：metadata（列表/详情文字）> cover（封面）> secondary（次要数据）> prefetch（预取）；
 *   3. 限流：同时最多 2 个、两次启动至少间隔 500ms；遇到 3007009（数据库繁忙）降为 1 个并指数退避；
 *   4. 取消：页面离开（mayContinue 返回 false）、换号、写入导致内容变化、App 进入后台时，丢弃排队中的旧请求；
 *   5. 重试：每个请求最多自动重试 1 次（Token 过期先刷新；数据库繁忙冷却后；网络错误 1 秒后）。
 * 【新人注意】这里的“槽位”是逻辑 RPC 数，不代表 SDK 底层 HTTP 请求次数。
 */
import { util } from '@kit.ArkTS';
import { AuthSessionStore } from './AuthSessionStore';
import { CloudBusinessError, ReadCancelledError, cloudReadError } from './CloudReadErrors';

// 读请求优先级，数值越靠前越先执行。
export type ReadPriority = 'metadata' | 'cover' | 'secondary' | 'prefetch';
/**
 * 发起读请求时的可选参数。
 * priority：优先级；currentPriority：动态优先级（例如滚动到可见区域后升级）；
 * mayContinue：返回 false 表示调用方已经不需要结果（页面已离开），请求会被取消。
 */
export interface ReadRequestOptions {
  priority?: ReadPriority;
  currentPriority?: () => ReadPriority;
  mayContinue?: () => Promise<boolean>;
}

// 调度队列中的一个读任务（可能被多个调用方共享）。
class ReadJob {
  key: string;
  operation: string;
  requestId: string;
  session: number;
  lifecycle: number;
  contentRevision: number;
  dataVersion: number;
  priority: ReadPriority;
  prioritySource: (() => ReadPriority) | undefined;
  attempt: number = 0;
  notBefore: number = 0;
  createdAt: number = Date.now();
  firstStartedAt: number = 0;
  mergedCount: number = 0;
  guards: Array<() => Promise<boolean>> = [];
  unguarded: boolean = false;
  action: (requestId: string, attempt: number) => Promise<object>;
  resolve: (value: object) => void;
  reject: (error: Error | ReadCancelledError | CloudBusinessError) => void;
  // 创建任务时记录当时的会话代次、生命周期版本、数据版本与账号内容版本，之后用于判断任务是否已过期。
  constructor(key: string, operation: string, lifecycle: number, dataVersion: number, options: ReadRequestOptions,
    action: (requestId: string, attempt: number) => Promise<object>,
    resolve: (value: object) => void, reject: (error: Error | ReadCancelledError | CloudBusinessError) => void) {
    this.key = key; this.operation = operation; this.requestId = util.generateRandomUUID();
    this.session = AuthSessionStore.generation(); this.lifecycle = lifecycle;
    this.dataVersion = dataVersion;
    this.contentRevision = AppStorage.get<number>('accountContentRevision') || 0;
    this.priority = options.priority || ReadScheduler.defaultPriority(operation);
    this.prioritySource = options.currentPriority;
    this.addGuard(options);
    this.action = action; this.resolve = resolve; this.reject = reject;
  }
  // 追加一个调用方的守卫；任一调用方没有提供守卫时，任务视为“必须完成”。
  addGuard(options: ReadRequestOptions): void {
    if (options.mayContinue === undefined) this.unguarded = true;
    else this.guards.push(options.mayContinue);
  }
  // 是否还有调用方需要这个结果：只要有一个守卫返回 true 就继续。
  async needed(): Promise<boolean> {
    if (this.unguarded) return true;
    for (const guard of this.guards) {
      try { if (await guard()) return true; } catch (_error) { }
    }
    return false;
  }
}

// 每个 App 实例一份：这里的“槽位”是逻辑 RPC 数量，并不代表 SDK 底层发出的 HTTP 请求次数。
export class ReadScheduler {
  // 等待执行的任务、正在执行的 Promise（用于合并）、任务表。
  private static pending: Array<ReadJob> = [];
  private static inFlight: Map<string, Promise<object>> = new Map<string, Promise<object>>();
  private static jobs: Map<string, ReadJob> = new Map<string, ReadJob>();
  // 当前并发数：总数 / 读图数 / 元数据读取数。
  private static active: number = 0;
  private static imageActive: number = 0;
  private static metadataActive: number = 0;
  // 正在显示的图片任务数（有图片在加载时暂停预取）。
  private static visibleImageWork: number = 0;
  // 下一次允许启动任务的时间（两次启动至少间隔 500ms）。
  private static nextStartAt: number = 0;
  // 生命周期版本：App 进入后台时 +1，之前排队的任务全部作废。
  private static lifecycle: number = 0;
  // 数据版本：写操作成功后 +1，之前发起的非图片读请求作废。
  private static dataVersion: number = 0;
  // 数据库繁忙冷却：冷却截止时间、繁忙等级、是否处于恢复期、恢复期内连续成功次数。
  private static busyUntil: number = 0;
  private static busyLevel: number = 0;
  private static recovering: boolean = false;
  private static successCount: number = 0;
  // 延迟唤醒用的定时器。
  private static timer: number | undefined = undefined;
  private static timerAt: number = 0;
  // 操作的默认优先级：读图为 cover；首页、详情、搜索、预览等用户正在等待的为 metadata；其余为 secondary。
  static defaultPriority(operation: string): ReadPriority {
    if (ReadScheduler.imageOperation(operation)) return 'cover';
    return ['get-card-detail', 'get-card-previews', 'list-nearby-cards',
      'search-public-cards', 'get-merchant-recommendations'].includes(operation) ? 'metadata' : 'secondary';
  }
  // 页面开始/结束显示一批图片时调用：有可见图片加载时不执行预取。
  static beginImageWork(): void { ReadScheduler.visibleImageWork++; }
  static endImageWork(): void { ReadScheduler.visibleImageWork = Math.max(0, ReadScheduler.visibleImageWork - 1); ReadScheduler.drain(); }
  // 当前是否适合做预取：不在恢复期、没有可见图片任务、没有元数据请求在执行或排队。
  static canPrefetch(): boolean {
    return !ReadScheduler.recovering && ReadScheduler.visibleImageWork === 0 && ReadScheduler.metadataActive === 0 &&
      !ReadScheduler.pending.some((job: ReadJob): boolean => job.priority === 'metadata' || job.priority === 'cover');
  }
  // 是否为读图类操作（读图任务不受数据版本影响，因为图片授权另有 ImageDescriptors 管理）。
  private static imageOperation(operation: string): boolean { return ['image-read-batch', 'get-public-media', 'get-review-media', 'get-revision-media'].includes(operation); }
  // 哪些操作交给调度器：批量读图以及所有 get-/list-/search- 开头的操作。
  static allows(operation: string): boolean { return operation === 'image-read-batch' || /^(get-|list-|search-)/.test(operation); }
  // 当前数据版本 / 生命周期版本（CloudGateway 用来判断响应是否过期）。
  static dataRevision(): number { return ReadScheduler.dataVersion; }
  static lifecycleRevision(): number { return ReadScheduler.lifecycle; }
  /**
   * 写操作成功后调用：数据版本 +1，并取消排队中的非图片读请求。
   * preserveOperations 中的操作（例如互动状态读取，它们自带版本校验）不受影响。
   */
  static contentChanged(preserveOperations: Array<string> = []): void {
    ReadScheduler.dataVersion++;
    // 互动类 DTO 自带版本校验。详情还在加载时如果用户点了赞，这些读请求需要继续，不应被取消。
    ReadScheduler.jobs.forEach((job: ReadJob): void => {
      if (preserveOperations.includes(job.operation)) job.dataVersion = ReadScheduler.dataVersion;
    });
    ReadScheduler.pending = ReadScheduler.pending.filter((job: ReadJob): boolean => {
      if (ReadScheduler.imageOperation(job.operation) || preserveOperations.includes(job.operation)) return true;
      job.reject(new ReadCancelledError()); return false;
    });
  }

  // 把请求参数序列化为“键排序后的 JSON”，保证 {a,b} 与 {b,a} 生成同一个合并键。
  private static parameters(payload: object): string {
    // 把所有出现过的键名排序后作为 replacer 数组，可让每一层对象的字段都按顺序输出，数组元素顺序保持不变。
    const raw: string = JSON.stringify(payload);
    const pattern: RegExp = /"(?:\\.|[^"\\])*"/g;
    const keys: Array<string> = [];
    let match: RegExpExecArray | null = pattern.exec(raw);
    while (match !== null) {
      if (raw.slice(pattern.lastIndex).trimStart().startsWith(':')) {
        const key: string = JSON.parse(match[0]) as string;
        if (!keys.includes(key)) keys.push(key);
      }
      match = pattern.exec(raw);
    }
    return JSON.stringify(payload, keys.sort());
  }

  /**
   * 提交一个读请求，返回结果 Promise。
   * 合并键 = 账号 + 会话代次 + 生命周期 +（非读图时的数据版本）+ 内容版本 + 是否带身份 + 操作名 + 参数。
   * 已有相同请求在途时直接共享结果，并把优先级提升为两者中较高的；队列超过 32 个时返回 QUEUE_FULL。
   */
  static schedule(operation: string, payload: object, authenticated: boolean, options: ReadRequestOptions,
    action: (requestId: string, attempt: number) => Promise<object>): Promise<object> {
    const key: string = AuthSessionStore.owner() + ':' + AuthSessionStore.generation() + ':' + ReadScheduler.lifecycle + ':' + (ReadScheduler.imageOperation(operation) ? 0 : ReadScheduler.dataVersion) + ':' +
      (AppStorage.get<number>('accountContentRevision') || 0) + ':' +
      String(authenticated) + ':' + operation + ':' +
      ReadScheduler.parameters(payload);
    const existing: Promise<object> | undefined = ReadScheduler.inFlight.get(key);
    if (existing !== undefined) {
      const priority: ReadPriority = options.priority || ReadScheduler.defaultPriority(operation);
      const job: ReadJob | undefined = ReadScheduler.jobs.get(key);
      if (job !== undefined) {
        job.mergedCount++;
        job.addGuard(options);
        if (ReadScheduler.rank(priority) < ReadScheduler.rank(job.priority)) job.priority = priority;
      }
      console.info('[ReadScheduler] operation=' + operation + ' requestId=' + (job === undefined ? '' : job.requestId) + ' event=merged');
      return existing;
    }
    if (ReadScheduler.pending.length >= 32) return Promise.reject(new CloudBusinessError('读取队列已满，请稍后重试。', 'QUEUE_FULL'));
    const promise: Promise<object> = new Promise<object>((resolve: (value: object) => void,
      reject: (error: Error | ReadCancelledError | CloudBusinessError) => void): void => {
      const job: ReadJob = new ReadJob(key, operation, ReadScheduler.lifecycle, ReadScheduler.dataVersion, options, action, resolve, reject);
      ReadScheduler.jobs.set(key, job);
      ReadScheduler.pending.push(job);
      console.info('[ReadScheduler] operation=' + operation + ' requestId=' + job.requestId + ' event=queued');
    });
    ReadScheduler.inFlight.set(key, promise);
    void promise.then((): void => ReadScheduler.remove(key, promise), (error: Object): void => ReadScheduler.remove(key, promise, error));
    ReadScheduler.drain();
    return promise;
  }

  // 任务结束（成功/失败/取消）后打印一行统计日志，并从在途表中移除。
  private static remove(key: string, promise: Promise<object>, error?: Object): void {
    if (ReadScheduler.inFlight.get(key) === promise) {
      const job: ReadJob | undefined = ReadScheduler.jobs.get(key);
      if (job !== undefined) {
        const outcome: string = error === undefined ? 'success' : error instanceof ReadCancelledError ? 'cancelled' : 'error';
        const code: string = error === undefined ? 'OK' : error instanceof CloudBusinessError ? error.code :
          error instanceof ReadCancelledError ? 'READ_CANCELLED' : 'REQUEST_FAILED';
        const stage: string = error instanceof CloudBusinessError ? error.stage : 'none';
        const queueMs: number = Math.max(0, (job.firstStartedAt || Date.now()) - job.createdAt);
        console.info('[ReadScheduler] metricsVersion=o0-20261008-v1 operation=' + job.operation + ' requestId=' + job.requestId +
          ' event=settled outcome=' + outcome + ' code=' + code + ' stage=' + stage + ' attempts=' + job.attempt +
          ' retryCount=' + Math.max(0, job.attempt - 1) + ' mergedCount=' + job.mergedCount +
          ' queueMs=' + queueMs + ' totalMs=' + Math.max(0, Date.now() - job.createdAt));
      }
      ReadScheduler.inFlight.delete(key); ReadScheduler.jobs.delete(key);
    }
  }
  // 优先级排序值（越小越优先）。
  private static rank(priority: ReadPriority): number { return priority === 'metadata' ? 0 : priority === 'cover' ? 1 : priority === 'secondary' ? 2 : 3; }
  // 任务是否仍然有效：会话、生命周期、数据版本、内容版本都未变化，且 App 在前台。
  private static current(job: ReadJob): boolean {
    return job.session === AuthSessionStore.generation() && job.lifecycle === ReadScheduler.lifecycle &&
      (ReadScheduler.imageOperation(job.operation) || job.dataVersion === ReadScheduler.dataVersion) &&
      job.contentRevision === (AppStorage.get<number>('accountContentRevision') || 0) &&
      AppStorage.get<boolean>('stage47AppActive') !== false;
  }
  // App 进入后台时调用：作废所有排队任务（正在执行的任务会继续到结束）。
  static invalidateQueued(): void {
    ReadScheduler.lifecycle++;
    const jobs: Array<ReadJob> = ReadScheduler.pending; ReadScheduler.pending = [];
    for (const job of jobs) job.reject(new ReadCancelledError());
    // 正在执行的调用会一直占用槽位，直到它真正结束。
  }
  // 安排一次延迟唤醒（最多 60 秒），用于冷却结束或间隔到期后继续出队。
  private static resume(delay: number): void {
    const wait: number = Math.min(60000, Math.max(1, delay));
    if (ReadScheduler.timer !== undefined) {
      if (ReadScheduler.timerAt <= Date.now() + wait) return;
      clearTimeout(ReadScheduler.timer);
    }
    ReadScheduler.timerAt = Date.now() + wait;
    ReadScheduler.timer = setTimeout((): void => {
      ReadScheduler.timer = undefined; ReadScheduler.drain();
    }, wait);
  }
  // 页面订阅变化时调用：异步清理已经没有调用方需要的排队任务。
  static subscriptionsChanged(): void { void ReadScheduler.pruneUnused(); }
  // 取消已经没有调用方需要的排队任务，然后继续出队。
  private static async pruneUnused(): Promise<void> {
    for (const job of ReadScheduler.pending.slice()) if (!ReadScheduler.current(job) || !await job.needed()) {
      if (!ReadScheduler.pending.includes(job)) continue;
      ReadScheduler.pending = ReadScheduler.pending.filter((value: ReadJob): boolean => value !== job); job.reject(new ReadCancelledError());
    }
    ReadScheduler.drain();
  }
  /**
   * 出队并启动任务（调度核心）。
   * 先剔除已过期/不需要的任务；冷却或间隔未到时安排唤醒；
   * 然后按优先级排序（等待超过 10 秒的 secondary 任务与 metadata 同级，防止饿死），
   * 在并发上限内挑选一个可执行的任务启动；前台有重要任务时，prefetch 和新的 secondary 任务暂缓。
   */
  private static drain(): void {
    ReadScheduler.pending = ReadScheduler.pending.filter((job: ReadJob): boolean => {
      if (job.prioritySource !== undefined) job.priority = job.prioritySource();
      if (job.priority === 'prefetch' && (ReadScheduler.recovering || ReadScheduler.visibleImageWork > 0)) {
        job.reject(new ReadCancelledError()); return false;
      }
      if (ReadScheduler.current(job)) return true;
      job.reject(new ReadCancelledError()); return false;
    });
    const remaining: number = Math.max(ReadScheduler.busyUntil, ReadScheduler.nextStartAt) - Date.now();
    if (remaining > 0) {
      if (ReadScheduler.pending.length > 0) ReadScheduler.resume(remaining);
      return;
    }
    const limit: number = ReadScheduler.recovering ? 1 : 2;
    ReadScheduler.pending.sort((a: ReadJob, b: ReadJob): number => (a.priority === 'secondary' && Date.now() - a.createdAt >= 10000 ? 0 : ReadScheduler.rank(a.priority)) - (b.priority === 'secondary' && Date.now() - b.createdAt >= 10000 ? 0 : ReadScheduler.rank(b.priority)) || a.createdAt - b.createdAt);
    while (ReadScheduler.active < limit && ReadScheduler.pending.length > 0) {
      const foreground: boolean = ReadScheduler.visibleImageWork > 0 || ReadScheduler.metadataActive > 0 || ReadScheduler.imageActive > 0 ||
        ReadScheduler.pending.some((entry: ReadJob): boolean => entry.priority === 'metadata' || entry.priority === 'cover');
      const index: number = ReadScheduler.pending.findIndex((entry: ReadJob): boolean => entry.notBefore <= Date.now() &&
        (!ReadScheduler.imageOperation(entry.operation) || ReadScheduler.imageActive === 0) &&
        (!foreground || entry.priority === 'metadata' || entry.priority === 'cover' ||
          entry.priority === 'secondary' && Date.now() - entry.createdAt >= 10000));
      if (index < 0) {
        let earliest: number = Number.MAX_SAFE_INTEGER;
        for (const entry of ReadScheduler.pending) {
          if (entry.notBefore > Date.now()) earliest = Math.min(earliest, entry.notBefore);
          if (entry.priority === 'secondary' && entry.createdAt + 10000 > Date.now()) earliest = Math.min(earliest, entry.createdAt + 10000);
        }
        if (earliest < Number.MAX_SAFE_INTEGER) ReadScheduler.resume(earliest - Date.now());
        return;
      }
      const job: ReadJob | undefined = ReadScheduler.pending.splice(index, 1)[0];
      if (job === undefined) return;
      if (ReadScheduler.recovering && job.priority === 'prefetch') { job.reject(new ReadCancelledError()); continue; }
      ReadScheduler.active++;
      if (ReadScheduler.imageOperation(job.operation)) ReadScheduler.imageActive++;
      if (job.priority === 'metadata') ReadScheduler.metadataActive++;
      ReadScheduler.nextStartAt = Date.now() + 500;
      void ReadScheduler.run(job);
      if (ReadScheduler.pending.length > 0) ReadScheduler.resume(500);
      return;
    }
  }
  // 执行一个任务并处理结果：成功则唤醒等待者；失败时按错误类型决定是否重新入队（最多重试 1 次）。
  private static async run(job: ReadJob): Promise<void> {
    const busyLevel: number = ReadScheduler.busyLevel;
    const metadataSlot: boolean = job.priority === 'metadata';
    try {
      if (!ReadScheduler.current(job) || !await job.needed()) throw new ReadCancelledError();
      if (!ReadScheduler.current(job)) throw new ReadCancelledError();
      job.attempt++;
      if (job.firstStartedAt === 0) job.firstStartedAt = Date.now();
      console.info('[ReadScheduler] operation=' + job.operation + ' requestId=' + job.requestId + ' event=started attempt=' +
        job.attempt + ' priority=' + job.priority + ' active=' + ReadScheduler.active + ' limit=' + (ReadScheduler.recovering ? 1 : 2));
      const value: object = await job.action(job.requestId, job.attempt);
      // 结果回来时再确认一次任务仍然有效且仍有人需要，否则按取消处理。
      if (!ReadScheduler.current(job) || !await job.needed()) throw new ReadCancelledError();
      if (!ReadScheduler.current(job)) throw new ReadCancelledError();
      // 恢复期内同一繁忙等级下连续成功 3 次，视为数据库已恢复，并发上限回到 2。
      if (ReadScheduler.recovering && busyLevel === ReadScheduler.busyLevel) {
        ReadScheduler.successCount++;
        if (ReadScheduler.successCount >= 3) {
          ReadScheduler.recovering = false; ReadScheduler.busyLevel = 0; ReadScheduler.successCount = 0;
          console.info('[ReadScheduler] event=recovered limit=2');
        }
      }
      console.info('[ReadScheduler] operation=' + job.operation + ' requestId=' + job.requestId + ' event=completed attempt=' + job.attempt);
      job.resolve(value);
    } catch (caught) {
      const error: Error = cloudReadError(caught as Object, job.operation, job.requestId);
      // Token 过期：强制刷新一次 Token，然后重新入队（只重试 1 次）。
      if (error instanceof CloudBusinessError && error.code === 'AUTH_REQUIRED' && job.attempt < 2 && ReadScheduler.current(job) && AuthSessionStore.owner().length > 0) {
        try {
          await AuthSessionStore.getAccessToken(true);
          if (ReadScheduler.current(job) && await job.needed()) ReadScheduler.pending.push(job);
          else job.reject(new ReadCancelledError());
        } catch (refreshFailure) { job.reject(cloudReadError(refreshFailure as Object, job.operation, job.requestId)); }
      // 数据库繁忙：进入恢复期（并发降为 1），按 2s、4s、8s… 最多 30s 退避；服务端要求等待超过 30 秒时不再自动重试。
      } else if (error instanceof CloudBusinessError && error.code === '3007009') {
        ReadScheduler.busyLevel++; ReadScheduler.successCount = 0; ReadScheduler.recovering = true;
        const hinted: number = Number.isFinite(error.retryAfterMs) ? Math.max(0, error.retryAfterMs) : 0;
        const automaticWindow: number = 30000;
        const localDelay: number = Math.min(automaticWindow, 2000 * Math.pow(2, Math.min(4, ReadScheduler.busyLevel - 1)) + Math.floor(Math.random() * 250));
        const delay: number = Math.max(hinted, localDelay);
        ReadScheduler.busyUntil = Math.max(ReadScheduler.busyUntil, Date.now() + delay);
        console.warn('[ReadScheduler] operation=' + job.operation + ' requestId=' + job.requestId + ' code=3007009 event=cooldown delayMs=' + delay + ' limit=1');
        if (hinted > automaticWindow) {
          error.retryable = false;
          error.message = '云数据库暂时繁忙，服务端要求等待 ' + Math.ceil(hinted / 1000).toString() + ' 秒后重试。';
        }
        if (hinted <= automaticWindow && error.retryable && job.attempt < 2 && ReadScheduler.current(job) && job.priority !== 'prefetch') {
          ReadScheduler.pending.push(job);
        } else job.reject(error);
      // 网络类可重试错误：1 秒（加随机抖动）后重试一次；预取任务不重试。
      } else if (error instanceof CloudBusinessError && error.retryable && ['1008210001', '503', 'NETWORK_UNAVAILABLE', 'MEDIA_TIMEOUT'].includes(error.code) && job.attempt < 2 && ReadScheduler.current(job) && job.priority !== 'prefetch') {
        job.notBefore = Date.now() + 1000 + Math.floor(Math.random() * 250); ReadScheduler.pending.push(job);
      // 其他错误或已取消：直接返回给调用方。
      } else {
        console.info('[ReadScheduler] operation=' + job.operation + ' requestId=' + job.requestId +
          ' event=' + (error instanceof ReadCancelledError ? 'cancelled' : 'failed') +
          ' code=' + (error instanceof CloudBusinessError ? error.code : error.name));
        job.reject(error);
      }
    } finally {
      ReadScheduler.active--; if (ReadScheduler.imageOperation(job.operation)) ReadScheduler.imageActive--;
      if (metadataSlot) ReadScheduler.metadataActive--;
      ReadScheduler.drain();
    }
  }
}
