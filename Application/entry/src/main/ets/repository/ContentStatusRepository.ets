/**
 * 【文件职责】“删除记录”：列出自己 30 天内删除的卡片，并可恢复。
 * 【链路位置】DeletedCardsPage → 本文件 → shike-content（lifecycle-services.js）。
 */
import { CursorRequest, ContentActionResult,
  DeletedCardsPageResult, RestoreDeletedRequest } from '../model/ContentStatusModels';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { ReadRequestOptions } from '../service/ReadScheduler';
// 删除记录仓库（无状态）。
export class ContentStatusRepository {
  // 分页读取删除记录。
  async deleted(cursor: string, options: ReadRequestOptions): Promise<DeletedCardsPageResult> {
    const request: CursorRequest = { cursor };
    return AccountRequestGuard.authenticated<DeletedCardsPageResult>('list-deleted-cards', request, options);
  }
  // 恢复一张已删除的卡片（超过 30 天的已被清理，无法恢复）。
  async restore(request: RestoreDeletedRequest): Promise<ContentActionResult> {
    return AccountRequestGuard.authenticated<ContentActionResult>('restore-deleted-card', request);
  }
}
