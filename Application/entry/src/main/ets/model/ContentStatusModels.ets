export type ContentStatusKind = 'CARD' | 'REVISION' | 'REPORT';
export type ContentStatusScope = 'REPORTS' | 'CORRECTIONS';
export interface CursorRequest { cursor: string; }
export interface ContentStatusRow { id: string; kind: ContentStatusKind; targetId: string; title: string; state: string; reason: string; createdAt: number; version: number; }
export interface ContentStatusPage { items: Array<ContentStatusRow>; nextCursor: string; scanned?: number; }
export interface ContentActionResult { success: boolean; alreadyProcessed?: boolean; reportId?: string; }
export interface ReportContentRequest { targetId: string; reason: string; }
export interface DeletedCardRow { cardId: string; title: string; deletedAt: number; purgeAt: number; version: number; canRestore: boolean; }
export interface DeletedCardsPageResult { items: Array<DeletedCardRow>; nextCursor: string; lifecycleEnabled: boolean; }
export interface RestoreDeletedRequest { cardId: string; expectedVersion: number; requestId: string; }
export interface ReportRoute { targetType: 'CARD' | 'MERCHANT'; targetId: string; }
