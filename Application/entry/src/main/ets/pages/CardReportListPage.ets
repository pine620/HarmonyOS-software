import { PagePaletteName, pageColor } from '../common/PagePaletteUi';
import { NoteActionStyle, WarmNoteBackdrop } from '../common/WarmNoteUi';
import { ChoiceActionStyle } from '../common/Stage47Ui';
import { AppDestinationStyle, AppPageSurface } from '../common/AppPageUi';
import { contentDate } from '../common/ContentStatusUi';
import { stage47ErrorText } from '../common/Stage47Ui';
import { CardReportPhoto } from '../components/CardReportPhoto';
import { CardReportStatus, CardReportRow, CardReportList, CardReportRoute, CardReportAccess, cardReportOutcome } from '../model/CardReportModels';
import { CardReportRepository } from '../repository/CardReportRepository';
import { ContentPageGuard, ContentPageTicket } from '../service/ContentPageGuard';
import { PagedDataSource } from '../service/PagedDataSource';
type CardReportAccessState = 'CHECKING' | 'ALLOWED' | 'DENIED' | 'ERROR';
interface CardReportAccessError { code?: string | number; }
@Component
export struct CardReportListPage {
  @Prop palette: PagePaletteName = AppPageSurface.palette;
  @Consume('pathStack') pathStack: NavPathStack;
  @Prop admin: boolean = false;
  @StorageLink('stage47AppActive') @Watch('onEnvironmentChanged') appActive: boolean = true;
  @StorageLink('authSessionRevision') @Watch('onEnvironmentChanged') sessionRevision: number = 0;
  @StorageLink('accountContentRevision') @Watch('onEnvironmentChanged') contentRevision: number = 0;
  @State status: CardReportStatus = 'PENDING';
  @State count: number = 0;
  @State cursor: string = '';
  @State busy: boolean = false;
  @State message: string = '';
  @State permitted: boolean = false;
  @State accessState: CardReportAccessState = 'CHECKING';
  private visible: boolean = false;
  private source: PagedDataSource<CardReportRow> = new PagedDataSource<CardReportRow>();
  private guard: ContentPageGuard = new ContentPageGuard();
  private repo: CardReportRepository = new CardReportRepository();
  private clear(): void { this.source.replace([]); this.count = 0; this.cursor = ''; this.busy = false; this.message = ''; this.permitted = false; this.accessState = 'CHECKING'; }
  private shown(): void { this.visible = true; this.reset(); }
  private hidden(): void { this.visible = false; this.guard.close(); this.clear(); }
  aboutToDisappear(): void { this.hidden(); }
  private onEnvironmentChanged(): void { this.reset(); }
  private reset(): void {
    this.guard.close(); this.clear();
    if (!this.visible || !this.appActive) return;
    this.guard.open();
    if (this.admin && this.guard.ticket().owner.length === 0) {
      this.accessState = 'DENIED'; this.message = '当前未登录，没有管理员权限。请使用已授权的管理员账号登录后再试。'; return;
    }
    void this.load(false);
  }
  private select(status: CardReportStatus): void { if (this.busy || this.status === status) return; this.status = status; this.reset(); }
  private async load(more: boolean): Promise<void> {
    const ticket: ContentPageTicket = this.guard.ticket(); if (this.busy || !this.guard.valid(ticket)) return;
    this.busy = true; this.message = this.admin && !this.permitted ? '正在校验管理员权限…' : '正在读取…';
    try {
      if (this.admin && !this.permitted) {
        const access: CardReportAccess = await this.repo.access(this.guard.options(ticket));
        if (!this.guard.valid(ticket)) return;
        if (!access.allowed) {
          this.clear(); this.accessState = 'DENIED'; this.message = '当前账号没有管理员权限，无法查看和处理卡片举报。'; return;
        }
        this.message = '正在读取举报…';
      }
      const result: CardReportList = await this.repo.list(this.admin, this.status, more ? this.cursor : '', this.guard.options(ticket));
      if (!this.guard.valid(ticket)) return;
      this.source.merge(result.items, (row: CardReportRow): string => row.id, more); this.count = this.source.totalCount();
      this.cursor = result.nextCursor; this.permitted = true; this.accessState = 'ALLOWED';
      this.message = result.items.length === 0 && this.cursor.length > 0 ? '本批没有匹配记录，可继续加载。' : this.count === 0 ? this.status === 'PENDING' ? '暂时没有待处理举报。' : '暂时没有已处理举报。' : '';
    } catch (error) {
      if (this.guard.valid(ticket)) {
        const detail: CardReportAccessError = error as CardReportAccessError;
        const code: string = String(detail.code || '');
        this.clear();
        if (this.admin && ['ADMIN_REQUIRED', 'AUTH_REQUIRED', 'ACCOUNT_INACTIVE', 'ACCOUNT_DELETED'].includes(code)) {
          this.accessState = 'DENIED';
          this.message = code === 'ADMIN_REQUIRED' ? '当前账号没有管理员权限，无法查看和处理卡片举报。' : '当前登录状态无法使用管理员系统，请使用已授权的管理员账号重新登录。';
        } else {
          this.accessState = 'ERROR'; this.message = stage47ErrorText(error as Object, '读取失败，请刷新重试。');
        }
      }
    }
    finally { if (this.guard.valid(ticket)) this.busy = false; }
  }
  private open(row: CardReportRow): void {
    if (!this.permitted || !this.guard.valid(this.guard.ticket())) return;
    const route: CardReportRoute = { reportId: row.id }; this.pathStack.pushPathByName(this.admin ? 'card-review-detail' : 'report-detail', route);
  }
  @Builder private reportCard(row: CardReportRow) {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        if ((row.previewMediaId || '').length > 0) {
          Column() { CardReportPhoto({ mediaId: row.previewMediaId || '', reportId: row.id, admin: this.admin }) }.width(76).height(76)
        } else { Image($r('app.media.ic_discovery_all')).width(56).height(56).padding(10).backgroundColor(pageColor(this.palette, 'soft')).borderRadius(16).accessibilityLevel('no') }
        Column({ space: 6 }) {
          Text(row.cardTitle).fontSize(18).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(contentDate(row.createdAt)).fontSize(12).fontColor(pageColor(this.palette, 'muted'))
          Text(row.status === 'PENDING' ? '待处理' : cardReportOutcome(row.resolutionAction)).fontSize(12).fontColor(pageColor(this.palette, 'action'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      Text('举报类型 · ' + row.reasonLabel).fontSize(14).fontColor(pageColor(this.palette, 'ink')).width('100%')
      if (row.description.length > 0) { Text(row.description).fontSize(14).lineHeight(21).fontColor(pageColor(this.palette, 'muted')).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%') }
      if (row.status === 'RESOLVED') { Text('处理说明 · ' + (row.resolutionReason || '已结束处理')).fontSize(13).fontColor(pageColor(this.palette, 'muted')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%') }
      Button(this.admin ? '查看卡片与举报详情' : '查看处理进度').width('100%').enabled(this.permitted && !this.busy)
        .attributeModifier(new NoteActionStyle(false, this.palette)).onClick((): void => this.open(row))
    }.width('100%').padding(18).alignItems(HorizontalAlign.Start).backgroundColor(pageColor(this.palette, 'surface')).borderRadius(24)
      .border({ width: 1, color: pageColor(this.palette, 'line') })
  }
  private accessTitle(): string {
    if (this.accessState === 'DENIED') return '暂无权限';
    if (this.accessState === 'ERROR') return '暂时无法打开';
    return '正在打开管理员系统';
  }
  @Builder private accessNotice() {
    Column({ space: 16 }) {
      if (this.busy) { LoadingProgress().width(36).height(36).color(pageColor(this.palette, 'action')) }
      Text(this.accessTitle()).fontSize(21).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink')).width('100%')
      Text(this.message).fontSize(15).lineHeight(23).fontColor(pageColor(this.palette, 'muted')).width('100%')
      if (!this.busy) {
        Button('返回设置').width('100%').attributeModifier(new NoteActionStyle(false, this.palette)).onClick((): void => { this.pathStack.pop(); })
      }
    }.width('100%').padding(24).alignItems(HorizontalAlign.Start).backgroundColor(pageColor(this.palette, 'surface')).borderRadius(24)
      .border({ width: 1, color: pageColor(this.palette, 'line') }).accessibilityGroup(true)
      .accessibilityText(this.accessTitle() + '。' + this.message)
  }
  build() {
    NavDestination() { Stack({ alignContent: Alignment.TopStart }) { WarmNoteBackdrop({ palette: this.palette })
      Column({ space: 14 }) {
        Row() { Text(this.admin ? '卡片举报审核' : '我的举报').fontSize(25).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink')).layoutWeight(1)
          Button('刷新').enabled(!this.busy).attributeModifier(new NoteActionStyle(false, this.palette)).onClick((): void => this.reset()) }.width('100%')
        Text(this.admin ? '逐条核对举报，记录处理结果。' : '在这里查看卡片举报的处理进度。').fontSize(14).fontColor(pageColor(this.palette, 'muted')).width('100%')
        if (this.admin && !this.permitted) {
          this.accessNotice()
        } else {
          Row({ space: 10 }) {
            Button('待处理').layoutWeight(1).enabled(!this.busy).attributeModifier(new ChoiceActionStyle(this.status === 'PENDING', this.palette)).onClick((): void => this.select('PENDING'))
            Button('已处理').layoutWeight(1).enabled(!this.busy).attributeModifier(new ChoiceActionStyle(this.status === 'RESOLVED', this.palette)).onClick((): void => this.select('RESOLVED'))
          }.width('100%')
          if (this.message.length > 0) { Text(this.message).fontSize(14).fontColor(pageColor(this.palette, 'ink')).width('100%') }
          List({ space: 14 }) {
            LazyForEach(this.source, (row: CardReportRow): void => { ListItem() { this.reportCard(row) } }, (row: CardReportRow): string => row.id + ':' + row.updatedAt)
            if (this.cursor.length > 0) { ListItem() { Button(this.busy ? '加载中…' : '加载更多').width('100%').enabled(!this.busy).attributeModifier(new NoteActionStyle(false, this.palette)).onClick((): void => { void this.load(true); }) } }
          }.layoutWeight(1).width('100%').scrollBar(BarState.Auto)
        }
      }.width('100%').height('100%').constraintSize({ maxWidth: 840 }).padding(20)
    }.width('100%').height('100%') }.attributeModifier(new AppDestinationStyle(this.admin ? '卡片举报审核' : '我的举报', pageColor(this.palette, 'canvas'), pageColor(this.palette, 'header'), this.palette)).backgroundColor(pageColor(this.palette, 'canvas'))
      .onShown((): void => this.shown()).onHidden((): void => this.hidden())
  }
}
