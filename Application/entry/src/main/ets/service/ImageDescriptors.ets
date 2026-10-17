/**
 * 【文件职责】图片“授权表”（只在内存中）。云端返回卡片、预览、榜单等内容时，会附带每张图片的描述符
 * （mediaId、尺寸、sha256、字节数）；CloudGateway 收到后调用 accept() 登记到这里。
 * 只有登记过的图片才允许从缓存或云端显示；删卡、换号、注销、作者修改生效时调用 revoke() 整体作废。
 * ImageRepository 和 ImageDiskCache 用这里的描述符校验图片字节，防止显示过期或被篡改的图片。
 */
import { CardPhoto, FoodCard } from '../model/CloudContracts';
import { ImageDescriptor, ImageMode, ImageVariant } from '../model/ImageModels';
import { AuthSessionStore } from './AuthSessionStore';

// 响应中可能出现的几种卡片 / 媒体字段形态（不同接口结构不同，accept() 统一遍历）。
interface CardEnvelopeItem { card?: FoodCard | null; }
interface MediaEnvelope {
  id?: string;
  contentRevision?: string;
  photos?: Array<CardPhoto>;
  cards?: Array<FoodCard>;
  card?: FoodCard | null;
  candidates?: Array<CardEnvelopeItem>;
  items?: Array<CardEnvelopeItem>;
}
// 一条授权：描述符 + 登记时的授权版本与会话代次。
interface CachedImageDescriptor { mediaId: string; descriptor: ImageDescriptor; epoch: number; session: number; }

// 从内容响应和图片响应中得知的图片版本（只存内存）。
export class ImageDescriptors {
  // 授权表、授权版本号，以及撤销时的回调（EntryAbility 设置为“同步撤销桌面卡片上的图片”）。
  private static descriptors: Map<string, CachedImageDescriptor> = new Map<string, CachedImageDescriptor>();
  private static revision: number = 0;
  static onRevoked: (mediaId: string) => void = (_mediaId: string): void => {};
  // 当前授权版本：每次 revoke() +1，旧任务据此判断是否作废。
  static epoch(): number { return ImageDescriptors.revision; }
  // 授权表的键：账号 + mediaId + 模式 + 尺寸 + 修订号。
  static key(mediaId: string, mode: ImageMode, variant: ImageVariant, revisionId: string = ''): string {
    return AuthSessionStore.owner() + ':' + mediaId + ':' + mode + ':' + variant + ':' + revisionId;
  }
  // 撤销全部授权（删卡、换号、注销、修改生效时调用）。
  static revoke(): void { ImageDescriptors.revision++; ImageDescriptors.descriptors.clear(); ImageDescriptors.onRevoked(''); }
  // 撤销某张图片的所有授权记录。
  static remove(mediaId: string): void {
    for (const key of ImageDescriptors.descriptors.keys()) if (key.includes(':' + mediaId + ':')) ImageDescriptors.descriptors.delete(key);
    ImageDescriptors.onRevoked(mediaId);
  }
  // 撤销某张卡片下所有图片的授权（例如详情返回“已下架”时）。
  static removeCard(cardId: string): void {
    const mediaIds: Set<string> = new Set<string>();
    for (const key of ImageDescriptors.descriptors.keys()) {
      const permit: CachedImageDescriptor | undefined = ImageDescriptors.descriptors.get(key);
      if (permit !== undefined && permit.descriptor.cardId === cardId) {
        ImageDescriptors.descriptors.delete(key);
        // 已经发布到桌面卡片上的图片副本也必须停止使用旧内容。
        mediaIds.add(permit.mediaId);
      }
    }
    for (const mediaId of mediaIds) ImageDescriptors.onRevoked(mediaId);
  }
  // 登记一条授权。
  static record(mediaId: string, mode: ImageMode, requested: ImageVariant, descriptor: ImageDescriptor, revisionId: string = ''): void {
    const permit: CachedImageDescriptor = { mediaId, descriptor, epoch: ImageDescriptors.revision, session: AuthSessionStore.generation() };
    ImageDescriptors.descriptors.set(ImageDescriptors.key(mediaId, mode, requested, revisionId), permit);
    if (ImageDescriptors.descriptors.size > 512) for (const first of ImageDescriptors.descriptors.keys()) { ImageDescriptors.descriptors.delete(first); break; }
  }
  // 读取一条授权；会话或授权版本不一致时视为不存在。
  static read(mediaId: string, mode: ImageMode, variant: ImageVariant, revisionId: string = ''): ImageDescriptor | undefined {
    const permit: CachedImageDescriptor | undefined = ImageDescriptors.descriptors.get(ImageDescriptors.key(mediaId, mode, variant, revisionId));
    return permit !== undefined && permit.epoch === ImageDescriptors.revision && permit.session === AuthSessionStore.generation() ? permit.descriptor : undefined;
  }
  // 从任意响应对象中找出所有卡片/媒体描述符并登记。
  static accept(value: Object): void {
    if (value === null || value === undefined) return;
    const envelope: MediaEnvelope = value as MediaEnvelope;
    if (Array.isArray(envelope.photos)) ImageDescriptors.photos(envelope.photos, envelope.id || '', envelope.contentRevision || '');
    if (Array.isArray(envelope.cards)) for (const card of envelope.cards) ImageDescriptors.photos(card.photos || [], card.id, card.contentRevision || '');
    if (envelope.card !== undefined && envelope.card !== null) ImageDescriptors.photos(envelope.card.photos || [], envelope.card.id, envelope.card.contentRevision || '');
    if (Array.isArray(envelope.candidates)) for (const item of envelope.candidates) if (item.card !== undefined && item.card !== null) ImageDescriptors.photos(item.card.photos || [], item.card.id, item.card.contentRevision || '');
    if (Array.isArray(envelope.items)) for (const item of envelope.items) if (item.card !== undefined && item.card !== null) ImageDescriptors.photos(item.card.photos || [], item.card.id, item.card.contentRevision || '');
  }
  // 登记一组卡片图片的描述符。
  private static photos(photos: Array<CardPhoto>, cardId: string = '', cardRevision: string = ''): void {
    for (const photo of photos) {
      photo.readAcceptedAt = Date.now();
      if (!photo.id) continue;
      const variants: Array<ImageVariant> = ['ORIGINAL', 'COVER_480'];
      for (const variant of variants) {
        const cover: boolean = variant === 'COVER_480';
        const sha256: string = (cover ? photo.coverSha256 : photo.sha256) || '';
        const byteSize: number = (cover ? photo.coverByteSize : photo.byteSize) || 0;
        if (!/^[a-f0-9]{64}$/.test(sha256) || byteSize < 4 || byteSize > 2097152) continue;
        const descriptor: ImageDescriptor = { variant, sha256, byteSize, width: cover ? photo.coverWidth || 0 : photo.width,
          height: cover ? photo.coverHeight || 0 : photo.height, ownerUid: '', cardId, cardRevision, recipeVersion: cover ? 1 : 0 };
        ImageDescriptors.record(photo.id, 'PUBLIC', variant, descriptor);
      }
    }
  }
}
