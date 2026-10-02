import { common } from '@kit.AbilityKit';
import { FoodCard, FoodCategory, RoundedLocation, UserProfile } from '../model/CloudContracts';
import { CardRepository } from '../repository/CardRepository';
import { NearbyPreloadService, NearbySnapshot } from '../service/NearbyPreloadService';
import { FriendRankingPreloadService } from '../service/FriendRankingPreloadService';
import { AuthService } from '../service/AuthService';
import { categoryLabel, coverFor } from '../components/FoodCover';
import { tasteScoreLabel } from '../model/TasteScore';
import { ErrorDetail, errorText } from '../common/ErrorKit';

interface CategoryOption {
  value: string;
  label: string;
}

type RankingBoard = 'nearby' | 'friends';

const RANKING_CATEGORIES: Array<CategoryOption> = [
  { value: 'all', label: '全部' },
  { value: 'staple', label: '米饭' },
  { value: 'bakery', label: '汤粉' },
  { value: 'snack', label: '炸鸡' },
  { value: 'fresh', label: '烧烤' },
  { value: 'drink', label: '饮品' },
  { value: 'other', label: '其他' }
];

@Component
export struct RankingPage {
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @Prop @Watch('onRevisionChanged') revision: number = 0;
  @State nearbyCards: Array<FoodCard> = [];
  @State friendCards: Array<FoodCard> = [];
  @State district: string = '等待定位';
  @State nearbyStatus: string = '将展示 20 km 内附有实拍图的公开推荐。';
  @State friendStatus: string = '只看自己和已通过好友发布的实拍卡片。';
  @State selectedCategory: string = 'all';
  @State selectedBoard: RankingBoard = 'nearby';
  @State nearbyLoading: boolean = false;
  @State friendLoading: boolean = false;
  @State friendLoaded: boolean = false;
  private repository: CardRepository = new CardRepository();
  private nearbyRefreshQueued: boolean = false;
  private friendRefreshQueued: boolean = false;
  private nearbyQueuedForceRefresh: boolean = false;
  private friendQueuedForceRefresh: boolean = false;
  private hydratingCardIds: Set<string> = new Set<string>();

  aboutToAppear(): void {
    const profile: UserProfile | undefined = AuthService.profile();
    if (profile !== undefined) {
      const revision: number = AppStorage.get<number>('friendRelationshipRevision') || 0;
      const cached: Array<FoodCard> | undefined = FriendRankingPreloadService.cached(profile.uid, revision);
      if (cached !== undefined) {
        this.friendCards = cached.filter((card: FoodCard): boolean =>
          card.status === 'APPROVED' && card.photoPath.length > 0);
        this.friendLoaded = true;
        this.friendStatus = `已汇总 ${this.friendCards.length} 条自己或好友的实拍推荐。`;
      } else {
        this.friendLoaded = false;
      }
    }
    if (this.selectedBoard === 'nearby') this.refreshNearby();
    else this.refreshFriendRankings();
  }

  private onRevisionChanged(): void {
    if (this.revision > 0) {
      this.friendLoaded = false;
      this.friendCards = [];
      this.refreshSelected(true);
    }
  }

  private topCovers(cards: Array<FoodCard>): Array<FoodCard> {
    return cards.slice().sort((first: FoodCard, second: FoodCard): number => {
      const scoreDifference: number = this.scoreOf(second) - this.scoreOf(first);
      return scoreDifference !== 0 ? scoreDifference : second.createdAt - first.createdAt;
    }).slice(0, 4);
  }

