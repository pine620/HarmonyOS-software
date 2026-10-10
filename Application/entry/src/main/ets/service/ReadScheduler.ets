import { util } from '@kit.ArkTS';
import { AuthSessionStore } from './AuthSessionStore';
import { CloudBusinessError, ReadCancelledError, cloudReadError } from './CloudReadErrors';

export type ReadPriority = 'metadata' | 'cover' | 'secondary' | 'prefetch';
export interface ReadRequestOptions {
  priority?: ReadPriority;
  currentPriority?: () => ReadPriority;
  mayContinue?: () => Promise<boolean>;
}

class ReadJob {
  key: string;
  operation: string;
  requestId: string;
  session: number;
  lifecycle: number;
  contentRevision: number;
  preferenceRevision: number;
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
  constructor(key: string, operation: string, lifecycle: number, dataVersion: number, options: ReadRequestOptions,
    action: (requestId: string, attempt: number) => Promise<object>,
    resolve: (value: object) => void, reject: (error: Error | ReadCancelledError | CloudBusinessError) => void) {
    this.key = key; this.operation = operation; this.requestId = util.generateRandomUUID();
    this.session = AuthSessionStore.generation(); this.lifecycle = lifecycle;
    this.dataVersion = dataVersion;
    this.contentRevision = AppStorage.get<number>('accountContentRevision') || 0;
    this.preferenceRevision = AppStorage.get<number>('preferenceRevision') || 0;
    this.priority = options.priority || ReadScheduler.defaultPriority(operation);
    this.prioritySource = options.currentPriority;
    this.addGuard(options);
    this.action = action; this.resolve = resolve; this.reject = reject;
  }
  addGuard(options: ReadRequestOptions): void {
    if (options.mayContinue === undefined) this.unguarded = true;
    else this.guards.push(options.mayContinue);
  }
  async needed(): Promise<boolean> {
    if (this.unguarded) return true;
    for (const guard of this.guards) {
      try { if (await guard()) return true; } catch (_error) { }
    }
    return false;
  }
}

/** Per app instance: logical RPC slots, never a claim about SDK HTTP attempts. */
export class ReadScheduler {
  private static pending: Array<ReadJob> = [];
  private static inFlight: Map<string, Promise<object>> = new Map<string, Promise<object>>();
  private static jobs: Map<string, ReadJob> = new Map<string, ReadJob>();
  private static active: number = 0;
  private static imageActive: number = 0;
  private static metadataActive: number = 0;
  private static visibleImageWork: number = 0;
  private static nextStartAt: number = 0;
  private static lifecycle: number = 0;
  private static dataVersion: number = 0;
  private static busyUntil: number = 0;
  private static busyLevel: number = 0;
  private static recovering: boolean = false;
  private static successCount: number = 0;
  private static timer: number | undefined = undefined;
  private static timerAt: number = 0;
  static defaultPriority(operation: string): ReadPriority {
    if (ReadScheduler.imageOperation(operation)) return 'cover';
    return ['get-card-detail', 'get-card-previews', 'list-personalized-recommendations', 'list-nearby-cards',
      'search-public-cards', 'get-merchant-recommendations'].includes(operation) ? 'metadata' : 'secondary';
  }
  static beginImageWork(): void { ReadScheduler.visibleImageWork++; }
  static endImageWork(): void { ReadScheduler.visibleImageWork = Math.max(0, ReadScheduler.visibleImageWork - 1); ReadScheduler.drain(); }
  static canPrefetch(): boolean {
    return !ReadScheduler.recovering && ReadScheduler.visibleImageWork === 0 && ReadScheduler.metadataActive === 0 &&
      !ReadScheduler.pending.some((job: ReadJob): boolean => job.priority === 'metadata' || job.priority === 'cover');
  }
  private static imageOperation(operation: string): boolean { return ['image-read-batch', 'get-public-media', 'get-review-media', 'get-revision-media'].includes(operation); }
  static allows(operation: string): boolean { return operation === 'image-read-batch' || /^(get-|list-|search-)/.test(operation); }
  static dataRevision(): number { return ReadScheduler.dataVersion; }
  static lifecycleRevision(): number { return ReadScheduler.lifecycle; }
  static contentChanged(): void {
    ReadScheduler.dataVersion++;
    ReadScheduler.pending = ReadScheduler.pending.filter((job: ReadJob): boolean => {
      if (ReadScheduler.imageOperation(job.operation)) return true;
      job.reject(new ReadCancelledError()); return false;
    });
  }

