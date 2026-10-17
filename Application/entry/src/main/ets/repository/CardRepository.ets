/**
 * 【文件职责】卡片相关的业务调用封装：首页推荐、详情、我的卡片、图片准备、发布、删除，以及卡片图片地址的补全。
 * 【链路位置】DiscoveryFeed / CardDetailPage / CreateCardPage / 个人页 → 本文件 → CloudGateway
 * → shike-content（list-nearby-cards、get-card-detail、list-my-cards、publish-card、delete-own-card）；
 * 图片准备 prepare-card-photo 由 CloudGateway 转给 shike-media。
 * 【依赖】HomeSnapshotReader（游客首页快照）、ImageRepository（图片下载与缓存）、AuthService（确保会话有效）。
 * 【新人注意】游客首页第一页优先读快照，读不到才查云函数；写操作成功后由 CloudGateway 统一刷新读缓存，这里不需要手动清缓存。
 */
import { common } from '@kit.AbilityKit';
import { ReadRequestOptions } from '../service/ReadScheduler';
import {
  CardDetailRequest, CardIdRequest, CardPhoto, EmptyRequest, FoodCard,
  MyCardsResponse, NearbyCardsResponse, OperationResponse,
  PrepareCardPhotoRequest, PrepareCardPhotoResponse, PublishCardRequest,
  PublishCardResponse, PublicCardsRequest
} from '../model/CloudContracts';
import { CloudBusinessError, ReadCancelledError } from '../service/CloudReadErrors';
import { AuthService } from '../service/AuthService';
import { CloudGateway, MediaServiceUnavailableError } from '../service/CloudGateway';
import { NearbyPerformanceTrace } from '../service/NearbyPerformanceTrace';
import { MediaPriority, MediaRequestGuard, ImageRepository } from '../service/ImageRepository';
import { HomeSnapshotReader } from '../service/HomeSnapshotReader';
import { ImageDescriptors } from '../service/ImageDescriptors';

// 卡片仓库（无状态，页面里 new 一个即可）。
export class CardRepository {
  /**
   * 读取推荐流的一页“元数据”（不含图片字节）。
   * 游客请求首页第一页时优先使用首页快照（不消耗 Cloud DB 读额度）；否则调用 list-nearby-cards（scope=all 为公开推荐流）。
   * mayContinue 返回 false 表示页面已不需要这个结果（例如用户已切走），此时抛错丢弃。
   */
  async listRecommendationsMetadata(request: PublicCardsRequest,
    mayContinue: () => boolean = (): boolean => true, options: ReadRequestOptions = {}): Promise<NearbyCardsResponse> {
    if (!mayContinue()) throw new Error('推荐请求已失效。');
    const traceTaskId: number = NearbyPerformanceTrace.start('shike.nearby.cloud_list');
    try {
      // 游客的第一页优先使用每 5 分钟发布一次的首页快照（快照存在且足够新时）。
      if (HomeSnapshotReader.matches(request) && !CloudGateway.hasSession()) {
        CloudGateway.ensureReady();
        const snapshot: NearbyCardsResponse | undefined = await HomeSnapshotReader.read();
        if (snapshot !== undefined && mayContinue() && !CloudGateway.hasSession()) {
          ImageDescriptors.accept(snapshot as Object);
          return snapshot;
        }
      }
      // scope=all 时服务端返回公开推荐流（与“附近”共用同一个操作）。
      const response: NearbyCardsResponse = await CloudGateway.callPublic<NearbyCardsResponse>('list-nearby-cards', request, options);
      if (!mayContinue()) throw new Error('推荐请求已失效。');
      return response;
    } finally {
      NearbyPerformanceTrace.finish('shike.nearby.cloud_list', traceTaskId);
    }
  }

