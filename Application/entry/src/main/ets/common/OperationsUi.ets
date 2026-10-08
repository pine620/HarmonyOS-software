import { ModerationAction, ModerationKind } from '../model/OperationsModels';
export function moderationKindLabel(kind: ModerationKind): string {
  switch (kind) { case 'CARD': return '新卡片'; case 'REVISION': return '编辑'; case 'MERCHANT': return '商家'; case 'REPORT': return '举报'; }
}
export function moderationActionLabel(action: ModerationAction): string {
  switch (action) { case 'APPROVE': return '通过'; case 'REQUEST_CHANGE': return '要求修改'; case 'TAKE_DOWN': return '下架'; case 'NO_ISSUE': return '无需处理'; }
}
export function operationsStateLabel(state: string): string {
  switch (state) {
    case 'PENDING': case 'PENDING_POST_REVIEW': case 'USER_CONFIRMED_PENDING': return '待处理';
    case 'RUNNING': return '执行中'; case 'RETRY_WAIT': return '等待重试'; case 'FAILED': return '需要处理';
    case 'DONE': return '已完成'; case 'CANCELLED': return '已取消'; case 'RESOLVED': return '已处理';
    case 'REQUEST_CHANGE': case 'REJECTED': return '请修改'; case 'TAKEN_DOWN': return '已下架';
    case 'APPROVED': case 'USER_CONFIRMED_APPROVED': return '已通过'; default: return state;
  }
}
export function operationsDate(value: number): string { return value > 0 ? new Date(value).toLocaleString() : '—'; }
