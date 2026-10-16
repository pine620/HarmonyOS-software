import { CursorRequest, ContentActionResult,
  DeletedCardsPageResult, RestoreDeletedRequest } from '../model/ContentStatusModels';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { ReadRequestOptions } from '../service/ReadScheduler';
export class ContentStatusRepository {
  async deleted(cursor: string, options: ReadRequestOptions): Promise<DeletedCardsPageResult> {
    const request: CursorRequest = { cursor };
    return AccountRequestGuard.authenticated<DeletedCardsPageResult>('list-deleted-cards', request, options);
  }
  async restore(request: RestoreDeletedRequest): Promise<ContentActionResult> {
    return AccountRequestGuard.authenticated<ContentActionResult>('restore-deleted-card', request);
  }
}
