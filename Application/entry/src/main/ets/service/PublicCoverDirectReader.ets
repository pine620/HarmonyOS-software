import { http } from '@kit.NetworkKit';
import { cloudStorage } from '@kit.CloudFoundationKit';
import { util } from '@kit.ArkTS';
import { ImageDescriptor } from '../model/ImageModels';
import { PUBLIC_COVER_DIRECT_READ_ENABLED } from './ImageReadConfig';

// Pack 3.2 (2026-10-15): published 480px covers are read straight from Cloud Storage (security rules allow
// anonymous read of `*.cover-v1.jpg` under public/approved/), so the feed no longer spends a cloud-function
// call per batch. The descriptor (sha256 + size) still comes from the card read; ImageDiskCache.put verifies
// the bytes against it, so a stale or tampered object is rejected. Any failure falls back to shike-image.
const COVER_SOURCE: RegExp = /^public\/approved\/([^/]+)\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jpg$/i;
const TIMEOUT_MS: number = 8000;
const FAILURES_BEFORE_PAUSE: number = 3;
const PAUSE_MS: number = 10 * 60 * 1000;

export class PublicCoverDirectReader {
  private static failures: number = 0;
  private static pausedUntil: number = 0;

  static available(): boolean {
    return PUBLIC_COVER_DIRECT_READ_ENABLED && Date.now() >= PublicCoverDirectReader.pausedUntil;
  }

  // Cover object next to the original: public/approved/{uid}/{mediaId}.cover-v1.jpg
  static coverPath(originalPath: string, mediaId: string): string {
    const match: RegExpMatchArray | null = originalPath.match(COVER_SOURCE);
    if (match === null || match[2].toLowerCase() !== mediaId.toLowerCase()) return '';
    return `public/approved/${match[1]}/${match[2]}.cover-v1.jpg`;
  }

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

  // Repeated failures (rules not deployed yet, network blocks) pause direct reads for a while.
  static recordFailure(): void {
    PublicCoverDirectReader.failures++;
    if (PublicCoverDirectReader.failures >= FAILURES_BEFORE_PAUSE) {
      PublicCoverDirectReader.failures = 0;
      PublicCoverDirectReader.pausedUntil = Date.now() + PAUSE_MS;
      console.warn('[ImageRead] event=direct-cover-paused');
    }
  }
}
