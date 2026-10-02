import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import util from '@ohos.util';
import { OperationResponse, PublicMediaRequest, PublicMediaResponse, UploadPreparedPhotoRequest } from '../model/CloudContracts';
import { CloudGateway, MediaServiceUnavailableError } from './CloudGateway';
import { NearbyPerformanceTrace, PreloadMetricState } from './NearbyPerformanceTrace';

const MEDIA_CACHE_IDLE_MS: number = 24 * 60 * 60 * 1000;
const MEDIA_CACHE_MAX_BYTES: number = 48 * 1024 * 1024;
const MEDIA_CACHE_MAX_FILES: number = 64;
const MEDIA_CACHE_MAX_FILE_BYTES: number = 8 * 1024 * 1024;
const MEDIA_URL_CACHE_MAX_ENTRIES: number = 128;
const MAX_CONCURRENT_MEDIA_DOWNLOADS: number = 2;
const MEDIA_DOWNLOAD_MAX_ATTEMPTS: number = 3;
const MEDIA_DOWNLOAD_RETRY_DELAY_MS: number = 600;

interface DownloadUrlCacheEntry {
  url: string;
  filePath: string;
}

export type MediaPriority = 'high' | 'normal' | 'low';
export type MediaRequestGuard = () => Promise<boolean>;

class MediaDownloadQueueEntry {
  cacheKey: string;
  priority: MediaPriority;
  operation: () => Promise<string>;
  resolve: (url: string) => void;
  reject: (error: Error | MediaServiceUnavailableError) => void;
  queuedAt: number = Date.now();

  constructor(cacheKey: string, priority: MediaPriority, operation: () => Promise<string>, resolve: (url: string) => void,
    reject: (error: Error | MediaServiceUnavailableError) => void) {
    this.cacheKey = cacheKey;
    this.priority = priority;
    this.operation = operation;
    this.resolve = resolve;
    this.reject = reject;
  }
}

export class PhotoUploadService {
  private static cacheOwner: string = 'public';
  private static cacheGeneration: number = 0;
  private static downloadUrlCache: Map<string, DownloadUrlCacheEntry> = new Map<string, DownloadUrlCacheEntry>();
  private static downloadUrlRequests: Map<string, Promise<string>> = new Map<string, Promise<string>>();
  private static mediaDownloadQueue: Array<MediaDownloadQueueEntry> = [];
  private static activeMediaDownloadCount: number = 0;

  static isMediaServiceUnavailable(): boolean {
    return CloudGateway.isMediaServiceUnavailable();
  }

  static retryMediaService(): void {
    CloudGateway.retryMediaService();
    PhotoUploadService.cacheGeneration += 1;
    PhotoUploadService.downloadUrlRequests.clear();
    PhotoUploadService.cancelQueuedMediaDownloads();
  }

  static setCacheOwner(uid: string): void {
    const nextOwner: string = uid.length > 0 ? uid : 'public';
    if (PhotoUploadService.cacheOwner === nextOwner) return;
    PhotoUploadService.cacheOwner = nextOwner;
    PhotoUploadService.cacheGeneration += 1;
    PhotoUploadService.downloadUrlCache.clear();
    PhotoUploadService.downloadUrlRequests.clear();
    PhotoUploadService.cancelQueuedMediaDownloads();
  }

  static clearCachedMedia(context: common.Context): void {
    PhotoUploadService.downloadUrlCache.clear();
    PhotoUploadService.downloadUrlRequests.clear();
    PhotoUploadService.cacheOwner = 'public';
    PhotoUploadService.cacheGeneration += 1;
    PhotoUploadService.cancelQueuedMediaDownloads();
    const directory: string = PhotoUploadService.cacheDirectory(context);
    try {
      for (const name of fileIo.listFileSync(directory)) {
        if (/^[0-9a-f]{64}\.jpg$/.test(name)) {
          try { fileIo.unlinkSync(`${directory}/${name}`); } catch (_error) { }
        }
      }
    } catch (_error) { }
  }

