import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';

const LONG_EDGE_LIMIT = 1600;
const AVATAR_EDGE_LIMIT = 720;
const BYTE_LIMIT = 2 * 1024 * 1024;

export interface PreparedPhoto {
  data: ArrayBuffer;
  sha256: string;
  width: number;
  height: number;
  byteSize: number;
  mimeType: string;
}

export interface ImageDimensions {
  width: number;
  height: number;
}

/**
 * A circular avatar crop expressed relative to the source image. The stored
 * pixel region is square and the profile renderers apply the circular mask.
 * Offsets use -1 (top/left) to 1 (bottom/right), which maps directly to the
 * crop editor.
 */
export interface AvatarCrop {
  scale: number;
  offsetX: number;
  offsetY: number;
}

function hex(bytes: Uint8Array): string {
  let value = '';
  for (let index = 0; index < bytes.length; index++) {
    value += bytes[index].toString(16).padStart(2, '0');
  }
  return value;
}

async function sha256(data: ArrayBuffer): Promise<string> {
  const digest = cryptoFramework.createMd('SHA256');
  await digest.update({ data: new Uint8Array(data) });
  const output = await digest.digest();
  return hex(output.data);
}

function bounded(value: number, minimum: number, maximum: number): number {
  return Math.max(minimum, Math.min(maximum, value));
}

function validDimensions(width: number, height: number): ImageDimensions {
  if (width <= 0 || height <= 0) {
    throw new Error('图片尺寸无效，请重新选择。');
  }
  return { width, height };
}

function scaledSize(width: number, height: number, longestEdge: number): image.Size {
  const scale = Math.min(1, longestEdge / Math.max(width, height));
  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale))
  };
}

function avatarRegion(source: ImageDimensions, crop: AvatarCrop): image.Region {
  const scale = bounded(crop.scale, 1, 3);
  const side = Math.max(1, Math.floor(Math.min(source.width, source.height) / scale));
  const availableX = Math.max(0, source.width - side);
  const availableY = Math.max(0, source.height - side);
  const normalizedX = (bounded(crop.offsetX, -1, 1) + 1) / 2;
  const normalizedY = (bounded(crop.offsetY, -1, 1) + 1) / 2;
  return {
    x: Math.min(availableX, Math.round(availableX * normalizedX)),
    y: Math.min(availableY, Math.round(availableY * normalizedY)),
    size: { width: side, height: side }
  };
}

async function preparePhoto(uri: string, crop: AvatarCrop | undefined): Promise<PreparedPhoto> {
  let sourceFile: fileIo.File | undefined = undefined;
  let source: image.ImageSource | undefined = undefined;
  let pixelMap: image.PixelMap | undefined = undefined;
  let packer: image.ImagePacker | undefined = undefined;
  try {
    sourceFile = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    source = image.createImageSource(sourceFile.fd);
    const info = await source.getImageInfo();
    const sourceSize = validDimensions(info.size.width, info.size.height);
    if (crop !== undefined) {
      const region = avatarRegion(sourceSize, crop);
      pixelMap = await source.createPixelMap({
        desiredRegion: region,
        desiredSize: scaledSize(region.size.width, region.size.height, AVATAR_EDGE_LIMIT),
        cropAndScaleStrategy: image.CropAndScaleStrategy.CROP_FIRST
      });
    } else {
      pixelMap = await source.createPixelMap({
        desiredSize: scaledSize(sourceSize.width, sourceSize.height, LONG_EDGE_LIMIT)
      });
    }
    const pixelInfo = await pixelMap.getImageInfo();
    const outputWidth = pixelInfo.size.width;
    const outputHeight = pixelInfo.size.height;
    if (Math.max(outputWidth, outputHeight) > LONG_EDGE_LIMIT) {
      throw new Error('图片解码后的长边仍超过 1600px，请重新选择。');
    }
    packer = image.createImagePacker();
    let data = await packer.packToData(pixelMap, { format: 'image/jpeg', quality: 82 });
    if (data.byteLength > BYTE_LIMIT) {
      data = await packer.packToData(pixelMap, { format: 'image/jpeg', quality: 70 });
    }
    if (data.byteLength > BYTE_LIMIT) {
      data = await packer.packToData(pixelMap, { format: 'image/jpeg', quality: 56 });
    }
    if (data.byteLength > BYTE_LIMIT) {
      throw new Error('处理后的实拍图仍超过 2MB，请选择更小的图片。');
    }
    return {
      data,
      sha256: await sha256(data),
      width: outputWidth,
      height: outputHeight,
      byteSize: data.byteLength,
      mimeType: 'image/jpeg'
    };
  } finally {
    if (packer !== undefined) {
      try { await packer.release(); } catch (_error) { }
    }
    if (pixelMap !== undefined) {
      try { await pixelMap.release(); } catch (_error) { }
    }
    if (source !== undefined) {
      try { await source.release(); } catch (_error) { }
    }
    if (sourceFile !== undefined) {
      try { await fileIo.close(sourceFile); } catch (_error) { }
    }
  }
}

export class ImagePreparationService {
  static async selectOne(): Promise<string> {
    const uris = await ImagePreparationService.selectMany(1);
    return uris.length > 0 ? uris[0] : '';
  }

  /** Selects up to six user-owned photos for one public recommendation card. */
  static async selectMany(maxSelectNumber: number): Promise<Array<string>> {
    const options = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    options.maxSelectNumber = Math.max(1, Math.min(6, Math.floor(maxSelectNumber)));
    const result = await new photoAccessHelper.PhotoViewPicker().select(options);
    return result.photoUris.slice(0, options.maxSelectNumber);
  }

  static async readImageDimensions(uri: string): Promise<ImageDimensions> {
    let sourceFile: fileIo.File | undefined = undefined;
    let source: image.ImageSource | undefined = undefined;
    try {
      sourceFile = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
      source = image.createImageSource(sourceFile.fd);
      const info = await source.getImageInfo();
      return validDimensions(info.size.width, info.size.height);
    } finally {
      if (source !== undefined) {
        try { await source.release(); } catch (_error) { }
      }
      if (sourceFile !== undefined) {
        try { await fileIo.close(sourceFile); } catch (_error) { }
      }
    }
  }

  /** Crops a user-confirmed square region and re-encodes it locally. */
  static async prepareAvatarPhoto(uri: string, crop: AvatarCrop): Promise<PreparedPhoto> {
    return preparePhoto(uri, crop);
  }

  /** Decoding then JPEG re-encoding strips EXIF/GPS metadata. */
  static async prepareOwnedPhoto(uri: string): Promise<PreparedPhoto> {
    return preparePhoto(uri, undefined);
  }
}
