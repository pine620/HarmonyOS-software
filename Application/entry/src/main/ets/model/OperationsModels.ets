import { CardPhoto, MaintenanceJobRecord } from './CloudContracts';
export type ModerationKind = 'CARD' | 'REVISION' | 'MERCHANT' | 'REPORT';
export type ModerationAction = 'APPROVE' | 'REQUEST_CHANGE' | 'TAKE_DOWN' | 'NO_ISSUE';
export type ModerationScope = 'ADMIN' | 'REPORTS' | 'CORRECTIONS';
export interface OperationsCapabilities { administrator: boolean; lifecycleEnabled: boolean; workerEnabled: boolean; }
export interface CursorRequest { cursor: string; }
export interface ModerationQueueRequest { kind: ModerationKind; cursor: string; }
export interface ModerationRow { id: string; kind: ModerationKind; targetId: string; title: string; state: string; reason: string; createdAt: number; version: number; }
export interface ModerationQueuePage { items: Array<ModerationRow>; nextCursor: string; scanned?: number; }
export interface ModerationDetailRequest { kind: ModerationKind; id: string; }
export interface ReviewField { label: string; before: string; after: string; }
export interface ModerationDetail { item: ModerationRow; body: string; sourceLink: string; photos: Array<CardPhoto>; changes: Array<ReviewField>; actions: Array<ModerationAction>; targetVersion: number; coordinateSystem: string; }
export interface ModerationDecisionRequest { kind: ModerationKind; id: string; action: ModerationAction; reason: string; expectedVersion: number; requestId: string; coordinateSystem: string; targetVersion: number; }
export interface OperationsResult { success: boolean; alreadyProcessed?: boolean; reportId?: string; }
export interface ReportContentRequest { targetId: string; reason: string; }
export interface DeletedCardRow { cardId: string; title: string; deletedAt: number; purgeAt: number; version: number; canRestore: boolean; }
export interface DeletedCardsPageResult { items: Array<DeletedCardRow>; nextCursor: string; lifecycleEnabled: boolean; }
export interface RestoreDeletedRequest { cardId: string; expectedVersion: number; requestId: string; }
export interface LifecycleJobSummary extends MaintenanceJobRecord { phase: string; processed: number; authActionRequired: boolean; }
export interface LifecycleJobsRequest { status: string; cursor: string; }
export interface LifecycleJobsPageResult { items: Array<LifecycleJobSummary>; nextCursor: string; }
export interface LifecycleJobRequest { jobId: string; identityCursor?: string; }
export interface AuthenticationIdentity { provider: string; providerUid: string; }
export interface ModerationAuditSummary { kind: string; action: string; reason: string; requestId: string; operatorUid: string; }
export interface LifecycleJobDetail { audit: ModerationAuditSummary | null; job: LifecycleJobSummary; authIdentities: Array<AuthenticationIdentity>; hasMoreIdentities: boolean; nextIdentityCursor?: string; }
export interface RetryLifecycleRequest { jobId: string; expectedVersion: number; requestId: string; confirmDeleted?: boolean; }
export interface ReviewMediaRequest { mediaId: string; }
export interface ReportRoute { targetType: 'CARD' | 'MERCHANT'; targetId: string; }