  static async upload(context: common.UIAbilityContext, bucketName: string, cloudPath: string,
    data: ArrayBuffer, sha256: string): Promise<void> {
    void context;
    const storageBucketName: string = bucketName.trim();
    if (storageBucketName.length === 0) {
      throw new Error('云端未返回云存储实例名称，请检查 shike-service 的 SHIKE_STORAGE_BUCKET 环境变量。');
    }
    const matchedMediaId: RegExpMatchArray | null = cloudPath.match(
      /^public\/approved\/[^/]+\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jpg$/i);
    if (matchedMediaId === null) {
      throw new Error('云端返回了无效的公开图片路径。');
    }
    if (!/^[a-f0-9]{64}$/i.test(sha256)) {
      throw new Error('图片摘要无效，请重新选择图片。');
    }
    const request: UploadPreparedPhotoRequest = {
      mediaId: matchedMediaId[1],
      dataBase64: new util.Base64Helper().encodeToStringSync(new Uint8Array(data)),
      sha256
    };
    console.info(`[PhotoUpload] server upload: bytes=${data.byteLength}, pathPrefix=public/approved`);
    const response: OperationResponse = await CloudGateway.callAuthenticated<OperationResponse>('upload-card-photo', request);
    if (!response.success) throw new Error('云端未确认图片上传。');
  }

  /**
   * Resolves an approved image through the authenticated business service and
   * stores it in the app cache. This avoids Cloud Storage's local-AGC-user
   * requirement for Huawei-account compatibility sessions.
   */
  static async getDownloadUrl(context: common.Context, bucketName: string, cloudPath: string,
    priority: MediaPriority = 'normal', mayContinue?: MediaRequestGuard): Promise<string> {
    if (mayContinue !== undefined && !await mayContinue()) return '';
    const storageBucketName: string = bucketName.trim();
    const normalizedCloudPath: string = cloudPath.trim();
    if (storageBucketName.length === 0 || !normalizedCloudPath.startsWith('public/approved/')) return '';
    const owner: string = PhotoUploadService.cacheOwner;
    const cacheKey: string = `${owner.length}:${owner}:${storageBucketName.length}:${storageBucketName}:${normalizedCloudPath}`;
    const cached: DownloadUrlCacheEntry | undefined = PhotoUploadService.downloadUrlCache.get(cacheKey);
    if (cached !== undefined && PhotoUploadService.usableCachedFile(cached.filePath)) {
      NearbyPerformanceTrace.record('media_cache', 'hit');
      return cached.url;
    }
    PhotoUploadService.downloadUrlCache.delete(cacheKey);
    const inFlight: Promise<string> | undefined = PhotoUploadService.downloadUrlRequests.get(cacheKey);
    if (inFlight !== undefined) {
      NearbyPerformanceTrace.record('media_cache', 'joined');
      PhotoUploadService.promoteQueued(cacheKey, priority);
      return inFlight;
    }
    const generation: number = PhotoUploadService.cacheGeneration;
    const urlRequest: Promise<string> = PhotoUploadService.resolveCachedOrDownload(context, cacheKey,
      storageBucketName, normalizedCloudPath, priority, generation, mayContinue);
    PhotoUploadService.downloadUrlRequests.set(cacheKey, urlRequest);
    try {
      const url: string = await urlRequest;
      if (url.length > 0 && generation === PhotoUploadService.cacheGeneration) {
        const filePath: string = url.slice('file://'.length);
        if (PhotoUploadService.downloadUrlCache.size >= MEDIA_URL_CACHE_MAX_ENTRIES) {
          PhotoUploadService.downloadUrlCache.clear();
        }
        PhotoUploadService.downloadUrlCache.set(cacheKey, { url, filePath });
      }
      return url;
    } finally {
      if (PhotoUploadService.downloadUrlRequests.get(cacheKey) === urlRequest) {
        PhotoUploadService.downloadUrlRequests.delete(cacheKey);
      }
    }
  }

