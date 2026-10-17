/**
 * 【文件职责】图片磁盘缓存（目录 cacheDir/shike-image-v1）。
 * 每个文件以“账号命名空间 + mediaId + 模式 + 尺寸 + 修订号”为键记录在索引中，命中时按 sha256 与字节数校验，
 * 同样大小但内容损坏的文件不会被当作命中。容量上限 128 个文件 / 96MB，淘汰时优先保留列表封面，其余按最近使用时间淘汰。
 * 不同账号使用不同的索引命名空间；游客使用 guest。
 * 【新人注意】缓存命中只说明“文件有效”，是否允许显示仍由 ImageDescriptors 的授权决定。
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { ImageCacheEntry, ImageDescriptor, ImageMode, ImageVariant } from '../model/ImageModels';

// 旧版缓存目录中的文件信息（迁移用）。
interface LegacyImageFile { path: string; byteSize: number; modified: number; }
// 磁盘索引文件的结构。
interface ImageDiskIndex { entries: Array<ImageCacheEntry>; }
// 图片磁盘缓存（静态类）。
export class ImageDiskCache {
  // 当前账号、索引命名空间、内存中的索引、加载状态、串行写入队列、上次写索引时间、已校验文件表。
  private static owner: string = 'guest';
  private static namespace: string = '';
  private static entries: Array<ImageCacheEntry> = [];
  private static loaded: string = '';
  private static loading: Promise<void> | undefined = undefined;
  private static writes: Promise<void> = Promise.resolve();
  private static lastAccessPersistAt: number = 0;
  private static verified: Map<string, string> = new Map<string, string>();
  // 切换缓存所属账号（游客为 guest），下次访问时加载对应索引。
  static activate(owner: string): void {
    const next: string = owner || 'guest';
    if (next === ImageDiskCache.owner) return;
    ImageDiskCache.owner = next; ImageDiskCache.namespace = ''; ImageDiskCache.entries = []; ImageDiskCache.loaded = ''; ImageDiskCache.loading = undefined; ImageDiskCache.verified.clear();
  }
  // 缓存目录路径。
  static directory(context: common.Context): string { return context.cacheDir + '/shike-image-v1'; }
  // 计算字节的 SHA-256（十六进制）。
  private static async hash(bytes: Uint8Array): Promise<string> {
    const digest: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    const input: cryptoFramework.DataBlob = { data: bytes };
    await digest.update(input);
    const value: Uint8Array = (await digest.digest()).data;
    let result: string = ''; for (const byte of value) result += byte.toString(16).padStart(2, '0');
    return result;
  }
  // 确保当前账号的索引已加载到内存（并发调用共享同一次加载）。
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
        if (raw.length <= 262144 && Array.isArray(index.entries)) entries = index.entries.slice(0, 128).filter((entry: ImageCacheEntry): boolean =>
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
  // 查找缓存：存在且 sha256 / 字节数与描述符一致才返回条目，否则删除坏文件并返回 undefined。
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
  // 把旧版缓存目录中的同一张图迁移到新缓存（校验通过才迁移），避免升级后重新下载。
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
          // 这里的本地描述符只是字节提示，绝不代表服务端授予了显示权限。
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
  // 条目对应的 file:// 地址。
  static url(context: common.Context, entry: ImageCacheEntry): string { return 'file://' + ImageDiskCache.directory(context) + '/' + entry.fileName; }
  // 写入缓存：Base64 解码后按描述符校验大小与 sha256，通过后写文件并更新索引；校验失败抛错。
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
  // 把写操作串行化，避免并发写索引造成覆盖。
  private static enqueue(work: () => Promise<void>): Promise<void> {
    const task: Promise<void> = ImageDiskCache.writes.catch((): void => {}).then(work);
    ImageDiskCache.writes = task; return task;
  }
  // 异步持久化当前索引。
  private static persist(context: common.Context, owner: string): Promise<void> {
    return ImageDiskCache.enqueue(async (): Promise<void> => ImageDiskCache.writeIndex(context, owner));
  }
  // 清理旧版缓存目录，控制旧缓存占用。
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
        if (count < 128 && bytes + file.byteSize <= 96 * 1024 * 1024) { count++; bytes += file.byteSize; }
        else try { await fileIo.unlink(file.path); } catch (_error) { }
      }
    } catch (_error) { }
  }
  // 写索引并执行容量淘汰（最多 128 个文件 / 96MB）。
  private static async writeIndex(context: common.Context, owner: string): Promise<void> {
    if (owner !== ImageDiskCache.owner) return;
    const namespace: string = ImageDiskCache.namespace;
    // 后台原图在有限的缓存中轮换时，优先保留列表封面。
    ImageDiskCache.entries.sort((a: ImageCacheEntry, b: ImageCacheEntry): number =>
      Number(b.requestedVariant === 'COVER_480') - Number(a.requestedVariant === 'COVER_480') || b.lastAccess - a.lastAccess);
    let total: number = 0; const keep: Array<ImageCacheEntry> = []; const removed: Array<ImageCacheEntry> = [];
    for (const entry of ImageDiskCache.entries) {
      if (keep.length < 128 && total + entry.descriptor.byteSize <= 96 * 1024 * 1024) { total += entry.descriptor.byteSize; keep.push(entry); }
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
  // 按 file:// 地址删除缓存文件，返回对应的 mediaId。
  static async evictUrl(context: common.Context, url: string): Promise<string> {
    const owner: string = ImageDiskCache.owner; await ImageDiskCache.ensure(context);
    if (owner !== ImageDiskCache.owner) return '';
    const entry: ImageCacheEntry | undefined = ImageDiskCache.entries.find((row: ImageCacheEntry): boolean => ImageDiskCache.url(context, row) === url);
    if (entry === undefined) return '';
    await ImageDiskCache.evict(context, entry.mediaId, entry.requestedVariant, entry.mode, entry.revisionId);
    return owner === ImageDiskCache.owner ? entry.mediaId : '';
  }
  // 删除某张图某个尺寸的缓存。
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
  // 清空当前账号的全部缓存。
  static async clear(context: common.Context): Promise<void> {
    const owner: string = ImageDiskCache.owner; await ImageDiskCache.ensure(context);
    await ImageDiskCache.enqueue(async (): Promise<void> => {
      if (owner !== ImageDiskCache.owner) return;
      const removed: Array<ImageCacheEntry> = ImageDiskCache.entries.slice();
      ImageDiskCache.entries = []; ImageDiskCache.verified.clear();
      for (const entry of removed) if (!ImageDiskCache.entries.some((value: ImageCacheEntry): boolean => value.fileName === entry.fileName)) try { await fileIo.unlink(ImageDiskCache.directory(context) + '/' + entry.fileName); } catch (_error) { }
      await ImageDiskCache.pruneLegacy(context, owner, 128, 96 * 1024 * 1024);
      await ImageDiskCache.writeIndex(context, owner);
    });
  }
}
