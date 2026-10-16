import { common } from '@kit.AbilityKit';
import util from '@ohos.util';
import { request } from '@kit.BasicServicesKit';
import { cloudStorage } from '@kit.CloudFoundationKit';
import { fileIo } from '@kit.CoreFileKit';
import { ConfirmPhotoUploadRequest, OperationResponse, UploadPreparedPhotoRequest } from '../model/CloudContracts';
import { CloudGateway } from './CloudGateway';
import { AuthSessionStore } from './AuthSessionStore';
import { CLIENT_DIRECT_UPLOAD_ENABLED } from './ImageReadConfig';

const DIRECT_UPLOAD_TIMEOUT_MS: number = 60000;
const DIRECT_FAILURES_BEFORE_PAUSE: number = 2;

export class PhotoUploadService {
  private static directFailures: number = 0;

  static async upload(context: common.UIAbilityContext, bucketName: string, cloudPath: string,
    data: ArrayBuffer, sha256: string): Promise<void> {
    const storageBucketName: string = bucketName.trim();
    if (storageBucketName.length === 0) {
      throw new Error('云端未返回云存储实例名称，请检查 shike-service 的 SHIKE_STORAGE_BUCKET 环境变量。');
    }
    const matchedMediaId: RegExpMatchArray | null = cloudPath.match(
      /^public\/approved\/([^/]+)\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jpg$/i);
    if (matchedMediaId === null) {
      throw new Error('云端返回了无效的公开图片路径。');
    }
    if (!/^[a-f0-9]{64}$/i.test(sha256)) {
      throw new Error('图片摘要无效，请重新选择图片。');
    }
    const storageUid: string = matchedMediaId[1];
    const mediaId: string = matchedMediaId[2];
    // Pack 3.3: native email users upload straight to Cloud Storage; any failure falls back to the function upload.
    if (CLIENT_DIRECT_UPLOAD_ENABLED && AuthSessionStore.isNativeEmailSession() &&
      PhotoUploadService.directFailures < DIRECT_FAILURES_BEFORE_PAUSE) {
      try {
        await PhotoUploadService.uploadDirect(context, storageBucketName, storageUid, mediaId, data);
        const confirm: ConfirmPhotoUploadRequest = { mediaId, sha256: sha256.toLowerCase() };
        const confirmed: OperationResponse = await CloudGateway.callAuthenticated<OperationResponse>('confirm-card-photo-upload', confirm);
        if (confirmed.success) {
          PhotoUploadService.directFailures = 0;
          console.info(`[PhotoUpload] direct upload confirmed: bytes=${data.byteLength}`);
          return;
        }
        throw new Error('云端未确认直传图片。');
      } catch (error) {
        PhotoUploadService.directFailures++;
        console.warn('[PhotoUpload] direct upload failed; falling back to function upload: ' + (error as Error).message);
      }
    }
    const uploadRequest: UploadPreparedPhotoRequest = {
      mediaId,
      dataBase64: new util.Base64Helper().encodeToStringSync(new Uint8Array(data)),
      sha256
    };
    console.info(`[PhotoUpload] server upload: bytes=${data.byteLength}, pathPrefix=public/approved`);
    const response: OperationResponse = await CloudGateway.callAuthenticated<OperationResponse>('upload-card-photo', uploadRequest);
    if (!response.success) throw new Error('云端未确认图片上传。');
  }

  // Writes the bytes to the cache directory, then uploads them to private/pending/{uid}/{mediaId}.jpg.
  private static async uploadDirect(context: common.UIAbilityContext, bucketName: string, storageUid: string,
    mediaId: string, data: ArrayBuffer): Promise<void> {
    CloudGateway.ensureReady();
    const fileName: string = `direct-upload-${mediaId}.jpg`;
    const filePath: string = context.cacheDir + '/' + fileName;
    const file: fileIo.File = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.writeSync(file.fd, data);
    } finally {
      fileIo.closeSync(file);
    }
    try {
      const parameters: cloudStorage.UploadParams = {
        localPath: 'internal://cache/' + fileName,
        cloudPath: `private/pending/${storageUid}/${mediaId}.jpg`,
        metadata: { contentType: 'image/jpeg' }
      };
      const task: request.agent.Task = await cloudStorage.bucket(bucketName).uploadFile(context, parameters);
      await new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
        const timer: number = setTimeout((): void => reject(new Error('直传超时。')), DIRECT_UPLOAD_TIMEOUT_MS);
        task.on('completed', (_progress: request.agent.Progress): void => { clearTimeout(timer); resolve(); });
        task.on('failed', (_progress: request.agent.Progress): void => { clearTimeout(timer); reject(new Error('直传失败。')); });
        task.start().catch((error: Error): void => { clearTimeout(timer); reject(error); });
      });
    } finally {
      try { fileIo.unlinkSync(filePath); } catch (_error) { }
    }
  }

}
