import { http } from '@kit.NetworkKit';
import { cloudStorage } from '@kit.CloudFoundationKit';
import { util } from '@kit.ArkTS';
import { ImageDescriptor } from '../model/ImageModels';
import { PUBLIC_COVER_DIRECT_READ_ENABLED } from './ImageReadConfig';

/**
 * 【文件职责】公开封面直读。已发布卡片的 480px 封面（public/approved/{uid}/{mediaId}.cover-v1.jpg）
 * 允许匿名读取（由 Cloud Storage 安全规则开放），所以推荐流不必为每批封面调用一次云函数。
 * 图片描述符（sha256 + 大小）仍来自卡片数据，写入缓存时由 ImageDiskCache.put 校验字节，过期或被篡改的对象会被拒绝。
 * 任何失败都会回落到 shike-image；连续失败 2 次后暂停直读一段时间。
 */
const COVER_SOURCE: RegExp = /^public\/approved\/([^/]+)\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jpg$/i;
const TIMEOUT_MS: number = 8000;
const FAILURES_BEFORE_PAUSE: number = 3;
const PAUSE_MS: number = 10 * 60 * 1000;

// 公开封面直读（静态类）。
export class PublicCoverDirectReader {
  // 连续失败次数与暂停截止时间。
  private static failures: number = 0;
  private static pausedUntil: number = 0;

  // 当前是否允许直读（开关打开且不在暂停期）。
  static available(): boolean {
    return PUBLIC_COVER_DIRECT_READ_ENABLED && Date.now() >= PublicCoverDirectReader.pausedUntil;
  }

  // 封面对象与原图同目录：public/approved/{uid}/{mediaId}.cover-v1.jpg
  static coverPath(originalPath: string, mediaId: string): string {
    const match: RegExpMatchArray | null = originalPath.match(COVER_SOURCE);
    if (match === null || match[2].toLowerCase() !== mediaId.toLowerCase()) return '';
    return `public/approved/${match[1]}/${match[2]}.cover-v1.jpg`;
  }

  // 读取一张封面并返回 Base64；字节数超过描述符或读取超时则抛错。
  static async readBase64(bucket: string, cloudPath: string, descriptor: ImageDescriptor): Promise<string> {
    const storage: cloudStorage.StorageBucket = bucket.trim().length > 0 ? cloudStorage.bucket(bucket.trim()) : cloudStorage.bucket();
    const url: string = await storage.getDownloadURL(cloudPath);
    if (!url.startsWith('https://')) throw new Error('封面地址无效。');
    const client: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET, expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: TIMEOUT_MS, readTimeout: TIMEOUT_MS
      };
      const response: http.HttpResponse = await client.request(url, options);
      if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer)) throw new Error('封面直读失败。');
      const bytes: Uint8Array = new Uint8Array(response.result as ArrayBuffer);
      if (bytes.length !== descriptor.byteSize) throw new Error('封面大小不一致。');
      PublicCoverDirectReader.failures = 0;
      return new util.Base64Helper().encodeToStringSync(bytes);
    } finally {
      client.destroy();
    }
  }

  // 连续失败（例如安全规则尚未部署、网络拦截）时暂停直读一段时间。
  static recordFailure(): void {
    PublicCoverDirectReader.failures++;
    if (PublicCoverDirectReader.failures >= FAILURES_BEFORE_PAUSE) {
      PublicCoverDirectReader.failures = 0;
      PublicCoverDirectReader.pausedUntil = Date.now() + PAUSE_MS;
      console.warn('[ImageRead] event=direct-cover-paused');
    }
  }
}
