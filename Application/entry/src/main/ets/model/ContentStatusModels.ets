/**
 * 【文件职责】“删除记录”与举报路由的数据结构。
 */
export interface CursorRequest { cursor: string; }
export interface ContentActionResult { success: boolean; alreadyProcessed?: boolean; reportId?: string; }
// 一条已删除卡片：删除时间与彻底清理时间（30 天后）。
export interface DeletedCardRow { cardId: string; title: string; deletedAt: number; purgeAt: number; version: number; canRestore: boolean; }
export interface DeletedCardsPageResult { items: Array<DeletedCardRow>; nextCursor: string; lifecycleEnabled: boolean; }
// 恢复请求：expectedVersion 防止重复恢复，requestId 用于幂等。
export interface RestoreDeletedRequest { cardId: string; expectedVersion: number; requestId: string; }
// 打开举报页的路由参数。
export interface ReportRoute { targetType: 'CARD' | 'MERCHANT'; targetId: string; }
