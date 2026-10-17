/**
 * 【文件职责】「今日吃什么」选择记录页面：按天分组列出历史选择（list-food-choices），可预览卡片、删除记录。
 */
import { PagePaletteName, pageColor } from '../common/PagePaletteUi';
import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import { cardPriceText } from '../model/CardPrice';
import { FoodChoiceItem, FoodChoicePage, randomFoodSourceLabel } from '../model/RandomFoodModels';
import { RandomPrimaryStyle, RandomSecondaryStyle, RandomFoodMotionObserver, randomFoodTransition,
  randomFoodAccountUnavailable } from '../common/RandomFoodUi';
import { stage47ErrorText } from '../common/Stage47Ui';
import { RandomFoodRepository } from '../repository/RandomFoodRepository';
import { CardRepository } from '../repository/CardRepository';
import { ContentPageGuard, ContentPageTicket } from '../service/ContentPageGuard';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { CloudBusinessError } from '../service/CloudReadErrors';
import { RandomFoodRoundStore } from '../service/RandomFoodRoundStore';

// 选择记录页面。
@Component
export struct FoodChoiceHistoryPage {
  @Prop palette: PagePaletteName = 'NOTE';
  @Prop @Watch('onVisibilityChanged') navigationVisible: boolean = true;
  @StorageLink('stage47AppActive') @Watch('onActiveChanged') appActive: boolean = true;
  @StorageLink('accountContentRevision') @Watch('onRevisionChanged') accountRevision: number = 0;
  onBack: () => void = (): void => {};
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  onLogin: () => void = (): void => {};
  @State items: Array<FoodChoiceItem> = [];
  @State busy: boolean = false;
  @State message: string = '';
  @State nextCursor: string = '';
  @State deletingId: string = '';
  @State loaded: boolean = false;
  @State motion: boolean = false;
  @State systemReduced: boolean = true;
  private active: boolean = false;
  private motionObserver: RandomFoodMotionObserver = new RandomFoodMotionObserver((reduced: boolean): void => {
    if (this.active) this.systemReduced = reduced;
  });
  private guard: ContentPageGuard = new ContentPageGuard();
  private repo: RandomFoodRepository = new RandomFoodRepository();
  private cardRepo: CardRepository = new CardRepository();
  // 取得 UIAbility 上下文。
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  // 是否允许动画（用户开关且系统未减弱动态效果）。
  private motionAllowed(): boolean { return this.motion && !this.systemReduced; }
  // 显示错误提示。
  private showError(error: Object, fallback: string): void {
    if (randomFoodAccountUnavailable(error)) { this.items = []; this.nextCursor = ''; this.deletingId = ''; this.loaded = false; }
    this.message = stage47ErrorText(error, fallback);
  }
  // 出现时恢复。
  aboutToAppear(): void { this.resume(); }
  // 消失时暂停。
  aboutToDisappear(): void { this.pause(); }
  // 导航可见性变化时暂停 / 恢复。
  private onVisibilityChanged(): void { if (this.navigationVisible) this.resume(); else this.pause(); }
  // App 前后台切换时暂停 / 恢复。
  private onActiveChanged(): void { if (this.appActive) this.resume(); else this.pause(); }
  // 账号内容变化时重新加载。
  private onRevisionChanged(): void { this.pause(); this.resume(); }
  // 暂停：作废进行中的加载。
  private pause(): void {
    this.active = false; this.motionObserver.stop(); this.guard.close(); this.items = []; this.busy = false;
    this.deletingId = ''; this.loaded = false;
  }
  // 恢复：加载第一页。
  private resume(): void {
    if (this.active || !this.navigationVisible || !this.appActive) return;
    this.active = true; this.guard.open();
    this.systemReduced = this.motionObserver.start();
    try { this.motion = RandomFoodRoundStore.motionEnabled(this.context()); } catch (_error) { this.motion = false; }
    if (AccountRequestGuard.owner().length === 0) { this.message = '登录后查看你的云端选择记录。'; return; }
    void this.load(true);
  }
  // 加载一页（reset=true 时从头开始）。
  private async load(reset: boolean): Promise<void> {
    if (this.busy) return;
    const ticket: ContentPageTicket = this.guard.ticket(); this.busy = true;
    try {
      const page: FoodChoicePage = await this.repo.history(reset ? '' : this.nextCursor, this.guard.options(ticket));
      if (!this.guard.valid(ticket)) return;
      const existing: Set<string> = new Set<string>(reset ? [] : this.items.map((item: FoodChoiceItem): string => item.historyId));
      const added: Array<FoodChoiceItem> = page.items.filter((item: FoodChoiceItem): boolean => !existing.has(item.historyId));
      this.items = reset ? added : this.items.concat(added); this.nextCursor = page.nextCursor;
      this.loaded = true;
      this.message = this.items.length === 0 ? '还没有确认过的选择，去翻三张吧。' : '只记录你点击“就吃这个”的选择。';
      const cards: Array<FoodCard> = [];
      for (const item of added) if (item.card !== null) cards.push(item.card);
      void this.cardRepo.hydrateNearbyPrimaryPhotoUrls(this.context(), cards, 0, cards.length, 'normal',
        async (): Promise<boolean> => this.guard.valid(ticket), (card: FoodCard): void => {
          if (this.guard.valid(ticket) && this.items.some((item: FoodChoiceItem): boolean => item.card === card)) this.items = this.items.slice();
        }, (card: FoodCard): boolean => this.items.some((item: FoodChoiceItem): boolean => item.card === card))
        .catch((): void => {});
    } catch (error) { if (this.guard.valid(ticket)) this.showError(error as Object, '记录暂不可读取，请刷新重试。'); }
    finally { if (this.guard.valid(ticket)) this.busy = false; }
  }
  // 删除选中的记录。
  private async remove(): Promise<void> {
    if (this.busy || this.deletingId.length === 0) return;
    const id: string = this.deletingId, ticket: ContentPageTicket = this.guard.ticket(); this.busy = true;
    try {
      await this.repo.remove(id);
      if (!this.guard.valid(ticket)) return;
      this.items = this.items.filter((item: FoodChoiceItem): boolean => item.historyId !== id); this.deletingId = '';
      RandomFoodRoundStore.markRecordDeleted(this.context(), 'user:' + AccountRequestGuard.owner(), id);
      this.message = '选择记录已删除。';
    } catch (error) { if (this.guard.valid(ticket)) this.showError(error as Object, '删除尚未确认，请重试。'); }
    finally { if (this.guard.valid(ticket)) this.busy = false; }
  }
  // 预览记录对应的卡片。
  private async preview(item: FoodChoiceItem): Promise<void> {
    if (this.busy || item.card === null) return;
    const cardId: string = item.card.id, ticket: ContentPageTicket = this.guard.ticket(); this.busy = true;
    try {
      const card: FoodCard = await this.cardRepo.detail(this.context(), cardId, this.guard.options(ticket));
      if (this.guard.valid(ticket)) this.onOpenCard(card);
    } catch (error) {
      if (this.guard.valid(ticket)) {
        if (error instanceof CloudBusinessError && ['CONTENT_UNAVAILABLE', 'CONTENT_ACCESS_DENIED', 'NOT_FOUND'].includes(error.code)) {
          item.card = null; this.items = this.items.slice();
        }
        this.showError(error as Object, '卡片暂不可读取，请重试。');
      }
    } finally { if (this.guard.valid(ticket)) this.busy = false; }
  }
  // 日期分组标题。
  private day(value: number): string {
    const date: Date = new Date(value), today: Date = new Date();
    const yesterday: Date = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1);
    if (date.toDateString() === today.toDateString()) return '今天';
    if (date.toDateString() === yesterday.toDateString()) return '昨天';
    return date.getFullYear().toString() + '年' + (date.getMonth() + 1).toString() + '月' + date.getDate().toString() + '日';
  }
  // 该行是否为新一天的第一行（需要显示日期标题）。
  private groupStarts(item: FoodChoiceItem, index: number): boolean { return index === 0 || this.day(item.selectedAt) !== this.day(this.items[index - 1].selectedAt); }
  // 卡片名称（卡片已不可用时给出提示）。
  private name(item: FoodChoiceItem): string { return item.card === null ? '卡片已不可用' : item.card.productName; }
  // 封面地址。
  private photo(item: FoodChoiceItem): string { return item.card === null ? '' : item.card.photoUrl; }
  // 店铺名称。
  private merchant(item: FoodChoiceItem): string {
    return item.card === null ? '原卡片当前不可展示' : item.card.merchantNameSnapshot || item.card.shop || '未关联店铺';
  }
  // 价格文本。
  private price(item: FoodChoiceItem): string { return item.card === null ? '' : cardPriceText(item.card); }
  // 选择时间。
  private time(item: FoodChoiceItem): string {
    const date: Date = new Date(item.selectedAt);
    return date.getHours().toString().padStart(2, '0') + ':' + date.getMinutes().toString().padStart(2, '0');
  }
  // 列表行的渲染键。
  private rowKey(item: FoodChoiceItem, index: number): string {
    const parts: Array<string> = [item.historyId, this.groupStarts(item, index) ? this.day(item.selectedAt) : '',
      this.name(item), this.photo(item), this.merchant(item), this.price(item), item.card === null ? '' : item.card.contentRevision || '',
      String(item.card !== null && item.card.primaryPhotoResolved === true),
      String(item.card !== null && item.card.primaryPhotoLoadFailed === true), String(this.deletingId === item.historyId)];
    return JSON.stringify(parts);
  }
  // 一行记录。
  @Builder private row(item: FoodChoiceItem) {
    Row({ space: 12 }) {
      if (this.photo(item).length > 0) {
        Image(this.photo(item)).width(80).height(80).objectFit(ImageFit.Cover).borderRadius(10).syncLoad(false)
          .accessibilityText(this.name(item) + '实拍图，查看卡片').onClick((): void => { void this.preview(item); })
      } else {
        Text(item.card === null ? '不可用' : '实拍图').fontSize(12).textAlign(TextAlign.Center).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted')))
          .width(80).height(80).backgroundColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'soft') : $r('app.color.random_soft'))).borderRadius(10)
          .onClick((): void => { void this.preview(item); })
      }
      Column({ space: 6 }) {
        Text(this.name(item)).fontSize(16).fontWeight(FontWeight.Bold).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'ink') : $r('app.color.random_ink'))).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        Text(this.merchant(item)).fontSize(12).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted'))).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        if (this.price(item).length > 0) {
          Text(this.price(item)).fontSize(14).fontWeight(FontWeight.Medium).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'action') : $r('app.color.random_accent'))).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
        Text(randomFoodSourceLabel(item.source) + ' · ' + this.time(item)).fontSize(12).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted'))).width('100%')
      }.layoutWeight(1).constraintSize({ minHeight: 48 }).alignItems(HorizontalAlign.Start).onClick((): void => { void this.preview(item); })
        .accessibilityText(this.name(item) + '，' + new Date(item.selectedAt).toLocaleString())
      Button() {
        Image($r('app.media.ic_random_food_delete')).width(22).height(22).accessibilityLevel('no')
      }.type(ButtonType.Normal).width(48).height(48).borderRadius(8).backgroundColor(Color.Transparent)
        .enabled(!this.busy).accessibilityText('删除这条选择记录')
        .onClick((): void => { this.deletingId = item.historyId; })
    }.width('100%').padding({ top: 16, bottom: 16 })
  }
  // 删除确认弹层。
  @Builder private deletePrompt() {
    Column({ space: 10 }) {
      Text('删除这条选择记录？').fontSize(16).fontWeight(FontWeight.Bold).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'ink') : $r('app.color.random_ink')))
      Row({ space: 8 }) {
        Button('取消').attributeModifier(new RandomSecondaryStyle(this.palette)).layoutWeight(1).enabled(!this.busy)
          .onClick((): void => { this.deletingId = ''; })
        Button('确认删除').attributeModifier(new RandomPrimaryStyle(this.palette)).layoutWeight(1).enabled(!this.busy)
          .onClick((): void => { void this.remove(); })
      }.width('100%')
    }.padding(16).width('100%').backgroundColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'soft') : $r('app.color.random_soft'))).borderRadius(12)
      .transition(randomFoodTransition(this.motionAllowed(), 'RECORD'))
  }
  // 页面布局。
  build() {
    Scroll() {
      Column({ space: 12 }) {
        Row({ space: 8 }) {
          Button('‹').fontSize(30).width(48).height(48).backgroundColor(Color.Transparent).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'ink') : $r('app.color.random_ink')))
            .accessibilityText('返回').onClick((): void => this.onBack())
          Text('选择记录').fontSize(19).fontWeight(FontWeight.Bold).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'ink') : $r('app.color.random_ink'))).layoutWeight(1)
          Button('刷新').constraintSize({ minWidth: 48, minHeight: 48 }).backgroundColor(Color.Transparent).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted')))
            .enabled(!this.busy && AccountRequestGuard.owner().length > 0).onClick((): void => { void this.load(true); })
        }.width('100%')
        Text('已选 / CHOICES').fontSize(12).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'action') : $r('app.color.random_accent'))).accessibilityLevel('no').margin({ top: 8 })
        Text('选过的好味道').fontSize(28).fontWeight(FontWeight.Bold).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'ink') : $r('app.color.random_ink'))).width('100%')
        if (this.busy) { LoadingProgress().width(28).height(28).color((this.palette === 'PERSONAL' ? pageColor(this.palette, 'ink') : $r('app.color.random_ink'))) }
        Text(this.message).fontSize(13).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted'))).width('100%')
        if (AccountRequestGuard.owner().length === 0) {
          Button('登录查看记录').attributeModifier(new RandomPrimaryStyle(this.palette)).width('100%').onClick((): void => this.onLogin())
        }
        if (this.loaded && this.items.length === 0 && !this.busy && AccountRequestGuard.owner().length > 0) {
          Column({ space: 16 }) {
            Image($r('app.media.ic_random_food_back')).width(96).height(96).accessibilityLevel('no')
            Text('下一餐，值得期待。').fontSize(20).fontWeight(FontWeight.Medium).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'ink') : $r('app.color.random_ink')))
            Text('选定以后，再把好味道留在这里。').fontSize(14).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'muted') : $r('app.color.random_muted'))).textAlign(TextAlign.Center)
          }.width('100%').padding({ top: 36, bottom: 36 })
            .transition(randomFoodTransition(this.motionAllowed(), 'RECORD'))
        }
        if (this.items.length > 0) {
          Column({ space: 0 }) {
            ForEach(this.items, (item: FoodChoiceItem, index: number): void => {
              if (this.groupStarts(item, index)) {
                Text(this.day(item.selectedAt)).fontSize(20).fontWeight(FontWeight.Medium).fontColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'ink') : $r('app.color.random_ink')))
                  .width('100%').margin({ top: 20, bottom: 4 })
              }
              this.row(item)
              if (this.deletingId === item.historyId) { this.deletePrompt() }
              Divider().strokeWidth(1).color((this.palette === 'PERSONAL' ? pageColor(this.palette, 'line') : $r('app.color.random_line'))).margin({ top: this.deletingId === item.historyId ? 12 : 0 })
            }, (item: FoodChoiceItem, index: number): string => this.rowKey(item, index))
          }.width('100%').alignItems(HorizontalAlign.Start).transition(randomFoodTransition(this.motionAllowed(), 'RECORD'))
        }
        if (this.nextCursor.length > 0) {
          Button('加载更多记录').attributeModifier(new RandomSecondaryStyle(this.palette)).width('100%').enabled(!this.busy).onClick((): void => { void this.load(false); })
        }
      }.width('100%').constraintSize({ maxWidth: 560 }).padding({ left: 20, right: 20, top: 8, bottom: 28 }).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').backgroundColor((this.palette === 'PERSONAL' ? pageColor(this.palette, 'canvas') : $r('app.color.random_canvas')))
  }
}
