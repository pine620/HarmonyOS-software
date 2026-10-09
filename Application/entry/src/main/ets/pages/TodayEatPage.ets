import { PrimaryActionStyle, SecondaryActionStyle, stage47ErrorText } from '../common/Stage47Ui';
import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import { cardPriceText } from '../model/CardPrice';
import { MealCandidate, MealCandidatePage } from '../model/MealModels';
import { MealRepository } from '../repository/MealRepository';
import { CardRepository } from '../repository/CardRepository';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { ReadRequestOptions } from '../service/ReadScheduler';

@Component
export struct TodayEatPage {
  @StorageLink('stage47AppActive') @Watch('onAppActiveChanged') appActive: boolean = true;
  @StorageLink('accountContentRevision') @Watch('onAccountContentChanged') accountContentRevision: number = 0;
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @State candidates: Array<MealCandidate> = [];
  @State message: string = '正在从你的想吃和收藏里随机选三张。';
  @State busy: boolean = false;
  @State closed: boolean = false;
  private visibleLifecycle: boolean = true;
  private active: boolean = false;
  private owner: string = '';
  private generation: number = 0;
  private excluded: Array<string> = [];
  private batchIds: Array<string> = [];
  private repo: MealRepository = new MealRepository();
  private cardRepo: CardRepository = new CardRepository();

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }
  private current(generation: number): boolean {
    return this.active && this.appActive && generation === this.generation &&
      this.owner === AccountRequestGuard.owner();
  }
  private onAppActiveChanged(): void {
    if (!this.appActive) this.aboutToDisappear();
    else if (this.visibleLifecycle) this.aboutToAppear();
  }
  private onVisibilityChanged(visible: boolean): void {
    if (this.visibleLifecycle === visible) return;
    this.visibleLifecycle = visible;
    if (visible && this.appActive) this.aboutToAppear();
    else this.aboutToDisappear();
  }
  private onAccountContentChanged(): void {
    this.aboutToDisappear();
    this.excluded = [];
    this.batchIds = [];
    this.closed = false;
    this.message = '正在从你的想吃和收藏里随机选三张。';
    if (this.visibleLifecycle && this.appActive) this.aboutToAppear();
  }
  aboutToAppear(): void {
    if (this.active || !this.appActive) return;
    this.active = true;
    this.owner = AccountRequestGuard.owner();
    if (this.closed) return;
    if (this.batchIds.length > 0) void this.restoreBatch();
    else void this.next();
  }
  aboutToDisappear(): void {
    this.active = false;
    this.generation++;
    this.candidates = [];
    this.busy = false;
  }
  private async hydrate(generation: number): Promise<void> {
    const cards: Array<FoodCard> = this.candidates.map((candidate: MealCandidate): FoodCard => candidate.card);
    try {
      await this.cardRepo.hydrateNearbyPrimaryPhotoUrls(this.context(), cards, 0, cards.length, 'normal',
        async (): Promise<boolean> => this.current(generation), (_card: FoodCard): void => { if (this.current(generation)) this.candidates = this.candidates.slice(); });
    } catch (_error) {
      if (this.current(generation)) this.message = '实拍图暂不可用，仍可查看卡片或换一批。';
    }
  }
  private async restoreBatch(): Promise<void> {
    const generation: number = ++this.generation;
    this.busy = true;
    try {
      const options: ReadRequestOptions = { mayContinue: async (): Promise<boolean> => this.current(generation) };
      const cards: Array<FoodCard> = await Promise.all(this.batchIds.map((cardId: string): Promise<FoodCard> =>
        this.cardRepo.detail(this.context(), cardId, options)));
      if (!this.current(generation)) return;
      this.candidates = cards.map((card: FoodCard): MealCandidate => {
        return { card, reasons: ['来自我的想吃或收藏'], distanceMeters: null };
      });
      this.message = '还是刚才这 ' + this.candidates.length + ' 张，不想吃就换一批。';
      void this.hydrate(generation);
    } catch (error) {
      if (this.current(generation)) {
        this.batchIds = [];
        this.message = stage47ErrorText(error as Object, '卡片暂时无法恢复，请换一批。');
      }
    } finally {
      if (this.current(generation)) this.busy = false;
    }
  }
  private async next(): Promise<void> {
    if (this.busy || !this.active) return;
    const generation: number = ++this.generation;
    this.busy = true;
    this.closed = false;
    this.message = '正在从你的想吃和收藏里随机选三张。';
    try {
      let restarted: boolean = false;
      const options: ReadRequestOptions = { mayContinue: async (): Promise<boolean> => this.current(generation) };
      let page: MealCandidatePage = await this.repo.personalCandidates(this.excluded.slice(-1000), options);
      if (!this.current(generation)) return;
      if (page.candidates.length === 0 && this.excluded.length > 0 &&
        (page.emptyReason === 'EXCLUDED_EXHAUSTED' || page.emptyReason === 'EXHAUSTED' ||
          page.emptyReason === undefined && page.sessionExhausted)) {
        page = await this.repo.personalCandidates([], options);
        if (!this.current(generation)) return;
        this.excluded = [];
        restarted = true;
      }
      this.candidates = page.candidates.slice(0, 3);
      this.batchIds = this.candidates.map((candidate: MealCandidate): string => candidate.card.id);
      for (const cardId of this.batchIds) if (!this.excluded.includes(cardId)) this.excluded.push(cardId);
      this.excluded = this.excluded.slice(-1000);
      if (this.candidates.length === 0) {
        this.message = page.emptyReason === 'SCAN_LIMIT' || page.coverage !== 'COMPLETE'
          ? '本次扫描暂未找到可选卡片，点换一批继续随机查找。'
          : page.emptyReason === 'EXHAUSTED' ? '当前可读取的候选已选完，点换一批重新随机选择。'
          : '暂时没有可选的卡片，先把喜欢的美食加入想吃或收藏吧。';
      } else if (this.candidates.length < 3) {
        this.message = '这批有 ' + this.candidates.length + ' 张可选卡片，不想吃就换一批。';
      } else {
        this.message = restarted ? '重新随机选了三张，不想吃就换一批。' : '随机选了三张，不想吃就换一批。';
      }
      void this.hydrate(generation);
    } catch (error) {
      if (this.current(generation)) {
        this.candidates = [];
        this.batchIds = [];
        this.message = stage47ErrorText(error as Object, '推荐暂时加载失败，点换一批重试。');
      }
    } finally {
      if (this.current(generation)) this.busy = false;
    }
  }
  private async preview(card: FoodCard): Promise<void> {
    if (this.busy) return;
    const generation: number = this.generation;
    this.busy = true;
    try {
      const options: ReadRequestOptions = { mayContinue: async (): Promise<boolean> => this.current(generation) };
      const fresh: FoodCard = await this.cardRepo.detail(this.context(), card.id, options);
      if (this.current(generation)) this.onOpenCard(fresh);
    } catch (error) {
      if (this.current(generation)) this.message = stage47ErrorText(error as Object, '卡片暂不可查看，请换一批。');
    } finally {
      if (this.current(generation)) this.busy = false;
    }
  }
  private async choose(card: FoodCard): Promise<void> {
    await this.preview(card);
  }
  private merchantLabel(card: FoodCard): string {
    const snapshot: string | undefined = card.merchantNameSnapshot;
    return snapshot !== undefined && snapshot.length > 0 ? snapshot : card.shop.length > 0 ? card.shop : '未关联店铺';
  }
  @Builder
  private candidateCard(candidate: MealCandidate): void {
    Column({ space: 10 }) {
      Row({ space: 12 }) {
        if (candidate.card.photoUrl.length > 0) {
          Image(candidate.card.photoUrl).width(88).height(112).objectFit(ImageFit.Contain).autoResize(true).syncLoad(false).borderRadius(18)
            .accessibilityText(candidate.card.productName + '实拍图')
        } else {
          Text(candidate.card.primaryPhotoLoadFailed === true ? '图片暂不可用' : candidate.card.photoPath.length === 0 ? '暂无实拍图' : '实拍图加载中')
            .width(88).height(112).fontSize(12).textAlign(TextAlign.Center)
            .fontColor($r('app.color.muted')).backgroundColor($r('app.color.accent_soft')).borderRadius(18)
        }
        Column({ space: 6 }) {
          Text(candidate.card.productName).fontSize(17).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          Text(this.merchantLabel(candidate.card)).fontSize(12).fontColor($r('app.color.muted'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          Text(cardPriceText(candidate.card)).fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.accent_action')).maxLines(2).width('100%')
          Text('评分 ' + candidate.card.tasteScore).fontSize(12).fontColor($r('app.color.muted'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').alignItems(VerticalAlign.Top)
      Text(candidate.reasons.join(' · ')).fontSize(12).fontColor($r('app.color.muted')).maxLines(2).width('100%')
      Row({ space: 8 }) {
        Button('查看卡片').attributeModifier(new SecondaryActionStyle()).constraintSize({ minHeight: 48 }).layoutWeight(1)
          .enabled(!this.busy && !this.closed).onClick((): void => { void this.preview(candidate.card); })
        Button('就吃这个').attributeModifier(new PrimaryActionStyle()).constraintSize({ minHeight: 48 }).layoutWeight(1)
          .enabled(!this.busy && !this.closed).onClick((): void => { void this.choose(candidate.card); })
      }.width('100%')
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.surface')).borderRadius(24).border({ width: 1, color: $r('app.color.line') })
  }
  build() {
    Scroll() {
      Column({ space: 12 }) {
        Column({ space: 8 }) {
          Text('今天吃什么').fontSize(26).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
          Text('把纠结留给食刻').fontSize(15).fontColor($r('app.color.action_text'))
          Text(this.message).fontSize(13).lineHeight(20).fontColor($r('app.color.muted')).width('100%')
          Text('从我的想吃和收藏里随机挑选').fontSize(12).fontColor($r('app.color.action_text'))
        }.width('100%').alignItems(HorizontalAlign.Start).padding(20).backgroundColor($r('app.color.accent_soft')).borderRadius(24)
        Button(this.busy ? '正在推荐…' : this.closed ? '再推荐三张' : '换一批')
          .attributeModifier(new PrimaryActionStyle()).constraintSize({ minHeight: 48 }).width('100%').enabled(!this.busy)
          .onClick((): void => { void this.next(); })
        if (this.busy && this.candidates.length === 0) {
          LoadingProgress().width(36).height(36).color($r('app.color.accent_action'))
        }
        if (!this.closed) {
          ForEach(this.candidates, (candidate: MealCandidate): void => {
            this.candidateCard(candidate)
          }, (candidate: MealCandidate): string => candidate.card.id)
        }
      }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').align(Alignment.TopStart).backgroundColor($r('app.color.canvas'))
      .onVisibleAreaChange([0, 1], (_visible: boolean, ratio: number): void => this.onVisibilityChanged(ratio > 0))
  }
}