  private async hydrateRankingCovers(cards: Array<FoodCard>, board: RankingBoard): Promise<void> {
    const pending: Array<FoodCard> = cards.filter((card: FoodCard): boolean =>
      card.primaryPhotoResolved !== true && !this.hydratingCardIds.has(`${board}:${card.id}`));
    if (pending.length === 0) return;
    pending.forEach((card: FoodCard): void => { this.hydratingCardIds.add(`${board}:${card.id}`); });
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.repository.hydrateNearbyPrimaryPhotoUrls(context, pending, 0, pending.length, 'low');
      if (board === 'nearby') this.nearbyCards = this.nearbyCards.slice();
      else this.friendCards = this.friendCards.slice();
    } catch (_error) {
      // Text rows remain usable when a preview cannot be fetched.
    } finally {
      pending.forEach((card: FoodCard): void => { this.hydratingCardIds.delete(`${board}:${card.id}`); });
    }
  }

  private hydrateVisibleRanking(first: number, last: number): void {
    const cards: Array<FoodCard> = this.rankedCards().slice(Math.max(0, first), Math.max(first, last) + 3);
    void this.hydrateRankingCovers(cards, this.selectedBoard);
  }

  private scoreOf(card: FoodCard): number {
    const score = typeof card.tasteScore === 'number' ? card.tasteScore : 0;
    return Number.isInteger(score) && score >= 1 && score <= 10 ? score : 0;
  }

  private tasteScoreText(card: FoodCard): string {
    const score = this.scoreOf(card);
    return score > 0 ? `${score}/10 · ${tasteScoreLabel(score)}` : '暂未评分';
  }

  private reviewPreview(card: FoodCard): string {
    const reviewText = typeof card.reviewText === 'string' ? card.reviewText.trim() : '';
    if (reviewText.length > 0) return reviewText;
    const points = Array.isArray(card.sellingPoints) ? card.sellingPoints : [];
    return points.length > 0 ? points.join('；') : '发布者暂未写点评。';
  }

  private shopText(card: FoodCard): string {
    const shop = typeof card.shop === 'string' ? card.shop.trim() : '';
    return shop;
  }

  private categoryAndShopText(card: FoodCard): string {
    const shop = this.shopText(card);
    return shop.length > 0 ? `${categoryLabel(card.category)} · ${shop}` : categoryLabel(card.category);
  }

  private distanceText(card: FoodCard): string {
    const distance = typeof card.distanceKm === 'number' ? card.distanceKm : 0;
    return Number.isFinite(distance) && distance > 0 ? `${distance.toFixed(1)} km 内` : '附近实拍';
  }

  private publisherText(card: FoodCard): string {
    if (card.viewerIsOwner === true) return '我发布的';
    const nickname = typeof card.authorNickname === 'string' ? card.authorNickname.trim() : '';
    return nickname.length > 0 ? `好友 · ${nickname}` : '好友推荐';
  }

  private activeStatus(): string {
    return this.selectedBoard === 'nearby' ? this.nearbyStatus : this.friendStatus;
  }

  private isLoading(): boolean {
    return this.selectedBoard === 'nearby' ? this.nearbyLoading : this.friendLoading;
  }

  private rankedCards(): Array<FoodCard> {
    const source = this.selectedBoard === 'nearby' ? this.nearbyCards : this.friendCards;
    const filtered = this.selectedBoard === 'nearby' && this.selectedCategory !== 'all'
      ? source.filter((card: FoodCard): boolean => card.category === (this.selectedCategory as FoodCategory))
      : source.slice();
    filtered.sort((first: FoodCard, second: FoodCard): number => {
      const scoreDifference = this.scoreOf(second) - this.scoreOf(first);
      return scoreDifference !== 0 ? scoreDifference : second.createdAt - first.createdAt;
    });
    return filtered;
  }

  private rankText(rank: number): string {
    return rank < 10 ? `0${rank}` : rank.toString();
  }

  private rankBadgeBackground(rank: number): Resource {
    return rank === 1 ? $r('app.color.accent_action') : $r('app.color.accent_soft');
  }

  private rankBadgeTextColor(rank: number): Resource {
    return rank === 1 ? $r('app.color.on_accent_action') : $r('app.color.accent_action');
  }

  private boardName(): string {
    return this.selectedBoard === 'nearby' ? '附近口碑榜' : '好友推荐榜';
  }

  private boardSubtitle(): string {
    return this.selectedBoard === 'nearby'
      ? `${this.district} · 20 km 内实拍分享`
      : '只看自己和好友发布的卡片';
  }

  private boardRule(): string {
    return this.selectedBoard === 'nearby'
      ? '按分类查看附近实拍推荐；评分高优先，同分时较新的发布优先。'
      : '不区分标签，只收录自己和已通过好友发布的实拍推荐；评分高优先。';
  }

  private emptyTitle(): string {
    if (this.isLoading()) return '正在准备榜单';
    return this.selectedBoard === 'nearby' ? '附近还没有上榜推荐' : '还没有好友推荐';
  }

  private emptyDescription(): string {
    if (this.isLoading()) {
      return this.selectedBoard === 'nearby' ? '正在读取一次定位并加载实拍评分。' : '正在汇总你和好友的实拍推荐。';
    }
    return this.selectedBoard === 'nearby'
      ? '榜单只收录 20 km 内、已公开且附有实拍图的推荐。'
      : '添加好友，或先发布一张带实拍图的美食卡片，让这份榜单热闹起来。';
  }

  private accessibilitySummary(card: FoodCard, rank: number): string {
    const source = this.selectedBoard === 'nearby' ? this.distanceText(card) : this.publisherText(card);
    return `${this.boardName()}第 ${rank} 名，${card.productName}，${this.tasteScoreText(card)}，${source}`;
  }

  private async refreshNearby(forceRefresh: boolean = false): Promise<void> {
    if (this.nearbyLoading) {
      this.nearbyRefreshQueued = true;
      this.nearbyQueuedForceRefresh = this.nearbyQueuedForceRefresh || forceRefresh;
      return;
    }
    this.nearbyLoading = true;
    this.nearbyStatus = '正在获取一次精确位置与附近评分…';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const snapshot: NearbySnapshot = await NearbyPreloadService.load(context, forceRefresh);
      const location: RoundedLocation = snapshot.location;
      this.district = location.district;
      const response = snapshot.response;
      this.nearbyCards = response.cards.filter((card: FoodCard): boolean =>
        card.status === 'APPROVED' && card.distanceKm <= 20.0 && card.photoPath.length > 0);
      this.district = response.district || location.district;
      this.nearbyStatus = this.nearbyCards.length === 0
        ? '附近还没有附实拍图的推荐。'
        : `已找到 ${this.nearbyCards.length} 条实拍推荐，按口味评分排序。`;
      void this.hydrateRankingCovers(this.topCovers(this.nearbyCards), 'nearby');
    } catch (error) {
      this.nearbyCards = [];
      this.nearbyStatus = `附近榜单加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.nearbyLoading = false;
      if (this.nearbyRefreshQueued) {
        const queuedForceRefresh: boolean = this.nearbyQueuedForceRefresh;
        this.nearbyRefreshQueued = false;
        this.nearbyQueuedForceRefresh = false;
        this.refreshNearby(queuedForceRefresh);
      }
    }
  }

  private async refreshFriendRankings(forceRefresh: boolean = false): Promise<void> {
    if (this.friendLoading) {
      this.friendRefreshQueued = true;
      this.friendQueuedForceRefresh = this.friendQueuedForceRefresh || forceRefresh;
      return;
    }
    this.friendLoading = true;
    this.friendStatus = '正在汇总自己和好友发布的实拍推荐…';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const profile: UserProfile | undefined = AuthService.profile();
      if (profile === undefined) throw new Error('登录状态已失效，请重新登录。');
      const revision: number = AppStorage.get<number>('friendRelationshipRevision') || 0;
      const cards: Array<FoodCard> = await FriendRankingPreloadService.load(context, profile.uid, revision,
        forceRefresh);
      this.friendCards = cards.filter((card: FoodCard): boolean =>
        card.status === 'APPROVED' && card.photoPath.length > 0);
      this.friendLoaded = true;
      this.friendStatus = this.friendCards.length === 0
        ? '你和已通过好友暂时还没有可上榜的实拍推荐。'
        : `已汇总 ${this.friendCards.length} 条自己或好友的实拍推荐，按口味评分排序。`;
      void this.hydrateRankingCovers(this.topCovers(this.friendCards), 'friends');
    } catch (error) {
      this.friendCards = [];
      this.friendLoaded = false;
      this.friendStatus = `好友榜加载失败：${errorText(error as ErrorDetail)}`;
    } finally {
      this.friendLoading = false;
      if (this.friendRefreshQueued) {
        const queuedForceRefresh: boolean = this.friendQueuedForceRefresh;
        this.friendRefreshQueued = false;
        this.friendQueuedForceRefresh = false;
        this.refreshFriendRankings(queuedForceRefresh);
      }
    }
  }

  private refreshSelected(forceRefresh: boolean = false): void {
    if (this.selectedBoard === 'nearby') this.refreshNearby(forceRefresh);
    else this.refreshFriendRankings(forceRefresh);
  }

  private selectBoard(board: RankingBoard): void {
    if (this.selectedBoard === board) return;
    this.selectedBoard = board;
    const profile: UserProfile | undefined = AuthService.profile();
    const revision: number = AppStorage.get<number>('friendRelationshipRevision') || 0;
    const cacheValid: boolean = profile !== undefined &&
      FriendRankingPreloadService.cached(profile.uid, revision) !== undefined;
    if (board === 'friends' && (!this.friendLoaded || !cacheValid)) this.refreshFriendRankings();
    else void this.hydrateRankingCovers(this.rankedCards().slice(0, 4), board);
  }

  private isCategorySelected(option: CategoryOption): boolean {
    return this.selectedCategory === option.value;
  }

  private isBoardSelected(board: RankingBoard): boolean {
    return this.selectedBoard === board;
  }

  private isCardOwner(card: FoodCard): boolean {
    return card.viewerIsOwner === true;
  }

  @Builder
  private boardTab(board: RankingBoard, label: string): void {
    Button(label)
      .height(48).layoutWeight(1).fontSize(14).fontWeight(FontWeight.Bold)
      .backgroundColor(this.isBoardSelected(board) ? $r('app.color.accent_action') : $r('app.color.surface'))
      .fontColor(this.isBoardSelected(board) ? $r('app.color.on_accent_action') : $r('app.color.ink'))
      .border({ width: this.isBoardSelected(board) ? 0 : 1, color: $r('app.color.line') })
      .borderRadius(16)
      .accessibilityText(`${label}${this.isBoardSelected(board) ? '，已选中' : ''}`)
      .onClick((): void => {
        this.selectBoard(board);
      });
  }

  @Builder
  private categoryChip(option: CategoryOption): void {
    Button(option.label)
      .height(44).padding({ left: 16, right: 16 })
      .backgroundColor(this.isCategorySelected(option) ? $r('app.color.accent_action') : $r('app.color.surface'))
      .fontColor(this.isCategorySelected(option) ? $r('app.color.on_accent_action') : $r('app.color.ink'))
      .fontSize(14).fontWeight(FontWeight.Medium)
      .border({ width: this.isCategorySelected(option) ? 0 : 1, color: $r('app.color.line') })
      .borderRadius(22)
      .accessibilityText(`${option.label}分类${this.isCategorySelected(option) ? '，已选中' : ''}`)
      .onClick((): void => {
        this.selectedCategory = option.value;
      });
  }

  @Builder
  private rankBadge(rank: number): void {
    Column({ space: 4 }) {
      Text(rank === 1 ? '本周推荐' : '口碑排名').fontSize(10).fontWeight(FontWeight.Medium)
        .fontColor(this.rankBadgeTextColor(rank)).accessibilityLevel('no');
      Text(this.rankText(rank)).fontSize(27).fontWeight(FontWeight.Bold)
        .fontColor(this.rankBadgeTextColor(rank)).accessibilityLevel('no');
    }
    .width(64).height(102).justifyContent(FlexAlign.Center)
    .backgroundColor(this.rankBadgeBackground(rank)).borderRadius(18)
    .accessibilityLevel('no');
  }

  @Builder
  private sourcePill(card: FoodCard): void {
    Text(this.selectedBoard === 'friends' ? this.publisherText(card) : this.distanceText(card))
      .fontSize(11).fontWeight(FontWeight.Medium)
      .fontColor(this.isCardOwner(card) ? $r('app.color.accent_action') : $r('app.color.leaf'))
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .backgroundColor($r('app.color.accent_soft')).borderRadius(10)
      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis });
  }

  @Builder
  private rankedCard(card: FoodCard, rank: number): void {
    Row({ space: 12 }) {
      this.rankBadge(rank);
      Image(card.photoUrl.length > 0 ? card.photoUrl : coverFor(card.category))
        .width(92).height(102).objectFit(ImageFit.Cover).borderRadius(16)
        .accessibilityLevel('no');
      Column({ space: 7 }) {
        Row({ space: 8 }) {
          Text(card.productName).fontSize(17).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.ink')).layoutWeight(1).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          Text(this.scoreOf(card).toString()).fontSize(24).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.accent_action')).maxLines(1);
          Text('/10').fontSize(11).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.muted')).maxLines(1);
        }.width('100%').alignItems(VerticalAlign.Center);

        this.sourcePill(card);

        Text(this.categoryAndShopText(card)).fontSize(12)
          .fontColor($r('app.color.muted')).width('100%').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });

        Text(this.reviewPreview(card)).fontSize(13).lineHeight(19)
          .fontColor($r('app.color.ink')).width('100%').maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
      }.layoutWeight(1).alignItems(HorizontalAlign.Start);
    }
    .width('100%').padding(12).backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.line') }).borderRadius(20)
    .clickEffect({ level: ClickEffectLevel.MIDDLE, scale: 0.98 })
    .accessibilityGroup(true).accessibilityRole(AccessibilityRoleType.BUTTON)
    .accessibilityText(this.accessibilitySummary(card, rank))
    .accessibilityDescription('轻点查看实拍卡详情')
    .onClick((): void => {
      this.onOpenCard(card);
    });
  }

  @Builder
  private emptyState(): void {
    Column({ space: 12 }) {
      Text(this.emptyTitle()).fontSize(19).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
      Text(this.emptyDescription()).fontSize(13).lineHeight(20).fontColor($r('app.color.muted'))
        .textAlign(TextAlign.Center).width('82%');
      Button(this.isLoading() ? '正在更新' : '刷新榜单').height(48).enabled(!this.isLoading())
        .backgroundColor($r('app.color.accent_action')).fontColor($r('app.color.on_accent_action'))
        .borderRadius(15).onClick((): void => {
          this.refreshSelected(true);
        });
    }
    .width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).padding(24)
    .backgroundColor($r('app.color.surface')).borderRadius(20)
    .border({ width: 1, color: $r('app.color.line') });
  }

  build() {
    Column({ space: 14 }) {
      Row() {
        Column({ space: 4 }) {
          Text('口碑榜').fontSize(26).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
          Text(this.boardSubtitle()).fontSize(13).fontColor($r('app.color.leaf'));
        }.alignItems(HorizontalAlign.Start);
        Blank();
        Button(this.isLoading() ? '更新中' : '刷新').enabled(!this.isLoading()).height(44).fontSize(14)
          .backgroundColor($r('app.color.accent_soft')).fontColor($r('app.color.accent_action'))
          .borderRadius(14)
          .accessibilityText(this.isLoading() ? '榜单正在更新' : `刷新${this.boardName()}`)
          .onClick((): void => {
            this.refreshSelected(true);
          });
      }.width('100%');

      Row({ space: 8 }) {
        this.boardTab('nearby', '附近口碑榜');
        this.boardTab('friends', '好友推荐榜');
      }.width('100%');

      Text(this.boardRule()).fontSize(12).lineHeight(19).fontColor($r('app.color.ink')).width('100%')
        .padding(12).backgroundColor($r('app.color.accent_soft')).borderRadius(14);

      if (this.selectedBoard === 'nearby') {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(RANKING_CATEGORIES, (option: CategoryOption): void => {
              this.categoryChip(option);
            }, (option: CategoryOption): string => option.value);
          }.padding({ right: 4 });
        }.width('100%').height(44).scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off);
      }

      Text(this.activeStatus()).fontSize(12).fontColor($r('app.color.muted')).width('100%').maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });

      if (this.rankedCards().length === 0) {
        this.emptyState();
      } else {
        List({ space: 10 }) {
          ForEach(this.rankedCards(), (card: FoodCard, index: number): void => {
            ListItem() {
              this.rankedCard(card, index + 1);
            }
          }, (card: FoodCard): string => `${card.id}:${card.photoUrl}`);
        }
        .width('100%').layoutWeight(1).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
        .onScrollIndex((start: number, end: number, _center: number): void =>
          this.hydrateVisibleRanking(start, end));
      }
    }
    .width('100%').height('100%').padding({ left: 16, right: 16, top: 18, bottom: 6 })
    .backgroundColor($r('app.color.canvas')).alignItems(HorizontalAlign.Start);
  }
}
