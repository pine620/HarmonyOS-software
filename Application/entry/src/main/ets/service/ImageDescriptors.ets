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
interface ImagePermit { descriptor: ImageDescriptor; epoch: number; session: number; }

/** Only CloudGateway responses and the image protocol register eligibility. Never persist permits. */
export class ImageDescriptors {
  private static permits: Map<string, ImagePermit> = new Map<string, ImagePermit>();
  private static revision: number = 0;
  static onRevoked: (mediaId: string) => void = (_mediaId: string): void => {};
  static epoch(): number { return ImageDescriptors.revision; }
  static key(mediaId: string, mode: ImageMode, variant: ImageVariant, revisionId: string = ''): string {
    return AuthSessionStore.owner() + ':' + mediaId + ':' + mode + ':' + variant + ':' + revisionId;
  }
  static revoke(): void { ImageDescriptors.revision++; ImageDescriptors.permits.clear(); ImageDescriptors.onRevoked(''); }
  static remove(mediaId: string): void {
    for (const key of ImageDescriptors.permits.keys()) if (key.includes(':' + mediaId + ':')) ImageDescriptors.permits.delete(key);
    ImageDescriptors.onRevoked(mediaId);
  }
  static record(mediaId: string, mode: ImageMode, requested: ImageVariant, descriptor: ImageDescriptor, revisionId: string = ''): void {
    const permit: ImagePermit = { descriptor, epoch: ImageDescriptors.revision, session: AuthSessionStore.generation() };
    ImageDescriptors.permits.set(ImageDescriptors.key(mediaId, mode, requested, revisionId), permit);
    if (ImageDescriptors.permits.size > 512) for (const first of ImageDescriptors.permits.keys()) { ImageDescriptors.permits.delete(first); break; }
  }
  static read(mediaId: string, mode: ImageMode, variant: ImageVariant, revisionId: string = ''): ImageDescriptor | undefined {
    const permit: ImagePermit | undefined = ImageDescriptors.permits.get(ImageDescriptors.key(mediaId, mode, variant, revisionId));
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
