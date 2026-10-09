import { util } from '@kit.ArkTS';
import { PrimaryActionStyle, QuietActionStyle, SecondaryActionStyle, stage47ErrorText, invalidatesProtectedPage } from '../common/Stage47Ui';
import { operationsDate } from '../common/OperationsUi';
import { DeletedCardRow, DeletedCardsPageResult, RestoreDeletedRequest } from '../model/OperationsModels';
import { OperationsRepository } from '../repository/OperationsRepository';
import { OperationsPageGuard, OperationsTicket } from '../service/OperationsPageGuard';
import { PagedDataSource } from '../service/PagedDataSource';
@Component
export struct DeletedCardsPage {
  @StorageLink('stage47AppActive') @Watch('onEnvironmentChanged') appActive: boolean = true;
  @StorageLink('authSessionRevision') @Watch('onEnvironmentChanged') sessionRevision: number = 0;
  @StorageLink('accountContentRevision') @Watch('onEnvironmentChanged') contentRevision: number = 0;
  @State busy: boolean = false; @State count: number = 0; @State cursor: string = ''; @State message: string = ''; @State retryCard: string = '';
  private visible: boolean = false; private guard: OperationsPageGuard = new OperationsPageGuard();
  private repo: OperationsRepository = new OperationsRepository(); private source: PagedDataSource<DeletedCardRow> = new PagedDataSource<DeletedCardRow>();
  private pending: RestoreDeletedRequest | undefined = undefined;
  private clear(): void { this.guard.close(); this.message = ''; this.source.replace([]); this.count = 0; this.cursor = ''; this.busy = false; this.pending = undefined; this.retryCard = ''; }
  private shown(): void { this.visible = true; this.clear(); if (this.appActive) { this.guard.open(); void this.load(false); } }
  private hidden(): void { this.visible = false; this.clear(); }
  aboutToDisappear(): void { this.hidden(); }
  private onEnvironmentChanged(): void { this.clear(); if (this.visible && this.appActive) { this.guard.open(); void this.load(false); } }
  private async load(more: boolean): Promise<void> {
    const ticket: OperationsTicket = this.guard.ticket(); if (this.busy || !this.guard.valid(ticket)) return;
    this.busy = true; this.message = '正在读取删除记录…';
    try { const result: DeletedCardsPageResult = await this.repo.deleted(more ? this.cursor : '', this.guard.options(ticket));
      if (!this.guard.valid(ticket)) return; this.source.merge(result.items, (row: DeletedCardRow): string => row.cardId, more);
      this.count = this.source.totalCount(); this.cursor = result.nextCursor;
      this.message = !result.lifecycleEnabled ? '恢复功能尚未开放。' : this.count === 0 ? this.cursor.length > 0 ? '本批没有删除记录，可继续加载。' : '暂无删除记录。' : '';
    } catch (error) { if (this.guard.valid(ticket)) { if (!more || invalidatesProtectedPage(error as Object)) { this.source.replace([]); this.count = 0; this.cursor = ''; } this.message = stage47ErrorText(error as Object, '读取失败。'); } }
    finally { if (this.guard.valid(ticket)) this.busy = false; }
  }
  private async restore(row: DeletedCardRow): Promise<void> {
    const ticket: OperationsTicket = this.guard.ticket(); if (this.busy || !row.canRestore || !this.guard.valid(ticket)) return;
    if (this.pending === undefined) { const request: RestoreDeletedRequest = { cardId: row.cardId, expectedVersion: row.version, requestId: util.generateRandomUUID() }; this.pending = request; }
    if (this.pending.cardId !== row.cardId) return; this.busy = true; this.retryCard = row.cardId;
    try { await this.repo.restore(this.pending); if (!this.guard.valid(ticket)) return;
      this.pending = undefined; this.retryCard = ''; this.source.replace(this.source.rows().filter((item: DeletedCardRow): boolean => item.cardId !== row.cardId));
      this.count = this.source.totalCount(); this.cursor = ''; this.message = '已恢复。可在我的卡片查看；继续查看记录请刷新。';
      AppStorage.setOrCreate('contentMutationRevision', (AppStorage.get<number>('contentMutationRevision') || 0) + 1);
    } catch (error) { if (this.guard.valid(ticket)) this.message = stage47ErrorText(error as Object, '恢复结果未确认，请重试原请求或刷新。'); }
    finally { if (this.guard.valid(ticket)) this.busy = false; }
  }
  @Builder
  private row(row: DeletedCardRow) {
    Column({ space: 8 }) {
      Text(row.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink')).width('100%')
      Text('删除于 ' + operationsDate(row.deletedAt)).fontSize(13).fontColor($r('app.color.muted')).width('100%')
      Text('可恢复截止：' + operationsDate(row.purgeAt)).fontSize(13).fontColor($r('app.color.muted')).width('100%')
      Button(row.canRestore ? this.retryCard === row.cardId ? '重试原恢复请求' : '恢复卡片' : '无法恢复').width('100%')
        .enabled(!this.busy && row.canRestore && (this.retryCard.length === 0 || this.retryCard === row.cardId)).attributeModifier(new PrimaryActionStyle())
        .onClick((): void => { void this.restore(row); })
    }.padding(14).width('100%').backgroundColor($r('app.color.surface')).borderRadius(16).alignItems(HorizontalAlign.Start)
  }
  build() {
    NavDestination() { Column({ space: 12 }) {
      Text('删除后保留 30 天；到期、已下架或已开始清理的卡片不可恢复。实际资格以服务端为准。').fontSize(14).fontColor($r('app.color.muted')).width('100%')
      Text(this.message).fontSize(14).fontColor($r('app.color.ink')).width('100%')
      Button('刷新记录').width('100%').enabled(!this.busy).attributeModifier(new QuietActionStyle()).onClick((): void => this.shown())
      List({ space: 12 }) {
        LazyForEach(this.source, (row: DeletedCardRow): void => { ListItem() { this.row(row) } }, (row: DeletedCardRow): string => row.cardId)
        if (this.cursor.length > 0) { ListItem() { Button(this.busy ? '读取中…' : '继续查找删除记录').width('100%').enabled(!this.busy && this.retryCard.length === 0).attributeModifier(new SecondaryActionStyle()).onClick((): void => { void this.load(true); }) } }
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
    }.padding(16).width('100%').height('100%').constraintSize({ maxWidth: 840 }).alignItems(HorizontalAlign.Start) }
      .title('删除记录').backgroundColor($r('app.color.canvas')).onShown((): void => this.shown()).onHidden((): void => this.hidden())
  }
}
