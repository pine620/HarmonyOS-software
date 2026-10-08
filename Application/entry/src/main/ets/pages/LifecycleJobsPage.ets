import { ChoiceActionStyle, PrimaryActionStyle, QuietActionStyle, SecondaryActionStyle, stage47ErrorText } from '../common/Stage47Ui';
import { operationsDate, operationsStateLabel } from '../common/OperationsUi';
import { LifecycleJobSummary, LifecycleJobsPageResult, LifecycleJobRequest } from '../model/OperationsModels';
import { OperationsRepository } from '../repository/OperationsRepository';
import { OperationsPageGuard, OperationsTicket } from '../service/OperationsPageGuard';
import { PagedDataSource } from '../service/PagedDataSource';
@Component
export struct LifecycleJobsPage {
  @Consume('pathStack') pathStack: NavPathStack;
  @StorageLink('stage47AppActive') @Watch('onEnvironmentChanged') appActive: boolean = true;
  @StorageLink('authSessionRevision') @Watch('onEnvironmentChanged') sessionRevision: number = 0;
  @StorageLink('accountContentRevision') @Watch('onEnvironmentChanged') contentRevision: number = 0;
  @State state: string = 'FAILED'; @State busy: boolean = false; @State count: number = 0; @State cursor: string = ''; @State message: string = '';
  private visible: boolean = false; private guard: OperationsPageGuard = new OperationsPageGuard(); private repo: OperationsRepository = new OperationsRepository();
  private source: PagedDataSource<LifecycleJobSummary> = new PagedDataSource<LifecycleJobSummary>();
  private clear(): void { this.guard.close(); this.message = ''; this.source.replace([]); this.busy = false; this.count = 0; this.cursor = ''; }
  private shown(): void { this.visible = true; this.clear(); if (this.appActive) { this.guard.open(); void this.load(false); } }
  private hidden(): void { this.visible = false; this.clear(); }
  aboutToDisappear(): void { this.hidden(); }
  private onEnvironmentChanged(): void { this.clear(); if (this.visible && this.appActive) { this.guard.open(); void this.load(false); } }
  private select(state: string): void { this.state = state; this.shown(); }
  private async load(more: boolean): Promise<void> {
    const ticket: OperationsTicket = this.guard.ticket(); if (this.busy || !this.guard.valid(ticket)) return;
    this.busy = true; this.message = '正在读取任务…';
    try { const result: LifecycleJobsPageResult = await this.repo.jobs(this.state, more ? this.cursor : '', this.guard.options(ticket));
      if (!this.guard.valid(ticket)) return; this.source.merge(result.items, (job: LifecycleJobSummary): string => job.jobId, more); this.count = this.source.totalCount(); this.cursor = result.nextCursor; this.message = this.count === 0 ? '此状态下暂无任务。' : '';
    } catch (error) { if (this.guard.valid(ticket)) { this.source.replace([]); this.count = 0; this.cursor = ''; this.message = stage47ErrorText(error as Object, '任务读取失败。'); } }
    finally { if (this.guard.valid(ticket)) this.busy = false; }
  }
  private open(job: LifecycleJobSummary): void { if (!this.guard.valid(this.guard.ticket())) return; const request: LifecycleJobRequest = { jobId: job.jobId }; this.pathStack.pushPathByName('lifecycle-job', request); }
  @Builder
  private filter(state: string) { Button(operationsStateLabel(state)).layoutWeight(1).enabled(!this.busy).attributeModifier(new ChoiceActionStyle(this.state === state)).onClick((): void => this.select(state)) }
  @Builder
  private row(job: LifecycleJobSummary) {
    Column({ space: 8 }) {
      Text(job.jobType + ' · ' + operationsStateLabel(job.status)).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink')).width('100%')
      Text('阶段：' + job.phase + ' · 已处理 ' + job.processed.toString()).fontSize(14).fontColor($r('app.color.ink')).width('100%')
      Text('更新 ' + operationsDate(job.updatedAt)).fontSize(13).fontColor($r('app.color.muted'))
      if ((job.lastErrorCode || '').length > 0) { Text('错误码：' + job.lastErrorCode).fontSize(13).fontColor($r('app.color.danger')).width('100%') }
      Button('查看任务').width('100%').attributeModifier(new PrimaryActionStyle()).onClick((): void => this.open(job))
    }.padding(14).width('100%').backgroundColor($r('app.color.surface')).borderRadius(16).alignItems(HorizontalAlign.Start)
  }
  build() {
    NavDestination() { Column({ space: 12 }) {
      Row({ space: 8 }) { this.filter('FAILED'); this.filter('RETRY_WAIT'); this.filter('PENDING') }.width('100%')
      Row({ space: 8 }) { this.filter('RUNNING'); this.filter('DONE'); this.filter('CANCELLED') }.width('100%')
      Text(this.message).fontSize(14).fontColor($r('app.color.ink')).width('100%')
      Button('刷新任务').width('100%').enabled(!this.busy).attributeModifier(new QuietActionStyle()).onClick((): void => this.shown())
      List({ space: 12 }) {
        LazyForEach(this.source, (job: LifecycleJobSummary): void => { ListItem() { this.row(job) } }, (job: LifecycleJobSummary): string => job.jobId)
        if (this.cursor.length > 0) { ListItem() { Button('加载更多').width('100%').enabled(!this.busy).attributeModifier(new SecondaryActionStyle()).onClick((): void => { void this.load(true); }) } }
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
    }.padding(16).width('100%').height('100%').constraintSize({ maxWidth: 840 }).alignItems(HorizontalAlign.Start) }
      .title('清理任务').backgroundColor($r('app.color.canvas')).onShown((): void => this.shown()).onHidden((): void => this.hidden())
  }
}
