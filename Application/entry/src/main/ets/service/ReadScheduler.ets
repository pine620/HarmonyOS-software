import { util } from '@kit.ArkTS';
import { AuthSessionStore } from './AuthSessionStore';
import { CloudBusinessError, ReadCancelledError, cloudReadError } from './CloudReadErrors';

export type ReadPriority = 'metadata' | 'cover' | 'prefetch';
export interface ReadRequestOptions {
  priority?: ReadPriority;
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
  attempt: number = 0;
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
    this.priority = options.priority || 'metadata';
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
  private static lifecycle: number = 0;
  private static dataVersion: number = 0;
  private static busyUntil: number = 0;
  private static busyLevel: number = 0;
  private static recovering: boolean = false;
  private static successCount: number = 0;
  private static timer: number | undefined = undefined;
  private static readonly operations: Set<string> = new Set<string>([
    'get-stage89-capabilities', 'list-moderation-queue', 'get-moderation-detail', 'list-my-reports', 'list-own-review-requests', 'list-deleted-cards', 'list-lifecycle-jobs', 'get-lifecycle-job', 'get-review-media', 'get-revision-media', 'get-meal-poll',
    'get-card-previews', 'list-personal-collection', 'get-personal-collection-migration',
    'get-stage47-capabilities', 'get-taste-preference', 'list-personalized-recommendations',
    'list-food-lists', 'list-food-list-items', 'get-personal-food-state', 'get-meal-candidates',
    'list-meal-choice-history', 'get-user-page', 'list-merchant-rankings', 'list-former-friend-content-grants',
    'get-discovery-capabilities', 'list-map-merchants', 'search-public-cards', 'get-merchant-recommendations',
    'get-public-media', 'get-card-detail', 'list-nearby-cards', 'list-friend-rankings', 'get-friend-profile',
    'list-notifications', 'list-conversations', 'list-group-conversations', 'get-group-chat'
  ]);

