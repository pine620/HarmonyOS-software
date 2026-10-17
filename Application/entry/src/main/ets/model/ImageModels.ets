/**
 * 【文件职责】图片读取协议（image-read-v1）的数据结构：描述符、批量读图请求/响应、磁盘缓存条目。
 */
// 读图模式：PUBLIC 公开 / REVIEW 审核 / REVISION 修订预览 / REPORT 举报。
export type ImageMode = 'PUBLIC' | 'REVIEW' | 'REVISION' | 'REPORT';
// 图片尺寸：480px 封面或原图。
export type ImageVariant = 'COVER_480' | 'ORIGINAL';
// 图片加载优先级。
export type MediaPriority = 'high' | 'normal' | 'prefetch' | 'low';
// 调用方“是否还需要”的回调。
export type MediaRequestGuard = () => Promise<boolean>;
// 图片描述符：mediaId、尺寸、sha256、字节数等（用于授权与缓存校验）。
export interface ImageDescriptor {
  variant: ImageVariant;
  sha256: string;
  byteSize: number;
  width: number;
  height: number;
  ownerUid: string;
  cardId: string;
  cardRevision: string;
  recipeVersion: number;
}
// 批量读图中的一项。
export interface ImageReadItem {
  mediaId: string;
  mode: ImageMode;
  variant: ImageVariant;
  revisionId: string;
  knownSha256: string;
  knownByteSize: number;
  wantBytes: boolean;
}
// 批量读图请求。
export interface ImageReadRequest { protocolVersion: string; items: Array<ImageReadItem>; readScope?: string; }
// 批量读图中一项的结果。
export interface ImageReadResult {
  mediaId: string;
  mode: ImageMode;
  revisionId: string;
  requestedVariant: ImageVariant;
  status: string;
  code: string;
  descriptor?: ImageDescriptor;
  dataBase64?: string;
}
// 批量读图响应。
export interface ImageBatchResponse {
  buildId: string;
  policyHash: string;
  protocolVersion: string;
  items: Array<ImageReadResult>;
}
// 磁盘缓存索引中的一条。
export interface ImageCacheEntry {
  key: string;
  mediaId: string;
  mode: ImageMode;
  revisionId: string;
  requestedVariant: ImageVariant;
  descriptor: ImageDescriptor;
  fileName: string;
  lastAccess: number;
}

// 旧接口逐张读图请求。
export interface LegacyImageRequest {
  mediaId: string; revisionId: string; bucketName: string; cloudPath: string; variant: ImageVariant;
  knownSha256: string; knownByteSize: number; readScope?: string;
}
// 旧接口读图响应。
export interface LegacyImageResponse extends ImageDescriptor { dataBase64: string; status: string; }
