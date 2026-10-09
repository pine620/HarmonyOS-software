import { EmptyRequest, MigrationJobResponse, MigrationStatusResponse, StartMigrationJobRequest } from '../model/CloudContracts';
import { CursorRequest, OperationsCapabilities, OperationsCapabilitiesRequest, ModerationKind, ModerationScope, ModerationQueueRequest, ModerationQueuePage,
  ModerationDetailRequest, ModerationDetail, ModerationDecisionRequest, OperationsResult, ReportContentRequest,
  DeletedCardsPageResult, RestoreDeletedRequest, LifecycleJobsRequest, LifecycleJobsPageResult, LifecycleJobRequest,
  LifecycleJobDetail, RetryLifecycleRequest, HistoricalMigrationType } from '../model/OperationsModels';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { ReadRequestOptions, ReadScheduler } from '../service/ReadScheduler';
import { AuthSessionStore } from '../service/AuthSessionStore';
export class OperationsRepository {
  private static hint: OperationsCapabilities | undefined = undefined;
  private static hintKey: string = '';
  private static hintUntil: number = 0;
  private static key(): string { return AuthSessionStore.owner() + ':' + AuthSessionStore.generation() + ':' +
    ReadScheduler.lifecycleRevision() + ':' + (AppStorage.get<number>('accountContentRevision') || 0) + ':' +
    (AppStorage.get<number>('operationsRoleRevision') || 0); }
  async capabilities(options: ReadRequestOptions = {}): Promise<OperationsCapabilities> {
    const key: string = OperationsRepository.key();
    const cached: OperationsCapabilities | undefined = OperationsRepository.hint;
    if (cached !== undefined && key === OperationsRepository.hintKey &&
      Date.now() < OperationsRepository.hintUntil && AppStorage.get<boolean>('stage47AppActive') !== false &&
      (options.mayContinue === undefined || await options.mayContinue()) && key === OperationsRepository.key()) return cached;
    const request: EmptyRequest = {};
    const value: OperationsCapabilities = await AccountRequestGuard.authenticated<OperationsCapabilities>('get-stage89-capabilities', request, options);
    // Only negative role hints are reused. Administrator entry always requires a
    // fresh capability response; every restricted operation authorizes server-side.
    if (!value.administrator && key === OperationsRepository.key()) {
      OperationsRepository.hint = value; OperationsRepository.hintKey = key; OperationsRepository.hintUntil = Date.now() + 15000;
    } else { OperationsRepository.hint = undefined; OperationsRepository.hintUntil = 0; }
    return value;
  }
  async diagnostics(options: ReadRequestOptions): Promise<OperationsCapabilities> {
    const request: OperationsCapabilitiesRequest = { includeDiagnostics: true };
    return AccountRequestGuard.authenticated<OperationsCapabilities>('get-stage89-capabilities', request, options);
  }
  async migrationStatus(options: ReadRequestOptions): Promise<MigrationStatusResponse> {
    const request: EmptyRequest = {};
    return AccountRequestGuard.authenticated<MigrationStatusResponse>('get-migration-status', request, options);
  }
  async startMigration(jobType: HistoricalMigrationType): Promise<MigrationJobResponse> {
    const request: StartMigrationJobRequest = { jobType };
    return AccountRequestGuard.authenticated<MigrationJobResponse>('start-migration-job', request);
  }
  async queue(scope: ModerationScope, kind: ModerationKind, cursor: string, options: ReadRequestOptions): Promise<ModerationQueuePage> {
    const request: ModerationQueueRequest = { kind, cursor };
    return AccountRequestGuard.authenticated<ModerationQueuePage>(scope === 'ADMIN' ? 'list-moderation-queue' : scope === 'REPORTS' ? 'list-my-reports' : 'list-own-review-requests', request, options);
  }
  async detail(request: ModerationDetailRequest, options: ReadRequestOptions): Promise<ModerationDetail> {
    return AccountRequestGuard.authenticated<ModerationDetail>('get-moderation-detail', request, options);
  }
  async decide(request: ModerationDecisionRequest): Promise<OperationsResult> { return AccountRequestGuard.authenticated<OperationsResult>('decide-moderation', request); }
  async report(targetType: 'CARD' | 'MERCHANT', request: ReportContentRequest): Promise<OperationsResult> {
    return AccountRequestGuard.authenticated<OperationsResult>(targetType === 'CARD' ? 'report-card' : 'report-merchant', request);
  }
  async deleted(cursor: string, options: ReadRequestOptions): Promise<DeletedCardsPageResult> {
    const request: CursorRequest = { cursor }; return AccountRequestGuard.authenticated<DeletedCardsPageResult>('list-deleted-cards', request, options);
  }
  async restore(request: RestoreDeletedRequest): Promise<OperationsResult> { return AccountRequestGuard.authenticated<OperationsResult>('restore-deleted-card', request); }
  async jobs(status: string, cursor: string, options: ReadRequestOptions): Promise<LifecycleJobsPageResult> {
    const request: LifecycleJobsRequest = { status, cursor }; return AccountRequestGuard.authenticated<LifecycleJobsPageResult>('list-lifecycle-jobs', request, options);
  }
  async job(request: LifecycleJobRequest, options: ReadRequestOptions): Promise<LifecycleJobDetail> { return AccountRequestGuard.authenticated<LifecycleJobDetail>('get-lifecycle-job', request, options); }
  async retry(request: RetryLifecycleRequest, confirm: boolean): Promise<OperationsResult> { return AccountRequestGuard.authenticated<OperationsResult>(confirm ? 'confirm-auth-cleanup' : 'retry-lifecycle-job', request); }
  async run(jobId: string): Promise<OperationsResult> { const request: LifecycleJobRequest = { jobId }; return AccountRequestGuard.authenticated<OperationsResult>('run-lifecycle-job', request); }
}