  static allows(operation: string): boolean { return ReadScheduler.operations.has(operation); }
  static contentChanged(): void { ReadScheduler.dataVersion++; ReadScheduler.invalidateQueued(); }

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
    const key: string = AuthSessionStore.owner() + ':' + AuthSessionStore.generation() + ':' + ReadScheduler.lifecycle + ':' + ReadScheduler.dataVersion + ':' +
      (AppStorage.get<number>('accountContentRevision') || 0) + ':' +
      (AppStorage.get<number>('preferenceRevision') || 0) + ':' + String(authenticated) + ':' + operation + ':' +
      ReadScheduler.parameters(payload);
    const existing: Promise<object> | undefined = ReadScheduler.inFlight.get(key);
    if (existing !== undefined) {
      const priority: ReadPriority = options.priority || 'metadata';
      const job: ReadJob | undefined = ReadScheduler.jobs.get(key);
      if (job !== undefined) {
        job.addGuard(options);
        if (ReadScheduler.rank(priority) < ReadScheduler.rank(job.priority)) job.priority = priority;
      }
      console.info('[ReadScheduler] operation=' + operation + ' requestId=' + (job === undefined ? '' : job.requestId) + ' event=merged');
      return existing;
    }
    const promise: Promise<object> = new Promise<object>((resolve: (value: object) => void,
      reject: (error: Error | ReadCancelledError | CloudBusinessError) => void): void => {
      const job: ReadJob = new ReadJob(key, operation, ReadScheduler.lifecycle, ReadScheduler.dataVersion, options, action, resolve, reject);
      ReadScheduler.jobs.set(key, job);
      ReadScheduler.pending.push(job);
      console.info('[ReadScheduler] operation=' + operation + ' requestId=' + job.requestId + ' event=queued');
    });
    ReadScheduler.inFlight.set(key, promise);
    void promise.then((): void => ReadScheduler.remove(key, promise), (_error: Object): void => ReadScheduler.remove(key, promise));
    ReadScheduler.drain();
    return promise;
  }

  private static remove(key: string, promise: Promise<object>): void {
    if (ReadScheduler.inFlight.get(key) === promise) {
      ReadScheduler.inFlight.delete(key); ReadScheduler.jobs.delete(key);
    }
  }
  private static rank(priority: ReadPriority): number { return priority === 'metadata' ? 0 : priority === 'cover' ? 1 : 2; }
  private static current(job: ReadJob): boolean {
    return job.session === AuthSessionStore.generation() && job.lifecycle === ReadScheduler.lifecycle &&
      job.dataVersion === ReadScheduler.dataVersion &&
      job.contentRevision === (AppStorage.get<number>('accountContentRevision') || 0) &&
      job.preferenceRevision === (AppStorage.get<number>('preferenceRevision') || 0) &&
      AppStorage.get<boolean>('stage47AppActive') !== false;
  }
  static invalidateQueued(): void {
    ReadScheduler.lifecycle++;
    const jobs: Array<ReadJob> = ReadScheduler.pending; ReadScheduler.pending = [];
    for (const job of jobs) job.reject(new ReadCancelledError());
    // Active calls retain their slots until the actual action has settled.
  }
  private static resume(delay: number): void {
    if (ReadScheduler.timer !== undefined) return;
    ReadScheduler.timer = setTimeout((): void => {
      ReadScheduler.timer = undefined; ReadScheduler.drain();
    }, Math.max(1, delay));
  }
  private static drain(): void {
    ReadScheduler.pending = ReadScheduler.pending.filter((job: ReadJob): boolean => {
      if (ReadScheduler.current(job)) return true;
      job.reject(new ReadCancelledError()); return false;
    });
    const remaining: number = ReadScheduler.busyUntil - Date.now();
    if (remaining > 0) {
      if (ReadScheduler.pending.length > 0) ReadScheduler.resume(remaining);
      return;
    }
    const limit: number = ReadScheduler.recovering ? 1 : 2;
    ReadScheduler.pending.sort((a: ReadJob, b: ReadJob): number => ReadScheduler.rank(a.priority) - ReadScheduler.rank(b.priority));
    while (ReadScheduler.active < limit && ReadScheduler.pending.length > 0) {
      const job: ReadJob | undefined = ReadScheduler.pending.shift();
      if (job === undefined) return;
      if (ReadScheduler.recovering && job.priority === 'prefetch') { job.reject(new ReadCancelledError()); continue; }
      ReadScheduler.active++;
      void ReadScheduler.run(job);
    }
  }
  private static async run(job: ReadJob): Promise<void> {
    const busyLevel: number = ReadScheduler.busyLevel;
    try {
      if (!ReadScheduler.current(job) || !await job.needed()) throw new ReadCancelledError();
      if (!ReadScheduler.current(job)) throw new ReadCancelledError();
      job.attempt++;
      console.info('[ReadScheduler] operation=' + job.operation + ' requestId=' + job.requestId + ' event=started attempt=' +
        job.attempt + ' active=' + ReadScheduler.active + ' limit=' + (ReadScheduler.recovering ? 1 : 2));
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
      if (error instanceof CloudBusinessError && error.code === '3007009') {
        ReadScheduler.busyLevel++; ReadScheduler.successCount = 0; ReadScheduler.recovering = true;
        const hinted: number = Number.isFinite(error.retryAfterMs) ? Math.max(0, error.retryAfterMs) : 0;
        const delay: number = Math.min(8000, Math.max(hinted, 2000 * Math.pow(2, Math.min(2, ReadScheduler.busyLevel - 1))) + Math.floor(Math.random() * 250));
        ReadScheduler.busyUntil = Math.max(ReadScheduler.busyUntil, Date.now() + delay);
        console.warn('[ReadScheduler] operation=' + job.operation + ' requestId=' + job.requestId + ' code=3007009 event=cooldown delayMs=' + delay + ' limit=1');
        if (error.retryable && job.attempt < 2 && ReadScheduler.current(job) && job.priority !== 'prefetch') {
          ReadScheduler.pending.push(job);
        } else job.reject(error);
      } else {
        console.info('[ReadScheduler] operation=' + job.operation + ' requestId=' + job.requestId +
          ' event=' + (error instanceof ReadCancelledError ? 'cancelled' : 'failed') +
          ' code=' + (error instanceof CloudBusinessError ? error.code : error.name));
        job.reject(error);
      }
    } finally {
      ReadScheduler.active--; ReadScheduler.drain();
    }
  }
}
