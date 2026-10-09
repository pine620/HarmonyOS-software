import { common } from '@kit.AbilityKit';
import util from '@ohos.util';
import { OperationResponse, UploadPreparedPhotoRequest } from '../model/CloudContracts';
import { CloudGateway } from './CloudGateway';

export class PhotoUploadService {
  static async upload(context: common.UIAbilityContext, bucketName: string, cloudPath: string,
    data: ArrayBuffer, sha256: string): Promise<void> {
    void context;
    const storageBucketName: string = bucketName.trim();
    if (storageBucketName.length === 0) {
      throw new Error('云端未返回云存储实例名称，请检查 shike-service 的 SHIKE_STORAGE_BUCKET 环境变量。');
    }
    const matchedMediaId: RegExpMatchArray | null = cloudPath.match(
      /^public\/approved\/[^/]+\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jpg$/i);
    if (matchedMediaId === null) {
      throw new Error('云端返回了无效的公开图片路径。');
    }
    if (!/^[a-f0-9]{64}$/i.test(sha256)) {
      throw new Error('图片摘要无效，请重新选择图片。');
    }
    const request: UploadPreparedPhotoRequest = {
      mediaId: matchedMediaId[1],
      dataBase64: new util.Base64Helper().encodeToStringSync(new Uint8Array(data)),
      sha256
    };
    console.info(`[PhotoUpload] server upload: bytes=${data.byteLength}, pathPrefix=public/approved`);
    const response: OperationResponse = await CloudGateway.callAuthenticated<OperationResponse>('upload-card-photo', request);
    if (!response.success) throw new Error('云端未确认图片上传。');
  }

}
