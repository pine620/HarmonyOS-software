import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import util from '@ohos.util';
import { FoodCard } from '../model/CloudContracts';
import { ImageRepository } from './ImageRepository';

const MAX_COVER_EDGE: number = 480;
const MAX_COVER_BYTES: number = 512 * 1024;
const COVER_FILE_PATTERN: RegExp = /^cover-[0-9a-f-]{36}\.jpg$/;

export class ServiceCardCoverCache {
  private static directory(context: common.Context): string {
    return `${context.filesDir}/shike-service-card-covers`;
  }

  static isUsable(context: common.Context, path: string): boolean {
    const prefix: string = `${ServiceCardCoverCache.directory(context)}/`;
    if (!path.startsWith(prefix) || !COVER_FILE_PATTERN.test(path.slice(prefix.length))) return false;
    try {
      const stat: fileIo.Stat = fileIo.statSync(path);
      return stat.isFile() && stat.size > 3 && stat.size <= MAX_COVER_BYTES;
    } catch (_error) {
      return false;
    }
  }

  // Foreground only: the form lifecycle reads this prepared file without network requests.
  static async prepare(context: common.Context, card: FoodCard,
    mayContinue: () => boolean): Promise<string> {
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
      const directory: string = ServiceCardCoverCache.directory(context);
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
      if (!completed && path.length > 0) ServiceCardCoverCache.remove(context, path);
      if (packer !== undefined) {
        try { await packer.release(); } catch (_error) { }
      }
      if (pixels !== undefined) {
        try { await pixels.release(); } catch (_error) { }
      }
      try { await source.release(); } catch (_error) { }
    }
  }

  static remove(context: common.Context, path: string): void {
    const prefix: string = `${ServiceCardCoverCache.directory(context)}/`;
    if (!path.startsWith(prefix) || !COVER_FILE_PATTERN.test(path.slice(prefix.length))) return;
    try { fileIo.unlinkSync(path); } catch (_error) { }
  }

  static prune(context: common.Context, keepPath: string): void {
    const directory: string = ServiceCardCoverCache.directory(context);
    try {
      for (const name of fileIo.listFileSync(directory)) {
        const path: string = `${directory}/${name}`;
        if (COVER_FILE_PATTERN.test(name) && path !== keepPath) ServiceCardCoverCache.remove(context, path);
      }
    } catch (_error) { }
  }
}
