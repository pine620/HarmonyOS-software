/**
 * 【文件职责】全 App 唯一的图片任务中心：页面需要显示一张图片时向这里“订阅”，拿到本机 file:// 地址。
 * 【查找顺序】
 *   1. ImageDescriptors：本会话是否允许显示这张图、它的 sha256 与大小是多少；
 *   2. ImageDiskCache：磁盘缓存命中且摘要校验通过则直接返回；
 *   3. PublicCoverDirectReader：公开的 480px 封面直接从 Cloud Storage 读；
 *   4. image-read-batch：调用 shike-image 批量读取（封面最多 4 张、总计不超过 512KB 一批），
 *      读到的 Base64 写入磁盘缓存后返回地址；IMAGE_TRANSPORT=LEGACY 时改为逐张读取旧接口。
 * 【调度】同一张图（同账号 + mediaId + 模式 + 尺寸 + 修订号）只会有一个任务，多个页面共享；
 * 按优先级 high > normal > prefetch > low 出队；页面离开（守卫返回 false）后，无人需要的任务会被取消。
 * 【新人注意】账号切换时 setCacheOwner 会撤销全部图片授权并切换磁盘缓存索引，旧账号的私有图片不会被新账号看到。
 */
import { common } from '@kit.AbilityKit';
import { CardPhoto, FoodCard } from '../model/CloudContracts';
import { ImageBatchResponse, ImageCacheEntry, ImageDescriptor, ImageMode, ImageReadItem, ImageReadRequest, ImageReadResult, ImageVariant, LegacyImageRequest, LegacyImageResponse, MediaPriority, MediaRequestGuard } from '../model/ImageModels';
import { CloudGateway } from './CloudGateway';
import { CloudBusinessError, ReadCancelledError } from './CloudReadErrors';
import { AuthSessionStore } from './AuthSessionStore';
import { ImageDescriptors } from './ImageDescriptors';
import { IMAGE_TRANSPORT, IMAGE_ALLOW_LEGACY_ON_UNSUPPORTED, ImageTransport } from './ImageReadConfig';
import { ReadPriority, ReadRequestOptions, ReadScheduler } from './ReadScheduler';
import { ImageDiskCache } from './ImageDiskCache';
import { PublicCoverDirectReader } from './PublicCoverDirectReader';
export { MediaPriority, MediaRequestGuard } from '../model/ImageModels';

// 图片任务可能的失败类型。
type ImageTaskError = Error | ReadCancelledError | CloudBusinessError;

/**
 * 一张图片的读取任务。key 唯一标识“谁的哪张图的哪个版本”；
 * session / epoch 记录创建时的会话代次与图片授权版本，变化后任务作废；guards 是各订阅页面的“是否还需要”回调。
 */
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
  // 是否仍需要这个任务：会话和授权版本未变化，且至少有一个订阅者仍然需要。
  async needed(): Promise<boolean> {
    if (this.session !== AuthSessionStore.generation() || this.epoch !== ImageDescriptors.epoch() || AppStorage.get<boolean>('stage47AppActive') === false) return false;
    for (const guard of this.guards) try { if (await guard()) return true; } catch (_error) { }
    return false;
  }
  // 以失败结束任务（只结束一次）。
  fail(error: ImageTaskError): void { if (!this.settled) { this.settled = true; this.reject(error); } }
  // 以成功结束任务，返回本机图片地址（只结束一次）。
  finish(url: string): void { if (!this.settled) { this.settled = true; this.resolve(url); } }
}

