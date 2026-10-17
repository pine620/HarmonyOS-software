/**
 * 【文件职责】桌面卡片封面文件缓存（filesDir 下的独立目录）。在 App 前台通过 ImageRepository 取图，
 * 缩放/压缩成受限大小的 JPEG 后保存；卡片生命周期回调里只读取这些文件，不发网络请求。
 * 「食刻推荐」和「今日吃什么」两个卡片各用自己的目录，清理时互不影响。
 */
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import util from '@ohos.util';
import { FoodCard } from '../model/CloudContracts';
import { ImageRepository } from './ImageRepository';

const MAX_COVER_EDGE: number = 480;
const MAX_COVER_BYTES: number = 512 * 1024;
const COVER_FILE_PATTERN: RegExp = /^cover-[0-9a-f-]{36}\.jpg$/;
// 每种卡片使用自己的目录，清理一个目录绝不会删掉另一个卡片的封面。
export const SERVICE_CARD_COVER_FOLDER: string = 'shike-service-card-covers';

// 交给 Form Kit 的一张封面：文件描述符要保持打开，直到卡片收到图片后再关闭。
export interface FormCoverImage {
  file: fileIo.File;
  imageName: string;
}

// 桌面卡片封面文件缓存（静态类）。
export class ServiceCardCoverCache {
  // 打开封面文件并生成新的内存图片名（只有图片名变化时 Form Kit 才会刷新图片）；prefix 区分两种卡片。失败返回 undefined。
  static openFormImage(path: string, prefix: string): FormCoverImage | undefined {
    let file: fileIo.File | undefined = undefined;
    try {
      const opened: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      file = opened;
      const cover: FormCoverImage = { file: opened, imageName: `${prefix}${util.generateRandomUUID().replace(/-/g, '_')}` };
      return cover;
    } catch (_error) {
      ServiceCardCoverCache.closeFile(file);
      return undefined;
    }
  }

  // 关闭封面文件描述符（关闭失败时忽略）。
  static closeFile(file: fileIo.File | undefined): void {
    if (file === undefined) return;
    try { fileIo.closeSync(file); } catch (_error) { }
  }

  // 某个目录的绝对路径。
  private static directory(context: common.Context, folder: string): string {
    return `${context.filesDir}/${folder}`;
  }

  // 判断路径是否位于该目录内且文件存在（防止读到目录外的文件）。
  static isUsable(context: common.Context, path: string, folder: string = SERVICE_CARD_COVER_FOLDER): boolean {
    const prefix: string = `${ServiceCardCoverCache.directory(context, folder)}/`;
    if (!path.startsWith(prefix) || !COVER_FILE_PATTERN.test(path.slice(prefix.length))) return false;
    try {
      const stat: fileIo.Stat = fileIo.statSync(path);
      return stat.isFile() && stat.size > 3 && stat.size <= MAX_COVER_BYTES;
    } catch (_error) {
      return false;
    }
  }

  // 只在前台调用：准备一张卡片封面（读取图片 → 缩放压缩为 JPEG → 写文件），卡片生命周期之后直接读这个文件，无需网络。mayContinue 返回 false 时放弃。
  static async prepare(context: common.Context, card: FoodCard,
    mayContinue: () => boolean, folder: string = SERVICE_CARD_COVER_FOLDER): Promise<string> {
    if (!card.photoPath.startsWith('public/approved/') || card.photoBucket.trim().length === 0) return '';
    const url: string = await ImageRepository.getDownloadUrl(context, card.photoBucket, card.photoPath,
      'low', async (): Promise<boolean> => mayContinue(), card.photos?.[0], true);
    if (!mayContinue() || !url.startsWith(`file://${context.cacheDir}/shike-image-v1/`)) return '';
    const source: image.ImageSource = image.createImageSource(url.slice('file://'.length));
    let pixels: image.PixelMap | undefined = undefined;
    let packer: image.ImagePacker | undefined = undefined;
    let file: fileIo.File | undefined = undefined;
    let path: string = '';
    let completed: boolean = false;
    try {
      const info: image.ImageInfo = await source.getImageInfo();
      if (!mayContinue() || info.size.width <= 0 || info.size.height <= 0) return '';
      const scale: number = Math.min(1, MAX_COVER_EDGE / Math.max(info.size.width, info.size.height));
      const size: image.Size = {
        width: Math.max(1, Math.round(info.size.width * scale)),
        height: Math.max(1, Math.round(info.size.height * scale))
      };
      const options: image.DecodingOptions = { desiredSize: size };
      pixels = await source.createPixelMap(options);
      if (!mayContinue()) return '';
      packer = image.createImagePacker();
      const packing: image.PackingOption = { format: 'image/jpeg', quality: 80 };
      const bytes: ArrayBuffer = await packer.packing(pixels, packing);
      if (!mayContinue() || bytes.byteLength <= 3 || bytes.byteLength > MAX_COVER_BYTES) return '';
      const directory: string = ServiceCardCoverCache.directory(context, folder);
      if (!fileIo.accessSync(directory)) fileIo.mkdirSync(directory);
      path = `${directory}/cover-${util.generateRandomUUID()}.jpg`;
      file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
      if (fileIo.writeSync(file.fd, bytes) !== bytes.byteLength) return '';
      fileIo.closeSync(file);
      file = undefined;
      completed = true;
      return path;
    } finally {
      if (file !== undefined) {
        try { fileIo.closeSync(file); } catch (_error) { }
      }
      if (!completed && path.length > 0) ServiceCardCoverCache.remove(context, path, folder);
      if (packer !== undefined) {
        try { await packer.release(); } catch (_error) { }
      }
      if (pixels !== undefined) {
        try { await pixels.release(); } catch (_error) { }
      }
      try { await source.release(); } catch (_error) { }
    }
  }

  // 删除目录内的一个封面文件。
  static remove(context: common.Context, path: string, folder: string = SERVICE_CARD_COVER_FOLDER): void {
    const prefix: string = `${ServiceCardCoverCache.directory(context, folder)}/`;
    if (!path.startsWith(prefix) || !COVER_FILE_PATTERN.test(path.slice(prefix.length))) return;
    try { fileIo.unlinkSync(path); } catch (_error) { }
  }

  // 清理推荐卡片目录，只保留 keepPath。
  static prune(context: common.Context, keepPath: string): void {
    ServiceCardCoverCache.pruneExcept(context, [keepPath], SERVICE_CARD_COVER_FOLDER);
  }

  // 清理目录，只保留 keepPaths 中的文件。
  static pruneExcept(context: common.Context, keepPaths: Array<string>, folder: string): void {
    const directory: string = ServiceCardCoverCache.directory(context, folder);
    try {
      for (const name of fileIo.listFileSync(directory)) {
        const path: string = `${directory}/${name}`;
        if (COVER_FILE_PATTERN.test(name) && !keepPaths.includes(path)) ServiceCardCoverCache.remove(context, path, folder);
      }
    } catch (_error) { }
  }
}
