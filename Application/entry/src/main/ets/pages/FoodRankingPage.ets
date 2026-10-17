/**
 * 【文件职责】“榜单”页签：高分榜 / 好友榜两个标签，分页读取（list-food-rankings），可见窗口懒加载封面；
 * 服务端快照生成中时显示“准备中”，并在页签切换时复用最近的数据（FoodRankingSnapshot）。
 */
import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import { FoodRankingItem, FoodRankingKind, FoodRankingRequest, FoodRankingResponse,
  FoodRankingSnapshot } from '../model/FoodRankingModels';
import { FoodRankingRepository } from '../repository/FoodRankingRepository';
import { CardRepository } from '../repository/CardRepository';
import { AuthService } from '../service/AuthService';
import { AuthSessionStore } from '../service/AuthSessionStore';
import { PersonalPreviewLoader, PersonalPreviewRow, PersonalPreviewSource } from '../service/PersonalPreviewLoader';
import { CloudBusinessError, ReadCancelledError } from '../service/CloudReadErrors';
import { ReadRequestOptions, ReadScheduler } from '../service/ReadScheduler';
import { FoodRankingTile } from '../components/FoodRankingTile';
import { stage47ErrorText } from '../common/Stage47Ui';

const RESULT_REUSE_MS: number = 5 * 60 * 1000;

