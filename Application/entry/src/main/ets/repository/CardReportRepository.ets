/**
 * 【文件职责】卡片举报与审核：普通用户提交举报、查看自己的举报；管理员（服务端白名单）查看并处理举报。
 * 【链路位置】ReportContentPage、CardReportListPage、CardReportDetailPage、ProfileSettingsPage → 本文件 → shike-governance。
 * 同一组页面用 admin 参数区分“我的举报”和“管理员审核”，实际权限每次都由云端校验。
 */
import { CardReportAccess, CardReportAccessRequest, CardReportContext, CardReportList, CardReportListRequest, CardReportStatus,
  CardReportDetail, CardReportRoute, ReportCardRequest, SubmitCardReportRequest, ResolveCardReportRequest, CardReportResult } from '../model/CardReportModels';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { ReadRequestOptions } from '../service/ReadScheduler';
// 举报与审核仓库（无状态）。
export class CardReportRepository {
  // 查询当前账号的举报/审核权限（设置页据此决定是否显示“管理员系统”入口）。
  async access(options: ReadRequestOptions = {}): Promise<CardReportAccess> {
    const request: CardReportAccessRequest = { probe: true };
    return AccountRequestGuard.authenticated<CardReportAccess>('get-card-report-access', request, options);
  }
  // 读取举报某张卡片所需的上下文（卡片摘要、是否已举报过等）。
  async context(cardId: string, options: ReadRequestOptions): Promise<CardReportContext> {
    const request: ReportCardRequest = { cardId };
    return AccountRequestGuard.authenticated<CardReportContext>('get-card-report-context', request, options);
  }
  // 分页读取举报列表：admin=true 为审核列表，否则为我的举报。
  async list(admin: boolean, status: CardReportStatus, cursor: string, options: ReadRequestOptions): Promise<CardReportList> {
    const request: CardReportListRequest = { status, cursor };
    return AccountRequestGuard.authenticated<CardReportList>(admin ? 'list-card-review-reports' : 'list-my-card-reports', request, options);
  }
  // 读取单条举报详情（admin 含义同上）。
  async detail(admin: boolean, reportId: string, options: ReadRequestOptions): Promise<CardReportDetail> {
    const request: CardReportRoute = { reportId };
    return AccountRequestGuard.authenticated<CardReportDetail>(admin ? 'get-card-review-report' : 'get-my-card-report', request, options);
  }
  // 提交举报。
  async submit(request: SubmitCardReportRequest): Promise<CardReportResult> {
    return AccountRequestGuard.authenticated<CardReportResult>('submit-card-report', request);
  }
  // 管理员处理举报（例如下架或驳回）。
  async resolve(request: ResolveCardReportRequest): Promise<CardReportResult> {
    return AccountRequestGuard.authenticated<CardReportResult>('resolve-card-report', request);
  }
}
