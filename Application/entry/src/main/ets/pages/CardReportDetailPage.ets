/**
 * 【文件职责】举报详情：显示被举报卡片与举报内容；管理员可选择“保留 / 下架”并填写理由后处理（resolve-card-report）。
 */
import { PagePaletteName, pageColor } from '../common/PagePaletteUi';
import { NoteActionStyle, WarmNoteBackdrop } from '../common/WarmNoteUi';
import { ChoiceActionStyle } from '../common/Stage47Ui';
import { categoryV2Label } from '../model/PublishingModels';
import { util } from '@kit.ArkTS';
import { AppDestinationStyle, AppPageSurface } from '../common/AppPageUi';
import { contentDate } from '../common/ContentStatusUi';
import { FormNoteStyle, stage47ErrorText, invalidatesProtectedPage } from '../common/Stage47Ui';
import { CardReportPhoto } from '../components/CardReportPhoto';
import { CardReportDetail, CardReportPhoto as ReportPhoto, ReportCardView, CardReportAction, ResolveCardReportRequest,
  CardReportResult, cardReportOutcome } from '../model/CardReportModels';
import { CardReportRepository } from '../repository/CardReportRepository';
import { ContentPageGuard, ContentPageTicket } from '../service/ContentPageGuard';
import { ImageDescriptors } from '../service/ImageDescriptors';
import { ReadScheduler } from '../service/ReadScheduler';
// 举报详情页面。
@Component
export struct CardReportDetailPage {
  @Prop palette: PagePaletteName = AppPageSurface.palette;
  @Prop reportId: string = '';
  @Prop admin: boolean = false;
  @StorageLink('stage47AppActive') @Watch('onEnvironmentChanged') appActive: boolean = true;
  @StorageLink('authSessionRevision') @Watch('onEnvironmentChanged') sessionRevision: number = 0;
  @StorageLink('accountContentRevision') @Watch('onEnvironmentChanged') contentRevision: number = 0;
  @State detail: CardReportDetail | undefined = undefined;
  @State reason: string = '';
  @State action: CardReportAction = 'KEEP';
  @State confirming: boolean = false;
  @State expanded: boolean = false;
  @State photoId: string = '';
  @State busy: boolean = false;
  @State message: string = '';
  private visible: boolean = false;
  private pending: ResolveCardReportRequest | undefined = undefined;
  private repo: CardReportRepository = new CardReportRepository();
  private guard: ContentPageGuard = new ContentPageGuard();
  // 清空数据。
  private clear(): void { this.detail = undefined; this.reason = ''; this.action = 'KEEP'; this.confirming = false; this.expanded = false; this.photoId = ''; this.busy = false; this.message = ''; this.pending = undefined; }
  // 重置并重新加载。
  private reset(): void { this.guard.close(); this.clear(); if (this.visible && this.appActive) { this.guard.open(); void this.load(); } }
  // 页面变为可见。
  private shown(): void { this.visible = true; this.reset(); }
  // 页面隐藏：清空。
  private hidden(): void { this.visible = false; this.guard.close(); this.clear(); }
  aboutToDisappear(): void { this.hidden(); }
  // 环境变化时重置。
  private onEnvironmentChanged(): void { this.reset(); }
  // 读取举报详情。
  private async load(): Promise<void> {
    const ticket: ContentPageTicket = this.guard.ticket(); if (this.busy || !this.guard.valid(ticket)) return;
    this.busy = true; this.message = '正在读取…';
    try { const result: CardReportDetail = await this.repo.detail(this.admin, this.reportId, this.guard.options(ticket));
      if (this.guard.valid(ticket)) { this.detail = result; this.message = ''; }
    } catch (error) { if (this.guard.valid(ticket)) { this.detail = undefined; this.message = stage47ErrorText(error as Object, '读取失败，请重试。'); } }
    finally { if (this.guard.valid(ticket)) this.busy = false; }
  }
  // 处理前二次确认。
  private confirm(): void {
    if (this.busy || !this.guard.valid(this.guard.ticket()) || this.detail === undefined) return;
    if (this.reason.trim().length === 0) { this.message = '请填写处理说明。'; return; }
    this.confirming = true; this.message = '';
  }
  // 提交处理结果。
  private async resolve(): Promise<void> {
    const ticket: ContentPageTicket = this.guard.ticket(); const detail: CardReportDetail | undefined = this.detail;
    if (!this.admin || this.busy || !this.confirming || !this.guard.valid(ticket) || detail === undefined || detail.report.status !== 'PENDING') return;
    if (this.pending === undefined) { const request: ResolveCardReportRequest = { reportId: this.reportId, expectedReportVersion: detail.report.updatedAt,
      expectedCardRevision: detail.card.revision, action: this.action, reason: this.reason.trim(), requestId: util.generateRandomUUID() }; this.pending = request; }
    this.busy = true; this.message = '';
    try { const result: CardReportResult = await this.repo.resolve(this.pending);
      if (!this.guard.valid(ticket)) return;
      if (result.success) {
        ImageDescriptors.removeCard(detail.card.id); ReadScheduler.contentChanged();
        AppStorage.setOrCreate('accountContentRevision', (AppStorage.get<number>('accountContentRevision') || 0) + 1);
      }
    } catch (error) { if (this.guard.valid(ticket)) {
      if (invalidatesProtectedPage(error as Object)) { this.detail = undefined; this.pending = undefined; this.confirming = false; this.photoId = ''; }
      this.message = stage47ErrorText(error as Object, '处理结果未确认，请保持原操作重试，或刷新查看结果。');
    } } finally { if (this.guard.valid(ticket)) this.busy = false; }
  }
  // 一行“标签：值”。
  @Builder private field(label: string, value: string) {
    if (value.length > 0) { Text(label + ' · ' + value).fontSize(14).lineHeight(22).fontColor(pageColor(this.palette, 'ink')).width('100%') }
  }
  // 卡片内容区域（含图片）。
  @Builder private cardContent(card: ReportCardView) {
    Column({ space: 12 }) {
      Text(card.available ? card.title : '内容已不可用').fontSize(21).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink')).width('100%')
      if (card.available) {
        Text((card.price || '') + ' · ' + (card.shop || '')).fontSize(14).fontColor(pageColor(this.palette, 'muted')).width('100%')
        if (!card.readable) { Text('这张卡片已下架。').fontSize(14).fontColor($r('app.color.danger')).width('100%') }
        Button(this.expanded ? '收起卡片完整内容与图片' : '查看卡片完整内容与图片').width('100%')
          .attributeModifier(new NoteActionStyle(false, this.palette)).onClick((): void => { this.expanded = !this.expanded; this.photoId = ''; })
        if (this.expanded) {
          this.field('用餐方式', card.consumptionMode || ''); this.field('单品价格', card.itemPrice || ''); this.field('人均价格', card.dineInAverage || '');
          this.field('订单总价', card.orderTotal || ''); this.field('配送费', card.deliveryFee || ''); this.field('原价', card.originalPrice || ''); this.field('外卖平台', card.deliveryPlatform || '');
          this.field('用餐时间', card.consumedAt ? contentDate(card.consumedAt) : ''); this.field('发布时间', card.publishedAt ? contentDate(card.publishedAt) : '');
          this.field('最近修改', card.modifiedAt ? contentDate(card.modifiedAt) : '');
          this.field('品牌', card.brand || ''); this.field('规格', card.specification || ''); this.field('分类', categoryV2Label(card.category || ''));
          this.field('地址', card.address || ''); this.field('卖点', card.sellingPoints || ''); this.field('优惠', card.offers || '');
          this.field('评价', card.reviewText || ''); this.field('口味评分', String(card.tasteScore || 0)); this.field('来源链接', card.sourceLink || '');
          if (card.photos.length > 0) {
            Scroll() { Row({ space: 10 }) {
              ForEach(card.photos, (photo: ReportPhoto) => {
                Column() { CardReportPhoto({ mediaId: photo.mediaId, reportId: this.reportId, admin: this.admin }) }.width(140).height(140)
                  .onClick((): void => { this.photoId = photo.mediaId; }).accessibilityText('查看完整卡片图片').focusable(true)
              }, (photo: ReportPhoto): string => photo.mediaId)
            } }.scrollable(ScrollDirection.Horizontal).width('100%').scrollBar(BarState.Auto)
          } else { Text('这张卡片没有图片。').fontSize(13).fontColor(pageColor(this.palette, 'muted')) }
          if (this.photoId.length > 0) {
            Column() { CardReportPhoto({ mediaId: this.photoId, reportId: this.reportId, admin: this.admin, cover: false }) }.height(360).width('100%')
            Button('关闭完整图片').attributeModifier(new NoteActionStyle(false, this.palette)).width('100%').onClick((): void => { this.photoId = ''; })
          }
        }
      } else { Text('卡片已删除或作者账号不可用，举报记录仍可查看。').fontSize(14).fontColor(pageColor(this.palette, 'muted')).width('100%') }
    }.padding(18).width('100%').alignItems(HorizontalAlign.Start).backgroundColor(pageColor(this.palette, 'surface')).borderRadius(24)
  }
  // 举报内容区域。
  @Builder private reportContent(detail: CardReportDetail) {
    Column({ space: 10 }) {
      Text('举报详情').fontSize(18).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink')).width('100%')
      this.field('卡片', detail.report.cardTitle); this.field('举报类型', detail.report.reasonLabel);
      this.field('补充说明', detail.report.description || '未填写'); this.field('提交时间', contentDate(detail.report.createdAt));
      if (detail.report.status === 'PENDING') {
        Text('已提交 → 等待处理').fontSize(14).fontColor(pageColor(this.palette, 'action')).width('100%')
        if (detail.cardChanged) { Text('卡片已在举报后变化，请核对当前内容。').fontSize(14).fontColor(pageColor(this.palette, 'action')).width('100%') }
      } else {
        Text('已提交 → 已处理').fontSize(14).fontColor(pageColor(this.palette, 'action')).width('100%')
        this.field('处理结果', cardReportOutcome(detail.report.resolutionAction)); this.field('处理说明', detail.report.resolutionReason || '已结束处理');
        this.field('处理时间', contentDate(detail.report.resolvedAt));
        if (this.admin) { this.field('处理管理员', detail.report.reviewerUid || '历史记录未注明'); }
      }
    }.padding(18).width('100%').alignItems(HorizontalAlign.Start).backgroundColor(pageColor(this.palette, 'surface')).borderRadius(24)
  }
  // 管理员处理区域。
  @Builder private decision(detail: CardReportDetail) {
    Column({ space: 12 }) {
      Text('审核处理').fontSize(18).fontWeight(FontWeight.Bold).fontColor(pageColor(this.palette, 'ink')).width('100%')
      Text(detail.card.readable ? '核对卡片后选择处理方式，并填写说明。' : '卡片已下架或不可用，可记录说明并结束这条审核。').fontSize(14).fontColor(pageColor(this.palette, 'muted')).width('100%')
      Row({ space: 10 }) {
        Button(detail.card.readable ? '保留卡片' : '结束审核').layoutWeight(1).enabled(!this.busy && this.pending === undefined)
          .attributeModifier(new ChoiceActionStyle(this.action === 'KEEP', this.palette)).onClick((): void => { this.action = 'KEEP'; this.confirming = false; })
        if (detail.card.readable) { Button('下架卡片').layoutWeight(1).enabled(!this.busy && this.pending === undefined)
          .attributeModifier(new ChoiceActionStyle(this.action === 'TAKE_DOWN', this.palette)).onClick((): void => { this.action = 'TAKE_DOWN'; this.confirming = false; }) }
      }.width('100%')
      TextArea({ text: this.reason, placeholder: '说明核对结果及处理理由，最多 200 字' }).height(130).maxLength(200).attributeModifier(new FormNoteStyle(this.palette))
        .enabled(!this.busy && this.pending === undefined).onChange((value: string): void => { this.reason = value; this.confirming = false; })
      Text(this.reason.length + ' / 200').fontSize(12).fontColor(pageColor(this.palette, 'muted')).width('100%').textAlign(TextAlign.End)
      if (!this.confirming) {
        Button('确认处理方式').width('100%').enabled(!this.busy).attributeModifier(new NoteActionStyle(true, this.palette)).onClick((): void => this.confirm())
      } else {
        Text(this.action === 'TAKE_DOWN' ? '确认下架？处理后其他用户将无法继续查看这张卡片。' : detail.card.readable ? '确认保留这张卡片，并结束这条举报？' : '确认记录处理说明并结束这条举报？').fontSize(14).fontColor(pageColor(this.palette, 'ink')).width('100%')
        Text(this.reason).fontSize(14).fontColor(pageColor(this.palette, 'muted')).width('100%')
        Button(this.busy ? '正在处理…' : this.pending !== undefined ? '用原操作重试' : this.action === 'TAKE_DOWN' ? '确认下架卡片' : '确认完成处理')
          .width('100%').height(48).enabled(!this.busy).backgroundColor(this.action === 'TAKE_DOWN' ? $r('app.color.danger_action') : pageColor(this.palette, 'gold'))
          .fontColor(this.action === 'TAKE_DOWN' ? $r('app.color.on_danger_action') : pageColor(this.palette, 'on_gold')).borderRadius(16).onClick((): void => { void this.resolve(); })
        if (this.pending === undefined) { Button('返回修改').width('100%').enabled(!this.busy).attributeModifier(new NoteActionStyle(false, this.palette)).onClick((): void => { this.confirming = false; }) }
      }
    }.padding(18).width('100%').alignItems(HorizontalAlign.Start).backgroundColor(pageColor(this.palette, 'surface')).borderRadius(24)
  }
  // 页面布局。
  build() {
    NavDestination() { Stack({ alignContent: Alignment.TopStart }) { WarmNoteBackdrop({ palette: this.palette })
      Scroll() { Column({ space: 14 }) {
        if (this.detail !== undefined) {
          this.cardContent(this.detail.card); this.reportContent(this.detail);
          if (this.admin && this.detail.report.status === 'PENDING') { this.decision(this.detail) }
        }
        if (this.message.length > 0) { Text(this.message).fontSize(14).fontColor(pageColor(this.palette, 'ink')).width('100%') }
        Button('刷新处理进度').width('100%').enabled(!this.busy).attributeModifier(new NoteActionStyle(false, this.palette)).onClick((): void => this.reset())
      }.width('100%').constraintSize({ maxWidth: 840 }).alignItems(HorizontalAlign.Start).padding(20) }.width('100%').height('100%')
    }.width('100%').height('100%') }.attributeModifier(new AppDestinationStyle(this.admin ? '举报审核详情' : '举报处理进度', pageColor(this.palette, 'canvas'), pageColor(this.palette, 'header'), this.palette)).backgroundColor(pageColor(this.palette, 'canvas'))
      .onShown((): void => this.shown()).onHidden((): void => this.hidden())
  }
}
