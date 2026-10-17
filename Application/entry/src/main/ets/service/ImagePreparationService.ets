/**
 * 【文件职责】图片本机预处理：从相册选图 → 解码 → 缩放（长边不超过上限）→ 重新编码为 JPEG → 计算 sha256。
 * 重新编码会自动去掉 EXIF / GPS 等元数据，避免泄露拍摄位置；头像额外按用户确认的区域裁剪成正方形。
 * 【链路位置】CreateCardPage（发布实拍图）、ProfileEditPage（头像/主页背景）、DraftStore（草稿图片）使用。
 * 处理结果 PreparedPhoto 交给 CardRepository.preparePhoto / PhotoUploadService.upload 上传。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';

const LONG_EDGE_LIMIT = 1600;
const AVATAR_EDGE_LIMIT = 720;
const BYTE_LIMIT = 2 * 1024 * 1024;

// 预处理后的图片：JPEG 字节、尺寸、字节数与 sha256。
export interface PreparedPhoto {
  data: ArrayBuffer;
  sha256: string;
  width: number;
  height: number;
  byteSize: number;
  mimeType: string;
  cover?: PreparedPhoto;
}

// 图片宽高。
export interface ImageDimensions {
  width: number;
  height: number;
}

/**
 * 头像圆形裁剪参数（相对于原图）。实际保存的像素区域是正方形，界面再加圆形遮罩显示。
 * 偏移量取值 -1（上/左）到 1（下/右），与裁剪编辑器的坐标一一对应；scale 为放大倍数（1–3）。
 */
export interface AvatarCrop {
  scale: number;
  offsetX: number;
  offsetY: number;
}

// 字节转十六进制字符串。
function hex(bytes: Uint8Array): string {
  let value = '';
  for (let index = 0; index < bytes.length; index++) {
    value += bytes[index].toString(16).padStart(2, '0');
  }
  return value;
}

// 计算 SHA-256 摘要（十六进制）。
async function sha256(data: ArrayBuffer): Promise<string> {
  const digest = cryptoFramework.createMd('SHA256');
  await digest.update({ data: new Uint8Array(data) });
  const output = await digest.digest();
  return hex(output.data);
}

// 把数值限制在 [minimum, maximum] 区间。
function bounded(value: number, minimum: number, maximum: number): number {
  return Math.max(minimum, Math.min(maximum, value));
}

// 校验宽高为正数。
function validDimensions(width: number, height: number): ImageDimensions {
  if (width <= 0 || height <= 0) {
    throw new Error('图片尺寸无效，请重新选择。');
  }
  return { width, height };
}

// 按长边上限等比缩小（不放大）。
function scaledSize(width: number, height: number, longestEdge: number): image.Size {
  const scale = Math.min(1, longestEdge / Math.max(width, height));
  return {
    width: Math.max(1, Math.round(width * scale)),
    height: Math.max(1, Math.round(height * scale))
  };
}

// 根据裁剪参数计算源图中的正方形区域。
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

// 通用预处理：打开文件 → 解码（可选裁剪）→ 缩放 → 编码 JPEG → 计算摘要；结束时关闭文件与释放图片资源。
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

// 图片预处理入口（静态方法）。
export class ImagePreparationService {
  // 从相册选择 1 张图片，返回 URI；用户取消返回空串。
  static async selectOne(): Promise<string> {
    const uris = await ImagePreparationService.selectMany(1);
    return uris.length > 0 ? uris[0] : '';
  }

  // 为一张推荐卡片从相册选择最多 maxSelectNumber 张（发布时最多 6 张）用户自己的照片。
  static async selectMany(maxSelectNumber: number): Promise<Array<string>> {
    const options = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    options.maxSelectNumber = Math.max(1, Math.min(6, Math.floor(maxSelectNumber)));
    const result = await new photoAccessHelper.PhotoViewPicker().select(options);
    return result.photoUris.slice(0, options.maxSelectNumber);
  }

  // 只读取图片尺寸（不解码像素），用于裁剪编辑器。
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

  // 按用户确认的正方形区域裁剪头像，并在本机重新编码。
  static async prepareAvatarPhoto(uri: string, crop: AvatarCrop): Promise<PreparedPhoto> {
    return preparePhoto(uri, crop);
  }

  // 由已处理的原图生成更小的封面版本（草稿列表等使用）。
  static async prepareCover(photo: PreparedPhoto): Promise<PreparedPhoto> {
    let source: image.ImageSource | undefined = undefined;
    let pixels: image.PixelMap | undefined = undefined;
    let packer: image.ImagePacker | undefined = undefined;
    try {
      source = image.createImageSource(photo.data);
      const options: image.DecodingOptions = { desiredSize: scaledSize(photo.width, photo.height, 480) };
      pixels = await source.createPixelMap(options);
      const info: image.ImageInfo = await pixels.getImageInfo();
      packer = image.createImagePacker();
      const packing: image.PackingOption = { format: 'image/jpeg', quality: 78 };
      const data: ArrayBuffer = await packer.packToData(pixels, packing);
      const result: PreparedPhoto = { data, sha256: await sha256(data), width: info.size.width, height: info.size.height, byteSize: data.byteLength, mimeType: 'image/jpeg' };
      return result;
    } finally {
      if (packer !== undefined) try { await packer.release(); } catch (_error) { }
      if (pixels !== undefined) try { await pixels.release(); } catch (_error) { }
      if (source !== undefined) try { await source.release(); } catch (_error) { }
    }
  }

  // 先解码再重新编码为 JPEG，会去掉 EXIF / GPS 元数据。用于卡片实拍图。
  static async prepareOwnedPhoto(uri: string): Promise<PreparedPhoto> {
    const photo: PreparedPhoto = await preparePhoto(uri, undefined);
    photo.cover = await ImagePreparationService.prepareCover(photo);
    return photo;
  }
}
