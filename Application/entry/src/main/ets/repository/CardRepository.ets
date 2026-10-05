import { common } from '@kit.AbilityKit';
import {
  CardActionResponse, CardComment, CardDetailRequest, CardIdRequest, CardPhoto, CommentReactionResponse, CreateCardCommentRequest,
  DeleteCardCommentRequest, EmptyRequest, FoodCard, FriendRankingsResponse, MyCardsResponse, NearbyCardsRequest, NearbyCardsResponse,
  OperationResponse, PrepareCardPhotoRequest, PrepareCardPhotoResponse, PublishCardRequest,
  PublishCardResponse, PublicCardsRequest, ReceivedCommentItem, ReceivedCommentsRequest, ReceivedCommentsResponse, ReportCardRequest,
  ToggleCardActionRequest, ToggleCommentReactionRequest
} from '../model/CloudContracts';
import { AuthService } from '../service/AuthService';
import { CloudGateway, MediaServiceUnavailableError } from '../service/CloudGateway';
import { NearbyPerformanceTrace } from '../service/NearbyPerformanceTrace';
import { MediaPriority, MediaRequestGuard, PhotoUploadService } from '../service/PhotoUploadService';

// The Cloud Object returns image bytes, not a direct storage URL. Keep this
// low so the recommendation waterfall cannot exhaust Cloud Foundation's
// function-request quota while the app is restoring or preloading nearby data.
const NEARBY_MEDIA_URL_CONCURRENCY: number = 2;

export class CardRepository {
  async listRecommendationsMetadata(request: PublicCardsRequest,
    mayContinue: () => boolean = (): boolean => true): Promise<NearbyCardsResponse> {
    if (!mayContinue()) throw new Error('推荐请求已失效。');
    const traceTaskId: number = NearbyPerformanceTrace.start('shike.nearby.cloud_list');
    try {
      // Reuse the generated method; scope=all selects the public feed server-side.
      const response: NearbyCardsResponse = await CloudGateway.callPublic<NearbyCardsResponse>('list-nearby-cards', request);
      if (!mayContinue()) throw new Error('推荐请求已失效。');
      return response;
    } finally {
      NearbyPerformanceTrace.finish('shike.nearby.cloud_list', traceTaskId);
    }
  }

  private async resolvePhotoUrl(context: common.Context, photo: CardPhoto,
    priority: MediaPriority = 'normal', mayContinue?: MediaRequestGuard): Promise<void> {
    if (photo.path.length === 0 || photo.bucket.length === 0) {
      photo.url = '';
      return;
    }
    try {
      photo.url = await PhotoUploadService.getDownloadUrl(context, photo.bucket, photo.path, priority, mayContinue);
    } catch (error) {
      photo.url = '';
      if (!(error instanceof MediaServiceUnavailableError)) {
        console.warn('[PhotoDownload] get-public-media failed; showing a placeholder.');
      }
    }
  }

  /** The waterfall uses one cover image; full galleries stay on the detail path. */
  private async resolveNearbyPrimaryPhotoUrl(context: common.Context, card: FoodCard,
    priority: MediaPriority, mayContinue?: MediaRequestGuard): Promise<void> {
    const photos: Array<CardPhoto> = card.photos === undefined ? [] : card.photos;
    let primary: CardPhoto | undefined = photos.length > 0 ? photos[0] : undefined;
    if (primary === undefined && card.photoPath.length > 0) {
      primary = {
        id: '', url: card.photoUrl, path: card.photoPath, bucket: card.photoBucket,
        width: card.photoWidth, height: card.photoHeight
      };
    }
    if (primary === undefined) {
      card.photoUrl = '';
      card.primaryPhotoResolved = true;
      card.primaryPhotoLoadFailed = false;
      return;
    }
    card.primaryPhotoResolved = false;
    card.primaryPhotoLoadFailed = false;
    await this.resolvePhotoUrl(context, primary, priority, mayContinue);
    card.photos = [primary];
    card.photoUrl = primary.url;
    card.photoPath = primary.path;
    card.photoBucket = primary.bucket;
    card.photoWidth = primary.width;
    card.photoHeight = primary.height;
    card.primaryPhotoResolved = true;
    card.primaryPhotoLoadFailed = primary.url.length === 0;
    if (card.primaryPhotoLoadFailed && !PhotoUploadService.isMediaServiceUnavailable()) {
      console.warn('[NearbyPhoto] preview URL was empty after Cloud Storage resolution.');
    }
  }