// 榜单页面。
@Component
export struct FoodRankingPage {
  @Prop @Watch('onActiveChanged') pageActive: boolean = true;
  @Prop @Watch('onRevisionChanged') revision: number = 0;
  @StorageLink('accountContentRevision') @Watch('onRevisionChanged') accountContentRevision: number = 0;
  @StorageLink('authSessionRevision') @Watch('onRevisionChanged') authSessionRevision: number = 0;
  @StorageLink('friendRelationshipRevision') @Watch('onRevisionChanged') relationshipRevision: number = 0;
  @StorageLink('stage47AppActive') @Watch('onAppActiveChanged') appActive: boolean = true;
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  onRequireLogin: () => void = (): void => {};
  @State kind: FoodRankingKind = 'HIGH_SCORE';
  @State items: Array<FoodRankingItem> = [];
  @State count: number = 0;
  @State totalCount: number = 0;
  @State cursor: string = '';
  @State updatedAt: number = 0;
  @State busy: boolean = false;
  @State opening: boolean = false;
  @State loginRequired: boolean = false;
  @State message: string = '';
  @State failed: boolean = false;
  @State pageWidth: number = 390;
  @State largeText: boolean = false;
  @State emptyHeight: number = 0;
  private readonly skeletonRows: Array<number> = [0, 1, 2, 3];
  private readonly headerBackgroundOptions: BackgroundOptions = {
    align: Alignment.Top, ignoresLayoutSafeAreaEdges: []
  };
  private readonly canvasBackgroundOptions: BackgroundOptions = {
    ignoresLayoutSafeAreaEdges: [LayoutSafeAreaEdge.BOTTOM]
  };
  private active: boolean = false;
  private visibleLifecycle: boolean = true;
  private generation: number = 0;
  private owner: string = '';
  private session: number = 0;
  private firstVisible: number = 0;
  private lastVisible: number = 5;
  private snapshots: Map<FoodRankingKind, FoodRankingSnapshot> = new Map<FoodRankingKind, FoodRankingSnapshot>();
  private source: PersonalPreviewSource = new PersonalPreviewSource();
  private previews: PersonalPreviewLoader = new PersonalPreviewLoader(this.source, true);
  private repository: FoodRankingRepository = new FoodRankingRepository();
  private cards: CardRepository = new CardRepository();
  // 取得 UIAbility 上下文。
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  // 异步结果是否仍有效。
  private valid(generation: number): boolean {
    return this.active && this.pageActive && this.appActive && generation === this.generation &&
      this.owner === (AuthService.profile()?.uid || '') && this.session === AuthSessionStore.generation();
  }
  // 页面激活状态变化。
  private onActiveChanged(): void { if (this.pageActive && this.appActive && this.visibleLifecycle) this.resume(); else this.pause(); }
  // App 前后台切换。
  private onAppActiveChanged(): void { if (this.appActive && this.pageActive && this.visibleLifecycle) this.resume(); else this.pause(); }
  // 页面可见性变化。
  private onVisibleChanged(visible: boolean): void {
    if (visible === this.visibleLifecycle) return;
    this.visibleLifecycle = visible; if (visible) this.onActiveChanged(); else this.pause();
  }
  // 账号内容变化时清空并重新加载。
  private onRevisionChanged(): void {
    this.snapshots.clear(); this.generation++; this.busy = false; this.opening = false;
    this.owner = AuthService.profile()?.uid || ''; this.session = AuthSessionStore.generation();
    this.clearRows();
    if (this.active) void this.load();
  }
  // 出现时恢复。
  aboutToAppear(): void { this.resume(); }
  // 消失时暂停。
  aboutToDisappear(): void { this.pause(); }
  // 恢复：复用缓存或加载第一页。
  private resume(): void {
    if (this.active || !this.pageActive || !this.appActive || !this.visibleLifecycle) return;
    this.updateTextScale();
    const owner: string = AuthService.profile()?.uid || '';
    const session: number = AuthSessionStore.generation();
    if (owner !== this.owner || session !== this.session) { this.snapshots.clear(); this.clearRows(); }
    this.owner = owner; this.session = session; this.active = true;
    this.previews.reset(true);
    const cached: FoodRankingSnapshot | undefined = this.snapshots.get(this.kind);
    if (cached !== undefined && Date.now() - cached.updatedAt < RESULT_REUSE_MS) {
      this.apply(cached); return;
    }
    void this.load();
  }
  // 暂停：作废进行中的加载。
  private pause(): void {
    if (!this.active) return;
    this.active = false; this.generation++; this.busy = false; this.opening = false;
    this.previews.reset(false); ReadScheduler.subscriptionsChanged();
  }
  // 清空列表。
  private clearRows(): void {
    this.previews.reset(this.active); this.source.setRows([]); this.items = []; this.count = 0;
    this.firstVisible = 0; this.lastVisible = 5;
    this.cursor = ''; this.totalCount = 0; this.updatedAt = 0; this.message = ''; this.failed = false;
  }
  // 应用一份榜单数据到界面。
  private apply(snapshot: FoodRankingSnapshot): void {
    this.items = snapshot.items.slice(); this.count = this.items.length; this.cursor = snapshot.cursor;
    this.totalCount = snapshot.totalCount; this.updatedAt = snapshot.updatedAt;
    this.failed = false; this.message = ''; this.loginRequired = false;
    this.previews.reset(true);
    const rows: Array<PersonalPreviewRow> = this.items.map((item: FoodRankingItem): PersonalPreviewRow => {
      const row: PersonalPreviewRow = new PersonalPreviewRow(item.card.id);
      row.card = item.card; row.state = item.card.photoPath.length > 0 ? 'MEDIA' : 'NO_IMAGE'; return row;
    });
    this.source.setRows(rows); this.window(this.firstVisible, this.lastVisible);
  }
  // 可见范围变化时更新懒加载窗口。
  private window(first: number, last: number): void {
    this.firstVisible = first; this.lastVisible = last;
    if (this.active) this.previews.window(this.context(), first, last, false);
  }
  // 切换高分榜 / 好友榜（好友榜需要登录）。
  private switchKind(kind: FoodRankingKind): void {
    if (this.kind === kind || this.busy || this.opening) return;
    this.generation++; this.kind = kind; this.clearRows();
    this.loginRequired = kind === 'FRIENDS' && this.owner.length === 0;
    if (this.loginRequired) return;
    const cached: FoodRankingSnapshot | undefined = this.snapshots.get(kind);
    if (cached !== undefined && Date.now() - cached.updatedAt < RESULT_REUSE_MS) this.apply(cached);
    else void this.load();
  }
  // 加载一页榜单。
  private async load(more: boolean = false): Promise<void> {
    if (!this.active || !this.pageActive || !this.appActive || this.busy) return;
    this.loginRequired = this.kind === 'FRIENDS' && this.owner.length === 0;
    if (this.loginRequired) { this.clearRows(); return; }
    const generation: number = ++this.generation;
    const kind: FoodRankingKind = this.kind;
    this.busy = true; this.failed = false;
    if (!more) this.clearRows();
    this.message = more ? '正在加载更多' : '正在整理榜单';
    try {
      if (!this.valid(generation)) return;
      let cursor: string = more ? this.cursor : '';
      const options: ReadRequestOptions = { priority: 'metadata', mayContinue: async (): Promise<boolean> => this.valid(generation) };
      let result: FoodRankingResponse | undefined = undefined;
      do {
        const request: FoodRankingRequest = { kind, cursor };
        result = await this.repository.list(request, options);
        if (!this.valid(generation)) return;
        if (result.kind !== kind || result.scope !== 'ALL_VISIBLE') throw new Error('榜单服务版本不一致，请更新后重试。');
        cursor = result.nextCursor;
        if (result.phase === 'PREPARING') {
          if (cursor.length === 0) throw new Error('榜单准备未完成，请重试。');
          this.message = '正在整理榜单';
        }
      } while (result !== undefined && result.phase === 'PREPARING');
      if (result === undefined) throw new Error('榜单未返回结果，请重试。');
      const previous: FoodRankingSnapshot | undefined = more ? this.snapshots.get(kind) : undefined;
      if (more && (previous === undefined || previous.updatedAt !== result.updatedAt)) throw new Error('榜单已更新，请刷新后继续查看。');
      const snapshot: FoodRankingSnapshot = new FoodRankingSnapshot(kind, result);
      if (previous !== undefined) snapshot.items = previous.items.concat(result.items.filter((item: FoodRankingItem): boolean =>
        !previous.items.some((existing: FoodRankingItem): boolean => existing.card.id === item.card.id)));
      this.snapshots.set(kind, snapshot); this.apply(snapshot);
    } catch (error) {
      if (!this.valid(generation) || error instanceof ReadCancelledError) return;
      this.failed = true; this.message = this.userMessage(error as Object, '榜单加载失败，请稍后重试。');
      if (error instanceof CloudBusinessError && ['CURSOR_STALE', 'ACCOUNT_INACTIVE', 'CONTENT_ACCESS_DENIED'].includes(error.code)) {
        this.snapshots.delete(kind); this.previews.reset(false); this.source.setRows([]);
        this.items = []; this.count = 0; this.cursor = ''; this.totalCount = 0; this.updatedAt = 0;
      }
    } finally { if (this.valid(generation)) this.busy = false; }
  }
  // 下拉刷新。
  private refresh(): void {
    if (this.busy || this.opening) return;
    this.snapshots.clear(); void this.load();
  }
  // 按卡片 id 找到榜单项。
  private entry(cardId: string): FoodRankingItem | undefined {
    return this.items.find((item: FoodRankingItem): boolean => item.card.id === cardId);
  }
  // 打开卡片详情。
  private async open(cardId: string): Promise<void> {
    if (this.busy || this.opening || !this.active) return;
    const generation: number = this.generation; this.opening = true;
    try {
      const options: ReadRequestOptions = { priority: 'metadata', mayContinue: async (): Promise<boolean> => this.valid(generation) };
      const card: FoodCard = await this.cards.detail(this.context(), cardId, options);
      if (this.valid(generation)) this.onOpenCard(card);
    } catch (error) {
      if (this.valid(generation) && !(error instanceof ReadCancelledError)) {
        this.message = this.userMessage(error as Object, '卡片暂不可访问，请刷新榜单。');
        this.snapshots.clear();
      }
    } finally { if (this.valid(generation)) this.opening = false; }
  }
  // 封面尺寸（窄屏更小）。
  private photoSize(): number { return this.pageWidth < 360 ? 72 : 84; }
  // 根据系统字体缩放调整布局。
  private updateTextScale(): void {
    const large: boolean = (this.context().config.fontSizeScale || 1) > 1.3;
    if (large !== this.largeText) this.largeText = large;
  }
  // 榜单更新时间文字。
  private updateTime(): string {
    const date: Date = new Date(this.updatedAt);
    return date.getHours().toString().padStart(2, '0') + ':' + date.getMinutes().toString().padStart(2, '0');
  }
  // 错误提示文字。
  private userMessage(error: Object, fallback: string): string {
    const code: string = error instanceof CloudBusinessError ? error.code : '';
    const detail: string = stage47ErrorText(error, fallback);
    console.warn('[FoodRankingPage] code=' + code + ' message=' + detail);
    if (code === 'CURSOR_STALE') return '榜单已更新，请刷新后继续查看。';
    if (code === 'ACCOUNT_INACTIVE') return '当前账号暂不可用，请重新登录。';
    if (detail === '服务繁忙，请稍后再试。') return detail;
    return fallback;
  }
  // 一个标签按钮。
  @Builder private tab(kind: FoodRankingKind, label: string) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Text(label).fontSize(16).maxFontScale(2).fontWeight(this.kind === kind ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.kind === kind ? $r('app.color.food_ranking_canvas') : $r('app.color.food_ranking_ink'))
        .maxLines(this.largeText ? 3 : 2).textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center).width('100%');
    }.layoutWeight(kind === 'HIGH_SCORE' ? 2 : 3).constraintSize({ minHeight: 48 })
      .padding({ left: 8, right: 8, top: 8, bottom: 8 }).borderRadius(24)
      .backgroundColor(this.kind === kind ? $r('app.color.food_ranking_accent') : Color.Transparent)
      .enabled(!this.busy && !this.opening).accessibilityGroup(true).accessibilityText(label)
      .accessibilitySelected(this.kind === kind)
      .onClick((): void => this.switchKind(kind));
  }
  // 顶部渐变。
  private headerGradient(): LinearGradient {
    const colors: Array<[ResourceColor, number]> = [
      [$r('app.color.food_ranking_header'), 0], [$r('app.color.food_ranking_canvas'), 1]
    ];
    const gradient: LinearGradient = { angle: 180, colors };
    return gradient;
  }
  // 顶部背景。
  @Builder private headerBackdrop(): void {
    Column() {}.width('100%').height('100%').linearGradient(this.headerGradient())
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no');
  }
  // 顶部区域（标题 + 标签）。
  @Builder private header() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Image($r('app.media.food_ranking_steam')).width(112).height(112).objectFit(ImageFit.Contain)
        .margin({ right: 4, top: 4 }).hitTestBehavior(HitTestMode.None).accessibilityLevel('no');
      Column({ space: 0 }) {
        Row() {
          Text('榜单').fontSize(28).maxFontScale(2).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.food_ranking_ink')).layoutWeight(1);
          Button({ type: ButtonType.Normal, stateEffect: true }) {
            Row({ space: 6 }) {
              if (this.busy) {
                LoadingProgress().width(18).height(18).color($r('app.color.food_ranking_accent'));
              } else {
                Image($r('app.media.ic_service_card_refresh')).width(18).height(18);
              }
              Text(this.busy ? '刷新中' : '刷新').fontSize(14).maxFontScale(1.6).fontColor($r('app.color.food_ranking_ink'));
            }.accessibilityLevel('no-hide-descendants');
          }.constraintSize({ minWidth: 80, minHeight: 48 }).padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor($r('app.color.food_ranking_surface')).borderRadius(24).enabled(!this.busy && !this.opening)
            .accessibilityText(this.busy ? '正在刷新榜单' : '刷新榜单').onClick((): void => this.refresh());
        }.width('100%').margin({ bottom: 8 });
        Row({ space: 8 }) {
          this.tab('HIGH_SCORE', '高分榜');
          this.tab('FRIENDS', '好友推荐榜');
        }.width('100%').padding(4).backgroundColor($r('app.color.food_ranking_tab_track')).borderRadius(28);
        Text(this.updatedAt > 0 ? '更新于 ' + this.updateTime() : this.busy ? '正在整理榜单' : ' ')
          .fontSize(12).maxFontScale(1.4).fontColor($r('app.color.food_ranking_muted')).textAlign(TextAlign.Center)
          .width('100%').padding({ top: 8, bottom: 8 });
      }.width('100%').padding({ left: 16, right: 16, top: 4 });
    }.width('100%').background(this.headerBackdrop, this.headerBackgroundOptions);
  }
  // 加载中状态。
  @Builder private loadingState() {
    List({ space: 8 }) {
      ForEach(this.skeletonRows, (_index: number): void => {
        ListItem() {
          Row({ space: 12 }) {
            Row().width(this.photoSize()).height(this.photoSize()).borderRadius(10)
              .backgroundColor($r('app.color.food_ranking_placeholder'));
            Column({ space: 8 }) {
              Row().width('84%').height(16).borderRadius(4).backgroundColor($r('app.color.food_ranking_placeholder'));
              Row().width('58%').height(12).borderRadius(4).backgroundColor($r('app.color.food_ranking_placeholder'));
              Row().width('48%').height(12).borderRadius(4).backgroundColor($r('app.color.food_ranking_placeholder'));
            }.layoutWeight(1).alignItems(HorizontalAlign.Start);
            if (!this.largeText) {
              Row().width(56).height(56).borderRadius(12).backgroundColor($r('app.color.food_ranking_score_surface'));
            }
          }.width('100%').padding(8).constraintSize({ minHeight: 100 })
            .backgroundColor($r('app.color.food_ranking_surface')).borderRadius(14);
        }
      }, (index: number): string => index.toString());
    }.width('100%').layoutWeight(1).padding({ left: 16, right: 16 })
      .scrollBar(BarState.Off).enabled(false).accessibilityLevel('no-hide-descendants');
  }
  // 空状态 / 准备中状态。
  @Builder private emptyState() {
    Scroll() {
      Column({ space: 12 }) {
        Column() {
          Image($r('app.media.ic_service_card_photo')).width(40).height(40).accessibilityLevel('no');
        }.width(80).height(80).justifyContent(FlexAlign.Center).borderRadius(24)
          .border({ width: 1, color: $r('app.color.food_ranking_line') })
          .backgroundColor($r('app.color.food_ranking_score_surface')).margin({ bottom: 4 }).accessibilityLevel('no');
        Text(this.loginRequired ? '登录后查看好友推荐榜' : this.failed ? '榜单暂时无法显示' :
          this.kind === 'FRIENDS' ? '暂无好友推荐' : '暂无推荐')
          .fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('app.color.food_ranking_ink')).textAlign(TextAlign.Center);
        if (this.loginRequired) {
          Text('看看当前好友发布的美食推荐').fontSize(14).fontColor($r('app.color.food_ranking_muted')).textAlign(TextAlign.Center);
        } else if (this.message.length > 0) {
          Text(this.message).fontSize(14).fontColor($r('app.color.food_ranking_muted')).textAlign(TextAlign.Center);
        }
        Button(this.loginRequired ? '登录' : this.failed ? '重试' : '刷新', { type: ButtonType.Normal, stateEffect: true })
          .constraintSize({ minWidth: 112, minHeight: 48 }).padding({ left: 24, right: 24, top: 12, bottom: 12 })
          .fontSize(14).fontColor($r('app.color.food_ranking_on_action')).borderRadius(24)
          .backgroundColor($r('app.color.food_ranking_action')).margin({ top: 4 }).enabled(!this.busy && !this.opening)
          .onClick((): void => { if (this.loginRequired) this.onRequireLogin(); else this.refresh(); });
      }.width('100%').constraintSize({ minHeight: this.emptyHeight })
        .padding({ left: 24, right: 24, top: 24, bottom: 40 }).justifyContent(FlexAlign.Center);
    }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
      .onAreaChange((_oldArea: Area, newArea: Area): void => {
        const height: number = Number(newArea.height);
        if (Number.isFinite(height) && height >= 0 && height !== this.emptyHeight) this.emptyHeight = height;
      });
  }
  // 页面布局。
  build() {
    Column({ space: 0 }) {
      this.header();
      if (this.count === 0 && this.busy) { this.loadingState(); }
      else if (this.count === 0) { this.emptyState(); }
      else {
        if (this.message.length > 0 && !this.busy) {
          Text(this.message).fontSize(13).fontColor($r('app.color.food_ranking_muted')).width('100%')
            .padding({ left: 16, right: 16, top: 4, bottom: 8 });
        }
        List({ space: 8 }) {
          LazyForEach(this.source, (row: PersonalPreviewRow): void => {
            ListItem() {
              FoodRankingTile({ row, rank: this.entry(row.cardId)?.rank || 0,
                merchantName: this.entry(row.cardId)?.merchantName || '', busy: this.busy || this.opening,
                photoSize: this.photoSize(), largeText: this.largeText,
                onOpen: (cardId: string): void => { void this.open(cardId); } });
            }
          }, (row: PersonalPreviewRow): string => row.cardId);
          ListItem() {
            if (this.cursor.length > 0) {
              Button(this.busy ? '加载中' : this.failed ? '重试加载' : '加载更多', { type: ButtonType.Normal, stateEffect: true })
                .width('100%').constraintSize({ minHeight: 48 }).fontSize(13)
                .fontColor($r('app.color.food_ranking_accent')).backgroundColor($r('app.color.food_ranking_surface')).borderRadius(14)
                .enabled(!this.busy && !this.opening).onClick((): void => { void this.load(true); });
            } else {
              Text('已显示全部 ' + this.totalCount.toString() + ' 张').fontSize(12)
                .fontColor($r('app.color.food_ranking_muted')).width('100%').textAlign(TextAlign.Center)
                .padding({ top: 16, bottom: 20 });
            }
          }
        }.width('100%').layoutWeight(1).padding({ left: 16, right: 16 }).cachedCount(2).scrollBar(BarState.Off)
          .onScrollIndex((first: number, last: number): void => this.window(first, last));
      }
    }.width('100%').height('100%').padding({ bottom: 8 })
      .background($r('app.color.food_ranking_canvas'), this.canvasBackgroundOptions).alignItems(HorizontalAlign.Start)
      .onAreaChange((_oldArea: Area, newArea: Area): void => {
        const width: number = Number(newArea.width);
        if (Number.isFinite(width) && width > 0 && width !== this.pageWidth) this.pageWidth = width;
        this.updateTextScale();
      })
      .onVisibleAreaChange([0, 1], (_visible: boolean, ratio: number): void => this.onVisibleChanged(ratio > 0));
  }
}
