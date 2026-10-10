import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { ImageCacheEntry, ImageDescriptor, ImageMode, ImageVariant } from '../model/ImageModels';

interface LegacyImageFile { path: string; byteSize: number; modified: number; }
interface ImageDiskIndex { entries: Array<ImageCacheEntry>; }
export class ImageDiskCache {
  private static owner: string = 'guest';
  private static namespace: string = '';
  private static entries: Array<ImageCacheEntry> = [];
  private static loaded: string = '';
  private static loading: Promise<void> | undefined = undefined;
  private static writes: Promise<void> = Promise.resolve();
  private static lastAccessPersistAt: number = 0;
  private static verified: Map<string, string> = new Map<string, string>();
  static activate(owner: string): void {
    const next: string = owner || 'guest';
    if (next === ImageDiskCache.owner) return;
    ImageDiskCache.owner = next; ImageDiskCache.namespace = ''; ImageDiskCache.entries = []; ImageDiskCache.loaded = ''; ImageDiskCache.loading = undefined; ImageDiskCache.verified.clear();
  }
  static directory(context: common.Context): string { return context.cacheDir + '/shike-image-v1'; }
  private static async hash(bytes: Uint8Array): Promise<string> {
    const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    const input: cryptoFramework.DataBlob = { data: bytes };
    await digest.update(input);
    const value: Uint8Array = (await digest.digest()).data;
    let result: string = ''; for (const byte of value) result += byte.toString(16).padStart(2, '0');
    return result;
  }
  private static async ensure(context: common.Context): Promise<void> {
    const owner: string = ImageDiskCache.owner;
    if (ImageDiskCache.loaded === owner) return;
    if (ImageDiskCache.loading !== undefined) return ImageDiskCache.loading;
    const task: Promise<void> = (async (): Promise<void> => {
      const namespace: string = await ImageDiskCache.hash(new util.TextEncoder().encode(owner));
      const directory: string = ImageDiskCache.directory(context);
      try { await fileIo.mkdir(directory); } catch (_error) { if (!await fileIo.access(directory)) throw new Error('无法创建图片缓存。'); }
      let entries: Array<ImageCacheEntry> = [];
      try {
        const raw: string = await fileIo.readText(directory + '/' + namespace + '.json');
        const index: ImageDiskIndex = JSON.parse(raw) as ImageDiskIndex;
        if (raw.length <= 262144 && Array.isArray(index.entries)) entries = index.entries.slice(0, 64).filter((entry: ImageCacheEntry): boolean =>
          typeof entry.fileName === 'string' && /^[a-f0-9]{64}\.jpg$/.test(entry.fileName) && entry.descriptor !== undefined && /^[a-f0-9]{64}$/.test(entry.descriptor.sha256 || ''));
      } catch (_error) { }
      if (owner === ImageDiskCache.owner) {
        const keep: Set<string> = new Set<string>(entries.map((entry: ImageCacheEntry): string => entry.fileName));
        for (const name of await fileIo.listFile(directory)) {
          if (owner !== ImageDiskCache.owner) return;
          if (/^[a-f0-9]{64}\.jpg$/.test(name) && !keep.has(name) || /^[a-f0-9]{64}\.json$/.test(name) && name !== namespace + '.json') try { await fileIo.unlink(directory + '/' + name); } catch (_error) { }
        }
      }
      if (owner === ImageDiskCache.owner) { ImageDiskCache.namespace = namespace; ImageDiskCache.entries = entries; ImageDiskCache.loaded = owner; }
    })();
    ImageDiskCache.loading = task;
    try { await task; } finally { if (ImageDiskCache.loading === task) ImageDiskCache.loading = undefined; }
  }
  static async find(context: common.Context, mediaId: string, mode: ImageMode, variant: ImageVariant, revisionId: string): Promise<ImageCacheEntry | undefined> {
    const owner: string = ImageDiskCache.owner; await ImageDiskCache.ensure(context);
    if (owner !== ImageDiskCache.owner) return undefined;
    const entry: ImageCacheEntry | undefined = ImageDiskCache.entries.find((row: ImageCacheEntry): boolean => row.mediaId === mediaId && row.mode === mode && row.requestedVariant === variant && row.revisionId === revisionId) ||
      ImageDiskCache.entries.find((row: ImageCacheEntry): boolean => row.mediaId === mediaId && row.mode === mode && row.descriptor.variant === variant && row.revisionId === revisionId);
    if (entry === undefined) return undefined;
    const path: string = ImageDiskCache.directory(context) + '/' + entry.fileName;
    let file: fileIo.File | undefined = undefined;
    try {
      const stat: fileIo.Stat = await fileIo.stat(path);
      if (!stat.isFile() || stat.size !== entry.descriptor.byteSize || stat.size < 4 || stat.size > 2097152) return undefined;
      const fingerprint: string = entry.descriptor.sha256 + ':' + stat.size + ':' + stat.mtime;
      if (ImageDiskCache.verified.get(path) !== fingerprint) {
        file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
        const bytes: ArrayBuffer = new ArrayBuffer(stat.size);
        if (await fileIo.read(file.fd, bytes) !== stat.size || await ImageDiskCache.hash(new Uint8Array(bytes)) !== entry.descriptor.sha256) return undefined;
        if (owner !== ImageDiskCache.owner) return undefined;
        ImageDiskCache.verified.set(path, fingerprint);
      }
      if (owner !== ImageDiskCache.owner) return undefined;
      entry.lastAccess = Date.now();
      if (Date.now() - ImageDiskCache.lastAccessPersistAt > 1000) { ImageDiskCache.lastAccessPersistAt = Date.now(); void ImageDiskCache.persist(context, owner).catch((): void => {}); }
      return entry;
    } catch (_error) { return undefined; }
    finally { if (file !== undefined) try { await fileIo.close(file); } catch (_error) { } }
  }
  static async migrateLegacy(context: common.Context, mediaId: string, mode: ImageMode, requested: ImageVariant, revisionId: string,
    bucket: string, cloudPath: string, descriptor?: ImageDescriptor): Promise<ImageCacheEntry | undefined> {
    const owner: string = ImageDiskCache.owner; const oldOwner: string = owner === 'guest' ? 'public' : owner;
    const variants: Array<ImageVariant> = requested === 'COVER_480' ? ['COVER_480', 'ORIGINAL'] : ['ORIGINAL'];
    for (const variant of variants) {
      const digests: Array<string> = descriptor !== undefined && descriptor.variant === variant ? [descriptor.sha256, 'legacy'] : ['legacy'];
      for (const digest of digests) {
        const key: string = mode === 'PUBLIC' ? oldOwner.length + ':' + oldOwner + ':' + bucket.trim() + ':' + cloudPath.trim() + ':jpeg-v4:' + variant + ':' + digest :
          mode === 'REVIEW' ? 'review:' + oldOwner + ':' + mediaId : 'revision:' + oldOwner + ':' + revisionId + ':' + mediaId;
        const path: string = context.cacheDir + '/shike-approved-media-v2/' + await ImageDiskCache.hash(new util.TextEncoder().encode(key)) + '.jpg';
        let file: fileIo.File | undefined = undefined;
        try {
          const stat: fileIo.Stat = await fileIo.stat(path);
          if (!stat.isFile() || stat.size < 4 || stat.size > 2097152) continue;
          file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY); const bytes: ArrayBuffer = new ArrayBuffer(stat.size);
          if (await fileIo.read(file.fd, bytes) !== stat.size) continue;
          await fileIo.close(file); file = undefined;
          const sha256: string = await ImageDiskCache.hash(new Uint8Array(bytes));
          if (owner !== ImageDiskCache.owner) return undefined;
          if (descriptor !== undefined && descriptor.variant === variant && (descriptor.sha256 !== sha256 || descriptor.byteSize !== stat.size)) continue;
          // This local descriptor is only a byte hint. It never registers server permission.
          const local: ImageDescriptor = { variant, sha256, byteSize: stat.size, width: descriptor?.width || 0, height: descriptor?.height || 0,
            ownerUid: '', cardId: descriptor?.cardId || '', cardRevision: '', recipeVersion: variant === 'COVER_480' ? 1 : 0 };
          const entry: ImageCacheEntry = await ImageDiskCache.put(context, mediaId, mode, requested, revisionId, local, new util.Base64Helper().encodeToStringSync(new Uint8Array(bytes)));
          if (owner !== ImageDiskCache.owner) return undefined;
          try { await fileIo.unlink(path); } catch (_error) { }
          console.info('[ImageCache] event=legacy-migrated'); return entry;
        } catch (_error) { }
        finally { if (file !== undefined) try { await fileIo.close(file); } catch (_error) { } }
      }
    }
    return undefined;
  }
  static url(context: common.Context, entry: ImageCacheEntry): string { return 'file://' + ImageDiskCache.directory(context) + '/' + entry.fileName; }
  static async put(context: common.Context, mediaId: string, mode: ImageMode, requested: ImageVariant, revisionId: string, descriptor: ImageDescriptor, base64: string): Promise<ImageCacheEntry> {
    const owner: string = ImageDiskCache.owner; await ImageDiskCache.ensure(context);
    const bytes: Uint8Array = new util.Base64Helper().decodeSync(base64);
    if (bytes.length < 4 || bytes.length > 2097152 || bytes.length !== descriptor.byteSize || bytes[0] !== 255 || bytes[1] !== 216 || bytes[2] !== 255 || bytes[bytes.length - 2] !== 255 || bytes[bytes.length - 1] !== 217 || await ImageDiskCache.hash(bytes) !== descriptor.sha256) throw new Error('图片校验失败。');
    const key: string = owner + ':' + mediaId + ':' + mode + ':' + revisionId + ':' + descriptor.variant + ':' + descriptor.recipeVersion + ':' + descriptor.sha256;
    const fileName: string = await ImageDiskCache.hash(new util.TextEncoder().encode(key)) + '.jpg';
    const path: string = ImageDiskCache.directory(context) + '/' + fileName;
    const temporary: string = path + '.' + util.generateRandomUUID() + '.tmp';
    let file: fileIo.File | undefined = undefined;
    try {
      file = await fileIo.open(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
      if (await fileIo.write(file.fd, bytes.buffer) !== bytes.length) throw new Error('图片缓存写入不完整。');
      await fileIo.close(file); file = undefined;
      if (owner !== ImageDiskCache.owner) throw new Error('账号已变化。');
      await fileIo.rename(temporary, path);
    } finally {
      if (file !== undefined) try { await fileIo.close(file); } catch (_error) { }
      try { await fileIo.unlink(temporary); } catch (_error) { }
    }
    if (owner !== ImageDiskCache.owner) throw new Error('账号已变化。');
    const entry: ImageCacheEntry = { key, mediaId, mode, requestedVariant: requested, revisionId, descriptor, fileName, lastAccess: Date.now() };
    await ImageDiskCache.enqueue(async (): Promise<void> => {
      if (owner !== ImageDiskCache.owner) throw new Error('账号已变化。');
      const replaced: Array<ImageCacheEntry> = ImageDiskCache.entries.filter((row: ImageCacheEntry): boolean => row.mediaId === mediaId && row.mode === mode && row.requestedVariant === requested && row.revisionId === revisionId && row.fileName !== fileName);
      ImageDiskCache.entries = ImageDiskCache.entries.filter((row: ImageCacheEntry): boolean => !(row.mediaId === mediaId && row.mode === mode && row.requestedVariant === requested && row.revisionId === revisionId));
      ImageDiskCache.entries.push(entry);
      for (const row of replaced) if (!ImageDiskCache.entries.some((value: ImageCacheEntry): boolean => value.fileName === row.fileName)) try { await fileIo.unlink(ImageDiskCache.directory(context) + '/' + row.fileName); } catch (_error) { }
      await ImageDiskCache.writeIndex(context, owner);
    });
    return entry;
  }
  private static enqueue(work: () => Promise<void>): Promise<void> {
    const task: Promise<void> = ImageDiskCache.writes.catch((): void => {}).then(work);
    ImageDiskCache.writes = task; return task;
  }
  private static persist(context: common.Context, owner: string): Promise<void> {
    return ImageDiskCache.enqueue(async (): Promise<void> => ImageDiskCache.writeIndex(context, owner));
  }
  private static async pruneLegacy(context: common.Context, owner: string, count: number, bytes: number): Promise<void> {
    const directory: string = context.cacheDir + '/shike-approved-media-v2'; const files: Array<LegacyImageFile> = [];
    try {
      for (const name of await fileIo.listFile(directory)) if (/^[a-f0-9]{64}\.jpg$/.test(name)) {
        const path: string = directory + '/' + name; const stat: fileIo.Stat = await fileIo.stat(path);
        const value: LegacyImageFile = { path, byteSize: stat.size, modified: stat.mtime }; files.push(value);
      }
      files.sort((a: LegacyImageFile, b: LegacyImageFile): number => b.modified - a.modified);
      for (const file of files) {
        if (owner !== ImageDiskCache.owner) return;
        if (count < 64 && bytes + file.byteSize <= 48 * 1024 * 1024) { count++; bytes += file.byteSize; }
        else try { await fileIo.unlink(file.path); } catch (_error) { }
      }
    } catch (_error) { }
  }
  private static async writeIndex(context: common.Context, owner: string): Promise<void> {
    if (owner !== ImageDiskCache.owner) return;
    const namespace: string = ImageDiskCache.namespace;
    ImageDiskCache.entries.sort((a: ImageCacheEntry, b: ImageCacheEntry): number => b.lastAccess - a.lastAccess);
    let total: number = 0; const keep: Array<ImageCacheEntry> = []; const removed: Array<ImageCacheEntry> = [];
    for (const entry of ImageDiskCache.entries) {
      if (keep.length < 64 && total + entry.descriptor.byteSize <= 48 * 1024 * 1024) { total += entry.descriptor.byteSize; keep.push(entry); }
      else removed.push(entry);
    }
    ImageDiskCache.entries = keep;
    const index: ImageDiskIndex = { entries: keep };
    const path: string = ImageDiskCache.directory(context) + '/' + namespace + '.json';
    const temporary: string = path + '.' + util.generateRandomUUID() + '.tmp';
    let file: fileIo.File | undefined = undefined;
    try {
      file = await fileIo.open(temporary, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      const bytes: Uint8Array = new util.TextEncoder().encode(JSON.stringify(index));
      if (await fileIo.write(file.fd, bytes.buffer) !== bytes.length) throw new Error('图片索引写入不完整。');
      await fileIo.close(file); file = undefined;
      if (owner !== ImageDiskCache.owner) return;
      await fileIo.rename(temporary, path);
      for (const row of removed) if (!keep.some((value: ImageCacheEntry): boolean => value.fileName === row.fileName)) try { await fileIo.unlink(ImageDiskCache.directory(context) + '/' + row.fileName); } catch (_error) { }
      await ImageDiskCache.pruneLegacy(context, owner, keep.length, total);
    } finally {
      if (file !== undefined) try { await fileIo.close(file); } catch (_error) { }
      try { await fileIo.unlink(temporary); } catch (_error) { }
    }
  }
  static async evictUrl(context: common.Context, url: string): Promise<string> {
    const owner: string = ImageDiskCache.owner; await ImageDiskCache.ensure(context);
    if (owner !== ImageDiskCache.owner) return '';
    const entry: ImageCacheEntry | undefined = ImageDiskCache.entries.find((row: ImageCacheEntry): boolean => ImageDiskCache.url(context, row) === url);
    if (entry === undefined) return '';
    await ImageDiskCache.evict(context, entry.mediaId, entry.requestedVariant, entry.mode, entry.revisionId);
    return owner === ImageDiskCache.owner ? entry.mediaId : '';
  }
  static async evict(context: common.Context, mediaId: string, variant: ImageVariant, mode: ImageMode, revisionId: string = ''): Promise<void> {
    const owner: string = ImageDiskCache.owner; await ImageDiskCache.ensure(context);
    await ImageDiskCache.enqueue(async (): Promise<void> => {
      if (owner !== ImageDiskCache.owner) return;
      const removed: Array<ImageCacheEntry> = ImageDiskCache.entries.filter((entry: ImageCacheEntry): boolean => entry.mediaId === mediaId &&
        (entry.requestedVariant === variant || entry.descriptor.variant === variant) && entry.mode === mode && entry.revisionId === revisionId);
      const files: Set<string> = new Set<string>(removed.map((entry: ImageCacheEntry): string => entry.fileName));
      ImageDiskCache.entries = ImageDiskCache.entries.filter((entry: ImageCacheEntry): boolean => !files.has(entry.fileName));
      for (const fileName of files) ImageDiskCache.verified.delete(ImageDiskCache.directory(context) + '/' + fileName);
      for (const entry of removed) if (!ImageDiskCache.entries.some((value: ImageCacheEntry): boolean => value.fileName === entry.fileName)) try { await fileIo.unlink(ImageDiskCache.directory(context) + '/' + entry.fileName); } catch (_error) { }
      await ImageDiskCache.writeIndex(context, owner);
    });
  }
  static async clear(context: common.Context): Promise<void> {
    const owner: string = ImageDiskCache.owner; await ImageDiskCache.ensure(context);
    await ImageDiskCache.enqueue(async (): Promise<void> => {
      if (owner !== ImageDiskCache.owner) return;
      const removed: Array<ImageCacheEntry> = ImageDiskCache.entries.slice();
      ImageDiskCache.entries = []; ImageDiskCache.verified.clear();
      for (const entry of removed) if (!ImageDiskCache.entries.some((value: ImageCacheEntry): boolean => value.fileName === entry.fileName)) try { await fileIo.unlink(ImageDiskCache.directory(context) + '/' + entry.fileName); } catch (_error) { }
      await ImageDiskCache.pruneLegacy(context, owner, 64, 48 * 1024 * 1024);
      await ImageDiskCache.writeIndex(context, owner);
    });
  }
}
