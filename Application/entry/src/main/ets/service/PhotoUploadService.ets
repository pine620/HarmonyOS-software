/**
 * 【文件职责】实拍图上传（发布流程第 2 步）。只负责上传，下载与缓存在 ImageRepository。
 * 【两条上传路径】
 *   1. 直传：邮箱原生登录 + CLIENT_DIRECT_UPLOAD_ENABLED=true 时，先把 JPEG 上传到 Cloud Storage 的
 *      private/pending/{uid}/{mediaId}.jpg（安全规则只允许本人写），再调用 confirm-card-photo-upload，
 *      由 shike-media 读回、核对大小与 sha256 后写入公开路径；
 *   2. 函数上传：其余情况，或直传连续失败 2 次后，把图片转成 Base64 调用 upload-card-photo，由 shike-media 写入。
 * 【链路位置】CreateCardPage / ProfileEditPage → 本文件 → CloudGateway → shike-media（以及 Cloud Storage 直传）。
 */
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

// 实拍图上传（静态类）。
export class PhotoUploadService {
  // 本进程内直传连续失败的次数；达到 2 次后不再尝试直传，直接走函数上传。
  private static directFailures: number = 0;

  /**
   * 上传一张已经准备好的 JPEG。
   * bucketName / cloudPath 来自 prepare-card-photo 的返回值；cloudPath 必须形如 public/approved/{storageUid}/{mediaId}.jpg，
   * sha256 是本机计算的摘要，云端会用它校验上传内容。任何一步不符合都抛错，由发布页提示用户重试。
   */
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
    // 邮箱原生会话优先直传 Cloud Storage；任何失败都会回落到函数上传。
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

  // 把字节写到缓存目录的临时文件，再上传到 private/pending/{uid}/{mediaId}.jpg；60 秒超时，结束后删除临时文件。
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
