import { PagePaletteName, pageColor } from '../common/PagePaletteUi';
import { common } from '@kit.AbilityKit';
import util from '@ohos.util';
import { FoodCard } from '../model/CloudContracts';
import { cardPriceText } from '../model/CardPrice';
import { FoodChoiceReceipt, FoodChoiceRequest, RandomFoodCards, RandomFoodCardsRequest, RandomFoodPool,
  RandomFoodPoolRequest, RandomFoodRound, RandomFoodSource, copyRandomFoodRound, randomFoodSourceLabel,
  randomFoodNextMealAt, randomFoodCanStartNextMeal } from '../model/RandomFoodModels';
import { RandomPrimaryStyle, RandomSecondaryStyle, RandomFoodMotionObserver, randomFoodTransition,
  randomFoodAccountUnavailable } from '../common/RandomFoodUi';
import { stage47ErrorText } from '../common/Stage47Ui';
import { RandomFoodRepository } from '../repository/RandomFoodRepository';
import { CardRepository } from '../repository/CardRepository';
import { RandomFoodRoundStore } from '../service/RandomFoodRoundStore';
import { AuthSessionStore } from '../service/AuthSessionStore';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { CloudBusinessError } from '../service/CloudReadErrors';
import { ReadRequestOptions } from '../service/ReadScheduler';
import { RandomFoodWidgetStore } from '../service/RandomFoodWidgetStore';

