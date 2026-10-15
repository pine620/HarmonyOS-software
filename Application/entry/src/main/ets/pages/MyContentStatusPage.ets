import { AppDestinationStyle } from '../common/AppPageUi';
import { QuietActionStyle, SecondaryActionStyle, stage47ErrorText, invalidatesProtectedPage } from '../common/Stage47Ui';
import { contentDate, contentStateLabel } from '../common/ContentStatusUi';
import { ContentStatusScope, ContentStatusRow, ContentStatusPage } from '../model/ContentStatusModels';
import { CardIdRequest } from '../model/CloudContracts';
import { ContentStatusRepository } from '../repository/ContentStatusRepository';
import { ContentPageGuard, ContentPageTicket } from '../service/ContentPageGuard';
import { PagedDataSource } from '../service/PagedDataSource';
@Component
export struct MyContentStatusPage {
  @Consume('pathStack') pathStack: NavPathStack;
  @Prop scope: ContentStatusScope = 'REPORTS';
  @StorageLink('stage47AppActive') @Watch('onEnvironmentChanged') appActive: boolean = true;
  @StorageLink('authSessionRevision') @Watch('onEnvironmentChanged') sessionRevision: number = 0;
  @StorageLink('accountContentRevision') @Watch('onEnvironmentChanged') contentRevision: number = 0;
  @State busy: boolean = false;
  @State message: string = '';
  @State cursor: string = '';
  @State count: number = 0;
  @State permitted: boolean = false;
  private visible: boolean = false;
  private guard: ContentPageGuard = new ContentPageGuard();
  private repo: ContentStatusRepository = new ContentStatusRepository();
  private source: PagedDataSource<ContentStatusRow> = new PagedDataSource<ContentStatusRow>();
  private title(): string { return this.scope === 'REPORTS' ? '我的举报' : '待修改内容'; }
  private clear(): void { this.guard.close(); this.message = ''; this.source.replace([]); this.count = 0; this.cursor = ''; this.permitted = false; this.busy = false; }
  private shown(): void { this.visible = true; this.clear(); if (this.appActive) { this.guard.open(); void this.load(false); } }
  private hidden(): void { this.visible = false; this.clear(); }
  aboutToDisappear(): void { this.hidden(); }
  private onEnvironmentChanged(): void { this.clear(); if (this.visible && this.appActive) { this.guard.open(); void this.load(false); } }
  private async load(more: boolean): Promise<void> {
    if (this.busy) return; const ticket: ContentPageTicket = this.guard.ticket(); if (!this.guard.valid(ticket)) return;
    this.busy = true; this.message = '正在读取…';
    try {
      // The RPC returns only the current account's content.
      const result: ContentStatusPage = await this.repo.queue(this.scope, more ? this.cursor : '', this.guard.options(ticket));
      if (!this.guard.valid(ticket)) return;
      this.permitted = true; this.source.merge(result.items, (row: ContentStatusRow): string => row.kind + ':' + row.id, more);
      this.count = this.source.totalCount(); this.cursor = result.nextCursor;
      this.message = result.items.length === 0 && result.nextCursor.length > 0 ? '本批没有匹配内容，可继续加载。' : this.count === 0 ? '暂无内容。' : '';
    } catch (error) { if (this.guard.valid(ticket)) { if (!more || invalidatesProtectedPage(error as Object)) { this.source.replace([]); this.count = 0; this.cursor = ''; this.permitted = false; } this.message = stage47ErrorText(error as Object, '读取失败，请重试。'); } }
    finally { if (this.guard.valid(ticket)) this.busy = false; }
  }
  private open(row: ContentStatusRow): void {
    if (!this.permitted || !this.guard.valid(this.guard.ticket())) return;
    if (this.scope === 'CORRECTIONS') { const request: CardIdRequest = { cardId: row.targetId }; this.pathStack.pushPathByName('review-correction', request); }
  }
  @Builder
  private row(row: ContentStatusRow) {
    Column({ space: 8 }) {
      Text(row.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.personal_ink')).width('100%')
      Text(contentStateLabel(row.state) + ' · ' + contentDate(row.createdAt)).fontSize(13).fontColor($r('app.color.personal_muted')).width('100%')
      if (row.reason.length > 0) { Text(row.reason).fontSize(14).fontColor($r('app.color.personal_ink')).width('100%') }
      if (this.scope !== 'REPORTS') {
        Button('修改并保存').width('100%').enabled(this.permitted && !this.busy)
          .attributeModifier(new SecondaryActionStyle('PERSONAL')).onClick((): void => this.open(row))
      }
    }.alignItems(HorizontalAlign.Start).width('100%').padding(14).backgroundColor($r('app.color.personal_surface')).borderRadius(16)
      .border({ width: 1, color: $r('app.color.personal_line') })
  }
  build() {
    NavDestination() {
      Column({ space: 12 }) {
        Text(this.message).fontSize(14).fontColor($r('app.color.personal_ink')).width('100%').accessibilityText(this.message)
        Button('刷新').width('100%').attributeModifier(new QuietActionStyle('PERSONAL')).enabled(!this.busy).onClick((): void => this.shown())
        List({ space: 12 }) {
          LazyForEach(this.source, (row: ContentStatusRow): void => { ListItem() { this.row(row) } }, (row: ContentStatusRow): string => row.kind + ':' + row.id)
          if (this.cursor.length > 0) { ListItem() { Button(this.busy ? '加载中…' : '加载更多').width('100%').enabled(!this.busy).attributeModifier(new SecondaryActionStyle('PERSONAL')).onClick((): void => { void this.load(true); }) } }
        }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
      }.padding(16).width('100%').height('100%').constraintSize({ maxWidth: 840 }).alignItems(HorizontalAlign.Start)
    }.attributeModifier(new AppDestinationStyle(this.title(), $r('app.color.personal_canvas'), $r('app.color.personal_header'), 'PERSONAL')).backgroundColor($r('app.color.personal_canvas')).onShown((): void => this.shown()).onHidden((): void => this.hidden())
  }
}