  /**
   * Resolves only the waterfall cover images. Callers can hydrate the visible
   * cards first and keep the rest off the first-contentful-render path.
   */
  async hydrateNearbyPrimaryPhotoUrls(context: common.Context, cards: Array<FoodCard>, startIndex: number = 0,
    maxCount: number = cards.length, priority: MediaPriority = 'normal', mayContinue?: MediaRequestGuard): Promise<void> {
    const safeStart: number = Math.max(0, startIndex);
    const safeCount: number = Math.max(0, maxCount);
    const endIndex: number = Math.min(cards.length, safeStart + safeCount);
    if (safeStart >= endIndex) return;
    const traceTaskId: number = NearbyPerformanceTrace.start('shike.nearby.primary_media');
    try {
      for (let start = safeStart; start < endIndex; start += NEARBY_MEDIA_URL_CONCURRENCY) {
        if (mayContinue !== undefined && !await mayContinue()) return;
        const batch: Array<FoodCard> = cards.slice(start, Math.min(endIndex, start + NEARBY_MEDIA_URL_CONCURRENCY));
        await Promise.all(batch.map((card: FoodCard): Promise<void> =>
          this.resolveNearbyPrimaryPhotoUrl(context, card, priority, mayContinue)));
      }
    } finally {
      NearbyPerformanceTrace.finish('shike.nearby.primary_media', traceTaskId);
    }
  }

  async hydrateDetailPhoto(context: common.Context, photo: CardPhoto,
    priority: MediaPriority = 'normal'): Promise<string> {
    if (photo.path.length === 0 || photo.bucket.length === 0) return '';
    return PhotoUploadService.getDownloadUrl(context, photo.bucket, photo.path, priority);
  }

  async hydrateCommentAvatar(context: common.Context, comment: CardComment): Promise<string> {
    if (comment.authorAvatarPath.length === 0 || comment.authorAvatarBucket.length === 0) return '';
    try {
      return await PhotoUploadService.getDownloadUrl(context, comment.authorAvatarBucket,
        comment.authorAvatarPath, 'low');
    } catch (_error) {
      return '';
    }
  }

  private async resolveCommentAvatarUrls(context: common.Context, comments: Array<CardComment>): Promise<void> {
    await Promise.all(comments.map(async (comment: CardComment): Promise<void> => {
      if (comment.authorAvatarPath.length > 0 && comment.authorAvatarBucket.length > 0) {
        try {
          comment.authorAvatarUrl = await PhotoUploadService.getDownloadUrl(context,
            comment.authorAvatarBucket, comment.authorAvatarPath);
        } catch (_error) {
          comment.authorAvatarUrl = '';
        }
      }
      await this.resolveCommentAvatarUrls(context, comment.replies);
    }));
  }

  private async resolvePublicMediaUrls(context: common.Context, card: FoodCard): Promise<void> {
    let photos: Array<CardPhoto> = card.photos === undefined ? [] : card.photos;
    if (photos.length === 0) {
      const fallback: CardPhoto = {
        id: '', url: card.photoUrl, path: card.photoPath, bucket: card.photoBucket,
        width: card.photoWidth, height: card.photoHeight
      };
      photos = card.photoPath.length > 0 ? [fallback] : [];
      card.photos = photos;
    }
    await Promise.all(photos.map((photo: CardPhoto): Promise<void> => this.resolvePhotoUrl(context, photo)));
    if (photos.length > 0) {
      const primary = photos[0];
      card.photoUrl = primary.url;
      card.photoPath = primary.path;
      card.photoBucket = primary.bucket;
      card.photoWidth = primary.width;
      card.photoHeight = primary.height;
    }
    const avatarPath = card.authorAvatarPath;
    const avatarBucket = card.authorAvatarBucket;
    if (avatarPath === undefined || avatarBucket === undefined
      || avatarPath.length === 0 || avatarBucket.length === 0) {
      card.authorAvatarUrl = '';
    } else {
      try {
        card.authorAvatarUrl = await PhotoUploadService.getDownloadUrl(context, avatarBucket, avatarPath);
      } catch (_error) {
        // A missing legacy avatar should fall back to the app icon in the UI.
        card.authorAvatarUrl = '';
      }
    }
    const comments = card.comments;
    if (comments !== undefined) await this.resolveCommentAvatarUrls(context, comments);
  }

  /**
   * Fetches nearby card metadata without blocking the first waterfall frame on
   * every signed download URL. The list service remains the authenticated
   * authority for the rounded-coordinate request.
   */
  async listNearbyMetadata(context: common.Context, request: NearbyCardsRequest,
    mayContinue: () => boolean = (): boolean => true): Promise<NearbyCardsResponse> {
    if (!mayContinue()) throw new Error('附近请求已失效。');
    await AuthService.ensureSession(context);
    if (!mayContinue()) throw new Error('附近请求已失效。');
    const traceTaskId: number = NearbyPerformanceTrace.start('shike.nearby.cloud_list');
    try {
      return await CloudGateway.callAuthenticated<NearbyCardsResponse>('list-nearby-cards', request);
    } finally {
      NearbyPerformanceTrace.finish('shike.nearby.cloud_list', traceTaskId);
    }
  }

  /** Legacy full-list caller; the visible ranking page now uses metadata first. */
  async listNearby(context: common.Context, request: NearbyCardsRequest): Promise<NearbyCardsResponse> {
    const response: NearbyCardsResponse = await this.listNearbyMetadata(context, request);
    await this.hydrateNearbyPrimaryPhotoUrls(context, response.cards);
    return response;
  }

