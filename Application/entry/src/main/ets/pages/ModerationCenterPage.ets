import { ChoiceActionStyle, QuietActionStyle, SecondaryActionStyle, stage47ErrorText } from '../common/Stage47Ui';
import { moderationKindLabel, operationsDate, operationsStateLabel } from '../common/OperationsUi';
import { ModerationKind, ModerationScope, ModerationRow, ModerationQueuePage, ModerationDetailRequest } from '../model/OperationsModels';
import { CardIdRequest } from '../model/CloudContracts';
import { OperationsRepository } from '../repository/OperationsRepository';
import { OperationsPageGuard, OperationsTicket } from '../service/OperationsPageGuard';
import { PagedDataSource } from '../service/PagedDataSource';
@Component
export struct ModerationCenterPage {
  @Consume('pathStack') pathStack: NavPathStack;
  @Prop scope: ModerationScope = 'ADMIN';
  @StorageLink('stage47AppActive') @Watch('onEnvironmentChanged') appActive: boolean = true;
  @StorageLink('authSessionRevision') @Watch('onEnvironmentChanged') sessionRevision: number = 0;
  @StorageLink('accountContentRevision') @Watch('onEnvironmentChanged') contentRevision: number = 0;
  @State kind: ModerationKind = 'CARD';
  @State busy: boolean = false;
  @State message: string = '';
  @State cursor: string = '';
  @State count: number = 0;
  @State permitted: boolean = false;
  private visible: boolean = false;
  private guard: OperationsPageGuard = new OperationsPageGuard();
  private repo: OperationsRepository = new OperationsRepository();
  private source: PagedDataSource<ModerationRow> = new PagedDataSource<ModerationRow>();
  private title(): string { return this.scope === 'ADMIN' ? '审核中心' : this.scope === 'REPORTS' ? '我的举报' : '待修改内容'; }
  private clear(): void { this.guard.close(); this.message = ''; this.source.replace([]); this.count = 0; this.cursor = ''; this.permitted = false; this.busy = false; }
  private shown(): void { this.visible = true; this.clear(); if (this.appActive) { this.guard.open(); void this.load(false); } }
  private hidden(): void { this.visible = false; this.clear(); }
  aboutToDisappear(): void { this.hidden(); }
  private onEnvironmentChanged(): void { this.clear(); if (this.visible && this.appActive) { this.guard.open(); void this.load(false); } }
  private select(kind: ModerationKind): void { if (this.busy || this.kind === kind) return; this.kind = kind; this.shown(); }
  private async load(more: boolean): Promise<void> {
    if (this.busy) return; const ticket: OperationsTicket = this.guard.ticket(); if (!this.guard.valid(ticket)) return;
    this.busy = true; this.message = '正在读取…';
    try {
      // The queue RPC validates the role itself, avoiding a redundant capability read.
      const result: ModerationQueuePage = await this.repo.queue(this.scope, this.kind, more ? this.cursor : '', this.guard.options(ticket));
      if (!this.guard.valid(ticket)) return;
      this.permitted = true; this.source.merge(result.items, (row: ModerationRow): string => row.kind + ':' + row.id, more);
      this.count = this.source.totalCount(); this.cursor = result.nextCursor;
      this.message = result.items.length === 0 && result.nextCursor.length > 0 ? '本批没有匹配内容，可继续加载。' : this.count === 0 ? '暂无内容。' : '';
    } catch (error) { if (this.guard.valid(ticket)) { this.source.replace([]); this.count = 0; this.cursor = ''; this.permitted = false; this.message = stage47ErrorText(error as Object, '读取失败，请重试。'); } }
    finally { if (this.guard.valid(ticket)) this.busy = false; }
  }
  private open(row: ModerationRow): void {
    if (!this.permitted || !this.guard.valid(this.guard.ticket())) return;
    if (this.scope === 'ADMIN') { const request: ModerationDetailRequest = { kind: row.kind, id: row.id }; this.pathStack.pushPathByName('moderation-detail', request); }
    if (this.scope === 'CORRECTIONS') { const request: CardIdRequest = { cardId: row.targetId }; this.pathStack.pushPathByName('review-correction', request); }
  }
  @Builder
  private kindButton(kind: ModerationKind) {
    Button(moderationKindLabel(kind)).layoutWeight(1).constraintSize({ minHeight: 48 }).enabled(!this.busy)
      .attributeModifier(new ChoiceActionStyle(this.kind === kind)).onClick((): void => this.select(kind))
  }
  @Builder
  private row(row: ModerationRow) {
    Column({ space: 8 }) {
      Text(row.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink')).width('100%')
      Text(operationsStateLabel(row.state) + ' · ' + operationsDate(row.createdAt)).fontSize(13).fontColor($r('app.color.muted')).width('100%')
      if (row.reason.length > 0) { Text(row.reason).fontSize(14).fontColor($r('app.color.ink')).width('100%') }
      if (this.scope !== 'REPORTS') {
        Button(this.scope === 'ADMIN' ? '查看审核详情' : '修改并重新提交').width('100%').enabled(this.permitted && !this.busy)
          .attributeModifier(new SecondaryActionStyle()).onClick((): void => this.open(row))
      }
    }.alignItems(HorizontalAlign.Start).width('100%').padding(14).backgroundColor($r('app.color.surface')).borderRadius(16)
      .border({ width: 1, color: $r('app.color.line') })
  }
  build() {
    NavDestination() {
      Column({ space: 12 }) {
        if (this.scope === 'ADMIN') {
          Row({ space: 8 }) { this.kindButton('CARD'); this.kindButton('REVISION') }.width('100%')
          Row({ space: 8 }) { this.kindButton('MERCHANT'); this.kindButton('REPORT') }.width('100%')
          Button('清理任务管理').width('100%').attributeModifier(new QuietActionStyle()).enabled(this.permitted)
            .onClick((): void => this.pathStack.pushPathByName('lifecycle-jobs', null))
        }
        Text(this.message).fontSize(14).fontColor($r('app.color.ink')).width('100%').accessibilityText(this.message)
        Button('刷新').width('100%').attributeModifier(new QuietActionStyle()).enabled(!this.busy).onClick((): void => this.shown())
        List({ space: 12 }) {
          LazyForEach(this.source, (row: ModerationRow): void => { ListItem() { this.row(row) } }, (row: ModerationRow): string => row.kind + ':' + row.id)
          if (this.cursor.length > 0) { ListItem() { Button(this.busy ? '加载中…' : '加载更多').width('100%').enabled(!this.busy).attributeModifier(new SecondaryActionStyle()).onClick((): void => { void this.load(true); }) } }
        }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
      }.padding(16).width('100%').height('100%').constraintSize({ maxWidth: 840 }).alignItems(HorizontalAlign.Start)
    }.title(this.title()).backgroundColor($r('app.color.canvas')).onShown((): void => this.shown()).onHidden((): void => this.hidden())
  }
}
