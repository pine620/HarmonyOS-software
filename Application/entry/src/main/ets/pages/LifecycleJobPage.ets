import { util } from '@kit.ArkTS';
import { DangerActionStyle, PrimaryActionStyle, QuietActionStyle, SecondaryActionStyle, stage47ErrorText, invalidatesProtectedPage } from '../common/Stage47Ui';
import { operationsDate, operationsStateLabel } from '../common/OperationsUi';
import { AuthenticationIdentity, LifecycleJobDetail, LifecycleJobRequest, LifecycleJobSummary, RetryLifecycleRequest } from '../model/OperationsModels';
import { MigrationCheckpoint } from '../model/CloudContracts';
import { OperationsRepository } from '../repository/OperationsRepository';
import { OperationsPageGuard, OperationsTicket } from '../service/OperationsPageGuard';
@Component
export struct LifecycleJobPage {
  @Prop jobId: string = '';
  @StorageLink('stage47AppActive') @Watch('onEnvironmentChanged') appActive: boolean = true;
  @StorageLink('authSessionRevision') @Watch('onEnvironmentChanged') sessionRevision: number = 0;
  @StorageLink('accountContentRevision') @Watch('onEnvironmentChanged') contentRevision: number = 0;
  @State detail: LifecycleJobDetail | undefined = undefined; @State identities: Array<AuthenticationIdentity> = [];
  @State busy: boolean = false; @State message: string = ''; @State confirmed: boolean = false; @State retryAvailable: boolean = false;
  private visible: boolean = false; private guard: OperationsPageGuard = new OperationsPageGuard(); private repo: OperationsRepository = new OperationsRepository();
  private pending: RetryLifecycleRequest | undefined = undefined; private confirmRequest: boolean = false;
  private clear(): void { this.guard.close(); this.message = ''; this.detail = undefined; this.identities = []; this.busy = false; this.confirmed = false; this.retryAvailable = false; this.pending = undefined; }
  private shown(): void { this.visible = true; this.clear(); if (this.appActive) { this.guard.open(); void this.load(false); } }
  private hidden(): void { this.visible = false; this.clear(); }
  aboutToDisappear(): void { this.hidden(); }
  private onEnvironmentChanged(): void { this.clear(); if (this.visible && this.appActive) { this.guard.open(); void this.load(false); } }
  private async load(more: boolean): Promise<void> {
    const ticket: OperationsTicket = this.guard.ticket(); if (this.busy || !this.guard.valid(ticket)) return;
    this.busy = true;
    try { const old: LifecycleJobDetail | undefined = this.detail; const request: LifecycleJobRequest = { jobId: this.jobId, identityCursor: more && old !== undefined ? old.nextIdentityCursor : '' };
      const result: LifecycleJobDetail = await this.repo.job(request, this.guard.options(ticket)); if (!this.guard.valid(ticket)) return;
      this.detail = result; this.identities = more ? this.identities.concat(result.authIdentities.filter((value: AuthenticationIdentity): boolean => !this.identities.some((old: AuthenticationIdentity): boolean => old.provider === value.provider && old.providerUid === value.providerUid))) : result.authIdentities; this.message = '';
    } catch (error) { if (this.guard.valid(ticket)) { if (!more || invalidatesProtectedPage(error as Object)) { this.detail = undefined; this.identities = []; } this.message = stage47ErrorText(error as Object, '任务读取失败。'); } }
    finally { if (this.guard.valid(ticket)) this.busy = false; }
  }
  private async retry(confirm: boolean): Promise<void> {
    const ticket: OperationsTicket = this.guard.ticket(); const detail: LifecycleJobDetail | undefined = this.detail;
    if (detail === undefined || this.busy || !this.guard.valid(ticket)) return;
    if (this.pending === undefined) {
      if (confirm && (!this.confirmed || detail.hasMoreIdentities)) { this.message = '请查看全部身份，并在 AGC 控制台核实删除后确认。'; return; }
      const request: RetryLifecycleRequest = { jobId: this.jobId, expectedVersion: detail.job.updatedAt, requestId: util.generateRandomUUID(), confirmDeleted: confirm };
      this.pending = request; this.confirmRequest = confirm;
    }
    this.busy = true;
    try { await this.repo.retry(this.pending, this.confirmRequest); if (!this.guard.valid(ticket)) return; this.pending = undefined; this.retryAvailable = false; this.detail = undefined; this.identities = []; this.message = '已安排重试。刷新查看最新进度。'; }
    catch (error) { if (this.guard.valid(ticket)) { this.retryAvailable = true; this.message = stage47ErrorText(error as Object, '请求未确认，请重试原请求或刷新。'); } }
    finally { if (this.guard.valid(ticket)) this.busy = false; }
  }
  private async run(): Promise<void> {
    const ticket: OperationsTicket = this.guard.ticket(); if (this.busy || !this.guard.valid(ticket)) return; this.busy = true;
    try { await this.repo.run(this.jobId); if (!this.guard.valid(ticket)) return; this.busy = false; await this.load(false); if (this.guard.valid(ticket) && this.detail !== undefined) this.message = '本次执行已返回，以下为最新任务状态。'; }
    catch (error) { if (this.guard.valid(ticket)) { this.detail = undefined; this.identities = []; this.message = stage47ErrorText(error as Object, '本次执行未完成，请刷新任务状态。'); } }
    finally { if (this.guard.valid(ticket)) this.busy = false; }
  }
  private canRun(job: LifecycleJobSummary): boolean {
    if (job.jobType === 'MEDIA_COVER_BACKFILL') return false;
    if (job.status === 'PENDING' || job.status === 'RETRY_WAIT') return true;
    return job.status === 'RUNNING' && (job.leaseUntilAt || 0) <= Date.now();
  }
  @Builder
  private migrationProgress(checkpoint: MigrationCheckpoint) {
    Column({ space: 8 }) {
      Text(checkpoint.phase === 'VERIFY' ? '正在检查历史数据覆盖' : '正在整理历史数据').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink')).width('100%')
      Text('已扫描 ' + checkpoint.scanned.toString() + ' · 已整理 ' + checkpoint.migrated.toString() + ' · 无需变更 ' + checkpoint.skipped.toString()).fontSize(14).fontColor($r('app.color.ink')).width('100%')
      Text('已验证 ' + checkpoint.verificationScanned.toString() + ' · 遗漏 ' + checkpoint.verificationMissing.toString() + ' · 失败 ' + checkpoint.failures.toString()).fontSize(14).fontColor($r('app.color.ink')).width('100%')
      Text(checkpoint.coverageComplete ? '覆盖检查已通过，返回榜单或详情页刷新状态。' : '整理和覆盖检查均完成后，相应功能才能就绪。').fontSize(14).lineHeight(21).fontColor($r('app.color.muted')).width('100%')
      if (checkpoint.failedEntityId.length > 0) { Text('失败记录：' + checkpoint.failedEntityId).fontSize(13).fontColor($r('app.color.danger')).copyOption(CopyOptions.LocalDevice).width('100%') }
    }.padding(14).width('100%').backgroundColor($r('app.color.surface')).borderRadius(16).alignItems(HorizontalAlign.Start)
  }
  @Builder
  private content(detail: LifecycleJobDetail) {
    Text(detail.job.jobType + ' · ' + operationsStateLabel(detail.job.status)).fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.ink'))
    Text('任务编号：' + detail.job.jobId).fontSize(13).fontColor($r('app.color.muted')).copyOption(CopyOptions.LocalDevice).width('100%')
    Text('阶段：' + detail.job.phase + ' · 已处理 ' + detail.job.processed.toString()).fontSize(16).fontColor($r('app.color.ink'))
    if (detail.job.migration !== undefined) { this.migrationProgress(detail.job.migration) }
    Text('连续尝试：' + detail.job.attemptCount.toString() + ' · 更新：' + operationsDate(detail.job.updatedAt)).fontSize(14).fontColor($r('app.color.muted'))
    Text('下次执行：' + operationsDate(detail.job.runAfterAt)).fontSize(14).fontColor($r('app.color.muted'))
    if ((detail.job.processingDeadlineAt || 0) > 0) { Text('处理截止：' + operationsDate(detail.job.processingDeadlineAt || 0) + (detail.job.overdue === true ? ' · 已超期，需优先处理' : '')).fontSize(15).fontColor($r('app.color.ink')).width('100%') }
    if ((detail.job.manualActionDueAt || 0) > 0) { Text('认证人工处理截止：' + operationsDate(detail.job.manualActionDueAt || 0)).fontSize(15).fontColor($r('app.color.danger')).width('100%') }
    if ((detail.job.lastProgressAt || 0) > 0) { Text('最后推进：' + operationsDate(detail.job.lastProgressAt || 0) + ' · 连续无进度 ' + (detail.job.noProgressRuns || 0).toString() + ' 次').fontSize(14).fontColor($r('app.color.muted')).width('100%') }
    if ((detail.job.lastErrorCode || '').length > 0) { Text('错误码：' + detail.job.lastErrorCode).fontSize(14).fontColor($r('app.color.danger')) }
    if (detail.audit !== null) {
      Text('操作：' + detail.audit.kind + ' / ' + detail.audit.action).fontSize(15).fontColor($r('app.color.ink'))
      Text('处理理由：' + detail.audit.reason).fontSize(15).fontColor($r('app.color.ink')).width('100%')
      Text('操作人：' + detail.audit.operatorUid).fontSize(13).fontColor($r('app.color.muted')).copyOption(CopyOptions.LocalDevice)
    }
    if (detail.job.authActionRequired) {
      Text('业务清理已暂停在认证身份阶段。请在 AGC 控制台逐个核实下列身份并完成删除，再确认继续。账号在此期间保持不可访问。').fontSize(15).fontColor($r('app.color.ink')).width('100%')
      ForEach(this.identities, (identity: AuthenticationIdentity): void => { Text(identity.provider + '：' + identity.providerUid).fontSize(14).copyOption(CopyOptions.LocalDevice).fontColor($r('app.color.ink')).width('100%') }, (identity: AuthenticationIdentity): string => identity.provider + ':' + identity.providerUid)
      if (detail.hasMoreIdentities) { Button('查看下一批身份').width('100%').enabled(!this.busy && !this.retryAvailable).attributeModifier(new SecondaryActionStyle()).onClick((): void => { void this.load(true); }) }
      Row({ space: 8 }) { Checkbox({ name: 'auth-deleted' }).width(48).height(48).select(this.confirmed).enabled(!this.busy && !detail.hasMoreIdentities && !this.retryAvailable).onChange((value: boolean): void => { this.confirmed = value; }).accessibilityText('我已在 AGC 控制台核实所有认证身份已删除'); Text('我已在 AGC 控制台核实所有认证身份已删除').fontSize(14).fontColor($r('app.color.ink')).layoutWeight(1) }.width('100%')
    }
    if (detail.job.jobType === 'MEDIA_COVER_BACKFILL') {
      Text('封面回填由专用定时任务逐张推进。连续失败会暂停；请核对转换库与任务日志，再在云端使用专用重试参数继续。').fontSize(14).lineHeight(21).fontColor($r('app.color.muted')).width('100%')
    } else if (this.retryAvailable) {
      Button('重试原管理请求').width('100%').enabled(!this.busy).attributeModifier(new PrimaryActionStyle()).onClick((): void => { void this.retry(this.confirmRequest); })
    } else if (detail.job.status === 'FAILED' || detail.job.status === 'RETRY_WAIT') {
      Button(detail.job.authActionRequired ? '确认认证已删除并继续清理' : '重试任务').width('100%').enabled(!this.busy && (!detail.job.authActionRequired || this.confirmed && !detail.hasMoreIdentities))
        .attributeModifier(new DangerActionStyle()).onClick((): void => { void this.retry(detail.job.authActionRequired); })
    }
    if (this.canRun(detail.job)) {
      Button('执行一个批次').width('100%').enabled(!this.busy && !this.retryAvailable).attributeModifier(new SecondaryActionStyle()).onClick((): void => { void this.run(); })
    }
  }
  build() {
    NavDestination() { Scroll() { Column({ space: 12 }) {
      Text(this.message).fontSize(14).fontColor($r('app.color.ink')).width('100%')
      Button('刷新状态').width('100%').enabled(!this.busy).attributeModifier(new QuietActionStyle()).onClick((): void => this.shown())
      if (this.detail !== undefined) { this.content(this.detail) }
    }.padding(16).width('100%').constraintSize({ maxWidth: 840 }).alignItems(HorizontalAlign.Start) }.width('100%').height('100%') }
      .title('任务详情').backgroundColor($r('app.color.canvas')).onShown((): void => this.shown()).onHidden((): void => this.hidden())
  }
}
