import { CursorRequest, ContentStatusScope, ContentStatusPage, ContentActionResult, ReportContentRequest,
  DeletedCardsPageResult, RestoreDeletedRequest } from '../model/ContentStatusModels';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { ReadRequestOptions } from '../service/ReadScheduler';
export class ContentStatusRepository {
  async queue(scope: ContentStatusScope, cursor: string, options: ReadRequestOptions): Promise<ContentStatusPage> {
    const request: CursorRequest = { cursor };
    return AccountRequestGuard.authenticated<ContentStatusPage>(scope === 'REPORTS' ? 'list-my-reports' : 'list-own-review-requests', request, options);
  }
  async report(targetType: 'CARD' | 'MERCHANT', request: ReportContentRequest): Promise<ContentActionResult> {
    return AccountRequestGuard.authenticated<ContentActionResult>(targetType === 'CARD' ? 'report-card' : 'report-merchant', request);
  }
  async deleted(cursor: string, options: ReadRequestOptions): Promise<DeletedCardsPageResult> {
    const request: CursorRequest = { cursor };
    return AccountRequestGuard.authenticated<DeletedCardsPageResult>('list-deleted-cards', request, options);
  }
  async restore(request: RestoreDeletedRequest): Promise<ContentActionResult> {
    return AccountRequestGuard.authenticated<ContentActionResult>('restore-deleted-card', request);
  }
}