  // 补全一张图片的本地地址；无权限（卡片已下架、账号停用）时标记 accessDenied，界面显示相应占位。
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
      // 离开页面只会取消这个页面的订阅，图片任务本身仍会继续；保留已得到的地址，由仍在显示的页面通过守卫再次请求。
      if (error instanceof ReadCancelledError) throw error;
      photo.accessDenied = error instanceof CloudBusinessError && ['CONTENT_ACCESS_DENIED', 'CONTENT_UNAVAILABLE', 'ACCOUNT_INACTIVE'].includes(error.code);
      photo.url = '';
      if (!(error instanceof MediaServiceUnavailableError)) {
        console.warn('[PhotoDownload] get-public-media failed; showing a placeholder.');
      }
    }
  }

  // 为列表中 [startIndex, startIndex+maxCount) 范围内的卡片批量加载封面；每张完成时回调 onSettled 以便逐张刷新界面。
  async hydrateNearbyPrimaryPhotoUrls(context: common.Context, cards: Array<FoodCard>, startIndex: number = 0,
    maxCount: number = cards.length, priority: MediaPriority = 'normal', mayContinue?: MediaRequestGuard,
    onSettled?: (card: FoodCard) => void, isCardNeeded?: (card: FoodCard) => boolean): Promise<void> {
    const guard: MediaRequestGuard = mayContinue === undefined ? async (): Promise<boolean> => true : mayContinue;
    const settled: (card: FoodCard) => void = onSettled === undefined ? (_card: FoodCard): void => {} : onSettled;
    await ImageRepository.hydrateCovers(context, cards.slice(Math.max(0, startIndex), Math.max(0, startIndex) + Math.max(0, maxCount)), guard, settled, false, priority, isCardNeeded);
  }

  // 加载详情页中的一张图片（原图），返回本地 file:// 地址。
  async hydrateDetailPhoto(context: common.Context, photo: CardPhoto,
    priority: MediaPriority = 'normal', mayContinue?: MediaRequestGuard): Promise<string> {
    if (photo.path.length === 0 || photo.bucket.length === 0) return '';
    return ImageRepository.getDownloadUrl(context, photo.bucket, photo.path, priority, mayContinue, photo, false);
  }

  // 补全“我的卡片”中每张卡片所有图片与作者头像的本地地址；没有 photos 数组的旧数据用单图字段兜底。
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
        // 旧数据缺少头像时，界面回退显示应用图标。
        card.authorAvatarUrl = '';
      }
    }
  }

  // 读取卡片详情：已登录时带身份（返回“我是否点赞/收藏”等），否则匿名读取。
  async detail(context: common.Context, cardId: string, options: ReadRequestOptions = {}): Promise<FoodCard> {
    const request: CardDetailRequest = { cardId };
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

  // 读取自己发布的全部卡片并补全图片。
  async myCards(context: common.Context): Promise<Array<FoodCard>> {
    await AuthService.ensureSession(context);
    const request: EmptyRequest = {};
    const result = await CloudGateway.callAuthenticated<MyCardsResponse>('list-my-cards', request);
    await Promise.all(result.cards.map((card: FoodCard): Promise<void> => this.resolvePublicMediaUrls(context, card)));
    return result.cards;
  }

  // 发布流程第 1 步：为一张实拍图申请上传位置（shike-media 写一条 PENDING_UPLOAD 记录并返回目标路径）。
  async preparePhoto(context: common.Context, request: PrepareCardPhotoRequest): Promise<PrepareCardPhotoResponse> {
    await AuthService.ensureSession(context);
    return CloudGateway.callAuthenticated<PrepareCardPhotoResponse>('prepare-card-photo', request);
  }

  // 发布流程第 3 步：提交卡片内容（图片已上传完成）；云端用请求回执防止重复发布。
  async publish(context: common.Context, request: PublishCardRequest): Promise<PublishCardResponse> {
    await AuthService.ensureSession(context);
    return CloudGateway.callAuthenticated<PublishCardResponse>('publish-card', request);
  }

  // 删除自己的卡片（软删除，30 天内可在“删除记录”恢复）。
  async deleteOwn(context: common.Context, cardId: string): Promise<void> {
    await AuthService.ensureSession(context);
    const request: CardIdRequest = { cardId };
    await CloudGateway.callAuthenticated<OperationResponse>('delete-own-card', request);
  }
}
