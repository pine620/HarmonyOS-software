import { common } from '@kit.AbilityKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { harmonyShare, systemShare } from '@kit.ShareKit';
import {
  CardActionType, CardComment, CardPhoto, CommentReactionType, FoodCard
} from '../model/CloudContracts';
import { CardRepository } from '../repository/CardRepository';
import { categoryLabel } from '../components/FoodCover';
import { AuthService } from '../service/AuthService';
import { CardVisitStore } from '../service/CardVisitStore';
import { cardPriceText } from '../model/CardPrice';
import { MediaServiceUnavailableError } from '../service/CloudGateway';
import { MediaPriority, PhotoUploadService } from '../service/PhotoUploadService';
import { NearbyPerformanceTrace, PreloadMetricState } from '../service/NearbyPerformanceTrace';
import { cardAppLink } from '../service/CardAppLink';
import { tasteScoreText as formatTasteScore } from '../model/TasteScore';
import { ErrorDetail, errorText } from '../common/ErrorKit';
import { BreakpointSystem } from '../common/BreakpointSystem';

const DETAIL_MEDIA_FRAME_HEIGHT = 360;

function emptyCard(): FoodCard {
  return {
    id: '', productName: '', brand: '', priceFen: 0, priceLabel: '', originalPriceFen: 0,
    specification: '', shop: '', sellingPoints: [], publicOffers: [], reviewText: '', tasteScore: 0,
    sourceLink: '', category: 'other',
    photoUrl: '', photoPath: '', photoBucket: '', photoWidth: 0, photoHeight: 0,
    authorNickname: '食刻用户', authorAvatarUrl: '', authorAvatarPath: '', authorAvatarBucket: '',
    photos: [], viewerIsOwner: false, likeCount: 0, favoriteCount: 0, viewerLiked: false,
    viewerFavorited: false, commentCount: 0, comments: [], district: '', distanceKm: 0,
    status: 'APPROVED', createdAt: 0
  };
}

function fallbackPhoto(card: FoodCard): CardPhoto {
  return {
    id: '', url: card.photoUrl, path: card.photoPath, bucket: card.photoBucket,
    width: card.photoWidth, height: card.photoHeight
  };
}

@Component
export struct CardDetailPage {
  @State detailWidthVp: number = 0;
  @Prop card: FoodCard = emptyCard();
  onShareToFriend: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @State detailPhotos: Array<CardPhoto> = [];
  @State photoFailures: Array<number> = [];
  @State mediaServiceUnavailable: boolean = false;
  @State photoIndex: number = 0;
  @State photoPreviewVisible: boolean = false;
  @State previewPhotoIndex: number = 0;
  @State detailAuthorNickname: string = '';
  @State detailAuthorAvatarUrl: string = '';
  @State viewerIsOwner: boolean = false;
  @State likeCount: number = 0;
  @State favoriteCount: number = 0;
  @State viewerLiked: boolean = false;
  @State viewerFavorited: boolean = false;
  @State commentCount: number = 0;
  @State comments: Array<CardComment> = [];
  @State visibleCommentCount: number = 3;
  @State expandedReplyCommentIds: Array<string> = [];
  @State commentInput: string = '';
  @State replyToCommentId: string = '';
  @State replyToNickname: string = '';
  @State deletingCommentId: string = '';
  @State actionMenuVisible: boolean = false;
  @State reportOptionsVisible: boolean = false;
  @State reportReason: string = '信息不准确';
  @State reportReasonIndex: number = 0;
  @State interactionBusy: boolean = false;
  @State commentBusy: boolean = false;
  @State status: string = '';
  @State knockShareEnabled: boolean = false;
  @State knockShareBusy: boolean = false;
  private repository: CardRepository = new CardRepository();
  private detailGeneration: number = 0;
  private primaryImageStarted: number = 0;
  private hydratingPhotoIndices: Set<number> = new Set<number>();
  private hydratingCommentIds: Set<string> = new Set<string>();
  private knockShareGeneration: number = 0;
  private knockSharePageVisible: boolean = false;
  private knockShareListener: (target: harmonyShare.SharableTarget) => void =
    (target: harmonyShare.SharableTarget): void => {
      void this.sendKnockShare(target);
    };

  aboutToAppear(): void {
    this.primaryImageStarted = Date.now();
    PhotoUploadService.retryMediaService();
    this.mediaServiceUnavailable = false;
    this.visibleCommentCount = 3;
    const initialPhotos: Array<CardPhoto> = this.card.photos === undefined ? [] : this.card.photos;
    this.detailPhotos = initialPhotos.length > 0 ? initialPhotos :
      (this.card.photoPath.length > 0 ? [fallbackPhoto(this.card)] : []);
    void this.loadDetail();
  }

  aboutToDisappear(): void {
    this.detailGeneration += 1;
    this.finishPrimaryImage('cancelled');
    this.stopKnockShare('');
  }

  private finishPrimaryImage(state: PreloadMetricState): void {
    if (this.primaryImageStarted === 0) return;
    NearbyPerformanceTrace.record('detail_primary_image', state, this.primaryImageStarted);
    this.primaryImageStarted = 0;
  }