  private static async resolveCachedOrDownload(context: common.Context, cacheKey: string, bucketName: string,
    cloudPath: string, priority: MediaPriority, generation: number, mayContinue?: MediaRequestGuard): Promise<string> {
    const filePath: string = await PhotoUploadService.cacheFilePath(context, cacheKey);
    if (mayContinue !== undefined && !await mayContinue()) return '';
    if (generation !== PhotoUploadService.cacheGeneration) return '';
    if (PhotoUploadService.usableCachedFile(filePath)) {
      NearbyPerformanceTrace.record('media_cache', 'hit');
      return `file://${filePath}`;
    }
    NearbyPerformanceTrace.record('media_cache', 'miss');
    if (CloudGateway.isMediaServiceUnavailable()) throw new MediaServiceUnavailableError();
    return PhotoUploadService.enqueueMediaDownload(cacheKey, priority,
      (): Promise<string> => PhotoUploadService.downloadApprovedMedia(context, filePath, bucketName,
        cloudPath, generation, mayContinue));
  }

  private static enqueueMediaDownload(cacheKey: string, priority: MediaPriority,
    operation: () => Promise<string>): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      PhotoUploadService.mediaDownloadQueue.push(new MediaDownloadQueueEntry(cacheKey, priority, operation,
        resolve, reject));
      PhotoUploadService.drainMediaDownloadQueue();
    });
  }

  private static cancelQueuedMediaDownloads(): void {
    const queued: Array<MediaDownloadQueueEntry> = PhotoUploadService.mediaDownloadQueue;
    PhotoUploadService.mediaDownloadQueue = [];
    queued.forEach((entry: MediaDownloadQueueEntry): void => {
      NearbyPerformanceTrace.record('media_queue', 'cancelled', entry.queuedAt);
      entry.resolve('');
    });
  }

  private static promoteQueued(cacheKey: string, priority: MediaPriority): void {
    for (const entry of PhotoUploadService.mediaDownloadQueue) {
      if (entry.cacheKey === cacheKey && PhotoUploadService.priorityRank(priority) <
        PhotoUploadService.priorityRank(entry.priority)) entry.priority = priority;
    }
  }

  private static priorityRank(priority: MediaPriority): number {
    return priority === 'high' ? 0 : priority === 'normal' ? 1 : 2;
  }

  private static drainMediaDownloadQueue(): void {
    if (CloudGateway.isMediaServiceUnavailable()) {
      const queued: Array<MediaDownloadQueueEntry> = PhotoUploadService.mediaDownloadQueue;
      PhotoUploadService.mediaDownloadQueue = [];
      queued.forEach((entry: MediaDownloadQueueEntry): void => {
        NearbyPerformanceTrace.record('media_queue', 'error', entry.queuedAt);
        entry.reject(new MediaServiceUnavailableError());
      });
      return;
    }
    while (PhotoUploadService.activeMediaDownloadCount < MAX_CONCURRENT_MEDIA_DOWNLOADS
      && PhotoUploadService.mediaDownloadQueue.length > 0) {
      let bestIndex: number = 0;
      for (let index = 1; index < PhotoUploadService.mediaDownloadQueue.length; index += 1) {
        if (PhotoUploadService.priorityRank(PhotoUploadService.mediaDownloadQueue[index].priority) <
          PhotoUploadService.priorityRank(PhotoUploadService.mediaDownloadQueue[bestIndex].priority)) bestIndex = index;
      }
      const entry: MediaDownloadQueueEntry | undefined = PhotoUploadService.mediaDownloadQueue.splice(bestIndex, 1)[0];
      if (entry === undefined) continue;
      PhotoUploadService.activeMediaDownloadCount += 1;
      void PhotoUploadService.runMediaDownload(entry);
    }
  }

  private static async runMediaDownload(entry: MediaDownloadQueueEntry): Promise<void> {
    NearbyPerformanceTrace.record('media_queue', 'success', entry.queuedAt);
    const started: number = Date.now();
    let state: PreloadMetricState = 'error';
    try {
      const url: string = await entry.operation();
      state = url.length > 0 ? 'success' : 'cancelled';
      entry.resolve(url);
    } catch (error) {
      if (error instanceof MediaServiceUnavailableError) {
        entry.reject(error);
      } else {
        const message: string = PhotoUploadService.mediaErrorMessage(error as Object);
        entry.reject(new Error(message));
      }
    } finally {
      NearbyPerformanceTrace.record('media_download', state, started);
      PhotoUploadService.activeMediaDownloadCount -= 1;
      PhotoUploadService.drainMediaDownloadQueue();
    }
  }

  private static async downloadApprovedMedia(context: common.Context, filePath: string, bucketName: string,
    cloudPath: string, generation: number, mayContinue?: MediaRequestGuard): Promise<string> {
    const request: PublicMediaRequest = { bucketName, cloudPath };
    let lastMessage: string = '获取实拍图失败。';
    for (let attempt = 1; attempt <= MEDIA_DOWNLOAD_MAX_ATTEMPTS; attempt += 1) {
      if (mayContinue !== undefined && !await mayContinue()) return '';
      if (generation !== PhotoUploadService.cacheGeneration) return '';
      try {
        const media: PublicMediaResponse = CloudGateway.hasSession()
          ? await CloudGateway.callAuthenticated<PublicMediaResponse>('get-public-media', request)
          : await CloudGateway.callPublic<PublicMediaResponse>('get-public-media', request);
        if (mayContinue !== undefined && !await mayContinue()) return '';
        if (generation !== PhotoUploadService.cacheGeneration) return '';
        return PhotoUploadService.writeCachedMedia(context, filePath, media);
      } catch (error) {
        if (error instanceof MediaServiceUnavailableError) throw error;
        lastMessage = PhotoUploadService.mediaErrorMessage(error as Object);
        const canRetry: boolean = PhotoUploadService.isBusyMediaError(lastMessage)
          && attempt < MEDIA_DOWNLOAD_MAX_ATTEMPTS;
        if (!canRetry) throw new Error(lastMessage);
        const delayMs: number = MEDIA_DOWNLOAD_RETRY_DELAY_MS * attempt;
        console.warn(`[PhotoDownload] get-public-media busy; retry ${attempt + 1}/${MEDIA_DOWNLOAD_MAX_ATTEMPTS} after ${delayMs}ms.`);
        await PhotoUploadService.waitForRetry(delayMs);
      }
    }
    throw new Error(lastMessage);
  }

  private static mediaErrorMessage(error: Object): string {
    return error instanceof Error && error.message.length > 0 ? error.message : '获取实拍图失败。';
  }

  private static isBusyMediaError(message: string): boolean {
    return message.includes('3007009') || message.includes('too many requests');
  }

  private static waitForRetry(delayMs: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout((): void => resolve(), delayMs);
    });
  }

  private static writeCachedMedia(context: common.Context, filePath: string, media: PublicMediaResponse): string {
    if (media.mimeType !== 'image/jpeg' || media.dataBase64.length === 0 || media.byteSize <= 3 ||
      media.byteSize > MEDIA_CACHE_MAX_FILE_BYTES) {
      throw new Error('云端返回了无效的图片内容。');
    }
    const decoded: Uint8Array = new util.Base64Helper().decodeSync(media.dataBase64);
    if (decoded.byteLength !== media.byteSize || decoded[0] !== 0xff || decoded[1] !== 0xd8 ||
      decoded[decoded.length - 2] !== 0xff || decoded[decoded.length - 1] !== 0xd9) {
      throw new Error('云端图片长度校验失败。');
    }
    PhotoUploadService.ensureCacheDirectory(context);
    const temporaryPath: string = `${filePath}.${util.generateRandomUUID()}.tmp`;
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(temporaryPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
      const exactBytes: Uint8Array = decoded.slice();
      const written: number = fileIo.writeSync(file.fd, exactBytes.buffer as ArrayBuffer);
      if (written !== decoded.byteLength) throw new Error('写入图片缓存失败。');
      fileIo.closeSync(file);
      file = undefined;
      // A stale or invalid destination may already exist; some file-system
      // implementations reject rename rather than replacing it.
      if (fileIo.accessSync(filePath)) fileIo.unlinkSync(filePath);
      fileIo.renameSync(temporaryPath, filePath);
    } catch (error) {
      try { fileIo.unlinkSync(temporaryPath); } catch (_error) { }
      const message: string = error instanceof Error && error.message.length > 0
        ? error.message : '写入图片缓存失败。';
      throw new Error(message);
    } finally {
      if (file !== undefined) {
        try { fileIo.closeSync(file); } catch (_error) { }
      }
    }
    PhotoUploadService.pruneCache(context, filePath);
    console.info(`[PhotoDownload] cached approved media: bytes=${media.byteSize}`);
    return `file://${filePath}`;
  }

  private static cacheDirectory(context: common.Context): string {
    return `${context.cacheDir}/shike-approved-media-v2`;
  }

  private static ensureCacheDirectory(context: common.Context): void {
    const directory: string = PhotoUploadService.cacheDirectory(context);
    if (!fileIo.accessSync(directory)) fileIo.mkdirSync(directory);
  }

  private static async cacheFilePath(context: common.Context, cacheKey: string): Promise<string> {
    const digest = cryptoFramework.createMd('SHA256');
    await digest.update({ data: new util.TextEncoder().encode(cacheKey) });
    const bytes: Uint8Array = (await digest.digest()).data;
    let hash: string = '';
    for (let index = 0; index < bytes.length; index += 1) hash += bytes[index].toString(16).padStart(2, '0');
    return `${PhotoUploadService.cacheDirectory(context)}/${hash}.jpg`;
  }

  private static usableCachedFile(filePath: string): boolean {
    if (filePath.length === 0) return false;
    let file: fileIo.File | undefined = undefined;
    try {
      const stat: fileIo.Stat = fileIo.statSync(filePath);
      if (!stat.isFile() || stat.size < 4 || stat.size > MEDIA_CACHE_MAX_FILE_BYTES ||
        Date.now() - stat.mtime * 1000 > MEDIA_CACHE_IDLE_MS) return false;
      file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      const first: Uint8Array = new Uint8Array(2);
      const last: Uint8Array = new Uint8Array(2);
      if (fileIo.readSync(file.fd, first.buffer as ArrayBuffer) !== 2) return false;
      fileIo.lseek(file.fd, stat.size - 2);
      if (fileIo.readSync(file.fd, last.buffer as ArrayBuffer) !== 2 ||
        first[0] !== 0xff || first[1] !== 0xd8 || last[0] !== 0xff || last[1] !== 0xd9) return false;
      try { fileIo.utimes(filePath, Date.now()); } catch (_error) { }
      return true;
    } catch (_error) {
      return false;
    } finally {
      if (file !== undefined) try { fileIo.closeSync(file); } catch (_error) { }
    }
  }

  private static pruneCache(context: common.Context, excludedPath: string): void {
    const directory: string = PhotoUploadService.cacheDirectory(context);
    let files: Array<string> = [];
    try { files = fileIo.listFileSync(directory); } catch (_error) { return; }
    const entries: Array<CacheFileStat> = [];
    let totalBytes: number = 0;
    for (const name of files) {
      if (!/^[0-9a-f]{64}\.jpg$/.test(name)) continue;
      const path: string = `${directory}/${name}`;
      try {
        const stat: fileIo.Stat = fileIo.statSync(path);
        if (!stat.isFile()) continue;
        if (Date.now() - stat.mtime * 1000 > MEDIA_CACHE_IDLE_MS || stat.size < 4 ||
          stat.size > MEDIA_CACHE_MAX_FILE_BYTES) {
          if (path !== excludedPath) fileIo.unlinkSync(path);
          continue;
        }
        totalBytes += stat.size;
        entries.push({ path, size: stat.size, modifiedAt: stat.mtime });
      } catch (_error) { }
    }
    entries.sort((left: CacheFileStat, right: CacheFileStat): number => left.modifiedAt - right.modifiedAt);
    let fileCount: number = entries.length;
    for (const entry of entries) {
      if (fileCount <= MEDIA_CACHE_MAX_FILES && totalBytes <= MEDIA_CACHE_MAX_BYTES) break;
      if (entry.path === excludedPath) continue;
      try {
        fileIo.unlinkSync(entry.path);
        totalBytes -= entry.size;
        fileCount -= 1;
      } catch (_error) { }
    }
  }
}

interface CacheFileStat {
  path: string;
  size: number;
  modifiedAt: number;
}
