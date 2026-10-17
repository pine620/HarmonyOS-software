/**
 * 【文件职责】卡片举报与审核的数据结构及举报原因选项，供 CardReportRepository 与举报相关页面使用。
 */
// 举报原因：信息不准确 / 侵权 / 内容不当 / 广告 / 链接失效 / 其他。
export type CardReportReason = 'INACCURATE' | 'COPYRIGHT' | 'INAPPROPRIATE' | 'ADVERTISING' | 'BROKEN_LINK' | 'OTHER';
// 举报状态：待处理 / 已处理。
export type CardReportStatus = 'PENDING' | 'RESOLVED';
// 审核处理动作：保留 / 下架。
export type CardReportAction = 'KEEP' | 'TAKE_DOWN';
export interface CardReportReasonChoice { key: CardReportReason; label: string; }
// 举报原因选项（界面显示用）。
export const CARD_REPORT_REASONS: Array<CardReportReasonChoice> = [
  { key: 'INACCURATE', label: '信息不准确' }, { key: 'COPYRIGHT', label: '图片侵权' },
  { key: 'INAPPROPRIATE', label: '不当内容' }, { key: 'ADVERTISING', label: '广告或引流' },
  { key: 'BROKEN_LINK', label: '链接失效' }, { key: 'OTHER', label: '其他问题' }
];
// 举报中的图片引用。
export interface CardReportPhoto { mediaId: string; }
// 举报页显示的卡片摘要。
export interface ReportCardView {
  available: boolean; readable: boolean; id: string; title: string; revision: string; photos: Array<CardReportPhoto>;
  consumptionMode?: string; itemPrice?: string; dineInAverage?: string; orderTotal?: string; deliveryFee?: string; originalPrice?: string;
  deliveryPlatform?: string; consumedAt?: number; publishedAt?: number; modifiedAt?: number;
  brand?: string; price?: string; specification?: string; shop?: string; address?: string;
  sellingPoints?: string; offers?: string; reviewText?: string; tasteScore?: number; sourceLink?: string; category?: string;
}
// 举报列表中的一行。
export interface CardReportRow {
  id: string; cardId: string; cardTitle: string; status: CardReportStatus; reasonType: string; reasonLabel: string;
  description: string; createdAt: number; updatedAt: number; reportedRevision: string;
  resolutionAction: string; resolutionReason: string; resolvedAt: number; previewMediaId?: string; reviewerUid?: string;
}
export interface CardReportList { items: Array<CardReportRow>; nextCursor: string; }
export interface CardReportDetail { report: CardReportRow; card: ReportCardView; cardChanged: boolean; }
export interface CardReportContext { card: ReportCardView; }
// 权限探测请求。
export interface CardReportAccessRequest { probe: boolean; }
export interface CardReportAccess { allowed: boolean; }
export interface CardReportRoute { reportId: string; }
export interface ReportCardRequest { cardId: string; }
export interface CardReportListRequest { status: CardReportStatus; cursor: string; }
// 提交举报请求。
export interface SubmitCardReportRequest {
  cardId: string; expectedRevision: string; reasonType: CardReportReason; description: string; requestId: string;
}
// 审核处理请求。
export interface ResolveCardReportRequest {
  reportId: string; expectedReportVersion: number; expectedCardRevision: string; action: CardReportAction; reason: string; requestId: string;
}
// 举报 / 处理结果。
export interface CardReportResult { success: boolean; reportId: string; alreadyReported?: boolean; action?: string; }
// 把处理动作转成用户可读的结果文字。
export function cardReportOutcome(action: string): string {
  if (action === 'KEEP') return '保留卡片';
  if (action === 'TAKE_DOWN') return '卡片已下架';
  if (action === 'ALREADY_DOWN') return '卡片已由其他举报下架';
  if (action === 'UNAVAILABLE') return '内容已不可用，审核结束';
  return '已处理';
}