  async listFriendRankingsMetadata(context: common.Context): Promise<Array<FoodCard>> {
    await AuthService.ensureSession(context);
    const request: EmptyRequest = {};
    const response = await CloudGateway.callAuthenticated<FriendRankingsResponse>('list-friend-rankings', request);
    return response.cards;
  }

  async listFriendRankings(context: common.Context): Promise<Array<FoodCard>> {
    const cards: Array<FoodCard> = await this.listFriendRankingsMetadata(context);
    await this.hydrateNearbyPrimaryPhotoUrls(context, cards, 0, cards.length, 'low');
    return cards;
  }

  async detail(context: common.Context, cardId: string): Promise<FoodCard> {
    const request: CardDetailRequest = { cardId, includeComments: false };
    const traceTaskId: number = NearbyPerformanceTrace.start('shike.detail.metadata');
    try {
      if (AuthService.profile() !== undefined && CloudGateway.hasSession()) {
        await AuthService.ensureSession(context);
        return await CloudGateway.callAuthenticated<FoodCard>('get-card-detail', request);
      }
      return await CloudGateway.callPublic<FoodCard>('get-card-detail', request);
    } finally {
      NearbyPerformanceTrace.finish('shike.detail.metadata', traceTaskId);
    }
  }

  async myCards(context: common.Context): Promise<Array<FoodCard>> {
    await AuthService.ensureSession(context);
    const request: EmptyRequest = {};
    const result = await CloudGateway.callAuthenticated<MyCardsResponse>('list-my-cards', request);
    await Promise.all(result.cards.map((card: FoodCard): Promise<void> => this.resolvePublicMediaUrls(context, card)));
    return result.cards;
  }

  async myFavoriteCards(context: common.Context): Promise<Array<FoodCard>> {
    await AuthService.ensureSession(context);
    const request: EmptyRequest = {};
    const result = await CloudGateway.callAuthenticated<MyCardsResponse>('list-my-favorite-cards', request);
    await Promise.all(result.cards.map((card: FoodCard): Promise<void> => this.resolvePublicMediaUrls(context, card)));
    return result.cards;
  }

  async receivedComments(context: common.Context, pageToken: string): Promise<ReceivedCommentsResponse> {
    await AuthService.ensureSession(context);
    const request: ReceivedCommentsRequest = { pageToken, pageSize: 20 };
    return CloudGateway.callAuthenticated<ReceivedCommentsResponse>('list-received-comments', request);
  }

  async hydrateReceivedCommentAvatar(context: common.Context, item: ReceivedCommentItem): Promise<string> {
    const path: string = typeof item.authorAvatarPath === 'string' ? item.authorAvatarPath : '';
    const bucket: string = typeof item.authorAvatarBucket === 'string' ? item.authorAvatarBucket : '';
    if (path.length === 0 || bucket.length === 0) return '';
    try {
      return await PhotoUploadService.getDownloadUrl(context, bucket, path, 'low');
    } catch (_error) {
      return '';
    }
  }

  async preparePhoto(context: common.Context, request: PrepareCardPhotoRequest): Promise<PrepareCardPhotoResponse> {
    await AuthService.ensureSession(context);
    return CloudGateway.callAuthenticated<PrepareCardPhotoResponse>('prepare-card-photo', request);
  }

  async publish(context: common.Context, request: PublishCardRequest): Promise<PublishCardResponse> {
    await AuthService.ensureSession(context);
    return CloudGateway.callAuthenticated<PublishCardResponse>('publish-card', request);
  }

  async report(context: common.Context, cardId: string, reason: string): Promise<void> {
    await AuthService.ensureSession(context);
    const request: ReportCardRequest = { cardId, reason };
    await CloudGateway.callAuthenticated<OperationResponse>('report-card', request);
  }

  async toggleCardAction(context: common.Context, request: ToggleCardActionRequest): Promise<CardActionResponse> {
    await AuthService.ensureSession(context);
    return CloudGateway.callAuthenticated<CardActionResponse>('toggle-card-action', request);
  }

  async createComment(context: common.Context, request: CreateCardCommentRequest): Promise<void> {
    await AuthService.ensureSession(context);
    await CloudGateway.callAuthenticated<OperationResponse>('create-card-comment', request);
  }

  async deleteComment(context: common.Context, request: DeleteCardCommentRequest): Promise<void> {
    await AuthService.ensureSession(context);
    await CloudGateway.callAuthenticated<OperationResponse>('delete-card-comment', request);
  }

  async toggleCommentReaction(context: common.Context,
    request: ToggleCommentReactionRequest): Promise<CommentReactionResponse> {
    await AuthService.ensureSession(context);
    return CloudGateway.callAuthenticated<CommentReactionResponse>('toggle-comment-reaction', request);
  }

  async deleteOwn(context: common.Context, cardId: string): Promise<void> {
    await AuthService.ensureSession(context);
    const request: CardIdRequest = { cardId };
    await CloudGateway.callAuthenticated<OperationResponse>('delete-own-card', request);
  }
}
