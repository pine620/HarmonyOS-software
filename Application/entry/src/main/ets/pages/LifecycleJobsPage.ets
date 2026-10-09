import { ChoiceActionStyle, PrimaryActionStyle, QuietActionStyle, SecondaryActionStyle, stage47ErrorText, invalidatesProtectedPage } from '../common/Stage47Ui';
import { operationsDate, operationsStateLabel } from '../common/OperationsUi';
import { HistoricalMigrationType, LifecycleJobSummary, LifecycleJobsPageResult, LifecycleJobRequest } from '../model/OperationsModels';
import { MigrationJobResponse, MigrationJobView, MigrationStatusResponse } from '../model/CloudContracts';
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
  @State migrationVisible: boolean = false;
  @State migrationBusy: boolean = false;
  @State migration: MigrationStatusResponse | undefined = undefined;
  @State migrationMessage: string = '';
  private visible: boolean = false; private guard: OperationsPageGuard = new OperationsPageGuard(); private repo: OperationsRepository = new OperationsRepository();
  private source: PagedDataSource<LifecycleJobSummary> = new PagedDataSource<LifecycleJobSummary>();
  private clear(): void { this.guard.close(); this.message = ''; this.source.replace([]); this.busy = false; this.count = 0; this.cursor = ''; this.migration = undefined; this.migrationBusy = false; this.migrationMessage = ''; }
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
    } catch (error) { if (this.guard.valid(ticket)) { if (!more || invalidatesProtectedPage(error as Object)) { this.source.replace([]); this.count = 0; this.cursor = ''; } this.message = stage47ErrorText(error as Object, '任务读取失败。'); } }
    finally { if (this.guard.valid(ticket)) { this.busy = false; if (!more && this.migrationVisible) void this.loadMigrations(); } }
  }
  private async loadMigrations(): Promise<void> {
    const ticket: OperationsTicket = this.guard.ticket();
    if (this.migrationBusy || !this.migrationVisible || !this.guard.valid(ticket)) return;
    this.migrationBusy = true; this.migrationMessage = '正在读取历史整理状态…';
    try {
      const result: MigrationStatusResponse = await this.repo.migrationStatus(this.guard.options(ticket));
      if (!this.guard.valid(ticket)) return;
      this.migration = result; this.migrationMessage = '';
    } catch (error) {
      if (this.guard.valid(ticket)) { this.migration = undefined; this.migrationMessage = stage47ErrorText(error as Object, '历史整理状态读取失败。'); }
    } finally { if (this.guard.valid(ticket)) this.migrationBusy = false; }
  }
  private async startMigration(kind: HistoricalMigrationType): Promise<void> {
    const ticket: OperationsTicket = this.guard.ticket();
    if (this.busy || this.migrationBusy || this.migration === undefined || !this.guard.valid(ticket)) return;
    this.migrationBusy = true; this.migrationMessage = '正在创建整理任务…';
    try {
      // The server keeps one durable job per type/version, including retries
      // after a lost response. No client-created DONE/coverage flags are sent.
      const result: MigrationJobResponse = await this.repo.startMigration(kind);
      if (!this.guard.valid(ticket)) return;
      this.migrationBusy = false;
      const request: LifecycleJobRequest = { jobId: result.job.jobId };
      this.pathStack.pushPathByName('lifecycle-job', request);
    } catch (error) {
      if (this.guard.valid(ticket)) this.migrationMessage = stage47ErrorText(error as Object, '创建结果未确认，可重试同一整理任务。');
    } finally { if (this.guard.valid(ticket)) this.migrationBusy = false; }
  }
  private migrationJob(kind: HistoricalMigrationType): MigrationJobView | undefined {
    const status: MigrationStatusResponse | undefined = this.migration;
    return status === undefined ? undefined : status.jobs.find((job: MigrationJobView): boolean => job.jobType === kind);
  }
  private openMigration(job: MigrationJobView | undefined): void {
    if (job === undefined || this.busy || this.migrationBusy || !this.guard.valid(this.guard.ticket())) return;
    const request: LifecycleJobRequest = { jobId: job.jobId }; this.pathStack.pushPathByName('lifecycle-job', request);
  }
  private open(job: LifecycleJobSummary): void { if (!this.guard.valid(this.guard.ticket())) return; const request: LifecycleJobRequest = { jobId: job.jobId }; this.pathStack.pushPathByName('lifecycle-job', request); }
  @Builder
  private filter(state: string) { Button(operationsStateLabel(state)).layoutWeight(1).enabled(!this.busy).attributeModifier(new ChoiceActionStyle(this.state === state)).onClick((): void => this.select(state)) }
  @Builder
  private migrationRow(kind: HistoricalMigrationType, job: MigrationJobView | undefined) {
    Column({ space: 8 }) {
      Text(kind === 'BACKFILL_CARD' ? '历史卡片整理' : '历史赞踩整理').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink')).width('100%')
      if (job === undefined) {
        Text('尚未创建任务').fontSize(14).fontColor($r('app.color.muted'))
        Button('启动整理').width('100%').constraintSize({ minHeight: 48 }).enabled(!this.busy && !this.migrationBusy && this.migration !== undefined)
          .attributeModifier(new PrimaryActionStyle()).onClick((): void => { void this.startMigration(kind); })
      } else {
        Text(operationsStateLabel(job.status) + ' · 已扫描 ' + job.checkpoint.scanned.toString() + ' · 已整理 ' + job.checkpoint.migrated.toString()).fontSize(14).fontColor($r('app.color.ink')).width('100%')
        Text(job.checkpoint.coverageComplete ? '覆盖检查已通过' : '覆盖检查待完成').fontSize(14).fontColor($r('app.color.muted'))
        Button('查看进度与执行').width('100%').constraintSize({ minHeight: 48 }).enabled(!this.busy && !this.migrationBusy)
          .attributeModifier(new SecondaryActionStyle()).onClick((): void => this.openMigration(job))
      }
    }.padding(14).width('100%').backgroundColor($r('app.color.surface')).borderRadius(16).alignItems(HorizontalAlign.Start)
  }
  @Builder
  private row(job: LifecycleJobSummary) {
    Column({ space: 8 }) {
      Text(job.jobType + ' · ' + operationsStateLabel(job.status)).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.ink')).width('100%')
      Text('阶段：' + job.phase + ' · 已处理 ' + job.processed.toString()).fontSize(14).fontColor($r('app.color.ink')).width('100%')
      Text('更新 ' + operationsDate(job.updatedAt)).fontSize(13).fontColor($r('app.color.muted'))
      if ((job.processingDeadlineAt || 0) > 0) { Text('处理截止：' + operationsDate(job.processingDeadlineAt || 0) + (job.overdue === true ? ' · 已超期' : '')).fontSize(14).fontColor(job.overdue === true ? $r('app.color.danger') : $r('app.color.ink')).width('100%') }
      if (job.stalled === true || (job.noProgressRuns || 0) >= 3) { Text('任务连续无进度，请检查子任务、租约与错误原因。').fontSize(14).fontColor($r('app.color.danger')).width('100%') }
      if ((job.lastErrorCode || '').length > 0) { Text('错误码：' + job.lastErrorCode).fontSize(13).fontColor($r('app.color.danger')).width('100%') }
      Button('查看任务').width('100%').attributeModifier(new PrimaryActionStyle()).onClick((): void => this.open(job))
    }.padding(14).width('100%').backgroundColor($r('app.color.surface')).borderRadius(16).alignItems(HorizontalAlign.Start)
  }
  build() {
    NavDestination() { Column({ space: 12 }) {
      Button(this.migrationVisible ? '收起历史数据整理' : '历史数据整理').width('100%').constraintSize({ minHeight: 48 })
        .enabled(!this.busy && !this.migrationBusy).attributeModifier(new SecondaryActionStyle()).onClick((): void => {
          this.migrationVisible = !this.migrationVisible; if (this.migrationVisible) void this.loadMigrations();
        })
      if (this.migrationVisible) {
        Scroll() { Column({ space: 10 }) {
          Text('历史卡片影响榜单；历史赞踩影响互动功能。创建后可执行一个批次，或由维护任务继续处理。').fontSize(14).lineHeight(21).fontColor($r('app.color.muted')).width('100%')
          Text(this.migrationMessage).fontSize(14).fontColor($r('app.color.ink')).width('100%')
          this.migrationRow('BACKFILL_CARD', this.migrationJob('BACKFILL_CARD'))
          this.migrationRow('MIGRATE_REACTION', this.migrationJob('MIGRATE_REACTION'))
          Button('刷新整理状态').width('100%').constraintSize({ minHeight: 48 }).enabled(!this.busy && !this.migrationBusy)
            .attributeModifier(new QuietActionStyle()).onClick((): void => { void this.loadMigrations(); })
        }.width('100%') }.width('100%').constraintSize({ maxHeight: 280 })
      }
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