  private async loadDetail(): Promise<void> {
    const generation: number = this.detailGeneration + 1;
    this.detailGeneration = generation;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const detail: FoodCard = await this.repository.detail(context, this.card.id);
      if (generation !== this.detailGeneration) return;
      const previousPhoto: CardPhoto | undefined = this.detailPhotos.length > 0 ? this.detailPhotos[0] : undefined;
      const photos: Array<CardPhoto> = detail.photos === undefined ? [] : detail.photos;
      if (photos.length > 0 && previousPhoto !== undefined && photos[0].path === previousPhoto.path &&
        photos[0].bucket === previousPhoto.bucket) {
        photos[0].url = previousPhoto.url;
        detail.photoUrl = previousPhoto.url;
      }
      this.card = detail;
      try {
        const viewer = AuthService.profile();
        if (viewer !== undefined) CardVisitStore.record(context, viewer.uid, detail);
      } catch (_error) {
        // Local browsing history must never turn a successful detail load into an error.
      }
      this.detailPhotos = photos.length > 0
        ? photos : (detail.photoPath.length > 0 ? [fallbackPhoto(detail)] : []);
      if (this.detailPhotos.length === 0) this.finishPrimaryImage('empty');
      this.photoIndex = 0;
      this.photoFailures = [];
      this.hydratingPhotoIndices.clear();
      this.hydratingCommentIds.clear();
      this.detailAuthorNickname = detail.authorNickname === undefined ? '' : detail.authorNickname;
      this.detailAuthorAvatarUrl = detail.authorAvatarUrl === undefined ? '' : detail.authorAvatarUrl;
      this.viewerIsOwner = detail.viewerIsOwner === true;
      const ownProfile = AuthService.profile();
      if (this.viewerIsOwner && ownProfile !== undefined) {
        if (this.detailAuthorNickname.length === 0 || this.detailAuthorNickname === '食刻用户') {
          this.detailAuthorNickname = ownProfile.nickname;
        }
        if (this.detailAuthorAvatarUrl.length === 0 && ownProfile.avatarUrl.length > 0) {
          this.detailAuthorAvatarUrl = ownProfile.avatarUrl;
        }
      }
      this.likeCount = detail.likeCount === undefined ? 0 : detail.likeCount;
      this.favoriteCount = detail.favoriteCount === undefined ? 0 : detail.favoriteCount;
      this.viewerLiked = detail.viewerLiked === true;
      this.viewerFavorited = detail.viewerFavorited === true;
      this.commentCount = detail.commentCount === undefined ? 0 : detail.commentCount;
      this.comments = this.normalizeComments(detail.comments === undefined ? [] : detail.comments);
      this.status = '';
      void this.hydratePhotoAt(0, 'high', generation);
      void this.hydrateAuthorAvatar(generation);
    } catch (error) {
      if (generation !== this.detailGeneration) return;
      this.finishPrimaryImage('error');
      this.status = `详情刷新失败：${errorText(error as ErrorDetail)}`;
    }
  }

  private async hydratePhotoAt(index: number, priority: MediaPriority,
    generation: number = this.detailGeneration): Promise<void> {
    if (index < 0 || index >= this.detailPhotos.length || this.hydratingPhotoIndices.has(index)) return;
    const photo: CardPhoto = this.detailPhotos[index];
    if (photo.url.length > 0 || photo.path.length === 0) return;
    this.hydratingPhotoIndices.add(index);
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const url: string = await this.repository.hydrateDetailPhoto(context, photo, priority);
      if (generation !== this.detailGeneration) return;
      this.detailPhotos = this.detailPhotos.map((item: CardPhoto, position: number): CardPhoto =>
        position === index ? { id: item.id, url, path: item.path, bucket: item.bucket,
          width: item.width, height: item.height } : item);
      if (index === 0) {
        this.card.photoUrl = url;
        this.card.photos = this.detailPhotos;
      }
      if (url.length === 0) {
        if (index === 0) this.finishPrimaryImage('error');
        this.photoFailures = this.photoFailures.concat([index]);
      }
    } catch (error) {
      if (generation === this.detailGeneration) {
        if (index === 0) this.finishPrimaryImage('error');
        if (error instanceof MediaServiceUnavailableError) this.mediaServiceUnavailable = true;
        if (!this.photoFailures.includes(index)) this.photoFailures = this.photoFailures.concat([index]);
      }
    } finally {
      if (generation === this.detailGeneration) this.hydratingPhotoIndices.delete(index);
    }
  }

  private retryPhoto(index: number): void {
    PhotoUploadService.retryMediaService();
    this.mediaServiceUnavailable = false;
    this.photoFailures = this.photoFailures.filter((failed: number): boolean => failed !== index);
    void this.hydratePhotoAt(index, 'high');
  }

  private async hydrateAuthorAvatar(generation: number): Promise<void> {
    if (this.detailAuthorAvatarUrl.length > 0 || !this.card.authorAvatarPath || !this.card.authorAvatarBucket) return;
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const url: string = await PhotoUploadService.getDownloadUrl(context, this.card.authorAvatarBucket,
        this.card.authorAvatarPath, 'low');
      if (generation === this.detailGeneration) this.detailAuthorAvatarUrl = url;
    } catch (_error) { }
  }

  private withCommentAvatar(comment: CardComment, commentId: string, url: string): CardComment {
    const replies: Array<CardComment> = comment.replies.map((reply: CardComment): CardComment =>
      this.withCommentAvatar(reply, commentId, url));
    const copy: CardComment = this.copyCommentWithReplies(comment, replies);
    if (comment.id === commentId) copy.authorAvatarUrl = url;
    return copy;
  }

  private async hydrateCommentAvatar(comment: CardComment, generation: number): Promise<void> {
    if (comment.authorAvatarUrl.length > 0 || comment.authorAvatarPath.length === 0 ||
      this.hydratingCommentIds.has(comment.id)) return;
    this.hydratingCommentIds.add(comment.id);
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const url: string = await this.repository.hydrateCommentAvatar(context, comment);
      if (generation === this.detailGeneration && url.length > 0) {
        this.comments = this.comments.map((root: CardComment): CardComment =>
          this.withCommentAvatar(root, comment.id, url));
      }
    } catch (_error) {
      // Keep the comment text available when its optional avatar fails.
    } finally {
      if (generation === this.detailGeneration) this.hydratingCommentIds.delete(comment.id);
    }
  }

  private authorName(): string {
    if (this.detailAuthorNickname.length > 0) return this.detailAuthorNickname;
    const value = this.card.authorNickname;
    return value !== undefined && value.length > 0 ? value : '食刻用户';
  }

  private authorAvatarUrl(): string {
    if (this.detailAuthorAvatarUrl.length > 0) return this.detailAuthorAvatarUrl;
    const value = this.card.authorAvatarUrl;
    return value === undefined ? '' : value;
  }

  private imageHeight(): number {
    if (this.isWideDetail()) {
      return Math.round(Math.max(300, Math.min(480, this.detailPaneWidth() * 0.9)));
    }
    return DETAIL_MEDIA_FRAME_HEIGHT;
  }

  private isWideDetail(): boolean {
    return this.detailWidthVp >= BreakpointSystem.LARGE_MIN;
  }

  private detailPadding(): number {
    return BreakpointSystem.pagePadding(BreakpointSystem.fromWidth(this.detailWidthVp));
  }

  private detailPaneWidth(): number {
    return Math.max(0, (this.detailWidthVp - this.detailPadding() * 2 - 24) / 2);
  }

  private detailColumnWidth(): number | string {
    return this.isWideDetail() ? this.detailPaneWidth() : '100%';
  }

  private openPhotoPreview(index: number): void {
    if (index < 0 || index >= this.detailPhotos.length || this.detailPhotos[index].url.length === 0) return;
    this.previewPhotoIndex = index;
    this.photoPreviewVisible = true;
  }

  private closePhotoPreview(): void {
    this.photoPreviewVisible = false;
  }

  private createdLabel(timestamp: number): string {
    if (timestamp <= 0) return '刚刚发布';
    const date = new Date(timestamp);
    return `${date.getMonth() + 1}月${date.getDate()}日`;
  }

  private copyCommentWithReplies(comment: CardComment, replies: Array<CardComment>): CardComment {
    const copy: CardComment = {
      id: comment.id,
      parentId: comment.parentId,
      replyToNickname: comment.replyToNickname,
      authorNickname: comment.authorNickname,
      authorAvatarUrl: comment.authorAvatarUrl,
      authorAvatarPath: comment.authorAvatarPath,
      authorAvatarBucket: comment.authorAvatarBucket,
      content: comment.content,
      deleted: false,
      likeCount: comment.likeCount,
      dislikeCount: comment.dislikeCount,
      viewerReaction: comment.viewerReaction,
      viewerIsAuthor: comment.viewerIsAuthor,
      viewerCanDelete: comment.viewerCanDelete === true,
      createdAt: comment.createdAt,
      replies
    };
    return copy;
  }

  private normalizeComments(source: Array<CardComment>): Array<CardComment> {
    const visible: Array<CardComment> = [];
    source.forEach((comment: CardComment): void => {
      const replies: Array<CardComment> = this.normalizeComments(comment.replies);
      if (comment.deleted) {
        replies.forEach((reply: CardComment): void => {
          visible.push(reply);
        });
      } else {
        visible.push(this.copyCommentWithReplies(comment, replies));
      }
    });
    return visible;
  }

  private visibleComments(): Array<CardComment> {
    return this.comments.slice(0, this.visibleCommentCount);
  }

  private repliesExpanded(commentId: string): boolean {
    return this.expandedReplyCommentIds.includes(commentId);
  }

  private visibleReplies(comment: CardComment): Array<CardComment> {
    return this.repliesExpanded(comment.id) ? comment.replies : comment.replies.slice(0, 2);
  }

  private toggleReplies(commentId: string): void {
    if (this.repliesExpanded(commentId)) {
      this.expandedReplyCommentIds = this.expandedReplyCommentIds.filter((id: string): boolean => id !== commentId);
    } else {
      this.expandedReplyCommentIds = this.expandedReplyCommentIds.concat([commentId]);
    }
  }

  private reviewText(): string {
    const reviewText = typeof this.card.reviewText === 'string' ? this.card.reviewText.trim() : '';
    if (reviewText.length > 0) return reviewText;
    return this.card.sellingPoints.length > 0
      ? this.card.sellingPoints.join('；') : '发布者暂未填写点评。';
  }

  private tasteScoreText(): string {
    const score = typeof this.card.tasteScore === 'number' ? this.card.tasteScore : 0;
    return formatTasteScore(score);
  }

  private cardLink(): string {
    return this.card.status === 'APPROVED' ? cardAppLink(this.card.id) : '';
  }

  private cardLinkShareData(): systemShare.SharedData {
    return new systemShare.SharedData({
      utd: utd.UniformDataType.HYPERLINK,
      content: this.cardLink(),
      title: '食刻推荐：' + (this.card.productName || '美食卡片'),
      description: '来自食刻的真实美食评价 · 碰一碰即可打开'
    });
  }

  private toggleKnockShare(): void {
    if (this.knockShareEnabled) {
      this.stopKnockShare('已结束碰一碰分享。');
      this.closeActionMenu();
      return;
    }
    if (!this.knockSharePageVisible) return;
    if (this.cardLink().length === 0) {
      this.status = '当前卡片还没有可分享的安全链接，请刷新详情后重试。';
      this.closeActionMenu();
      return;
    }
    if (!canIUse('SystemCapability.Collaboration.HarmonyShare')) {
      this.status = '当前设备不支持碰一碰分享，请使用系统分享发送卡片链接。';
      this.closeActionMenu();
      return;
    }
    try {
      this.knockShareGeneration += 1;
      harmonyShare.on('knockShare', this.knockShareListener);
      this.knockShareEnabled = true;
      this.status = '已准备碰一碰：让两台已解锁、亮屏且开启华为分享的设备顶部轻碰。';
    } catch (error) {
      this.status = '当前设备无法开启碰一碰：' + errorText(error as ErrorDetail)
        + '；你仍可使用系统分享。';
    }
    this.closeActionMenu();
  }

  private stopKnockShare(status: string): void {
    const wasEnabled: boolean = this.knockShareEnabled;
    this.knockShareGeneration += 1;
    this.knockShareEnabled = false;
    this.knockShareBusy = false;
    if (wasEnabled) {
      try {
        harmonyShare.off('knockShare', this.knockShareListener);
      } catch (_error) {
        // The system may already have removed the foreground callback.
      }
    }
    if (status.length > 0) this.status = status;
  }

  private async sendKnockShare(target: harmonyShare.SharableTarget): Promise<void> {
    if (!this.knockShareEnabled || this.knockShareBusy || !this.knockSharePageVisible) return;
    if (this.cardLink().length === 0) {
      this.stopKnockShare('当前卡片不再公开或链接无效，已结束碰一碰分享。');
      return;
    }
    const generation: number = this.knockShareGeneration;
    this.knockShareBusy = true;
    try {
      await target.share(this.cardLinkShareData());
      if (generation !== this.knockShareGeneration || !this.knockSharePageVisible) return;
      this.status = '已向系统提交卡片链接，请在接收端确认打开结果。';
    } catch (error) {
      if (generation !== this.knockShareGeneration || !this.knockSharePageVisible) return;
      this.status = '碰一碰未完成：' + errorText(error as ErrorDetail) + '；可改用系统分享。';
    } finally {
      if (generation === this.knockShareGeneration) this.knockShareBusy = false;
    }
  }

  private async shareCard(): Promise<void> {
    if (this.cardLink().length === 0) {
      this.status = '当前卡片还没有可分享的安全链接，请刷新详情后重试。';
      this.closeActionMenu();
      return;
    }
    try {
      const title = '食刻推荐：' + (this.card.productName || '美食卡片');
      const shareData: systemShare.SharedData = new systemShare.SharedData({
        utd: utd.UniformDataType.HYPERLINK,
        content: this.cardLink(),
        title,
        description: this.tasteScoreText().length > 0
          ? `口味 ${this.tasteScoreText()} · 打开食刻查看详情`
          : '打开食刻查看这张真实美食推荐'
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(shareData);
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await controller.show(context, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL
      });
      this.status = '已打开系统分享面板。';
    } catch (error) {
      this.status = '无法打开系统分享：' + errorText(error as ErrorDetail);
    } finally {
      this.closeActionMenu();
    }
  }

  private priceText(): string {
    return cardPriceText(this.card);
  }

  private async openSource(): Promise<void> {
    if (!this.card.sourceLink.startsWith('https://')) {
      this.status = '当前卡片没有可打开的来源页面。';
      this.closeActionMenu();
      return;
    }
    this.closeActionMenu();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await context.startAbility({ action: 'ohos.want.action.viewData', uri: this.card.sourceLink });
  }

  private closeActionMenu(): void {
    this.actionMenuVisible = false;
    this.reportOptionsVisible = false;
  }

  private shareToFriend(): void {
    this.closeActionMenu();
    this.onShareToFriend(this.card);
  }

  private dismissOverlay(): void {
    this.closeActionMenu();
    this.closePhotoPreview();
    this.deletingCommentId = '';
  }

  private async report(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.repository.report(context, this.card.id, this.reportReason);
      this.status = '举报已提交。同一账号对同一卡片只计一次。';
      this.closeActionMenu();
    } catch (error) {
      this.status = errorText(error as ErrorDetail);
    }
  }

  private async toggleCardAction(action: CardActionType): Promise<void> {
    if (this.interactionBusy) return;
    this.interactionBusy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const result = await this.repository.toggleCardAction(context, { cardId: this.card.id, action });
      this.likeCount = result.likeCount;
      this.favoriteCount = result.favoriteCount;
      this.viewerLiked = result.viewerLiked;
      this.viewerFavorited = result.viewerFavorited;
    } catch (error) {
      this.status = `互动未完成：${errorText(error as ErrorDetail)}`;
    } finally {
      this.interactionBusy = false;
    }
  }

  private replyTo(comment: CardComment): void {
    if (comment.deleted) {
      this.status = '该评论已删除，不能回复。';
      return;
    }
    if (comment.viewerIsAuthor) {
      this.status = '这是你的评论；如需删除，请长按该评论。';
      return;
    }
    if (comment.id.length === 0) {
      this.status = '这条评论暂时无法回复，请刷新后重试。';
      return;
    }
    this.replyToCommentId = comment.id;
    this.replyToNickname = comment.authorNickname;
    this.status = '';
  }

  private clearReply(): void {
    this.replyToCommentId = '';
    this.replyToNickname = '';
  }

  private async publishComment(): Promise<void> {
    if (this.commentBusy) return;
    if (this.commentInput.trim().length === 0) {
      this.status = '请输入评论内容后再发布。';
      return;
    }
    this.commentBusy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.repository.createComment(context, {
        cardId: this.card.id, parentCommentId: this.replyToCommentId, content: this.commentInput
      });
      this.commentInput = '';
      this.clearReply();
      await this.loadDetail();
    } catch (error) {
      this.status = `评论发布失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.commentBusy = false;
    }
  }

  private async toggleCommentReaction(comment: CardComment, reaction: CommentReactionType): Promise<void> {
    if (this.commentBusy || comment.deleted) return;
    this.commentBusy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.repository.toggleCommentReaction(context, { commentId: comment.id, reaction });
      await this.loadDetail();
    } catch (error) {
      this.status = `评论互动未完成：${errorText(error as ErrorDetail)}`;
    } finally {
      this.commentBusy = false;
    }
  }

  private async deleteComment(comment: CardComment): Promise<void> {
    if (this.commentBusy || !this.canDeleteComment(comment)) return;
    this.commentBusy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.repository.deleteComment(context, { commentId: comment.id });
      this.deletingCommentId = '';
      await this.loadDetail();
    } catch (error) {
      this.status = `删除评论失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.commentBusy = false;
    }
  }

  private canDeleteComment(comment: CardComment): boolean {
    return comment.viewerCanDelete === true || comment.viewerIsAuthor;
  }

  private requestDeleteComment(comment: CardComment): void {
    if (!this.canDeleteComment(comment) || comment.deleted) return;
    this.deletingCommentId = comment.id;
  }

  private findComment(comments: Array<CardComment>, commentId: string): CardComment | undefined {
    for (const comment of comments) {
      if (comment.id === commentId) return comment;
      const reply = this.findComment(comment.replies, commentId);
      if (reply !== undefined) return reply;
    }
    return undefined;
  }

  private async deletePendingComment(): Promise<void> {
    const comment = this.findComment(this.comments, this.deletingCommentId);
    if (comment === undefined) {
      this.deletingCommentId = '';
      return;
    }
    await this.deleteComment(comment);
  }

  private reactionCount(comment: CardComment, reaction: CommentReactionType): number {
    return reaction === 'LIKE' ? comment.likeCount : comment.dislikeCount;
  }

  private reactionName(reaction: CommentReactionType): string {
    return reaction === 'LIKE' ? '赞' : '踩';
  }

  @Builder
  private authorHeader() {
    Row({ space: 12 }) {
      if (this.authorAvatarUrl().length > 0) {
        Image(this.authorAvatarUrl()).width(48).height(48).borderRadius(24).objectFit(ImageFit.Cover)
          .accessibilityText(`${this.authorName()}的头像`);
      } else {
        Image($r('app.media.app_icon')).width(48).height(48).borderRadius(18)
          .accessibilityText('食刻默认头像');
      }
      Column({ space: 4 }) {
        Text(this.authorName()).fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.ink')).width('100%').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Row({ space: 6 }) {
          Text('实拍分享者').fontSize(11).fontColor($r('app.color.leaf'))
            .padding({ left: 7, right: 7, top: 3, bottom: 3 })
            .backgroundColor($r('app.color.accent_soft')).borderRadius(8);
          Text(`${this.card.district || '附近'} · ${this.createdLabel(this.card.createdAt)}`).fontSize(12)
            .fontColor($r('app.color.muted')).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
      Button() {
        Image($r('app.media.ic_more')).width(24).height(24).objectFit(ImageFit.Contain)
          .accessibilityLevel('no');
      }
      .width(48).height(48).padding(12).backgroundColor($r('app.color.surface')).borderRadius(24)
      .accessibilityText('更多帖子操作')
      .onClick(() => {
        this.actionMenuVisible = !this.actionMenuVisible;
        if (!this.actionMenuVisible) this.reportOptionsVisible = false;
      });
    }.width('100%').padding({ left: 2, right: 2, top: 4, bottom: 4 });
  }

  @Builder
  private actionMenu() {
    Column({ space: 10 }) {
      Row() {
        Text('更多操作').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
        Blank();
        Button('关闭').height(44).fontSize(13).backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.muted')).border({ width: 1, color: $r('app.color.line') })
          .onClick(() => this.closeActionMenu());
      }.width('100%');
      Button('发送给食刻好友').width('100%').height(48).backgroundColor($r('app.color.accent_soft'))
        .fontColor($r('app.color.accent_action')).onClick((): void => {
          this.shareToFriend();
        });
      Button(this.knockShareEnabled ? '结束碰一碰分享' : '碰一碰分享').width('100%').height(48)
        .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
        .enabled(!this.knockShareBusy).accessibilityText(this.knockShareEnabled ? '结束碰一碰分享' : '开启碰一碰分享')
        .onClick((): void => {
          this.toggleKnockShare();
        });
      Button('系统分享').width('100%').height(48).backgroundColor($r('app.color.canvas'))
        .fontColor($r('app.color.ink')).onClick(() => this.shareCard());
      if (this.card.sourceLink.startsWith('https://')) {
        Button('打开来源页面').width('100%').height(48).backgroundColor($r('app.color.canvas'))
          .fontColor($r('app.color.ink')).onClick(() => this.openSource());
      }
      Button(this.reportOptionsVisible ? '收起举报选项' : '举报内容').width('100%').height(48)
        .backgroundColor($r('app.color.danger_soft')).fontColor($r('app.color.danger'))
        .onClick(() => this.reportOptionsVisible = !this.reportOptionsVisible);
      if (this.reportOptionsVisible) {
        Select([{ value: '信息不准确' }, { value: '图片侵权' }, { value: '不当内容' }, { value: '链接失效' }])
          .selected(this.reportReasonIndex).width('100%').onSelect((index: number, value: string) => {
            this.reportReasonIndex = index;
            this.reportReason = value;
          });
        Button('提交举报').width('100%').height(48).backgroundColor($r('app.color.danger_action'))
          .fontColor($r('app.color.on_danger_action')).onClick(() => this.report());
      }
      Button('取消').width('100%').height(48).backgroundColor($r('app.color.surface'))
        .fontColor($r('app.color.ink')).border({ width: 1, color: $r('app.color.line') })
        .onClick(() => this.closeActionMenu());
    }
    .width('100%').constraintSize({ maxWidth: 560 }).padding({ left: 20, right: 20, top: 18, bottom: 20 })
    .backgroundColor($r('app.color.surface')).borderRadius(24)
    .border({ width: 1, color: $r('app.color.line') });
  }

  @Builder
  private knockShareNotice(): void {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        Column() {}
          .width(4).height(40).backgroundColor($r('app.color.accent_action')).borderRadius(2)
          .accessibilityLevel('no');
        Column({ space: 3 }) {
          Text(this.knockShareBusy ? '正在发送商品卡' : '碰一碰已就绪')
            .fontSize(15).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink')).width('100%');
          Text(this.knockShareBusy ? '请保持两台设备靠近，等待系统完成传送。' : '保持本页打开，让两台设备顶部轻碰。')
            .fontSize(12).lineHeight(18).fontColor($r('app.color.muted')).width('100%');
        }.layoutWeight(1).alignItems(HorizontalAlign.Start);
        Button('结束').height(44).fontSize(13).backgroundColor($r('app.color.surface'))
          .fontColor($r('app.color.accent_action')).border({ width: 1, color: $r('app.color.line') })
          .accessibilityText('结束碰一碰分享').onClick((): void => {
            this.stopKnockShare('已结束碰一碰分享。');
          });
      }.width('100%').alignItems(VerticalAlign.Center);
      Text('若对方设备不支持或华为分享未开启，请改用“系统分享”。')
        .fontSize(11).lineHeight(17).fontColor($r('app.color.muted')).width('100%');
    }
    .width('100%').padding(14).backgroundColor($r('app.color.accent_soft')).borderRadius(16)
    .border({ width: 1, color: $r('app.color.line') }).alignItems(HorizontalAlign.Start)
    .accessibilityText('碰一碰分享已就绪；可随时点击结束。');
  }

  @Builder
  private commentDeleteSheet() {
    Column({ space: 12 }) {
      Text('删除这条评论？').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
      Text('删除后正文和删除占位都不会显示；已经存在的有效回复会继续保留。').fontSize(13).lineHeight(20)
        .fontColor($r('app.color.muted')).width('100%');
      Button(this.commentBusy ? '正在删除…' : '删除评论').width('100%').height(48).enabled(!this.commentBusy)
        .backgroundColor($r('app.color.danger_action')).fontColor($r('app.color.on_danger_action'))
        .onClick(() => this.deletePendingComment());
      Button('取消').width('100%').height(48).backgroundColor($r('app.color.surface'))
        .fontColor($r('app.color.ink')).border({ width: 1, color: $r('app.color.line') })
        .onClick(() => this.deletingCommentId = '');
    }
    .width('100%').constraintSize({ maxWidth: 560 }).padding({ left: 20, right: 20, top: 18, bottom: 20 })
    .backgroundColor($r('app.color.surface')).borderRadius(24)
    .border({ width: 1, color: $r('app.color.line') });
  }

  @Builder
  private photoCarousel() {
    if (this.detailPhotos.length > 0) {
      Swiper() {
        ForEach(this.detailPhotos, (photo: CardPhoto, index: number) => {
          if (photo.url.length > 0) {
            Image(photo.url).width('100%').height(this.imageHeight()).objectFit(ImageFit.Cover)
              .onComplete((event): void => {
                if (index === 0 && event !== undefined && event.loadingStatus === 1) {
                  this.finishPrimaryImage('decoded');
                }
              })
              .onError((): void => {
                if (index === 0) this.finishPrimaryImage('error');
              })
              .backgroundColor($r('app.color.surface')).borderRadius(20)
              .accessibilityText(`${this.card.productName}的发布者实拍图，轻点查看完整图片`)
              .accessibilityDescription('轻点查看完整图片；左右滑动可切换实拍图')
              .onClick(() => this.openPhotoPreview(index));
          } else {
            Column({ space: 6 }) {
              Text(this.mediaServiceUnavailable && this.photoFailures.includes(index)
                ? '实拍图服务暂时不可用' : this.photoFailures.includes(index)
                  ? '这张实拍图暂不可用' : '正在加载这张实拍图')
                .fontSize(15).fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.muted'));
              Text(this.photoFailures.includes(index) ? '点评与评论仍可阅读，点下方重试。' :
                '点评与评论已可阅读。').fontSize(12).fontColor($r('app.color.muted'));
              if (this.photoFailures.includes(index)) {
                Button('重试实拍图').height(44).fontSize(13)
                  .backgroundColor($r('app.color.surface')).fontColor($r('app.color.accent_action'))
                  .onClick((): void => this.retryPhoto(index));
              }
            }
            .width('100%').height(this.imageHeight()).justifyContent(FlexAlign.Center)
            .backgroundColor($r('app.color.accent_soft')).borderRadius(20);
          }
        }, (photo: CardPhoto): string => `${photo.id.length > 0 ? photo.id : photo.path}:${photo.url}`)
      }
      .width('100%').height(this.imageHeight()).index(this.photoIndex).indicator(this.detailPhotos.length > 1)
      .loop(false).onChange((index: number): void => {
        this.photoIndex = index;
        void this.hydratePhotoAt(index, 'high');
      });
      Text(`发布者实拍 ${this.photoIndex + 1} / ${this.detailPhotos.length} · 轻点图片查看完整图片`).fontSize(11)
        .fontColor($r('app.color.muted')).width('100%');
    } else {
      Column({ space: 6 }) {
        Text('暂无发布者实拍图').fontSize(15).fontWeight(FontWeight.Medium).fontColor($r('app.color.muted'));
        Text('卡片仍可查看点评、商品信息与来源。').fontSize(12).fontColor($r('app.color.muted'));
      }.width('100%').height(180).justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.accent_soft')).borderRadius(20);
    }
  }

  @Builder
  private photoPreview() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {}
        .width('100%').height('100%').backgroundColor($r('app.color.scrim'))
        .onClick(() => this.closePhotoPreview());
      Column({ space: 12 }) {
        Row() {
          Text('实拍图预览').fontSize(17).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_danger_action'));
          Blank();
          Button('关闭').width(72).height(48).fontSize(13).backgroundColor($r('app.color.surface'))
            .fontColor($r('app.color.ink')).borderRadius(24)
            .accessibilityText('关闭实拍图预览')
            .onClick(() => this.closePhotoPreview());
        }.width('100%');
        Swiper() {
          ForEach(this.detailPhotos, (photo: CardPhoto, index: number) => {
            if (photo.url.length > 0) {
              Image(photo.url).width('100%').height('100%').objectFit(ImageFit.Contain)
                .backgroundColor($r('app.color.canvas')).borderRadius(16)
                .accessibilityText(`${this.card.productName}的完整实拍图`);
            } else {
              Column({ space: 6 }) {
                Text(this.mediaServiceUnavailable && this.photoFailures.includes(index)
                  ? '实拍图服务暂时不可用' : this.photoFailures.includes(index)
                    ? '这张实拍图暂不可用' : '正在加载这张实拍图')
                  .fontSize(15).fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.on_danger_action'));
                Text('可左右切换查看其他图片，或重试当前图片。')
                  .fontSize(12).fontColor($r('app.color.on_danger_action'));
                if (this.photoFailures.includes(index)) {
                  Button('重试实拍图').height(44).fontSize(13)
                    .backgroundColor($r('app.color.surface')).fontColor($r('app.color.accent_action'))
                    .onClick((): void => this.retryPhoto(index));
                }
              }
              .width('100%').height('100%').justifyContent(FlexAlign.Center)
              .backgroundColor($r('app.color.canvas')).borderRadius(16);
            }
          }, (photo: CardPhoto): string => `${photo.id.length > 0 ? photo.id : photo.path}:${photo.url}`)
        }
        .width('100%').layoutWeight(1).index(this.previewPhotoIndex).indicator(this.detailPhotos.length > 1)
        .loop(false).onChange((index: number): void => {
          this.previewPhotoIndex = index;
          void this.hydratePhotoAt(index, 'high');
        });
        Text(`完整实拍 ${this.previewPhotoIndex + 1} / ${this.detailPhotos.length}`).fontSize(12)
          .fontColor($r('app.color.on_danger_action')).width('100%').textAlign(TextAlign.Center);
      }
      .width('100%').height('100%').padding({ left: 16, right: 16, top: 24, bottom: 28 });
    }
    .width('100%').height('100%')
    .accessibilityText(`实拍图预览，共 ${this.detailPhotos.length} 张`);
  }

  @Builder
  private cardActions() {
    Row({ space: 10 }) {
      Button(this.viewerLiked ? `已点赞 ${this.likeCount}` : `点赞 ${this.likeCount}`)
        .layoutWeight(1).height(48).enabled(!this.interactionBusy)
        .backgroundColor(this.viewerLiked ? $r('app.color.accent_soft') : $r('app.color.surface'))
        .fontColor(this.viewerLiked ? $r('app.color.accent_action') : $r('app.color.ink'))
        .border({ width: 1, color: $r('app.color.line') })
        .onClick(() => this.toggleCardAction('LIKE'));
      Button(this.viewerFavorited ? `已收藏 ${this.favoriteCount}` : `收藏 ${this.favoriteCount}`)
        .layoutWeight(1).height(48).enabled(!this.interactionBusy)
        .backgroundColor(this.viewerFavorited ? $r('app.color.accent_soft') : $r('app.color.surface'))
        .fontColor(this.viewerFavorited ? $r('app.color.accent_action') : $r('app.color.ink'))
        .border({ width: 1, color: $r('app.color.line') })
        .onClick(() => this.toggleCardAction('FAVORITE'));
    }.width('100%');
  }

  @Builder
  private reviewSection() {
    Column({ space: 8 }) {
      Row() {
        Text('发布者点评').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
        Blank();
        if (this.tasteScoreText().length > 0) {
          Text('口味 ' + this.tasteScoreText()).fontSize(12).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.accent_action')).padding({ left: 8, right: 8, top: 5, bottom: 5 })
            .backgroundColor($r('app.color.accent_soft')).borderRadius(10);
        }
      }.width('100%');
      Text(this.reviewText()).fontSize(16).lineHeight(26).fontColor($r('app.color.ink')).width('100%');
    }
    .width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(18)
    .border({ width: 1, color: $r('app.color.line') });
  }

  @Builder
  private infoRow(label: string, value: string) {
    Row({ space: 12 }) {
      Text(label).fontSize(13).fontColor($r('app.color.muted')).width(64);
      Text(value.length > 0 ? value : '待补充').fontSize(14).fontColor($r('app.color.ink'))
        .layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis });
    }.width('100%').alignItems(VerticalAlign.Top);
  }

  @Builder
  private productInfo() {
    Column({ space: 12 }) {
      Row() {
        Text('商品信息').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
        Blank();
        Text(categoryLabel(this.card.category)).fontSize(11).fontColor($r('app.color.leaf'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor($r('app.color.accent_soft')).borderRadius(8);
      }.width('100%');
      this.infoRow('商品名称', this.card.productName);
      this.infoRow('价格', this.priceText());
      if (this.card.sourceLink.startsWith('https://')) {
        this.infoRow('来源链接', '已提供，可从更多操作打开');
      }
      if (this.card.shop.trim().length > 0) {
        this.infoRow('店名-地址', this.card.shop);
      }
      if (this.card.specification.trim().length > 0) {
        this.infoRow('规格', this.card.specification);
      }
      if (this.card.publicOffers.length > 0) {
        this.infoRow('公开优惠', this.card.publicOffers.join('；'));
      }
    }
    .width('100%').padding(16).backgroundColor($r('app.color.surface')).borderRadius(18)
    .border({ width: 1, color: $r('app.color.line') });
  }

  @Builder
  private commentAvatar(comment: CardComment) {
    if (comment.authorAvatarUrl.length > 0) {
      Image(comment.authorAvatarUrl).width(32).height(32).borderRadius(16).objectFit(ImageFit.Cover)
        .accessibilityText(`${comment.authorNickname}的头像`);
    } else {
      Image($r('app.media.app_icon')).width(32).height(32).borderRadius(12)
        .accessibilityText('食刻默认头像');
    }
  }

  @Builder
  private commentReactionButton(comment: CardComment, reaction: CommentReactionType) {
    Button(`${this.reactionName(reaction)} ${this.reactionCount(comment, reaction)}`)
    .height(36).padding({ left: 10, right: 10 })
    .backgroundColor(comment.viewerReaction === reaction ? $r('app.color.accent_soft') : $r('app.color.canvas')).borderRadius(18)
    .border({ width: 1, color: comment.viewerReaction === reaction ? $r('app.color.accent_action') : $r('app.color.line') })
    .fontSize(12)
    .fontColor(comment.viewerReaction === reaction
      ? (reaction === 'LIKE' ? $r('app.color.accent_action') : $r('app.color.danger'))
      : $r('app.color.muted'))
    .enabled(!this.commentBusy)
    .accessibilityText(`${this.reactionName(reaction)}，${this.reactionCount(comment, reaction)} 次${comment.viewerReaction === reaction ? '，已选中' : ''}`)
    .onClick(() => this.toggleCommentReaction(comment, reaction));
  }

  @Builder
  private commentActions(comment: CardComment) {
    if (!comment.deleted && !comment.viewerIsAuthor) {
      Row({ space: 4 }) {
        Blank().layoutWeight(1);
        this.commentReactionButton(comment, 'LIKE');
        this.commentReactionButton(comment, 'DISLIKE');
      }.width('100%');
    }
  }

  @Builder
  private commentBody(comment: CardComment) {
    Column({ space: 6 }) {
      if (comment.replyToNickname.length > 0) {
        Text(`回复 @${comment.replyToNickname}`).fontSize(12).fontColor($r('app.color.leaf')).width('100%');
      }
      Text(comment.content).fontSize(13).lineHeight(20).fontColor($r('app.color.ink')).width('100%');
    }
    .width('100%').padding({ top: 2, bottom: 2 });
  }

  private commentTapDescription(comment: CardComment): string {
    return comment.viewerIsAuthor ? '这是你的评论；长按可删除' : '点击回复这条评论';
  }

  @Builder
  private commentReplyTarget(comment: CardComment, nested: boolean) {
    Button() {
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          this.commentAvatar(comment);
          Column({ space: 2 }) {
            Text(comment.authorNickname).fontSize(13).fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.ink')).width('100%').maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
            Text(this.createdLabel(comment.createdAt)).fontSize(11).fontColor($r('app.color.muted'));
          }.layoutWeight(1).alignItems(HorizontalAlign.Start);
        }.width('100%');
        this.commentBody(comment);
        if (this.replyToCommentId === comment.id) {
          Text(`正在回复 @${comment.authorNickname}`).fontSize(12).fontColor($r('app.color.leaf')).width('100%');
        }
      }
      .width('100%').alignItems(HorizontalAlign.Start);
    }
    .width('100%').padding(0).backgroundColor(nested ? $r('app.color.canvas') : $r('app.color.surface'))
    .borderRadius(nested ? 12 : 14)
    .accessibilityText(`评论：${comment.authorNickname}，${comment.content}`)
    .accessibilityDescription(this.commentTapDescription(comment))
    .onAppear((): void => { void this.hydrateCommentAvatar(comment, this.detailGeneration); })
    .onClick(() => this.replyTo(comment))
    .gesture(
      LongPressGesture({ fingers: 1, repeat: false, duration: 500 })
        .onAction(() => this.requestDeleteComment(comment))
    );
  }

  @Builder
  private replyItem(comment: CardComment) {
    Column({ space: 6 }) {
      this.commentReplyTarget(comment, true);
      this.commentActions(comment);
    }
    .width('100%').padding(8).backgroundColor($r('app.color.canvas')).borderRadius(12);
  }

  @Builder
  private commentItem(comment: CardComment, nested: boolean) {
    Column({ space: 6 }) {
      this.commentReplyTarget(comment, nested);
      this.commentActions(comment);
      if (!nested && comment.replies.length > 0) {
        Column({ space: 8 }) {
          ForEach(this.visibleReplies(comment), (reply: CardComment) => {
            this.replyItem(reply);
          }, (reply: CardComment): string => `${reply.id}:${reply.authorAvatarUrl}`)
          if (comment.replies.length > 2) {
            Button(this.repliesExpanded(comment.id)
              ? '收起回复'
              : `展开其余 ${comment.replies.length - 2} 条回复`)
              .width('100%').height(44).fontSize(12)
              .backgroundColor($r('app.color.surface')).fontColor($r('app.color.accent_action'))
              .border({ width: 1, color: $r('app.color.line') }).borderRadius(14)
              .onClick((): void => {
                this.toggleReplies(comment.id);
              });
          }
        }
        .width('100%').padding({ left: 8, right: 0, top: 8, bottom: 0 })
        .border({ width: 1, color: $r('app.color.line') });
      }
    }
    .width('100%').padding(nested ? 0 : 10).backgroundColor(nested ? $r('app.color.canvas') : $r('app.color.surface'))
    .borderRadius(nested ? 0 : 16);
  }

  @Builder
  private commentComposer() {
    TextArea({ text: this.commentInput, placeholder: this.replyToNickname.length > 0
      ? `回复 @${this.replyToNickname}` : '写下你的评论' })
      .width('100%').height(68).backgroundColor($r('app.color.canvas')).borderRadius(14)
      .onChange((value: string) => this.commentInput = value);
    Button(this.commentBusy ? '正在发布…' : '发布评论').width('100%').height(44).enabled(!this.commentBusy)
      .backgroundColor($r('app.color.accent')).onClick(() => this.publishComment());
  }

  @Builder
  private commentsSection() {
    Column({ space: 8 }) {
      Row() {
        Text('评论').fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
        Blank();
        Text(`${this.commentCount} 条讨论`).fontSize(13).fontColor($r('app.color.muted'));
      }.width('100%');
      if (this.replyToCommentId.length > 0) {
        Row({ space: 8 }) {
          Text(`正在回复 @${this.replyToNickname}`).fontSize(12).fontColor($r('app.color.leaf')).layoutWeight(1);
          Button('取消回复').height(36).fontSize(12).backgroundColor($r('app.color.surface'))
            .fontColor($r('app.color.ink')).border({ width: 1, color: $r('app.color.line') })
            .onClick(() => this.clearReply());
        }.width('100%').padding(10).backgroundColor($r('app.color.accent_soft')).borderRadius(12);
        this.commentComposer();
      }
      if (this.comments.length === 0) {
        Text('还没有评论，等第一位朋友分享看法。').fontSize(14).fontColor($r('app.color.muted'))
          .width('100%').padding({ top: 8, bottom: 4 });
      } else {
        ForEach(this.visibleComments(), (comment: CardComment) => {
          this.commentItem(comment, false);
        }, (comment: CardComment): string => `${comment.id}:${comment.authorAvatarUrl}`);
        if (this.comments.length > 3) {
          Button(this.visibleCommentCount >= this.comments.length ? '收起评论' :
            `再看 ${Math.min(8, this.comments.length - this.visibleCommentCount)} 条评论`)
            .width('100%').height(48).fontSize(13).fontWeight(FontWeight.Medium)
            .backgroundColor($r('app.color.canvas')).fontColor($r('app.color.accent_action'))
            .border({ width: 1, color: $r('app.color.line') }).borderRadius(15)
            .accessibilityText(this.visibleCommentCount >= this.comments.length ? '收起评论列表' : '加载更多评论')
            .onClick((): void => {
              this.visibleCommentCount = this.visibleCommentCount >= this.comments.length ? 3 :
                Math.min(this.comments.length, this.visibleCommentCount + 8);
            });
        }
      }
      if (this.replyToCommentId.length === 0) {
        this.commentComposer();
      }
    }
    .width('100%').padding(12).backgroundColor($r('app.color.surface')).borderRadius(16)
    .border({ width: 1, color: $r('app.color.line') });
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
        Scroll() {
          Column({ space: 18 }) {
            this.authorHeader();
            // Keep one media/composer subtree while resizing, preserving photo
            // index, pending comments and the existing async loading generation.
            Flex({ direction: this.isWideDetail() ? FlexDirection.Row : FlexDirection.Column,
              alignItems: ItemAlign.Start }) {
              Column({ space: 18 }) {
                this.photoCarousel();
                this.cardActions();
                if (this.knockShareEnabled) {
                  this.knockShareNotice();
                }
              }
              .width(this.detailColumnWidth()).flexShrink(0).alignItems(HorizontalAlign.Start)
              .margin({ right: this.isWideDetail() ? 24 : 0, bottom: this.isWideDetail() ? 0 : 18 });
              Column({ space: 18 }) {
                this.reviewSection();
                this.productInfo();
                this.commentsSection();
                if (this.status.length > 0) {
                  Text(this.status).fontSize(12).lineHeight(19).fontColor($r('app.color.muted')).width('100%')
                    .padding(12).backgroundColor($r('app.color.accent_soft')).borderRadius(14);
                }
              }.width(this.detailColumnWidth()).flexShrink(0).alignItems(HorizontalAlign.Start);
            }
            .width('100%');
          }
          .width('100%').padding({ left: this.detailPadding(), right: this.detailPadding(), top: 14, bottom: 28 })
          .alignItems(HorizontalAlign.Start);
        }
        .width('100%').height('100%').backgroundColor($r('app.color.canvas'));
        if (this.photoPreviewVisible) {
          this.photoPreview();
        } else if (this.actionMenuVisible || this.deletingCommentId.length > 0) {
          Column() {}
            .width('100%').height('100%').backgroundColor($r('app.color.scrim'))
            .onClick(() => this.dismissOverlay());
          if (this.actionMenuVisible) {
            this.actionMenu();
          } else {
            this.commentDeleteSheet();
          }
        }
      }
      .width('100%').height('100%').backgroundColor($r('app.color.canvas'))
      .onAreaChange((_oldArea: Area, newArea: Area): void => {
        const width: number = Number(newArea.width);
        if (Number.isFinite(width) && width > 0 && this.detailWidthVp !== width) {
          this.detailWidthVp = width;
        }
      });
    }.title('卡片详情')
      .onShown((): void => {
        this.knockSharePageVisible = true;
      })
      .onHidden((): void => {
        this.knockSharePageVisible = false;
        this.stopKnockShare(this.knockShareEnabled ? '已离开详情前台，碰一碰分享已结束。' : '');
      });
  }
}
