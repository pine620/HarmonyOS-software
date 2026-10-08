import { common } from '@kit.AbilityKit';
import { FoodCard } from '../model/CloudContracts';
import { CardRepository } from '../repository/CardRepository';
import { AuthService } from '../service/AuthService';
import { AuthSessionStore } from '../service/AuthSessionStore';
import { CardVisit, CardVisitStore } from '../service/CardVisitStore';
import { PersonalPreviewLoader, PersonalPreviewRow, PersonalPreviewSource } from '../service/PersonalPreviewLoader';
import { PersonalPreviewTile } from '../components/PersonalPreviewTile';
import { ErrorDetail, errorText } from '../common/ErrorKit';
import { ReadRequestOptions } from '../service/ReadScheduler';

@Component
export struct CardHistoryPage {
  onOpenCard: (card: FoodCard) => void = (_card: FoodCard): void => {};
  @StorageLink('stage47AppActive') @Watch('onEnvironmentChanged') appActive: boolean = true;
  @StorageLink('accountContentRevision') @Watch('onEnvironmentChanged') accountContentRevision: number = 0;
  @State count: number = 0;
  @State opening: boolean = false;
  @State clearPending: boolean = false;
  @State message: string = '';
  private source: PersonalPreviewSource = new PersonalPreviewSource();
  private previews: PersonalPreviewLoader = new PersonalPreviewLoader(this.source);
  private cards: CardRepository = new CardRepository();
  private active: boolean = false;
  private visible: boolean = false;
  private generation: number = 0;
  private owner: string = '';
  private session: number = 0;
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private valid(generation: number): boolean { return this.active && this.appActive && generation === this.generation &&
    this.owner === (AuthService.profile()?.uid || '') && this.session === AuthSessionStore.generation(); }
  private activate(): void {
    if (this.active || !this.appActive) return;
    this.active = true; this.generation++; this.owner = AuthService.profile()?.uid || ''; this.session = AuthSessionStore.generation();
    this.previews.reset(true); this.opening = false; this.message = '';
    try {
      const visits: Array<CardVisit> = CardVisitStore.list(this.context(), this.owner);
      this.source.setRows(visits.map((visit: CardVisit): PersonalPreviewRow => new PersonalPreviewRow(visit.cardId, visit.visitedAt)));
      this.count = visits.length; this.window(0, 5);
    } catch (error) { this.message = errorText(error as ErrorDetail); }
  }
  private deactivate(): void {
    this.active = false; this.generation++; this.previews.reset(false); this.source.setRows([]);
    this.count = 0; this.opening = false; this.clearPending = false;
  }
  private onEnvironmentChanged(): void { this.deactivate(); if (this.visible && this.appActive) this.activate(); }
  aboutToDisappear(): void { this.visible = false; this.deactivate(); }
  private window(first: number, last: number): void { if (this.active) this.previews.window(this.context(), first, last, true); }
  private refresh(): void { this.deactivate(); this.activate(); }
  private clear(): void {
    if (!this.active || this.owner.length === 0) return;
    try { CardVisitStore.clear(this.context(), this.owner); this.deactivate(); this.activate(); this.message = '本机浏览记录已清空。'; }
    catch (error) { this.message = errorText(error as ErrorDetail); }
  }
  private async open(cardId: string): Promise<void> {
    if (!this.active || this.opening) return;
    const generation: number = this.generation; this.opening = true;
    try {
      const options: ReadRequestOptions = { mayContinue: async (): Promise<boolean> => this.valid(generation) };
      const card: FoodCard = await this.cards.detail(this.context(), cardId, options);
      if (!this.valid(generation)) return;
      CardVisitStore.backfillCover(this.context(), this.owner, card); this.onOpenCard(card);
    } catch (error) { if (this.valid(generation)) { this.refresh(); this.message = errorText(error as ErrorDetail); } }
    finally { if (this.valid(generation)) this.opening = false; }
  }
  build() {
    NavDestination() {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 3 }) {
            Text(`浏览记录 · ${this.count} 条`).fontSize(18).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'));
            Text('仅保存在本机，最多保留最近 100 张卡片').fontSize(12).fontColor($r('app.color.muted'));
          }.layoutWeight(1).alignItems(HorizontalAlign.Start);
          Button(this.clearPending ? '取消' : '清空').constraintSize({ minWidth: 48, minHeight: 48 })
            .fontSize(12).backgroundColor(Color.Transparent).fontColor($r('app.color.danger'))
            .enabled(this.count > 0 && !this.opening).onClick((): void => { this.clearPending = !this.clearPending; });
        }.width('100%').padding(12).backgroundColor($r('app.color.surface')).borderRadius(16);
        if (this.clearPending) { Button('确认清空本机浏览记录').width('100%').constraintSize({ minHeight: 48 })
          .backgroundColor($r('app.color.danger_action')).fontColor($r('app.color.on_danger_action'))
          .onClick((): void => this.clear()); }
        if (this.message.length > 0) { Text(this.message).fontSize(13).fontColor($r('app.color.muted')).width('100%'); }
        Button('重新读取预览').constraintSize({ minHeight: 48 }).fontSize(13).enabled(!this.opening)
          .fontColor($r('app.color.action_text')).backgroundColor(Color.Transparent).onClick((): void => this.refresh());
        if (this.count === 0) { Text('还没有本机浏览记录').fontSize(16).fontColor($r('app.color.muted')).width('100%').padding(20); }
        List({ space: 10 }) {
          LazyForEach(this.source, (row: PersonalPreviewRow): void => {
            ListItem() { PersonalPreviewTile({ row, busy: this.opening,
              onOpen: (cardId: string): void => { void this.open(cardId); } }); }
          }, (row: PersonalPreviewRow): string => row.cardId);
        }.width('100%').layoutWeight(1).cachedCount(2).onScrollIndex((first: number, last: number): void => this.window(first, last));
      }.width('100%').height('100%').padding({ left: 16, right: 16, top: 8, bottom: 12 })
        .backgroundColor($r('app.color.canvas')).alignItems(HorizontalAlign.Start);
    }.title('浏览记录').onShown((): void => { this.visible = true; this.activate(); })
      .onHidden((): void => { this.visible = false; this.deactivate(); });
  }
}
