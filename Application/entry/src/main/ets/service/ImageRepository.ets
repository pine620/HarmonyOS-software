import { common } from '@kit.AbilityKit';
import { CardPhoto, FoodCard } from '../model/CloudContracts';
import { ImageBatchResponse, ImageCacheEntry, ImageDescriptor, ImageMode, ImageReadItem, ImageReadRequest, ImageReadResult, ImageVariant, LegacyImageRequest, LegacyImageResponse, MediaPriority, MediaRequestGuard } from '../model/ImageModels';
import { CloudGateway } from './CloudGateway';
import { CloudBusinessError, ReadCancelledError } from './CloudReadErrors';
import { AuthSessionStore } from './AuthSessionStore';
import { ImageDescriptors } from './ImageDescriptors';
import { IMAGE_TRANSPORT, IMAGE_ALLOW_LEGACY_ON_UNSUPPORTED, ImageTransport } from './ImageReadConfig';
import { ReadRequestOptions } from './ReadScheduler';
import { ImageDiskCache } from './ImageDiskCache';
export { MediaPriority, MediaRequestGuard } from '../model/ImageModels';

type ImageTaskError = Error | ReadCancelledError | CloudBusinessError;

class ImageTask {
  key: string;
  mediaId: string;
  mode: ImageMode;
  variant: ImageVariant;
  revisionId: string;
  readCycle: number = 0;
  priority: MediaPriority;
  createdAt: number = Date.now();
  session: number = AuthSessionStore.generation();
  epoch: number = ImageDescriptors.epoch();
  guards: Array<MediaRequestGuard> = [];
  cached: ImageCacheEntry | undefined = undefined;
  descriptor: ImageDescriptor | undefined = undefined;
  force: boolean;
  settled: boolean = false;
  bucket: string = '';
  path: string = '';
  promise: Promise<string>;
  resolve: (url: string) => void = (_url: string): void => {};
  reject: (error: ImageTaskError) => void = (_error: ImageTaskError): void => {};
  constructor(key: string, mediaId: string, mode: ImageMode, variant: ImageVariant, revisionId: string, priority: MediaPriority, force: boolean) {
    this.key = key; this.mediaId = mediaId; this.mode = mode; this.variant = variant; this.revisionId = revisionId; this.priority = priority; this.force = force;
    this.promise = new Promise<string>((resolve: (url: string) => void, reject: (error: ImageTaskError) => void): void => { this.resolve = resolve; this.reject = reject; });
  }
  async needed(): Promise<boolean> {
    if (this.session !== AuthSessionStore.generation() || this.epoch !== ImageDescriptors.epoch() || AppStorage.get<boolean>('stage47AppActive') === false) return false;
    for (const guard of this.guards) try { if (await guard()) return true; } catch (_error) { }
    return false;
  }
  fail(error: ImageTaskError): void { if (!this.settled) { this.settled = true; this.reject(error); } }
  finish(url: string): void { if (!this.settled) { this.settled = true; this.resolve(url); } }
}