  private static parameters(payload: object): string {
    // A replacer key array sorts fields at every object depth, retaining array order.
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

  static schedule(operation: string, payload: object, authenticated: boolean, options: ReadRequestOptions,
    action: (requestId: string, attempt: number) => Promise<object>): Promise<object> {
    const key: string = AuthSessionStore.owner() + ':' + AuthSessionStore.generation() + ':' + ReadScheduler.lifecycle + ':' + (ReadScheduler.imageOperation(operation) ? 0 : ReadScheduler.dataVersion) + ':' +
      (AppStorage.get<number>('accountContentRevision') || 0) + ':' +
      (ReadScheduler.imageOperation(operation) ? 0 : (AppStorage.get<number>('preferenceRevision') || 0)) + ':' + String(authenticated) + ':' + operation + ':' +
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
  private static rank(priority: ReadPriority): number { return priority === 'metadata' ? 0 : priority === 'cover' ? 1 : priority === 'secondary' ? 2 : 3; }
  private static current(job: ReadJob): boolean {
    return job.session === AuthSessionStore.generation() && job.lifecycle === ReadScheduler.lifecycle &&
      (ReadScheduler.imageOperation(job.operation) || job.dataVersion === ReadScheduler.dataVersion) &&
      job.contentRevision === (AppStorage.get<number>('accountContentRevision') || 0) &&
      (ReadScheduler.imageOperation(job.operation) || job.preferenceRevision === (AppStorage.get<number>('preferenceRevision') || 0)) &&
      AppStorage.get<boolean>('stage47AppActive') !== false;
  }
  static invalidateQueued(): void {
    ReadScheduler.lifecycle++;
    const jobs: Array<ReadJob> = ReadScheduler.pending; ReadScheduler.pending = [];
    for (const job of jobs) job.reject(new ReadCancelledError());
    // Active calls retain their slots until the actual action has settled.
  }
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
  static subscriptionsChanged(): void { void ReadScheduler.pruneUnused(); }
  private static async pruneUnused(): Promise<void> {
    for (const job of ReadScheduler.pending.slice()) if (!ReadScheduler.current(job) || !await job.needed()) {
      if (!ReadScheduler.pending.includes(job)) continue;
      ReadScheduler.pending = ReadScheduler.pending.filter((value: ReadJob): boolean => value !== job); job.reject(new ReadCancelledError());
    }
    ReadScheduler.drain();
  }
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
      if (!ReadScheduler.current(job) || !await job.needed()) throw new ReadCancelledError();
      if (!ReadScheduler.current(job)) throw new ReadCancelledError();
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
      if (error instanceof CloudBusinessError && error.code === 'AUTH_REQUIRED' && job.attempt < 2 && ReadScheduler.current(job) && AuthSessionStore.owner().length > 0) {
        try {
          await AuthSessionStore.getAccessToken(true);
          if (ReadScheduler.current(job) && await job.needed()) ReadScheduler.pending.push(job);
          else job.reject(new ReadCancelledError());
        } catch (refreshFailure) { job.reject(cloudReadError(refreshFailure as Object, job.operation, job.requestId)); }
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
      } else if (error instanceof CloudBusinessError && error.retryable && ['1008210001', '503', 'NETWORK_UNAVAILABLE', 'MEDIA_TIMEOUT'].includes(error.code) && job.attempt < 2 && ReadScheduler.current(job) && job.priority !== 'prefetch') {
        job.notBefore = Date.now() + 1000 + Math.floor(Math.random() * 250); ReadScheduler.pending.push(job);
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
