export interface CursorRequest { cursor: string; }
export interface ContentActionResult { success: boolean; alreadyProcessed?: boolean; reportId?: string; }
export interface DeletedCardRow { cardId: string; title: string; deletedAt: number; purgeAt: number; version: number; canRestore: boolean; }
export interface DeletedCardsPageResult { items: Array<DeletedCardRow>; nextCursor: string; lifecycleEnabled: boolean; }
export interface RestoreDeletedRequest { cardId: string; expectedVersion: number; requestId: string; }
export interface ReportRoute { targetType: 'CARD' | 'MERCHANT'; targetId: string; }