/** One app-wide owner of image tasks. Pages subscribe; SDK calls retain their real scheduler slots. */
export class ImageRepository {
  private static tasks: Map<string, ImageTask> = new Map<string, ImageTask>();
  private static pending: Array<ImageTask> = [];
  private static running: boolean = false;
  private static timer: number | undefined = undefined;
  private static transport: ImageTransport = IMAGE_TRANSPORT;
  private static unsupported: boolean = false;
  private static owner: string = '';
  private static readCycle: number = 0;
  private static ownerSession: number = -1;
  static setCacheOwner(owner: string): void {
    if (ImageRepository.owner === owner && ImageRepository.ownerSession === AuthSessionStore.generation()) return;
    ImageRepository.owner = owner; ImageRepository.ownerSession = AuthSessionStore.generation();
    ImageDescriptors.revoke(); ImageDiskCache.activate(owner); ImageRepository.unsupported = false; ImageRepository.transport = IMAGE_TRANSPORT;
    for (const task of ImageRepository.pending) {
      if (ImageRepository.tasks.get(task.key) === task) ImageRepository.tasks.delete(task.key);
      task.fail(new ReadCancelledError());
    }
    ImageRepository.pending = [];
  }
  static subscriptionsChanged(): void { void ImageRepository.pruneUnused(); }
  private static async pruneUnused(): Promise<void> {
    for (const task of ImageRepository.pending.slice()) if (!await task.needed()) {
      if (!ImageRepository.pending.includes(task)) continue;
      ImageRepository.pending = ImageRepository.pending.filter((value: ImageTask): boolean => value !== task);
      if (ImageRepository.tasks.get(task.key) === task) ImageRepository.tasks.delete(task.key);
      task.fail(new ReadCancelledError());
    }
  }
  static retryUnavailableService(): void { ImageRepository.unsupported = false; }
  static isMediaServiceUnavailable(): boolean { return ImageRepository.unsupported; }
  static async clearCachedMedia(context: common.Context): Promise<void> { ImageDescriptors.revoke(); await ImageDiskCache.clear(context); }
  static async reportDecodeFailure(context: common.Context, mediaId: string, variant: ImageVariant = 'ORIGINAL', mode: ImageMode = 'PUBLIC', revisionId: string = ''): Promise<void> { ImageDescriptors.remove(mediaId); await ImageDiskCache.evict(context, mediaId, variant, mode, revisionId); }
  static async reportDecodeFailureByUrl(context: common.Context, url: string): Promise<void> {
    const session: number = AuthSessionStore.generation();
    const mediaId: string = await ImageDiskCache.evictUrl(context, url);
    if (session === AuthSessionStore.generation() && mediaId.length > 0) ImageDescriptors.remove(mediaId);
  }
  static revokePermissions(): void { ImageDescriptors.revoke(); }
  static async getDownloadUrl(context: common.Context, bucket: string, path: string, priority: MediaPriority = 'normal', mayContinue?: MediaRequestGuard,
    photo?: CardPhoto, cover: boolean = false, revalidate: boolean = false, readCycle: number = 0): Promise<string> {
    if (bucket.trim().length === 0) return '';
    const match: RegExpMatchArray | null = path.match(/^public\/approved\/[^/]+\/([0-9a-f-]{36})\.jpg$/i);
    const mediaId: string = photo !== undefined && photo.id.length > 0 ? photo.id : match === null ? '' : match[1];
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(mediaId)) return '';
    return ImageRepository.subscribe(context, mediaId, 'PUBLIC', cover ? 'COVER_480' : 'ORIGINAL', '', priority, mayContinue, revalidate, bucket, path, readCycle);
  }
  static getRevisionDownloadUrl(context: common.Context, revisionId: string, mediaId: string, mayContinue?: MediaRequestGuard): Promise<string> {
    return ImageRepository.subscribe(context, mediaId, 'REVISION', 'ORIGINAL', revisionId, 'high', mayContinue, true);
  }
  static getReviewDownloadUrl(context: common.Context, mediaId: string, mayContinue: MediaRequestGuard): Promise<string> {
    return ImageRepository.subscribe(context, mediaId, 'REVIEW', 'ORIGINAL', '', 'high', mayContinue, true);
  }
  private static async subscribe(context: common.Context, mediaId: string, mode: ImageMode, variant: ImageVariant, revisionId: string,
    priority: MediaPriority, mayContinue: MediaRequestGuard | undefined, force: boolean, bucket: string = '', path: string = '', readCycle: number = 0): Promise<string> {
    const guard: MediaRequestGuard = mayContinue === undefined ? async (): Promise<boolean> => true : mayContinue;
    if (!await guard()) throw new ReadCancelledError();
    if (ImageRepository.unsupported) throw new CloudBusinessError('图片服务尚未启用，请稍后重试。', 'NOT_SUPPORTED');
    const cycle: number = force && readCycle === 0 ? ++ImageRepository.readCycle : readCycle;
    const known: ImageDescriptor | undefined = ImageDescriptors.read(mediaId, mode, variant, revisionId);
    const key: string = ImageDescriptors.key(mediaId, mode, variant, revisionId) + ':' + (known?.sha256 || '') + ':' + cycle + ':' + AuthSessionStore.generation() + ':' + ImageDescriptors.epoch();
    let task: ImageTask | undefined = ImageRepository.tasks.get(key);
    if (task === undefined) {
      if (ImageRepository.pending.length >= 32) throw new CloudBusinessError('图片队列已满，请稍后重试。', 'QUEUE_FULL');
      task = new ImageTask(key, mediaId, mode, variant, revisionId, priority, force); task.bucket = bucket; task.path = path; task.readCycle = cycle;
      ImageRepository.tasks.set(key, task); ImageRepository.pending.push(task);
    }
    task.guards.push(guard);
    console.info('[ImageRepository] event=subscribed registeredGuards=' + task.guards.length + ' pending=' + ImageRepository.pending.length + ' priority=' + priority);
    task.force = task.force || force;
    if (ImageRepository.rank(priority) < ImageRepository.rank(task.priority)) task.priority = priority;
    if (!ImageRepository.running && ImageRepository.timer === undefined) ImageRepository.timer = setTimeout((): void => {
      ImageRepository.timer = undefined; void ImageRepository.pump(context);
    }, 10);
    const result: string = await task.promise;
    if (!await guard() || task.session !== AuthSessionStore.generation() || task.epoch !== ImageDescriptors.epoch()) throw new ReadCancelledError();
    return result;
  }
  private static rank(priority: MediaPriority): number { return priority === 'high' ? 0 : priority === 'normal' ? 1 : 2; }
  private static async pump(context: common.Context): Promise<void> {
    if (ImageRepository.running) return;
    ImageRepository.running = true;
    try {
      while (ImageRepository.pending.length > 0) {
        if (ImageRepository.unsupported) {
          for (const task of ImageRepository.pending) {
            if (ImageRepository.tasks.get(task.key) === task) ImageRepository.tasks.delete(task.key);
            task.fail(new CloudBusinessError('图片服务尚未启用，请稍后重试。', 'NOT_SUPPORTED'));
          }
          ImageRepository.pending = []; break;
        }
        ImageRepository.pending.sort((a: ImageTask, b: ImageTask): number => (Date.now() - a.createdAt > 10000 ? 0 : ImageRepository.rank(a.priority)) - (Date.now() - b.createdAt > 10000 ? 0 : ImageRepository.rank(b.priority)) || a.createdAt - b.createdAt);
        const first: ImageTask | undefined = ImageRepository.pending.shift(); if (first === undefined) break;
        const batch: Array<ImageTask> = [first];
        if (first.variant === 'COVER_480') {
          for (const task of ImageRepository.pending.slice()) if (batch.length < 4 && task.variant === 'COVER_480' && task.mode === first.mode && task.session === first.session && task.epoch === first.epoch && !batch.some((entry: ImageTask): boolean => entry.mediaId === task.mediaId && entry.revisionId === task.revisionId)) {
            batch.push(task); ImageRepository.pending = ImageRepository.pending.filter((item: ImageTask): boolean => item !== task);
          }
        }
        console.info('[ImageRepository] event=batch count=' + batch.length + ' pending=' + ImageRepository.pending.length + ' mode=' + first.mode + ' requestedVariant=' + first.variant);
        try { await ImageRepository.load(context, batch); }
        catch (error) { if (error instanceof CloudBusinessError && error.code === 'NOT_SUPPORTED') ImageRepository.unsupported = true; const failure: Error = error instanceof Error ? error : new Error('图片读取失败。'); for (const task of batch) task.fail(failure); }
        finally { for (const task of batch) if (ImageRepository.tasks.get(task.key) === task) ImageRepository.tasks.delete(task.key); }
      }
    } finally { ImageRepository.running = false; }
  }
  private static async load(context: common.Context, batch: Array<ImageTask>): Promise<void> {
    const needed: Array<ImageTask> = [];
    for (const task of batch) {
      if (!await task.needed()) { task.fail(new ReadCancelledError()); continue; }
      task.cached = await ImageDiskCache.find(context, task.mediaId, task.mode, task.variant, task.revisionId);
      task.descriptor = ImageDescriptors.read(task.mediaId, task.mode, task.variant, task.revisionId);
      if (task.cached === undefined) {
        const fallback: ImageDescriptor | undefined = task.descriptor || (task.variant === 'COVER_480' ? ImageDescriptors.read(task.mediaId, task.mode, 'ORIGINAL', task.revisionId) : undefined);
        task.cached = await ImageDiskCache.migrateLegacy(context, task.mediaId, task.mode, task.variant, task.revisionId, task.bucket, task.path, fallback);
      }
      if (!await task.needed()) { task.fail(new ReadCancelledError()); continue; }
      if (!task.force && task.cached !== undefined && task.descriptor !== undefined && task.cached.descriptor.sha256 === task.descriptor.sha256 && task.cached.descriptor.variant === task.descriptor.variant) {
        task.finish(ImageDiskCache.url(context, task.cached)); console.info('[ImageCache] event=hit bytes=0');
      } else needed.push(task);
    }
    if (needed.length === 0) return;
    await ImageRepository.fetch(context, needed, true);
    const rest: Array<ImageTask> = needed.filter((task: ImageTask): boolean => !task.settled);
    if (rest.length > 0) await ImageRepository.fetch(context, rest, false);
    // A missing rendition is split once into a single-original request.
    for (const task of rest) if (!task.settled) await ImageRepository.fetch(context, [task], false);
    for (const task of batch) if (!task.settled) task.fail(new CloudBusinessError('图片暂未就绪，请单张重试。', 'MEDIA_DEFERRED'));
  }
  private static async fetch(context: common.Context, tasks: Array<ImageTask>, firstOnly: boolean): Promise<void> {
    const active: Array<ImageTask> = [];
    for (const task of tasks) if (await task.needed()) active.push(task); else task.fail(new ReadCancelledError());
    if (active.length === 0) return;
    const items: Array<ImageReadItem> = active.map((task: ImageTask, index: number): ImageReadItem => {
      const item: ImageReadItem = { mediaId: task.mediaId, mode: task.mode, variant: task.variant, revisionId: task.revisionId,
        knownSha256: task.cached === undefined ? '' : task.cached.descriptor.sha256, knownByteSize: task.cached === undefined ? 0 : task.cached.descriptor.byteSize,
        wantBytes: !firstOnly || index === 0 };
      return item;
    });
    // A new display confirmation must not join an RPC admitted before it was hidden/revoked.
    let cycle: number = 0;
    for (const task of active) cycle = Math.max(cycle, task.readCycle);
    const request: ImageReadRequest = { protocolVersion: 'image-read-v1', items, readScope: active[0].epoch + ':' + cycle };
    const options: ReadRequestOptions = {
      priority: active[0].priority === 'low' ? 'prefetch' : 'cover', mayContinue: async (): Promise<boolean> => {
        for (const task of active) if (await task.needed()) return true; return false;
      }
    };
    if (ImageRepository.transport === 'LEGACY') { await ImageRepository.fetchLegacy(context, active); return; }
    let response: ImageBatchResponse;
    try { response = await CloudGateway.callPublic<ImageBatchResponse>('image-read-batch', request, options); }
    catch (error) {
      if (error instanceof CloudBusinessError && error.code === 'NOT_SUPPORTED' && IMAGE_ALLOW_LEGACY_ON_UNSUPPORTED) {
        ImageRepository.transport = 'LEGACY'; await ImageRepository.fetchLegacy(context, active); return;
      }
      throw error instanceof Error ? error : new Error('图片调用失败。');
    }
    if (response.protocolVersion !== 'image-read-v1' || !Array.isArray(response.items)) throw new Error('图片协议响应无效。');
    console.info('[ImageRead] buildId=' + response.buildId + ' policyHash=' + response.policyHash + ' count=' + active.length);
    for (const task of active) {
      const result: ImageReadResult | undefined = response.items.find((item: ImageReadResult): boolean => item.mediaId === task.mediaId && item.mode === task.mode && item.revisionId === task.revisionId && item.requestedVariant === task.variant);
      if (!await task.needed()) { task.fail(new ReadCancelledError()); continue; }
      if (result === undefined) { task.fail(new Error('图片批次缺少结果。')); continue; }
      if (result.status === 'DENIED') { ImageDescriptors.remove(task.mediaId); task.fail(new CloudBusinessError('图片已不可访问。', result.code || 'CONTENT_ACCESS_DENIED')); continue; }
      if (result.status === 'RETRYABLE_ERROR') { task.fail(new CloudBusinessError('图片暂时读取失败，请重试。', result.code || 'MEDIA_UNAVAILABLE')); continue; }
      const descriptor: ImageDescriptor | undefined = result.descriptor;
      if (descriptor === undefined) { task.fail(new Error('图片描述符缺失。')); continue; }
      task.descriptor = descriptor;
      if (result.status === 'BYTES') {
        try {
          task.cached = await ImageDiskCache.put(context, task.mediaId, task.mode, task.variant, task.revisionId, descriptor, result.dataBase64 || '');
          if (!await task.needed()) { task.fail(new ReadCancelledError()); continue; }
          ImageDescriptors.record(task.mediaId, task.mode, task.variant, descriptor, task.revisionId);
          task.finish(ImageDiskCache.url(context, task.cached));
        } catch (error) { task.fail(error instanceof Error ? error : new Error('图片缓存写入失败。')); }
      } else if (result.status === 'CACHE_OK' && task.cached !== undefined && task.cached.descriptor.sha256 === descriptor.sha256 && task.cached.descriptor.byteSize === descriptor.byteSize) {
        ImageDescriptors.record(task.mediaId, task.mode, task.variant, descriptor, task.revisionId);
        task.finish(ImageDiskCache.url(context, task.cached));
      } else {
        if (result.status !== 'DEFERRED') task.cached = undefined;
      }
    }
  }
  private static async fetchLegacy(context: common.Context, tasks: Array<ImageTask>): Promise<void> {
    for (const task of tasks) {
      if (!await task.needed()) { task.fail(new ReadCancelledError()); continue; }
      const payload: LegacyImageRequest = { mediaId: task.mediaId, revisionId: task.revisionId, bucketName: task.bucket, cloudPath: task.path,
        variant: task.variant, knownSha256: task.cached === undefined ? '' : task.cached.descriptor.sha256,
        knownByteSize: task.cached === undefined ? 0 : task.cached.descriptor.byteSize, readScope: task.epoch + ':' + task.readCycle };
      const options: ReadRequestOptions = { priority: task.priority === 'low' ? 'prefetch' : 'cover', mayContinue: async (): Promise<boolean> => task.needed() };
      try {
        const result: LegacyImageResponse = task.mode === 'PUBLIC' ? await CloudGateway.callPublic<LegacyImageResponse>('get-public-media', payload, options) :
          await CloudGateway.callAuthenticated<LegacyImageResponse>(task.mode === 'REVIEW' ? 'get-review-media' : 'get-revision-media', payload, options);
        if (!await task.needed()) { task.fail(new ReadCancelledError()); continue; }
        const descriptor: ImageDescriptor = { variant: result.variant, sha256: result.sha256, byteSize: result.byteSize, width: result.width, height: result.height,
          ownerUid: result.ownerUid, cardId: result.cardId, cardRevision: result.cardRevision, recipeVersion: result.recipeVersion };
        if (result.status !== 'CACHE_OK' || task.cached === undefined || task.cached.descriptor.sha256 !== descriptor.sha256) {
          task.cached = await ImageDiskCache.put(context, task.mediaId, task.mode, task.variant, task.revisionId, descriptor, result.dataBase64);
        }
        if (!await task.needed()) { task.fail(new ReadCancelledError()); continue; }
        ImageDescriptors.record(task.mediaId, task.mode, task.variant, descriptor, task.revisionId);
        task.finish(ImageDiskCache.url(context, task.cached));
      } catch (error) { task.fail(error instanceof Error ? error : new Error('兼容图片读取失败。')); }
    }
  }
  static async hydrateCovers(context: common.Context, cards: Array<FoodCard>, guard: MediaRequestGuard, onSettled: (card: FoodCard) => void,
    revalidate: boolean = false, priority: MediaPriority = 'normal', isCardNeeded?: (card: FoodCard) => boolean): Promise<void> {
    const cycle: number = revalidate ? ++ImageRepository.readCycle : 0;
    await Promise.all(cards.map(async (card: FoodCard): Promise<void> => {
      const photo: CardPhoto | undefined = card.photos?.[0];
      const valid: MediaRequestGuard = async (): Promise<boolean> => await guard() && (isCardNeeded === undefined || isCardNeeded(card));
      if (!await valid()) return;
      if (card.photoPath.length === 0) { card.primaryPhotoResolved = true; card.primaryPhotoLoadFailed = false; onSettled(card); return; }
      try {
        card.photoUrl = await ImageRepository.getDownloadUrl(context, card.photoBucket, card.photoPath, priority, valid, photo, true, revalidate, cycle);
        const permit: ImageDescriptor | undefined = ImageDescriptors.read(photo?.id || card.photoPath.split('/').pop()?.replace('.jpg', '') || '', 'PUBLIC', 'COVER_480');
        card.mediaContentChanged = card.contentRevision !== undefined && permit !== undefined && permit.cardRevision.length > 0 && permit.cardRevision !== card.contentRevision;
        if (photo !== undefined) photo.url = card.photoUrl;
        card.mediaAccessDenied = false; card.primaryPhotoLoadFailed = card.photoUrl.length === 0; card.primaryPhotoResolved = true;
      } catch (error) {
        if (error instanceof ReadCancelledError) return;
        card.photoUrl = ''; card.primaryPhotoResolved = true; card.primaryPhotoLoadFailed = true;
        card.mediaAccessDenied = error instanceof CloudBusinessError && ['CONTENT_ACCESS_DENIED', 'ACCOUNT_INACTIVE', 'CONTENT_UNAVAILABLE'].includes(error.code);
      }
      if (await valid()) onSettled(card);
    }));
  }
}
