import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { DangerActionStyle, FormNoteStyle, PrimaryActionStyle, QuietActionStyle, ChoiceActionStyle, stage47ErrorText } from '../common/Stage47Ui';
import { moderationActionLabel, operationsDate, operationsStateLabel } from '../common/OperationsUi';
import { CardPhoto } from '../model/CloudContracts';
import { ModerationKind, ModerationDetailRequest, ModerationDetail, ModerationAction, ModerationDecisionRequest, ReviewField } from '../model/OperationsModels';
import { OperationsRepository } from '../repository/OperationsRepository';
import { OperationsPageGuard, OperationsTicket } from '../service/OperationsPageGuard';
import { ImageRepository } from '../service/ImageRepository';
@Component
export struct ModerationDetailPage {
  @Prop kind: ModerationKind = 'CARD'; @Prop itemId: string = '';
  @StorageLink('stage47AppActive') @Watch('onEnvironmentChanged') appActive: boolean = true;
  @StorageLink('authSessionRevision') @Watch('onEnvironmentChanged') sessionRevision: number = 0;
  @StorageLink('accountContentRevision') @Watch('onEnvironmentChanged') contentRevision: number = 0;
  @State detail: ModerationDetail | undefined = undefined;
  @State busy: boolean = false; @State photoBusy: boolean = false;
  @State message: string = ''; @State reason: string = ''; @State coordinate: string = 'UNKNOWN';
  @State photoUrl: string = ''; @State selectedPhoto: string = ''; @State retryAvailable: boolean = false;
  private visible: boolean = false;
  private guard: OperationsPageGuard = new OperationsPageGuard(); private repo: OperationsRepository = new OperationsRepository();
  private pending: ModerationDecisionRequest | undefined = undefined;
  private clear(): void { this.guard.close(); this.message = ''; this.detail = undefined; this.photoUrl = ''; this.selectedPhoto = ''; this.busy = false; this.photoBusy = false; this.pending = undefined; this.retryAvailable = false; this.reason = ''; }
  private shown(): void { this.visible = true; this.clear(); if (this.appActive) { this.guard.open(); void this.load(); } }
  private hidden(): void { this.visible = false; this.clear(); }
  aboutToDisappear(): void { this.hidden(); }
  private onEnvironmentChanged(): void { this.clear(); if (this.visible && this.appActive) { this.guard.open(); void this.load(); } }
  private async load(): Promise<void> {
    const ticket: OperationsTicket = this.guard.ticket(); if (!this.guard.valid(ticket) || this.busy) return;
    this.busy = true; this.message = '正在核对审核权限…';
    try { const request: ModerationDetailRequest = { kind: this.kind, id: this.itemId };
      const detail: ModerationDetail = await this.repo.detail(request, this.guard.options(ticket)); if (!this.guard.valid(ticket)) return;
      this.detail = detail; this.coordinate = detail.coordinateSystem; this.message = '';
    } catch (error) { if (this.guard.valid(ticket)) { this.detail = undefined; this.message = stage47ErrorText(error as Object, '详情读取失败。'); } }
    finally { if (this.guard.valid(ticket)) this.busy = false; }
  }
  private async photo(photo: CardPhoto): Promise<void> {
    const ticket: OperationsTicket = this.guard.ticket(); if (!this.guard.valid(ticket) || this.photoBusy || this.busy) return;
    this.photoBusy = true; this.photoUrl = ''; this.selectedPhoto = photo.id;
    try { const context: common.Context = getContext(this); const guard: () => Promise<boolean> = async (): Promise<boolean> => this.guard.valid(ticket);
      const url: string = this.kind === 'REVISION' ? await ImageRepository.getRevisionDownloadUrl(context, this.itemId, photo.id, guard) : await ImageRepository.getReviewDownloadUrl(context, photo.id, guard);
      if (this.guard.valid(ticket)) this.photoUrl = url;
    } catch (error) { if (this.guard.valid(ticket)) this.message = stage47ErrorText(error as Object, '图片读取失败，可重试。'); }
    finally { if (this.guard.valid(ticket)) this.photoBusy = false; }
  }
  private async decide(action: ModerationAction): Promise<void> {
    const ticket: OperationsTicket = this.guard.ticket(); const detail: ModerationDetail | undefined = this.detail;
    if (detail === undefined || this.busy || !this.guard.valid(ticket)) return;
    if (this.pending === undefined) {
      if (action !== 'APPROVE' && this.reason.trim().length === 0) { this.message = '请填写处理理由。'; return; }
      const request: ModerationDecisionRequest = { kind: this.kind, id: this.itemId, action, reason: this.reason.trim(),
        coordinateSystem: this.coordinate, targetVersion: detail.targetVersion, expectedVersion: detail.item.version, requestId: util.generateRandomUUID() };
      this.pending = request;
    }
    this.busy = true;
    try { await this.repo.decide(this.pending); if (!this.guard.valid(ticket)) return;
      this.pending = undefined; this.retryAvailable = false; this.detail = undefined; this.photoUrl = ''; this.message = '处理已保存。返回队列或刷新查看最新状态。';
    } catch (error) { if (this.guard.valid(ticket)) { this.retryAvailable = true; this.message = stage47ErrorText(error as Object, '处理结果未确认，请重试原请求或刷新。'); } }
    finally { if (this.guard.valid(ticket)) this.busy = false; }
  }
  @Builder
  private content(detail: ModerationDetail) {
    Text(detail.item.title).fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink')).width('100%')
    Text(operationsStateLabel(detail.item.state) + ' · ' + operationsDate(detail.item.createdAt)).fontSize(13).fontColor($r('app.color.muted'))
    Text(detail.body).fontSize(16).fontColor($r('app.color.ink')).width('100%')
    if (detail.sourceLink.length > 0) { Text(detail.sourceLink).fontSize(14).fontColor($r('app.color.action_text')).copyOption(CopyOptions.LocalDevice).width('100%') }
    ForEach(detail.changes, (field: ReviewField): void => {
      Column({ space: 6 }) {
        Text(field.label).fontSize(14).fontWeight(FontWeight.Medium)
        if (field.before.length > 0) {
          Text('原内容：' + field.before).fontSize(14)
        }
        Text('提交内容：' + field.after).fontSize(14)
      }
        .width('100%').padding(12).backgroundColor($r('app.color.surface')).borderRadius(12).alignItems(HorizontalAlign.Start).foregroundColor($r('app.color.ink'))
    }, (field: ReviewField): string => field.label)
    if (detail.photos.length > 0) {
      Text('实拍图（按需查看）').fontSize(15).fontColor($r('app.color.ink'))
      ForEach(detail.photos, (photo: CardPhoto, index: number): void => {
        Button('查看实拍 ' + (index + 1).toString()).width('100%').enabled(!this.photoBusy && !this.busy)
          .attributeModifier(new ChoiceActionStyle(this.selectedPhoto === photo.id)).onClick((): void => { void this.photo(photo); })
      }, (photo: CardPhoto): string => photo.id)
      if (this.photoBusy) { Text('正在读取实拍…').fontSize(14).fontColor($r('app.color.muted')) }
      if (this.photoUrl.length > 0) { Image(this.photoUrl).width('100%').height(280).objectFit(ImageFit.Contain)
        .onError((): void => { const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
          void ImageRepository.reportDecodeFailure(context, this.selectedPhoto, 'ORIGINAL', this.kind === 'REVISION' ? 'REVISION' : 'REVIEW', this.kind === 'REVISION' ? this.itemId : '').catch((): void => {});
          this.photoUrl = ''; this.message = '图片解码失败，请重新读取实拍图。'; })
        .accessibilityText('当前审核内容实拍图') }
    }
    if (this.kind === 'MERCHANT') {
      Text('审核坐标系').fontSize(15).fontColor($r('app.color.ink'))
      Row({ space: 8 }) {
        Button('GCJ02').layoutWeight(1).attributeModifier(new ChoiceActionStyle(this.coordinate === 'GCJ02')).onClick((): void => { this.coordinate = 'GCJ02'; })
        Button('WGS84').layoutWeight(1).attributeModifier(new ChoiceActionStyle(this.coordinate === 'WGS84')).onClick((): void => { this.coordinate = 'WGS84'; })
      }.enabled(!this.busy && !this.retryAvailable)
    }
    Text('处理理由').fontSize(15).fontColor($r('app.color.ink'))
    TextArea({ text: this.reason, placeholder: '要求修改、下架或无需处理时必填，最多 200 字' }).height(120).maxLength(200)
      .attributeModifier(new FormNoteStyle()).enabled(!this.busy && !this.retryAvailable).accessibilityText('审核处理理由')
      .onChange((value: string): void => { this.reason = value; })
    if (this.retryAvailable && this.pending !== undefined) {
      Button('重试原处理请求').width('100%').enabled(!this.busy).attributeModifier(new PrimaryActionStyle())
        .onClick((): void => { const request: ModerationDecisionRequest | undefined = this.pending; if (request !== undefined) void this.decide(request.action); })
    } else {
      ForEach(detail.actions, (action: ModerationAction): void => {
        Button(moderationActionLabel(action)).width('100%').enabled(!this.busy && !this.photoBusy)
          .attributeModifier(new DangerActionStyle()).onClick((): void => { void this.decide(action); })
      }, (action: ModerationAction): string => action)
    }
  }
  build() {
    NavDestination() { Scroll() { Column({ space: 12 }) {
      Text(this.message).fontSize(14).fontColor($r('app.color.ink')).width('100%')
      Button('刷新内容').width('100%').enabled(!this.busy).attributeModifier(new QuietActionStyle()).onClick((): void => this.shown())
      if (this.detail !== undefined) { this.content(this.detail) }
    }.padding(16).width('100%').constraintSize({ maxWidth: 840 }).alignItems(HorizontalAlign.Start) }.width('100%').height('100%') }
      .title('审核详情').backgroundColor($r('app.color.canvas')).onShown((): void => this.shown()).onHidden((): void => this.hidden())
  }
}
