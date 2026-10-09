import { common } from '@kit.AbilityKit';
import { ReadRequestOptions } from '../service/ReadScheduler';
import {
  CardActionResponse, CardComment, CardDetailRequest, CardIdRequest, CardPhoto, CommentReactionResponse, CreateCardCommentRequest,
  DeleteCardCommentRequest, EmptyRequest, FoodCard, FriendRankingsResponse, MyCardsResponse, NearbyCardsRequest, NearbyCardsResponse,
  OperationResponse, PrepareCardPhotoRequest, PrepareCardPhotoResponse, PublishCardRequest,
  PublishCardResponse, PublicCardsRequest, ReceivedCommentItem, ReceivedCommentsRequest, ReceivedCommentsResponse, ReportCardRequest,
  ToggleCardActionRequest, ToggleCommentReactionRequest
} from '../model/CloudContracts';
import { CloudBusinessError, ReadCancelledError } from '../service/CloudReadErrors';
import { AuthService } from '../service/AuthService';
import { CloudGateway, MediaServiceUnavailableError } from '../service/CloudGateway';
import { NearbyPerformanceTrace } from '../service/NearbyPerformanceTrace';
import { MediaPriority, MediaRequestGuard, ImageRepository } from '../service/ImageRepository';

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
    photo.accessDenied = false;
    try {
      photo.url = await ImageRepository.getDownloadUrl(context, photo.bucket, photo.path, priority, mayContinue, photo, true);
    } catch (error) {
      // Leaving a page cancels its subscriber, not the image itself. Preserve
      // any resolved URL and let the active page request it through its guard.
      if (error instanceof ReadCancelledError) throw error;
      photo.accessDenied = error instanceof CloudBusinessError && ['CONTENT_ACCESS_DENIED', 'CONTENT_UNAVAILABLE', 'ACCOUNT_INACTIVE'].includes(error.code);
      photo.url = '';
      if (!(error instanceof MediaServiceUnavailableError)) {
        console.warn('[PhotoDownload] get-public-media failed; showing a placeholder.');
      }
    }
  }

  async hydrateNearbyPrimaryPhotoUrls(context: common.Context, cards: Array<FoodCard>, startIndex: number = 0,
    maxCount: number = cards.length, priority: MediaPriority = 'normal', mayContinue?: MediaRequestGuard,
    onSettled?: (card: FoodCard) => void, isCardNeeded?: (card: FoodCard) => boolean): Promise<void> {
    const guard: MediaRequestGuard = mayContinue === undefined ? async (): Promise<boolean> => true : mayContinue;
    const settled: (card: FoodCard) => void = onSettled === undefined ? (_card: FoodCard): void => {} : onSettled;
    await ImageRepository.hydrateCovers(context, cards.slice(Math.max(0, startIndex), Math.max(0, startIndex) + Math.max(0, maxCount)), guard, settled, false, priority, isCardNeeded);
  }

  async hydrateDetailPhoto(context: common.Context, photo: CardPhoto,
    priority: MediaPriority = 'normal', mayContinue?: MediaRequestGuard): Promise<string> {
    if (photo.path.length === 0 || photo.bucket.length === 0) return '';
    return ImageRepository.getDownloadUrl(context, photo.bucket, photo.path, priority, mayContinue, photo, false);
  }

  async hydrateCommentAvatar(context: common.Context, comment: CardComment): Promise<string> {
    if (comment.authorAvatarPath.length === 0 || comment.authorAvatarBucket.length === 0) return '';
    try {
      return await ImageRepository.getDownloadUrl(context, comment.authorAvatarBucket,
        comment.authorAvatarPath, 'low');
    } catch (_error) {
      return '';
    }
  }

  private async resolveCommentAvatarUrls(context: common.Context, comments: Array<CardComment>): Promise<void> {
    await Promise.all(comments.map(async (comment: CardComment): Promise<void> => {
      if (comment.authorAvatarPath.length > 0 && comment.authorAvatarBucket.length > 0) {
        try {
          comment.authorAvatarUrl = await ImageRepository.getDownloadUrl(context,
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
        card.authorAvatarUrl = await ImageRepository.getDownloadUrl(context, avatarBucket, avatarPath);
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

  async detail(context: common.Context, cardId: string, options: ReadRequestOptions = {}): Promise<FoodCard> {
    const request: CardDetailRequest = { cardId, includeComments: false };
    const traceTaskId: number = NearbyPerformanceTrace.start('shike.detail.metadata');
    try {
      if (AuthService.profile() !== undefined && CloudGateway.hasSession()) {
        await AuthService.ensureSession(context);
        return await CloudGateway.callAuthenticated<FoodCard>('get-card-detail', request, options);
      }
      return await CloudGateway.callPublic<FoodCard>('get-card-detail', request, options);
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
      return await ImageRepository.getDownloadUrl(context, bucket, path, 'low');
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
