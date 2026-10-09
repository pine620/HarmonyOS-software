export type ImageMode = 'PUBLIC' | 'REVIEW' | 'REVISION';
export type ImageVariant = 'COVER_480' | 'ORIGINAL';
export type MediaPriority = 'high' | 'normal' | 'low';
export type MediaRequestGuard = () => Promise<boolean>;
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
export interface ImageReadItem {
  mediaId: string;
  mode: ImageMode;
  variant: ImageVariant;
  revisionId: string;
  knownSha256: string;
  knownByteSize: number;
  wantBytes: boolean;
}
export interface ImageReadRequest { protocolVersion: string; items: Array<ImageReadItem>; readScope?: string; }
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
export interface ImageBatchResponse {
  buildId: string;
  policyHash: string;
  protocolVersion: string;
  items: Array<ImageReadResult>;
}
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

export interface LegacyImageRequest {
  mediaId: string; revisionId: string; bucketName: string; cloudPath: string; variant: ImageVariant;
  knownSha256: string; knownByteSize: number; readScope?: string;
}
export interface LegacyImageResponse extends ImageDescriptor { dataBase64: string; status: string; }
