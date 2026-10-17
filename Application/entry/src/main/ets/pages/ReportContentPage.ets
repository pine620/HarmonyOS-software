/**
 * 【文件职责】提交卡片举报：读取举报上下文（卡片摘要），选择原因并填写说明后提交（submit-card-report）。
 */
import { PagePaletteName, pageColor } from '../common/PagePaletteUi';
import { NoteActionStyle, WarmNoteBackdrop } from '../common/WarmNoteUi';
import { ChoiceActionStyle } from '../common/Stage47Ui';
import { util } from '@kit.ArkTS';
import { AppDestinationStyle, AppPageSurface } from '../common/AppPageUi';
import { FormNoteStyle, stage47ErrorText } from '../common/Stage47Ui';
import { CardReportPhoto } from '../components/CardReportPhoto';
import { CARD_REPORT_REASONS, CardReportReason, CardReportReasonChoice, CardReportContext, ReportCardView,
  SubmitCardReportRequest, CardReportResult, CardReportRoute } from '../model/CardReportModels';
import { CardReportRepository } from '../repository/CardReportRepository';
import { ContentPageGuard, ContentPageTicket } from '../service/ContentPageGuard';
// 举报页面。
@Component
export struct ReportContentPage {
  @Prop palette: PagePaletteName = AppPageSurface.palette;
  @Consume('pathStack') pathStack: NavPathStack;
  @Prop targetType: 'CARD' | 'MERCHANT' = 'CARD';
  @Prop targetId: string = '';
  @StorageLink('stage47AppActive') @Watch('onEnvironmentChanged') appActive: boolean = true;
  @StorageLink('authSessionRevision') @Watch('onEnvironmentChanged') sessionRevision: number = 0;
  @StorageLink('accountContentRevision') @Watch('onEnvironmentChanged') contentRevision: number = 0;
  @State card: ReportCardView | undefined = undefined;
  @State reasonType: CardReportReason = 'INACCURATE';
  @State description: string = '';
  @State message: string = '';
  @State busy: boolean = false;
  @State submitted: boolean = false;
  @State resultId: string = '';
  private visible: boolean = false;
  private pending: SubmitCardReportRequest | undefined = undefined;
  private guard: ContentPageGuard = new ContentPageGuard();
  private repo: CardReportRepository = new CardReportRepository();
  // 清空表单与卡片数据。
  private clear(): void { this.card = undefined; this.description = ''; this.reasonType = 'INACCURATE'; this.message = ''; this.busy = false; this.submitted = false; this.resultId = ''; this.pending = undefined; }
  // 页面变为可见：重新加载。
  private shown(): void { this.visible = true; this.guard.close(); this.clear(); if (this.appActive) { this.guard.open(); void this.load(); } }
  // 页面隐藏：清空。
  private hidden(): void { this.visible = false; this.guard.close(); this.clear(); }
  aboutToDisappear(): void { this.hidden(); }
  // App 前后台或账号变化时重新加载。
  private onEnvironmentChanged(): void { this.guard.close(); this.clear(); if (this.visible && this.appActive) { this.guard.open(); void this.load(); } }
  // 读取被举报卡片的摘要。
  private async load(): Promise<void> {
    const ticket: ContentPageTicket = this.guard.ticket(); if (!this.guard.valid(ticket) || this.busy) return;
    if (this.targetType !== 'CARD') { this.message = '当前仅受理卡片内容举报。'; return; }
    this.busy = true; this.message = '正在读取卡片…';
    try { const result: CardReportContext = await this.repo.context(this.targetId, this.guard.options(ticket));
      if (this.guard.valid(ticket)) { this.card = result.card; this.message = ''; }
    } catch (error) { if (this.guard.valid(ticket)) this.message = stage47ErrorText(error as Object, '读取失败，请重试。'); }
    finally { if (this.guard.valid(ticket)) this.busy = false; }
  }
  // 提交举报。
  private async submit(): Promise<void> {
    const ticket: ContentPageTicket = this.guard.ticket(); const card: ReportCardView | undefined = this.card;
    if (!this.guard.valid(ticket) || this.busy || this.submitted || card === undefined) return;
    if (this.reasonType === 'OTHER' && this.description.trim().length === 0) { this.message = '请补充说明其他问题。'; return; }
    if (this.pending === undefined) { const request: SubmitCardReportRequest = { cardId: this.targetId, expectedRevision: card.revision,
      reasonType: this.reasonType, description: this.description.trim(), requestId: util.generateRandomUUID() }; this.pending = request; }
    this.busy = true; this.message = '';
    try { const result: CardReportResult = await this.repo.submit(this.pending);
      if (this.guard.valid(ticket)) { this.submitted = true; this.resultId = result.reportId; this.pending = undefined;
        this.message = result.alreadyReported ? '该版本已有举报记录，可查看处理进度。' : '举报已提交，处理进度会更新到“我的举报”。'; }
    } catch (error) { if (this.guard.valid(ticket)) this.message = stage47ErrorText(error as Object, '提交结果未确认，请用原内容重试。'); }
    finally { if (this.guard.valid(ticket)) this.busy = false; }
  }
  // 卡片内容已变化时重新读取摘要。
  private async refreshCard(): Promise<void> { if (this.busy) return; this.pending = undefined; this.card = undefined; await this.load(); }
  // 被举报卡片的摘要区域。
  @Builder private cardSummary(card: ReportCardView) {
    Row({ space: 12 }) {
      if (card.photos.length > 0) { Column() { CardReportPhoto({ mediaId: card.photos[0].mediaId }) }.width(76).height(76) }
      Column({ space: 6 }) { Text(card.title).fontSize(18).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink')); Text((card.shop || '') + ' · ' + (card.price || '')).fontSize(13).fontColor(pageColor(this.palette, 'muted')); }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)
    }.width('100%').padding(16).backgroundColor(pageColor(this.palette, 'surface')).borderRadius(22)
  }
  // 页面布局。
  build() {
    NavDestination() { Stack({ alignContent: Alignment.TopStart }) { WarmNoteBackdrop({ palette: this.palette })
      Scroll() { Column({ space: 14 }) {
        Text(this.submitted ? '举报已提交' : '哪里需要改进？').fontSize(25).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink'))
        Text('请选择卡片内容问题，帮助我们准确核对。').fontSize(14).fontColor(pageColor(this.palette, 'muted'))
        if (this.card !== undefined) { this.cardSummary(this.card) }
        if (!this.submitted) {
          Grid() {
            ForEach(CARD_REPORT_REASONS, (item: CardReportReasonChoice) => {
              GridItem() {
                Button(item.label).width('100%').height(48).enabled(!this.busy && this.pending === undefined)
                  .attributeModifier(new ChoiceActionStyle(this.reasonType === item.key, this.palette)).onClick((): void => { this.reasonType = item.key; })
              }
            }, (item: CardReportReasonChoice): string => item.key)
          }.columnsTemplate('1fr 1fr').rowsGap(10).columnsGap(10).height(174).width('100%')
          Text(this.reasonType === 'OTHER' ? '补充说明（必填）' : '补充说明（选填）').fontSize(15).fontColor(pageColor(this.palette, 'ink'))
          TextArea({ text: this.description, placeholder: '描述具体问题，最多 200 字' }).height(130).maxLength(200)
            .attributeModifier(new FormNoteStyle(this.palette)).enabled(!this.busy && this.pending === undefined).onChange((value: string): void => { this.description = value; })
          Text(this.description.length + ' / 200').fontSize(12).fontColor(pageColor(this.palette, 'muted')).width('100%').textAlign(TextAlign.End)
        }
        if (this.message.length > 0) { Text(this.message).fontSize(14).fontColor(pageColor(this.palette, 'ink')).width('100%') }
        if (this.submitted) {
          Button('查看这条举报').width('100%').attributeModifier(new NoteActionStyle(true, this.palette)).onClick((): void => {
            const request: CardReportRoute = { reportId: this.resultId }; this.pathStack.replacePathByName('report-detail', request);
          })
          Button('我的举报').width('100%').attributeModifier(new NoteActionStyle(false, this.palette)).onClick((): void => { this.pathStack.replacePathByName('my-reports', null); })
        } else {
          Button(this.busy ? '处理中…' : this.pending !== undefined ? '用原内容重试提交' : '提交举报').width('100%')
            .enabled(!this.busy && this.card !== undefined).attributeModifier(new NoteActionStyle(true, this.palette)).onClick((): void => { void this.submit(); })
          Button('刷新卡片内容').width('100%').enabled(!this.busy).attributeModifier(new NoteActionStyle(false, this.palette)).onClick((): void => { void this.refreshCard(); })
        }
      }.width('100%').constraintSize({ maxWidth: 720 }).alignItems(HorizontalAlign.Start).padding(20) }.width('100%').height('100%')
    }.width('100%').height('100%') }.attributeModifier(new AppDestinationStyle('举报卡片', pageColor(this.palette, 'canvas'), pageColor(this.palette, 'header'), this.palette)).backgroundColor(pageColor(this.palette, 'canvas'))
      .onShown((): void => this.shown()).onHidden((): void => this.hidden())
  }
}
