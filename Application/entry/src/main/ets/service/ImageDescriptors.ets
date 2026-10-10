import { CardPhoto, FoodCard } from '../model/CloudContracts';
import { ImageDescriptor, ImageMode, ImageVariant } from '../model/ImageModels';
import { AuthSessionStore } from './AuthSessionStore';

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
interface CachedImageDescriptor { mediaId: string; descriptor: ImageDescriptor; epoch: number; session: number; }

/** In-memory image versions learned from content and image responses. */
export class ImageDescriptors {
  private static descriptors: Map<string, CachedImageDescriptor> = new Map<string, CachedImageDescriptor>();
  private static revision: number = 0;
  static onRevoked: (mediaId: string) => void = (_mediaId: string): void => {};
  static epoch(): number { return ImageDescriptors.revision; }
  static key(mediaId: string, mode: ImageMode, variant: ImageVariant, revisionId: string = ''): string {
    return AuthSessionStore.owner() + ':' + mediaId + ':' + mode + ':' + variant + ':' + revisionId;
  }
  static revoke(): void { ImageDescriptors.revision++; ImageDescriptors.descriptors.clear(); ImageDescriptors.onRevoked(''); }
  static remove(mediaId: string): void {
    for (const key of ImageDescriptors.descriptors.keys()) if (key.includes(':' + mediaId + ':')) ImageDescriptors.descriptors.delete(key);
    ImageDescriptors.onRevoked(mediaId);
  }
  static removeCard(cardId: string): void {
    const mediaIds: Set<string> = new Set<string>();
    for (const key of ImageDescriptors.descriptors.keys()) {
      const permit: CachedImageDescriptor | undefined = ImageDescriptors.descriptors.get(key);
      if (permit !== undefined && permit.descriptor.cardId === cardId) {
        ImageDescriptors.descriptors.delete(key);
        // Published service-card copies must also stop using the old content.
        mediaIds.add(permit.mediaId);
      }
    }
    for (const mediaId of mediaIds) ImageDescriptors.onRevoked(mediaId);
  }
  static record(mediaId: string, mode: ImageMode, requested: ImageVariant, descriptor: ImageDescriptor, revisionId: string = ''): void {
    const permit: CachedImageDescriptor = { mediaId, descriptor, epoch: ImageDescriptors.revision, session: AuthSessionStore.generation() };
    ImageDescriptors.descriptors.set(ImageDescriptors.key(mediaId, mode, requested, revisionId), permit);
    if (ImageDescriptors.descriptors.size > 512) for (const first of ImageDescriptors.descriptors.keys()) { ImageDescriptors.descriptors.delete(first); break; }
  }
  static read(mediaId: string, mode: ImageMode, variant: ImageVariant, revisionId: string = ''): ImageDescriptor | undefined {
    const permit: CachedImageDescriptor | undefined = ImageDescriptors.descriptors.get(ImageDescriptors.key(mediaId, mode, variant, revisionId));
    return permit !== undefined && permit.epoch === ImageDescriptors.revision && permit.session === AuthSessionStore.generation() ? permit.descriptor : undefined;
  }
  static accept(value: Object): void {
    if (value === null || value === undefined) return;
    const envelope: MediaEnvelope = value as MediaEnvelope;
    if (Array.isArray(envelope.photos)) ImageDescriptors.photos(envelope.photos, envelope.id || '', envelope.contentRevision || '');
    if (Array.isArray(envelope.cards)) for (const card of envelope.cards) ImageDescriptors.photos(card.photos || [], card.id, card.contentRevision || '');
    if (envelope.card !== undefined && envelope.card !== null) ImageDescriptors.photos(envelope.card.photos || [], envelope.card.id, envelope.card.contentRevision || '');
    if (Array.isArray(envelope.candidates)) for (const item of envelope.candidates) if (item.card !== undefined && item.card !== null) ImageDescriptors.photos(item.card.photos || [], item.card.id, item.card.contentRevision || '');
    if (Array.isArray(envelope.items)) for (const item of envelope.items) if (item.card !== undefined && item.card !== null) ImageDescriptors.photos(item.card.photos || [], item.card.id, item.card.contentRevision || '');
  }
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
