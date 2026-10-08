import { FormNoteStyle, PrimaryActionStyle, stage47ErrorText } from '../common/Stage47Ui';
import { ReportContentRequest } from '../model/OperationsModels';
import { OperationsRepository } from '../repository/OperationsRepository';
import { OperationsPageGuard, OperationsTicket } from '../service/OperationsPageGuard';
@Component
export struct ReportContentPage {
  @Prop targetType: 'CARD' | 'MERCHANT' = 'CARD'; @Prop targetId: string = '';
  @StorageLink('stage47AppActive') @Watch('onEnvironmentChanged') appActive: boolean = true;
  @StorageLink('authSessionRevision') @Watch('onEnvironmentChanged') sessionRevision: number = 0;
  @StorageLink('accountContentRevision') @Watch('onEnvironmentChanged') contentRevision: number = 0;
  @State reason: string = ''; @State message: string = ''; @State busy: boolean = false; @State submitted: boolean = false;
  private visible: boolean = false; private guard: OperationsPageGuard = new OperationsPageGuard(); private repo: OperationsRepository = new OperationsRepository();
  private shown(): void { this.visible = true; this.guard.close(); this.reason = ''; this.message = ''; this.busy = false; this.submitted = false; if (this.appActive) this.guard.open(); }
  private hidden(): void { this.visible = false; this.guard.close(); this.reason = ''; this.message = ''; this.busy = false; this.submitted = false; }
  aboutToDisappear(): void { this.hidden(); }
  private onEnvironmentChanged(): void { this.guard.close(); this.reason = ''; this.message = ''; this.busy = false; this.submitted = false; if (this.visible && this.appActive) this.guard.open(); }
  private async submit(): Promise<void> {
    const ticket: OperationsTicket = this.guard.ticket(); if (!this.guard.valid(ticket) || this.busy || this.submitted) return;
    if (this.reason.trim().length === 0) { this.message = '请填写举报理由。'; return; } this.busy = true;
    try { const request: ReportContentRequest = { targetId: this.targetId, reason: this.reason.trim() }; await this.repo.report(this.targetType, request);
      if (this.guard.valid(ticket)) { this.submitted = true; this.reason = ''; this.message = '举报已提交。可在“我的举报”查看处理状态，同一对象不重复登记。'; }
    } catch (error) { if (this.guard.valid(ticket)) this.message = stage47ErrorText(error as Object, '举报未确认，请重试。'); }
    finally { if (this.guard.valid(ticket)) this.busy = false; }
  }
  build() {
    NavDestination() { Scroll() { Column({ space: 12 }) {
      Text(this.targetType === 'MERCHANT' ? '举报商家资料' : '举报卡片内容').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
      Text('请说明内容问题，便于审核处理。').fontSize(14).fontColor($r('app.color.muted'))
      Text('举报理由').fontSize(15).fontColor($r('app.color.ink'))
      TextArea({ text: this.reason, placeholder: '例如地址不准确、内容违规，最多 200 字' }).height(140).maxLength(200).enabled(!this.busy && !this.submitted)
        .attributeModifier(new FormNoteStyle()).accessibilityText('举报理由').onChange((value: string): void => { this.reason = value; })
      Text(this.message).fontSize(14).fontColor($r('app.color.ink')).width('100%')
      Button(this.busy ? '提交中…' : this.submitted ? '已提交' : '提交举报').width('100%').enabled(!this.busy && !this.submitted)
        .attributeModifier(new PrimaryActionStyle()).onClick((): void => { void this.submit(); })
    }.padding(16).width('100%').constraintSize({ maxWidth: 840 }).alignItems(HorizontalAlign.Start) }.width('100%').height('100%') }
      .title('举报内容').backgroundColor($r('app.color.canvas')).onShown((): void => this.shown()).onHidden((): void => this.hidden())
  }
}
