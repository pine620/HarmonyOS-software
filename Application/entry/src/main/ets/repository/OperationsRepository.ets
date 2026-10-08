import { EmptyRequest } from '../model/CloudContracts';
import { CursorRequest, OperationsCapabilities, ModerationKind, ModerationScope, ModerationQueueRequest, ModerationQueuePage,
  ModerationDetailRequest, ModerationDetail, ModerationDecisionRequest, OperationsResult, ReportContentRequest,
  DeletedCardsPageResult, RestoreDeletedRequest, LifecycleJobsRequest, LifecycleJobsPageResult, LifecycleJobRequest,
  LifecycleJobDetail, RetryLifecycleRequest } from '../model/OperationsModels';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { ReadRequestOptions } from '../service/ReadScheduler';
export class OperationsRepository {
  async capabilities(options: ReadRequestOptions = {}): Promise<OperationsCapabilities> {
    const request: EmptyRequest = {};
    return AccountRequestGuard.authenticated<OperationsCapabilities>('get-stage89-capabilities', request, options);
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