@Component
export struct RandomFoodPage {
  @Prop palette: PagePaletteName = 'NOTE';
  @Prop @Watch('onVisibilityChanged') navigationVisible: boolean = true;
  @StorageLink('stage47AppActive') @Watch('onActiveChanged') appActive: boolean = true;
  @StorageLink('accountContentRevision') @Watch('onRevisionChanged') accountRevision: number = 0;
  @StorageLink('contentMutationRevision') @Watch('onRevisionChanged') contentRevision: number = 0;
  // Votes no longer bump contentMutationRevision; the personal pool is built from favorites.
  @StorageLink('favoritesMutationRevision') @Watch('onRevisionChanged') favoritesRevision: number = 0;
  onBack: () => void = (): void => {};
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  onOpenHistory: () => void = (): void => {};
  onLogin: () => void = (): void => {};
  @State source: RandomFoodSource = 'MY';
  @State round: RandomFoodRound | undefined = undefined;
  @State cards: Array<FoodCard> = [];
  @State index: number = 0;
  @State busy: boolean = false;
  @State message: string = '';
  @State motion: boolean = true;
  @State systemReduced: boolean = true;
  @State rangeOpen: boolean = false;
  @State mealNow: number = Date.now();
  private owner: string = '';
  private session: number = 0;
  private generation: number = 0;
  private active: boolean = false;
  private mealClockTimer: number = -1;
  private mealClockGeneration: number = 0;
  private motionObserver: RandomFoodMotionObserver = new RandomFoodMotionObserver((reduced: boolean): void => {
    if (this.active) this.systemReduced = reduced;
  });
  private swiper: SwiperController = new SwiperController();
  private repo: RandomFoodRepository = new RandomFoodRepository();
  private cardRepo: CardRepository = new CardRepository();
  private sources: Array<RandomFoodSource> = ['MY', 'PUBLIC', 'FRIENDS'];
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private fontScale(): number { return Math.max(1, this.context().config.fontSizeScale || 1); }
  private foodHeight(): number { return 224 + 44 + 112 * this.fontScale(); }
  private backHeight(): number { return 200 + 60 * Math.min(1.4, this.fontScale()); }
  private largeText(): boolean { return this.fontScale() > 1.3; }
  private motionAllowed(): boolean { return this.motion && !this.systemReduced; }
  private showError(error: Object, fallback: string): void {
    if (randomFoodAccountUnavailable(error)) { this.cards = []; this.round = undefined; this.stopMealClock(); }
    this.message = stage47ErrorText(error, fallback);
  }
  private viewer(): string { const uid: string = AccountRequestGuard.owner(); return uid.length === 0 ? 'guest' : 'user:' + uid; }
  private current(generation: number): boolean {
    return this.active && this.navigationVisible && this.appActive && generation === this.generation &&
      this.owner === this.viewer() && this.session === AuthSessionStore.generation();
  }
  private options(generation: number): ReadRequestOptions {
    const options: ReadRequestOptions = { priority: 'metadata', mayContinue: async (): Promise<boolean> => this.current(generation) };
    return options;
  }
  aboutToAppear(): void { this.resume(); }
  aboutToDisappear(): void { this.pause(); }
  private onVisibilityChanged(): void { if (this.navigationVisible) this.resume(); else this.pause(); }
  private onActiveChanged(): void { if (this.appActive) this.resume(); else this.pause(); }
  private onRevisionChanged(): void { this.pause(); this.resume(); }
  private pause(): void {
    this.active = false; this.motionObserver.stop(); this.stopMealClock(); this.generation++; this.cards = []; this.busy = false;
  }
  private resume(): void {
    if (this.active || !this.navigationVisible || !this.appActive) return;
    this.active = true; this.owner = this.viewer(); this.session = AuthSessionStore.generation();
    this.systemReduced = this.motionObserver.start();
    try {
      this.motion = RandomFoodRoundStore.motionEnabled(this.context());
      this.source = RandomFoodRoundStore.selectedSource(this.context(), this.owner);
      this.loadSource();
    } catch (error) { this.round = undefined; this.message = stage47ErrorText(error as Object, '本轮进度暂不可读取。'); }
  }
  private loadSource(): void {
    this.stopMealClock();
    this.generation++; this.cards = []; this.index = 0; this.busy = false; this.rangeOpen = false;
    this.round = RandomFoodRoundStore.read(this.context(), this.owner, this.source);
    this.message = this.round !== undefined && this.round.ended ? '本轮已结束，点击开始新一轮。' : '翻开三张，选一个喜欢的。';
    if (this.round !== undefined && this.round.batchIds.length > 0) void this.restore();
    this.refreshMealClock();
  }
  private switchSource(source: RandomFoodSource): void {
    if (this.busy || source === this.source) return;
    if (this.owner === 'guest' && source !== 'PUBLIC') { this.onLogin(); return; }
    try {
      RandomFoodRoundStore.selectSource(this.context(), this.owner, source); this.source = source; this.loadSource();
      // The desktop card follows this source; it refreshes its own pool in the background.
      void RandomFoodWidgetStore.sync(this.context()).catch((): void => {});
    }
    catch (error) { this.message = stage47ErrorText(error as Object, '来源切换暂未保存。'); }
  }
  private commit(round: RandomFoodRound): void {
    RandomFoodRoundStore.write(this.context(), round);
    this.round = copyRandomFoodRound(round);
    this.refreshMealClock();
  }
  private nextMealAt(): number { return this.round === undefined ? 0 : randomFoodNextMealAt(this.round); }
  private nextMealReady(now: number): boolean {
    return this.round !== undefined && randomFoodCanStartNextMeal(this.round, now);
  }
  private nextMealRemaining(): string {
    const totalMinutes: number = Math.ceil(Math.max(0, this.nextMealAt() - this.mealNow) / 60000);
    const hours: number = Math.floor(totalMinutes / 60), minutes: number = totalMinutes % 60;
    return (hours > 0 ? hours.toString() + '小时' : '') + (minutes > 0 || hours === 0 ? minutes.toString() + '分钟' : '');
  }
  private stopMealClock(): void {
    this.mealClockGeneration++;
    if (this.mealClockTimer !== -1) clearTimeout(this.mealClockTimer);
    this.mealClockTimer = -1;
  }
  private refreshMealClock(): void {
    this.stopMealClock(); this.mealNow = Date.now();
    const remaining: number = this.nextMealAt() - this.mealNow;
    if (!this.current(this.generation) || !this.confirmed() || !Number.isFinite(remaining) || remaining <= 0) return;
    const clockGeneration: number = this.mealClockGeneration, generation: number = this.generation;
    // Refresh presentation only; expiration never clears a choice or starts a request.
    this.mealClockTimer = setTimeout((): void => {
      if (clockGeneration === this.mealClockGeneration && this.current(generation)) this.refreshMealClock();
    }, Math.max(1, Math.min(60000, remaining)));
  }
  private blankRound(): RandomFoodRound {
    const value: RandomFoodRound = { version: 1, owner: this.owner, source: this.source, roundId: util.generateRandomUUID(),
      cardIds: [], position: 0, shownCount: 0, batchIds: [], drawId: '', chosenCardId: '', pendingCardId: '', selectedAt: 0,
      historyId: '', recordDeleted: false, rangeLabel: '', preparedAt: 0, ended: false };
    return value;
  }
  private async fetch(ids: Array<string>, drawId: string, generation: number): Promise<Array<FoodCard>> {
    const request: RandomFoodCardsRequest = { source: this.source, drawId, cardIds: ids };
    const page: RandomFoodCards = await this.repo.cards(request, this.options(generation));
    const ordered: Array<FoodCard> = [];
    for (const id of ids) { const card: FoodCard | undefined = page.cards.find((item: FoodCard): boolean => item.id === id); if (card !== undefined) ordered.push(card); }
    return ordered;
  }
  private async hydrate(generation: number): Promise<void> {
    const cards: Array<FoodCard> = this.cards.slice();
    try {
      await this.cardRepo.hydrateNearbyPrimaryPhotoUrls(this.context(), cards, 0, cards.length, 'normal',
        async (): Promise<boolean> => this.current(generation), (card: FoodCard): void => {
          if (this.current(generation) && this.cards.some((item: FoodCard): boolean => item === card)) this.cards = this.cards.slice();
        }, (card: FoodCard): boolean => this.cards.some((item: FoodCard): boolean => item === card));
    } catch (_error) { /* The card stays usable with an explicit photo placeholder. */ }
  }
  private async restore(): Promise<void> {
    if (this.round === undefined) return;
    const saved: RandomFoodRound = copyRandomFoodRound(this.round), generation: number = ++this.generation;
    this.busy = true;
    try {
      const selected: string = saved.chosenCardId || saved.pendingCardId;
      const ids: Array<string> = selected.length > 0 ? [selected] : saved.batchIds;
      const cards: Array<FoodCard> = await this.fetch(ids, saved.drawId, generation);
      if (!this.current(generation)) return;
      this.cards = cards.length === ids.length ? cards : [];
      this.index = 0;
      this.message = cards.length === ids.length ? saved.pendingCardId.length > 0 ? '上次保存尚待确认，请重试保存。' :
        saved.chosenCardId.length > 0 ? this.choiceMessage(saved, true) : '继续刚才这组三张。' : saved.pendingCardId.length > 0 ?
        '原卡片当前不可展示，请重试保存以确认上次请求的结果。' : '原结果有卡片已不可用，请再抽三张。';
      void this.hydrate(generation);
    } catch (error) { if (this.current(generation)) this.showError(error as Object, '结果恢复失败，进度仍保留。'); }
    finally { if (this.current(generation)) this.busy = false; }
  }
  private finishRound(round: RandomFoodRound): void {
    round.ended = true; round.batchIds = []; round.drawId = ''; round.chosenCardId = ''; round.pendingCardId = '';
    round.historyId = ''; round.selectedAt = 0; round.recordDeleted = false;
    this.commit(round); this.cards = [];
    this.message = round.shownCount === 0 ? '本轮候选不足三张，请换来源或稍后开始新一轮。' : '剩余可用候选不足三张，本轮结束。';
  }
  private async draw(newRound: boolean = false): Promise<void> {
    if (this.busy || !this.current(this.generation)) return;
    if (this.round !== undefined && this.round.pendingCardId.length > 0) { this.message = '先重试保存上次选择，再继续抽取。'; return; }
    const nextMeal: boolean = this.confirmed();
    if (nextMeal && !this.nextMealReady(Date.now())) {
      this.refreshMealClock(); this.message = '本餐已经选定，满6小时后可抽下一餐。'; return;
    }
    const generation: number = ++this.generation;
    this.busy = true; this.message = nextMeal ? '正在准备下一餐的三张…' : '正在准备这一轮的三张…';
    try {
      let round: RandomFoodRound = this.round === undefined || newRound || nextMeal ? this.blankRound() : copyRandomFoodRound(this.round);
      if (round.ended && !newRound) return;
      if (round.preparedAt === 0) {
        this.commit(round);
        const request: RandomFoodPoolRequest = { source: this.source, roundId: round.roundId };
        const pool: RandomFoodPool = await this.repo.pool(request, this.options(generation));
        if (!this.current(generation)) return;
        if (pool.source !== round.source || pool.roundId !== round.roundId || !Array.isArray(pool.cardIds) || pool.cardIds.length > 60 ||
          pool.poolSize !== pool.cardIds.length || pool.poolLimit !== 60 || pool.coverage !== 'BOUNDED' ||
          typeof pool.rangeLabel !== 'string' || pool.rangeLabel.length > 240 || !Number.isSafeInteger(pool.preparedAt) || pool.preparedAt <= 0 ||
          !pool.cardIds.every((id: string): boolean => typeof id === 'string' && /^[A-Za-z0-9:_-]{1,160}$/.test(id)) ||
          new Set<string>(pool.cardIds).size !== pool.cardIds.length) throw new Error('候选池响应无效，请重试。');
        round.cardIds = pool.cardIds.slice(); round.rangeLabel = pool.rangeLabel; round.preparedAt = pool.preparedAt;
        this.commit(round);
      }
      if (round.cardIds.length - round.position < 3) { this.finishRound(round); return; }
      const drawId: string = util.generateRandomUUID();
      let collected: Array<FoodCard> = [];
      let ready: boolean = false;
      while (round.position < round.cardIds.length || collected.length === 3) {
        if (collected.length === 3) {
          collected = await this.fetch(collected.map((card: FoodCard): string => card.id), drawId, generation);
          if (!this.current(generation)) return;
          if (collected.length === 3) { ready = true; break; }
        }
        const ids: Array<string> = round.cardIds.slice(round.position, round.position + 3 - collected.length);
        if (ids.length === 0) break;
        const cards: Array<FoodCard> = await this.fetch(ids, drawId, generation);
        if (!this.current(generation)) return;
        round.position += ids.length; collected = collected.concat(cards);
      }
      if (!ready) { this.finishRound(round); return; }
      round.batchIds = collected.map((card: FoodCard): string => card.id); round.drawId = drawId; round.shownCount += 3;
      round.chosenCardId = ''; round.pendingCardId = ''; round.historyId = ''; round.selectedAt = 0; round.recordDeleted = false;
      this.commit(round); this.index = 0; this.cards = collected; this.message = '左右滑动比较三张，喜欢就选它。';
      void this.hydrate(generation);
    } catch (error) { if (this.current(generation)) this.showError(error as Object, '暂未抽取成功，点击重试，本轮进度保留。'); }
    finally { if (this.current(generation)) this.busy = false; }
  }
  private choiceMessage(round: RandomFoodRound, restored: boolean = false): string {
    return this.owner === 'guest' ? '已经选好。游客不保存选择记录，登录后可使用云端记录。' : round.recordDeleted ? '这次选择的记录已删除。' :
      restored ? '继续这次已确认的选择，云端记录状态可在记录页查看。' : '已保存到选择记录。';
  }
  private async choose(): Promise<void> {
    if (this.busy || this.round === undefined || this.round.chosenCardId.length > 0) return;
    const round: RandomFoodRound = copyRandomFoodRound(this.round), generation: number = this.generation;
    const card: FoodCard | undefined = this.cards[this.index];
    const cardId: string = round.pendingCardId || (card === undefined ? '' : card.id);
    if (cardId.length === 0) return;
    this.busy = true;
    try {
      let fresh: Array<FoodCard> = [];
      if (round.pendingCardId.length === 0) {
        fresh = await this.fetch([cardId], round.drawId, generation);
        if (!this.current(generation)) return;
        if (fresh.length !== 1) throw new CloudBusinessError('卡片已不可用，未保存选择。', 'CONTENT_UNAVAILABLE');
      }
      if (this.owner === 'guest') { round.chosenCardId = cardId; round.selectedAt = Date.now(); }
      else {
        round.pendingCardId = cardId; this.commit(round);
        const request: FoodChoiceRequest = { source: round.source, roundId: round.roundId, drawId: round.drawId, cardId };
        const receipt: FoodChoiceReceipt = await this.repo.save(request);
        if (!this.current(generation)) return;
        round.chosenCardId = cardId; round.pendingCardId = ''; round.selectedAt = receipt.selectedAt;
        round.historyId = receipt.historyId; round.recordDeleted = receipt.deleted;
      }
      this.commit(round); this.cards = fresh; this.index = 0; this.message = this.choiceMessage(round);
      if (fresh.length === 0) {
        try { fresh = await this.fetch([cardId], round.drawId, generation); }
        catch (_error) { /* The receipt remains authoritative even if the card disappeared afterwards. */ }
        if (!this.current(generation)) return;
        this.cards = fresh;
      }
      void this.hydrate(generation);
      // Only an explicit successful choice opens details; restore keeps the chosen screen.
      const chosen: FoodCard | undefined = fresh.find((item: FoodCard): boolean => item.id === cardId);
      if (chosen !== undefined && this.current(generation)) {
        try { this.onOpenCard(chosen); }
        catch (error) {
          this.message = this.choiceMessage(round) + ' ' + stage47ErrorText(error as Object, '详情暂未打开，请点击“查看卡片”重试。');
        }
      }
    } catch (error) {
      if (this.current(generation)) {
        if (error instanceof CloudBusinessError && error.code === 'CONTENT_UNAVAILABLE') {
          round.pendingCardId = ''; this.commit(round); this.cards = [];
        }
        this.showError(error as Object, '保存结果尚未确认，请重试保存。');
      }
    } finally { if (this.current(generation)) this.busy = false; }
  }
  private async preview(): Promise<void> {
    if (this.busy) return;
    const card: FoodCard | undefined = this.cards[this.index]; if (card === undefined) return;
    const generation: number = this.generation; this.busy = true;
    try {
      if (this.round !== undefined && (await this.fetch([card.id], this.round.drawId, generation)).length !== 1)
        throw new Error('卡片已不在当前来源中。');
      const fresh: FoodCard = await this.cardRepo.detail(this.context(), card.id, this.options(generation));
      if (this.current(generation)) this.onOpenCard(fresh);
    } catch (error) { if (this.current(generation)) this.showError(error as Object, '卡片已不可用。'); }
    finally { if (this.current(generation)) this.busy = false; }
  }
  private confirmed(): boolean { return this.round !== undefined && this.round.chosenCardId.length > 0; }
  private drawStyle(): AttributeModifier<ButtonAttribute> {
    return !this.confirmed() && this.cards.length > 0 ? new RandomSecondaryStyle(this.palette) : new RandomPrimaryStyle(this.palette);
  }
  private drawLabel(): string {
    if (this.confirmed()) return '抽下一餐';
    if (this.round !== undefined && this.round.ended) return '开始新一轮';
    return this.cards.length > 0 || (this.round !== undefined && this.round.batchIds.length > 0) ? '再抽三张' : '帮我选';
  }
  private sourceNote(): string { return this.source === 'MY' ? '我的收藏' : this.source === 'FRIENDS' ? '当前好友发布的卡片' : '公开发布的美食卡片'; }
  private merchant(card: FoodCard): string { return card.merchantNameSnapshot || card.shop || '未关联店铺'; }
  private cardRenderKey(card: FoodCard): string {
    // Match the feed: rebuild the placeholder when an asynchronous cover settles.
    const parts: Array<string> = [card.id, card.contentRevision || '', card.photoUrl,
      String(card.primaryPhotoResolved === true), String(card.primaryPhotoLoadFailed === true)];
    return JSON.stringify(parts);
  }
  private resultKeys(): Array<string> {
    // Replay the page entrance for a new draw/confirmation, never for cover hydration.
    const parts: Array<string> = [this.owner, this.source, this.round === undefined ? '' : this.round.drawId,
      this.round === undefined ? '' : this.round.chosenCardId];
    return [JSON.stringify(parts)];
  }
  private moveCard(previous: boolean): void {
    if (this.busy || this.cards.length !== 3 || this.confirmed()) return;
    if (previous && this.index > 0) this.swiper.showPrevious();
    else if (!previous && this.index < 2) this.swiper.showNext();
  }
  private async toggleMotion(): Promise<void> {
    try { RandomFoodRoundStore.setMotion(this.context(), !this.motion); this.motion = !this.motion; }
    catch (_error) { this.message = '动效偏好暂未保存。'; }
  }
  @Builder private header() {
    Row({ space: 8 }) {
      Button('‹').fontSize(30).width(48).height(48).backgroundColor(Color.Transparent).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'ink') : $r('app.color.random_ink')))
        .accessibilityText('返回').onClick((): void => this.onBack())
      Column({ space: 2 }) {
        Text('食刻').fontSize(19).fontWeight(FontWeight.Bold).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'ink') : $r('app.color.random_ink')))
        Text('FOOD MOMENTS').fontSize(10).letterSpacing(1).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'action') : $r('app.color.random_accent'))).accessibilityLevel('no')
      }.layoutWeight(1)
      Button('选择记录').fontSize(13).labelStyle({ maxLines: 2, overflow: TextOverflow.Ellipsis })
        .constraintSize({ minWidth: 64, minHeight: 48 }).backgroundColor(Color.Transparent)
        .fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted'))).onClick((): void => { if (this.owner === 'guest') this.onLogin(); else this.onOpenHistory(); })
    }.width('100%')
  }
  @Builder private sourcesControl() {
    Column({ space: 0 }) {
      Row({ space: 0 }) {
        ForEach(this.sources, (source: RandomFoodSource): void => {
          Button(randomFoodSourceLabel(source)).type(ButtonType.Normal).constraintSize({ minHeight: 48 }).layoutWeight(1).borderRadius(8)
            .labelStyle({ maxLines: 2, overflow: TextOverflow.Ellipsis })
            .backgroundColor(Color.Transparent)
            .fontColor(source === this.source ? (this.palette === 'PERSONAL' ? pageColor(this.palette, 'action') : $r('app.color.random_accent')) : (this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted'))).fontSize(15)
            .fontWeight(source === this.source ? FontWeight.Bold : FontWeight.Normal).enabled(!this.busy)
            .accessibilitySelected(source === this.source).onClick((): void => this.switchSource(source))
        }, (source: RandomFoodSource): string => source)
      }.width('100%')
      Row() {
        Row().width('33.333%').height(2).backgroundColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'action') : $r('app.color.random_accent')))
          .translate({ x: (this.sources.indexOf(this.source) * 100).toString() + '%' })
          .animation({ duration: this.motionAllowed() ? 180 : 0, curve: Curve.EaseOut })
      }.width('100%').height(2).backgroundColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'line') : $r('app.color.random_line')))
    }.width('100%')
  }
  @Builder private cardBack(ordinal: string, angle: number, offset: number) {
    Column({ space: 8 }) {
      Text(ordinal).fontSize(24).maxFontScale(1.4).fontWeight(FontWeight.Medium).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'action') : $r('app.color.random_accent')))
        .width('100%').margin({ top: 16 })
      Blank()
      Image($r('app.media.ic_random_food_back')).width(128).height(128).accessibilityLevel('no')
      Text('下一份灵感').fontSize(14).maxFontScale(1.4).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted')))
      Blank()
      Text('食刻 · 今日篇').fontSize(11).maxFontScale(1.4).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted'))).margin({ bottom: 16 })
    }.width('72%').height(this.backHeight()).padding({ left: 20, right: 20 }).backgroundColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'surface') : $r('app.color.random_surface')))
      .borderRadius(16).border({ width: 1, color: (this.palette === 'PERSONAL' ? pageColor(this.palette, 'line') : $r('app.color.random_line')) }).rotate({ angle }).translate({ x: offset })
  }
  @Builder private backs() {
    Stack({ alignContent: Alignment.Center }) {
      this.cardBack('01', -9, -24)
      this.cardBack('03', 9, 24)
      this.cardBack('02', 0, 0)
    }.width('100%').height(this.backHeight() + 50).accessibilityGroup(true)
      .accessibilityText('三张未翻开的美食卡片，点击帮我选开始')
  }
  @Builder private food(card: FoodCard) {
    Column({ space: 0 }) {
      if (card.photoUrl.length > 0) {
        Image(card.photoUrl).width('100%').height(224).objectFit(ImageFit.Cover).autoResize(true).syncLoad(false)
          .accessibilityText(card.productName + '实拍图')
      } else {
        Column({ space: 12 }) {
          Image($r('app.media.ic_random_food_back')).width(this.largeText() ? 48 : 64).height(this.largeText() ? 48 : 64).accessibilityLevel('no')
          Text(card.photoPath.length === 0 ? '暂无实拍图' : '实拍图加载中或暂不可用').fontSize(13).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted')))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).textAlign(TextAlign.Center)
        }.width('100%').height(224).padding(16).justifyContent(FlexAlign.Center).backgroundColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'soft') : $r('app.color.random_soft')))
      }
      Column({ space: 6 }) {
        Text(card.productName).fontSize(21).fontWeight(FontWeight.Bold).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'ink') : $r('app.color.random_ink'))).width('100%')
        Text(this.merchant(card)).fontSize(13).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted'))).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(cardPriceText(card)).fontSize(16).fontWeight(FontWeight.Medium).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'action') : $r('app.color.random_accent')))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }.padding(16).width('100%').alignItems(HorizontalAlign.Start)
    }.width('100%').backgroundColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'surface') : $r('app.color.random_surface'))).borderRadius(16).clip(true)
      .border({ width: 1, color: (this.palette === 'PERSONAL' ? pageColor(this.palette, 'line') : $r('app.color.random_line')) })
  }
  @Builder private results(key: string) {
    Swiper(this.swiper) {
      ForEach(this.cards, (card: FoodCard): void => { this.food(card) }, (card: FoodCard): string => this.cardRenderKey(card))
    }.width('100%').height(this.foodHeight()).loop(false).index(this.index).indicator(false)
      .prevMargin(this.cards.length === 3 ? 16 : 0).nextMargin(this.cards.length === 3 ? 16 : 0).itemSpace(10)
      .duration(this.motionAllowed() ? 220 : 0).enabled(!this.busy)
      .onChange((index: number): void => {
        if (this.active && key === this.resultKeys()[0] && index >= 0 && index < this.cards.length) this.index = index;
      })
      .transition(randomFoodTransition(this.motionAllowed(), this.confirmed() ? 'CONFIRM' : 'REVEAL'))
  }
  @Builder private navigationButtons() {
    Row({ space: 4 }) {
      if (!this.confirmed() && this.cards.length === 3) {
        Button('‹').width(48).height(48).fontSize(24).backgroundColor(Color.Transparent).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'ink') : $r('app.color.random_ink')))
          .enabled(!this.busy && this.index > 0).accessibilityText('上一张美食卡片').onClick((): void => this.moveCard(true))
        Text((this.index + 1).toString() + ' / 3').fontSize(14).fontWeight(FontWeight.Medium).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'ink') : $r('app.color.random_ink')))
          .layoutWeight(1).textAlign(TextAlign.Center).maxLines(1)
          .accessibilityText('第' + (this.index + 1).toString() + '张，共三张')
        Button('›').width(48).height(48).fontSize(24).backgroundColor(Color.Transparent).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'ink') : $r('app.color.random_ink')))
          .enabled(!this.busy && this.index < 2).accessibilityText('下一张美食卡片').onClick((): void => this.moveCard(false))
      }
    }.width(this.largeText() ? '100%' : '58%')
  }
  @Builder private previewButton() {
    Button('查看卡片 ›').constraintSize({ minHeight: 48 }).fontSize(13).backgroundColor(Color.Transparent)
      .width(this.largeText() || this.cards.length !== 3 ? '100%' : '42%')
      .labelStyle({ maxLines: 2, overflow: TextOverflow.Ellipsis }).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'action') : $r('app.color.random_accent')))
      .enabled(!this.busy).onClick((): void => { void this.preview(); })
  }
  @Builder private navigationRail() {
    if (this.largeText() || this.cards.length !== 3) {
      Column({ space: 0 }) {
        if (this.cards.length === 3) { this.navigationButtons() }
        this.previewButton()
      }.width('100%')
    } else {
      Row({ space: 0 }) { this.navigationButtons(); this.previewButton() }.width('100%')
    }
  }
  build() {
    Scroll() {
      Column({ space: 12 }) {
        this.header()
        Text(this.confirmed() ? '这餐，就它了。' : this.cards.length > 0 ? '今天，从这三张选。' : '今天，吃点什么？')
          .fontSize(this.cards.length > 0 ? 26 : 30).fontWeight(FontWeight.Bold)
          .fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'ink') : $r('app.color.random_ink'))).width('100%').margin({ top: 8 })
        if (!this.confirmed()) { this.sourcesControl() }
        Text(this.sourceNote()).fontSize(13).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted'))).width('100%')
        if (this.cards.length > 0) {
          ForEach(this.resultKeys(), (key: string): void => { this.results(key) }, (key: string): string => key)
          this.navigationRail()
          if (!this.confirmed()) {
            Button(this.busy ? '正在确认…' : this.round !== undefined && this.round.pendingCardId.length > 0 ? '重试保存' : '就吃这个')
              .attributeModifier(new RandomPrimaryStyle(this.palette)).width('100%').enabled(!this.busy).onClick((): void => { void this.choose(); })
          }
        } else if (this.confirmed()) {
          Text('已确认的卡片当前不可展示').fontSize(16).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted'))).width('100%')
            .constraintSize({ minHeight: 180 }).padding(20).textAlign(TextAlign.Center)
        } else if (this.round !== undefined && this.round.ended) {
          Column({ space: 12 }) {
            Image($r('app.media.ic_random_food_back')).width(80).height(80).accessibilityLevel('no')
            Text('这一轮，到这里。').fontSize(25).fontWeight(FontWeight.Bold).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'ink') : $r('app.color.random_ink')))
            Text('不足三张的尾批留在本轮，重新开一轮再遇见。').fontSize(14).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted'))).textAlign(TextAlign.Center)
          }.width('100%').constraintSize({ minHeight: 250 }).justifyContent(FlexAlign.Center).padding(24)
            .backgroundColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'soft') : $r('app.color.random_soft'))).borderRadius(16)
        } else { this.backs() }
        if (this.busy) { LoadingProgress().width(28).height(28).color((this.palette === 'PERSONAL' ? pageColor(this.palette, 'ink') : $r('app.color.random_ink'))) }
        Text(this.message).fontSize(14).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted'))).width('100%').textAlign(TextAlign.Center)
        if (this.confirmed()) {
          Text(this.nextMealReady(this.mealNow) ? '已满6小时，可以重新抽下一餐。' : '还需' + this.nextMealRemaining() + '，即可抽下一餐。')
            .fontSize(14).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'ink') : $r('app.color.random_ink'))).width('100%').textAlign(TextAlign.Center)
          Text('下一餐可抽取时间：' + new Date(this.nextMealAt()).toLocaleString())
            .fontSize(12).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted'))).width('100%').textAlign(TextAlign.Center)
        }
        Button(this.drawLabel())
          .attributeModifier(this.drawStyle()).width('100%')
          .enabled(!this.busy && (this.round === undefined || this.round.pendingCardId.length === 0) &&
            (!this.confirmed() || this.nextMealReady(this.mealNow)))
          .onClick((): void => { void this.draw(this.round !== undefined && this.round.ended); })
        if (this.round !== undefined && this.round.pendingCardId.length > 0 && this.cards.length === 0) {
          Button('重试保存上次选择').attributeModifier(new RandomPrimaryStyle(this.palette)).width('100%').enabled(!this.busy)
            .onClick((): void => { void this.choose(); })
        }
        if (this.confirmed() && this.round !== undefined) {
          Text('本餐选定时间：' + new Date(this.round.selectedAt).toLocaleString()).fontSize(12).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted')))
          if (this.owner === 'guest') { Button('登录后使用选择记录').attributeModifier(new RandomSecondaryStyle(this.palette)).width('100%').onClick((): void => this.onLogin()) }
        }
        Button(this.round === undefined || this.round.preparedAt === 0 ? '本轮最多60张 · 池内随机' :
          '本轮已翻' + this.round.shownCount.toString() + '张 · 候选池' + this.round.cardIds.length.toString() + '张')
          .constraintSize({ minHeight: 48 }).backgroundColor(Color.Transparent).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted'))).fontSize(12)
          .onClick((): void => { this.rangeOpen = !this.rangeOpen; })
        if (this.rangeOpen) {
          Text((this.round === undefined || this.round.rangeLabel.length === 0 ? '每轮最多60张；从明确范围准备候选，不覆盖来源全部卡片。' : this.round.rangeLabel) +
            '。池内等概率，每次三张、本轮不重复；新增卡片下一轮加入，不可用卡片即时跳过。')
            .fontSize(12).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted'))).width('100%')
        }
        Button(!this.motion ? '页面动效：关 · 点此开启' : this.systemReduced ? '当前使用减少动态 · 点此关闭页面动效' :
          '页面动效：开 · 点此关闭').constraintSize({ minHeight: 48 })
          .backgroundColor(Color.Transparent).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted'))).fontSize(12).onClick((): void => { void this.toggleMotion(); })
      }.width('100%').constraintSize({ maxWidth: 560 }).padding({ left: 20, right: 20, top: 8, bottom: 24 })
    }.width('100%').height('100%').backgroundColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'canvas') : $r('app.color.random_canvas')))
  }
}