// 全 App 唯一的图片任务管理者：页面只是订阅者；真正的云调用仍要占用 ReadScheduler 的槽位。
export class ImageRepository {
  // 任务表（去重）、等待队列、是否正在出队、读图方式、是否已确认服务端不支持新协议、当前缓存所属账号。
  private static tasks: Map<string, ImageTask> = new Map<string, ImageTask>();
  private static pending: Array<ImageTask> = [];
  private static running: boolean = false;
  private static timer: number | undefined = undefined;
  private static transport: ImageTransport = IMAGE_TRANSPORT;
  private static unsupported: boolean = false;
  private static owner: string = '';
  private static readCycle: number = 0;
  private static ownerSession: number = -1;
  // 切换图片缓存所属账号：撤销全部图片授权、切换磁盘缓存索引、取消所有排队中的旧账号任务。
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
  // 页面订阅变化时调用：异步清理没有订阅者的任务。
  static subscriptionsChanged(): void { void ImageRepository.pruneUnused(); }
  // 取消已经没有人需要的排队任务。
  private static async pruneUnused(): Promise<void> {
    for (const task of ImageRepository.pending.slice()) if (!await task.needed()) {
      if (!ImageRepository.pending.includes(task)) continue;
      ImageRepository.pending = ImageRepository.pending.filter((value: ImageTask): boolean => value !== task);
      if (ImageRepository.tasks.get(task.key) === task) ImageRepository.tasks.delete(task.key);
      task.fail(new ReadCancelledError());
    }
  }
  // 用户点“重试”时调用：清除“服务端不支持”的标记，下次重新尝试新协议。
  static retryUnavailableService(): void { ImageRepository.unsupported = false; }
  // 服务端是否尚未启用图片新协议（界面据此显示可重试占位）。
  static isMediaServiceUnavailable(): boolean { return ImageRepository.unsupported; }
  // 清空本机图片缓存，并撤销所有图片授权（设置页“清除缓存”使用）。
  static async clearCachedMedia(context: common.Context): Promise<void> { ImageDescriptors.revoke(); await ImageDiskCache.clear(context); }
  // 图片解码失败时调用：删除这张图的缓存文件，下次重新从云端读取。
  static async reportDecodeFailure(context: common.Context, mediaId: string, variant: ImageVariant = 'ORIGINAL', mode: ImageMode = 'PUBLIC', revisionId: string = ''): Promise<void> { ImageDescriptors.remove(mediaId); await ImageDiskCache.evict(context, mediaId, variant, mode, revisionId); }
  // 按本地地址报告解码失败（只知道 file:// 地址时使用）。
  static async reportDecodeFailureByUrl(context: common.Context, url: string): Promise<void> {
    const session: number = AuthSessionStore.generation();
    const mediaId: string = await ImageDiskCache.evictUrl(context, url);
    if (session === AuthSessionStore.generation() && mediaId.length > 0) ImageDescriptors.remove(mediaId);
  }
  // 这张卡片的封面是否已有可复用的授权与缓存（用于决定能否先显示缓存封面）。
  static canReuseCover(card: FoodCard): boolean {
    const id: string = card.photos?.[0]?.id || card.photoPath.split('/').pop()?.replace('.jpg', '') || '';
    const descriptor: ImageDescriptor | undefined = ImageDescriptors.read(id, 'PUBLIC', 'COVER_480') || ImageDescriptors.read(id, 'PUBLIC', 'ORIGINAL');
    return descriptor !== undefined && card.photoUrl.length > 0 &&
      (!card.contentRevision || descriptor.cardRevision === card.contentRevision);
  }
  // 只在本机查询当前内容版本对应的缓存。
  static async cachedPhotoUrl(context: common.Context, photo: CardPhoto, cover: boolean, cardRevision: string = ''): Promise<string> {
    const id: string = photo.id || photo.path.split('/').pop()?.replace('.jpg', '') || '';
    const url: string = await ImageRepository.cachedUrl(context, id, 'PUBLIC', cover ? 'COVER_480' : 'ORIGINAL', '', cardRevision);
    return cover && url.length === 0 ? ImageRepository.cachedUrl(context, id, 'PUBLIC', 'ORIGINAL', '', cardRevision) : url;
  }
  // 只查本机：授权表中有描述符且磁盘缓存校验通过时返回地址，否则返回空串。
  private static async cachedUrl(context: common.Context, mediaId: string, mode: ImageMode, variant: ImageVariant,
    revisionId: string, cardRevision: string = ''): Promise<string> {
    const session: number = AuthSessionStore.generation(); const epoch: number = ImageDescriptors.epoch();
    const permit: ImageDescriptor | undefined = ImageDescriptors.read(mediaId, mode, variant, revisionId);
    if (permit === undefined || cardRevision.length > 0 && permit.cardRevision !== cardRevision) return '';
    const cached: ImageCacheEntry | undefined = await ImageDiskCache.find(context, mediaId, mode, variant, revisionId);
    const current: ImageDescriptor | undefined = ImageDescriptors.read(mediaId, mode, variant, revisionId);
    if (session !== AuthSessionStore.generation() || epoch !== ImageDescriptors.epoch() || cached === undefined || current === undefined ||
      current.sha256 !== permit.sha256 || current.cardRevision !== permit.cardRevision || cached.descriptor.sha256 !== current.sha256 ||
      cached.descriptor.byteSize !== current.byteSize || cached.descriptor.variant !== current.variant) return '';
    return ImageDiskCache.url(context, cached);
  }
  /**
   * 获取一张卡片图片 / 头像的本机地址（最常用的入口）。
   * bucket + path 是卡片数据里的存储位置；cover=true 时优先取 480px 封面；revalidate=true 时即使有缓存也重新确认授权。
   * mayContinue 返回 false 时取消订阅（页面已离开）。
   */
  static async getDownloadUrl(context: common.Context, bucket: string, path: string, priority: MediaPriority = 'normal', mayContinue?: MediaRequestGuard,
    photo?: CardPhoto, cover: boolean = false, revalidate: boolean = false, readCycle: number = 0): Promise<string> {
    if (bucket.trim().length === 0) return '';
    const match: RegExpMatchArray | null = path.match(/^public\/approved\/[^/]+\/([0-9a-f-]{36})\.jpg$/i);
    const mediaId: string = photo !== undefined && photo.id.length > 0 ? photo.id : match === null ? '' : match[1];
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(mediaId)) return '';
    return ImageRepository.subscribe(context, mediaId, 'PUBLIC', cover ? 'COVER_480' : 'ORIGINAL', '', priority, mayContinue, revalidate, bucket, path, readCycle);
  }
  // 获取“修订版本”中的图片（作者修改未生效时预览用）。
  static getRevisionDownloadUrl(context: common.Context, revisionId: string, mediaId: string, mayContinue?: MediaRequestGuard): Promise<string> {
    return ImageRepository.subscribe(context, mediaId, 'REVISION', 'ORIGINAL', revisionId, 'high', mayContinue, true);
  }
  // 获取举报 / 审核页面中的图片：admin=true 走审核模式（仅审核员可读）。
  static getCardReportPhotoUrl(context: common.Context, mediaId: string, reportId: string, admin: boolean, cover: boolean, mayContinue: MediaRequestGuard): Promise<string> {
    return ImageRepository.subscribe(context, mediaId, admin ? 'REPORT' : 'PUBLIC', cover ? 'COVER_480' : 'ORIGINAL', admin ? reportId : '', 'high', mayContinue, true);
  }
  // 订阅一张图片：已有同 key 任务则加入订阅，否则新建任务入队；被取消的预取在重新可见时允许重新加入一次。
  private static async subscribe(context: common.Context, mediaId: string, mode: ImageMode, variant: ImageVariant, revisionId: string,
    priority: MediaPriority, mayContinue: MediaRequestGuard | undefined, force: boolean, bucket: string = '', path: string = '', readCycle: number = 0): Promise<string> {
    const session: number = AuthSessionStore.generation(); const epoch: number = ImageDescriptors.epoch();
    const lifecycle: number = ReadScheduler.lifecycleRevision();
    if (ImageRepository.isForeground(priority)) ReadScheduler.beginImageWork();
    try { return await ImageRepository.subscribeImage(context, mediaId, mode, variant, revisionId, priority, mayContinue, force, bucket, path, readCycle); }
    catch (error) {
      // 排队中的预取任务可能在刚变为可见时被取消；如果仍是同一个活跃的前台订阅，允许重新加入一次。
      if (error instanceof ReadCancelledError && ImageRepository.isForeground(priority) &&
        (mayContinue === undefined || await mayContinue()) && session === AuthSessionStore.generation() &&
        epoch === ImageDescriptors.epoch() && lifecycle === ReadScheduler.lifecycleRevision() && AppStorage.get<boolean>('stage47AppActive') !== false)
        return await ImageRepository.subscribeImage(context, mediaId, mode, variant, revisionId, priority, mayContinue, force, bucket, path, readCycle);
      throw error instanceof Error ? error : new Error('图片读取失败。');
    }
    finally { if (ImageRepository.isForeground(priority)) ReadScheduler.endImageWork(); }
  }
  // 订阅的具体实现：先查授权与磁盘缓存，未命中再创建任务并触发出队。
  private static async subscribeImage(context: common.Context, mediaId: string, mode: ImageMode, variant: ImageVariant, revisionId: string,
    priority: MediaPriority, mayContinue: MediaRequestGuard | undefined, force: boolean, bucket: string, path: string, readCycle: number): Promise<string> {
    const guard: MediaRequestGuard = mayContinue === undefined ? async (): Promise<boolean> => true : mayContinue;
    const session: number = AuthSessionStore.generation(); const epoch: number = ImageDescriptors.epoch();
    if (!await guard()) throw new ReadCancelledError();
    if (!force) {
      const local: string = await ImageRepository.cachedUrl(context, mediaId, mode, variant, revisionId);
      if (!await guard() || session !== AuthSessionStore.generation() || epoch !== ImageDescriptors.epoch()) throw new ReadCancelledError();
      if (local.length > 0) { console.info('[ImageCache] event=fast-hit bytes=0'); return local; }
    }
    if (!ImageRepository.isForeground(priority) && !ReadScheduler.canPrefetch()) throw new ReadCancelledError();
    if (ImageRepository.unsupported) throw new CloudBusinessError('图片服务尚未启用，请稍后重试。', 'NOT_SUPPORTED');
    const cycle: number = force && readCycle === 0 ? ++ImageRepository.readCycle : readCycle;
    const known: ImageDescriptor | undefined = ImageDescriptors.read(mediaId, mode, variant, revisionId);
    const key: string = ImageDescriptors.key(mediaId, mode, variant, revisionId) + ':' + (known?.sha256 || '') + ':' + cycle + ':' + AuthSessionStore.generation() + ':' + ImageDescriptors.epoch();
    let task: ImageTask | undefined = ImageRepository.tasks.get(key);
    if (task !== undefined && task.settled) { ImageRepository.tasks.delete(key); task = undefined; }
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
  // 是否为前台优先级（high / normal）。
  private static isForeground(priority: MediaPriority): boolean { return priority === 'high' || priority === 'normal'; }
  // 优先级排序值（越小越优先）。
  private static rank(priority: MediaPriority): number { return priority === 'high' ? 0 : priority === 'normal' ? 1 : priority === 'prefetch' ? 2 : 3; }
  /**
   * 出队循环（同一时间只运行一个）：按优先级取出任务，能合并时把最多 4 张、总大小不超过 512KB 的封面合成一批，
   * 交给 load()；服务端返回 NOT_SUPPORTED 时把剩余任务全部以“图片服务尚未启用”结束。
   */
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
        ImageRepository.pending.sort((a: ImageTask, b: ImageTask): number => ImageRepository.rank(a.priority) - ImageRepository.rank(b.priority) || a.createdAt - b.createdAt);
        const first: ImageTask | undefined = ImageRepository.pending.shift(); if (first === undefined) break;
        const batch: Array<ImageTask> = [first];
        const firstCover: ImageDescriptor | undefined = ImageDescriptors.read(first.mediaId, first.mode, 'COVER_480', first.revisionId);
        if (first.variant === 'COVER_480' && firstCover !== undefined && firstCover.variant === 'COVER_480') {
          let remainingBytes: number = 524288 - firstCover.byteSize;
          for (const task of ImageRepository.pending.slice()) {
            const cover: ImageDescriptor | undefined = ImageDescriptors.read(task.mediaId, task.mode, 'COVER_480', task.revisionId);
            if (batch.length >= 4 || cover === undefined || cover.variant !== 'COVER_480' || cover.byteSize > remainingBytes) continue;
            if (task.variant === 'COVER_480' && task.mode === first.mode && task.session === first.session && task.epoch === first.epoch && !batch.some((entry: ImageTask): boolean => entry.mediaId === task.mediaId && entry.revisionId === task.revisionId)) {
              batch.push(task); ImageRepository.pending = ImageRepository.pending.filter((item: ImageTask): boolean => item !== task);
              remainingBytes -= cover.byteSize;
            }
          }
        }
        console.info('[ImageRepository] event=batch count=' + batch.length + ' pending=' + ImageRepository.pending.length + ' mode=' + first.mode + ' requestedVariant=' + first.variant);
        try { await ImageRepository.load(context, batch); }
        catch (error) { if (error instanceof CloudBusinessError && error.code === 'NOT_SUPPORTED') ImageRepository.unsupported = true; const failure: Error = error instanceof Error ? error : new Error('图片读取失败。'); for (const task of batch) task.fail(failure); }
        finally { for (const task of batch) if (ImageRepository.tasks.get(task.key) === task) ImageRepository.tasks.delete(task.key); }
      }
    } finally { ImageRepository.running = false; }
  }
  // 处理一批任务：过滤已不需要的任务，先尝试公开封面直读，剩下的交给 fetch()（批量）或 fetchLegacy()（旧接口）。
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
      task.descriptor = ImageDescriptors.read(task.mediaId, task.mode, task.variant, task.revisionId);
      if (!task.force && task.cached !== undefined && task.descriptor !== undefined && task.cached.descriptor.sha256 === task.descriptor.sha256 && task.cached.descriptor.variant === task.descriptor.variant) {
        task.finish(ImageDiskCache.url(context, task.cached)); console.info('[ImageCache] event=hit bytes=0');
      } else needed.push(task);
    }
    if (needed.length === 0) return;
    // 所有小封面在一次有大小上限的响应中返回；服务端控制字节预算，缺失封面时改为单张读取原图。
    await ImageRepository.fetch(context, needed);
    const rest: Array<ImageTask> = needed.filter((task: ImageTask): boolean => !task.settled);
    // 缺少某个尺寸时，拆分一次为“单张读原图”的请求。
    for (const task of rest) if (!task.settled) await ImageRepository.fetch(context, [task]);
    for (const task of batch) if (!task.settled) task.fail(new CloudBusinessError('图片暂未就绪，请单张重试。', 'MEDIA_DEFERRED'));
  }
  // 已发布且描述符已知的封面，直接从 Cloud Storage 读取。
  // 公开封面直读：描述符已知的已发布封面直接从 Cloud Storage 读取，写入磁盘缓存时按描述符校验字节。
  private static async readDirectCovers(context: common.Context, tasks: Array<ImageTask>): Promise<void> {
    if (!PublicCoverDirectReader.available()) return;
    await Promise.all(tasks.map(async (task: ImageTask): Promise<void> => {
      if (task.mode !== 'PUBLIC' || task.variant !== 'COVER_480' || task.revisionId.length > 0 || task.path.length === 0) return;
      const descriptor: ImageDescriptor | undefined = ImageDescriptors.read(task.mediaId, 'PUBLIC', 'COVER_480');
      if (descriptor === undefined || descriptor.variant !== 'COVER_480' || !/^[a-f0-9]{64}$/.test(descriptor.sha256)) return;
      const cloudPath: string = PublicCoverDirectReader.coverPath(task.path, task.mediaId);
      if (cloudPath.length === 0) return;
      try {
        const base64: string = await PublicCoverDirectReader.readBase64(task.bucket, cloudPath, descriptor);
        if (!await task.needed()) { task.fail(new ReadCancelledError()); return; }
        task.cached = await ImageDiskCache.put(context, task.mediaId, 'PUBLIC', 'COVER_480', '', descriptor, base64);
        if (!await task.needed()) { task.fail(new ReadCancelledError()); return; }
        ImageDescriptors.record(task.mediaId, 'PUBLIC', 'COVER_480', descriptor, '');
        task.descriptor = descriptor;
        task.finish(ImageDiskCache.url(context, task.cached));
        console.info('[ImageRead] event=direct-cover');
      } catch (_error) {
        PublicCoverDirectReader.recordFailure();
      }
    }));
  }
  // 批量读图：调用 image-read-batch（shike-image），把返回的 Base64 写入磁盘缓存并完成任务。
  private static async fetch(context: common.Context, tasks: Array<ImageTask>): Promise<void> {
    const candidates: Array<ImageTask> = [];
    for (const task of tasks) if (await task.needed()) candidates.push(task); else task.fail(new ReadCancelledError());
    if (candidates.length === 0) return;
    await ImageRepository.readDirectCovers(context, candidates);
    const active: Array<ImageTask> = candidates.filter((task: ImageTask): boolean => !task.settled);
    if (active.length === 0) return;
    const items: Array<ImageReadItem> = active.map((task: ImageTask): ImageReadItem => {
      const item: ImageReadItem = { mediaId: task.mediaId, mode: task.mode, variant: task.variant, revisionId: task.revisionId,
        knownSha256: task.cached === undefined ? '' : task.cached.descriptor.sha256, knownByteSize: task.cached === undefined ? 0 : task.cached.descriptor.byteSize,
        wantBytes: true };
      return item;
    });
    // 新的显示确认不能加入在“隐藏/撤销授权”之前就已发出的云调用。
    let cycle: number = 0;
    for (const task of active) cycle = Math.max(cycle, task.readCycle);
    const request: ImageReadRequest = { protocolVersion: 'image-read-v1', items, readScope: active[0].epoch + ':' + cycle };
    const options: ReadRequestOptions = {
      priority: ImageRepository.isForeground(active[0].priority) ? 'cover' : 'prefetch', mayContinue: async (): Promise<boolean> => {
        for (const task of active) if (await task.needed()) return true; return false;
      }, currentPriority: (): ReadPriority => active.some((task: ImageTask): boolean => ImageRepository.isForeground(task.priority)) ? 'cover' : 'prefetch'
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
  // 旧接口逐张读图（get-public-media / get-review-media / get-revision-media），仅在 LEGACY 模式下使用。
  private static async fetchLegacy(context: common.Context, tasks: Array<ImageTask>): Promise<void> {
    for (const task of tasks) {
      if (task.mode === 'REPORT') { task.fail(new Error('审核图片需要新版 shike-image 云函数，请更新后重试。')); continue; }
      if (!await task.needed()) { task.fail(new ReadCancelledError()); continue; }
      const payload: LegacyImageRequest = { mediaId: task.mediaId, revisionId: task.revisionId, bucketName: task.bucket, cloudPath: task.path,
        variant: task.variant, knownSha256: task.cached === undefined ? '' : task.cached.descriptor.sha256,
        knownByteSize: task.cached === undefined ? 0 : task.cached.descriptor.byteSize, readScope: task.epoch + ':' + task.readCycle };
      const options: ReadRequestOptions = { priority: ImageRepository.isForeground(task.priority) ? 'cover' : 'prefetch',
        currentPriority: (): ReadPriority => ImageRepository.isForeground(task.priority) ? 'cover' : 'prefetch', mayContinue: async (): Promise<boolean> => task.needed() };
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
  // 为一组卡片批量加载封面（推荐流使用），每完成一张调用一次 onSettled，界面可逐张刷新。
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
