import { CardReportAccess, CardReportAccessRequest, CardReportContext, CardReportList, CardReportListRequest, CardReportStatus,
  CardReportDetail, CardReportRoute, ReportCardRequest, SubmitCardReportRequest, ResolveCardReportRequest, CardReportResult } from '../model/CardReportModels';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { ReadRequestOptions } from '../service/ReadScheduler';
export class CardReportRepository {
  async access(options: ReadRequestOptions = {}): Promise<CardReportAccess> {
    const request: CardReportAccessRequest = { probe: true };
    return AccountRequestGuard.authenticated<CardReportAccess>('get-card-report-access', request, options);
  }
  async context(cardId: string, options: ReadRequestOptions): Promise<CardReportContext> {
    const request: ReportCardRequest = { cardId };
    return AccountRequestGuard.authenticated<CardReportContext>('get-card-report-context', request, options);
  }
  async list(admin: boolean, status: CardReportStatus, cursor: string, options: ReadRequestOptions): Promise<CardReportList> {
    const request: CardReportListRequest = { status, cursor };
    return AccountRequestGuard.authenticated<CardReportList>(admin ? 'list-card-review-reports' : 'list-my-card-reports', request, options);
  }
  async detail(admin: boolean, reportId: string, options: ReadRequestOptions): Promise<CardReportDetail> {
    const request: CardReportRoute = { reportId };
    return AccountRequestGuard.authenticated<CardReportDetail>(admin ? 'get-card-review-report' : 'get-my-card-report', request, options);
  }
  async submit(request: SubmitCardReportRequest): Promise<CardReportResult> {
    return AccountRequestGuard.authenticated<CardReportResult>('submit-card-report', request);
  }
  async resolve(request: ResolveCardReportRequest): Promise<CardReportResult> {
    return AccountRequestGuard.authenticated<CardReportResult>('resolve-card-report', request);
  }
}
