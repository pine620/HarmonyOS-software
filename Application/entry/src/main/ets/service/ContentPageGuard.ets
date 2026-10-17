/**
 * 【文件职责】页面级请求守卫（用于举报、审核、删除记录等账号私有页面）。
 * 页面打开时 open()、隐藏时 close()；发请求前取一张 ticket（页面代次 + 会话代次 + 账号 + 内容版本），
 * 结果返回时用 valid(ticket) 判断是否仍可写入界面。任何一项变了（页面关闭、换号、App 进入后台、内容版本变化）都丢弃结果。
 */
import { AuthSessionStore } from './AuthSessionStore';
import { AccountRequestGuard } from './AccountRequestGuard';
import { ReadRequestOptions } from './ReadScheduler';
// 一次请求发起时的“快照”。
export interface ContentPageTicket { generation: number; session: number; owner: string; revision: number; }
// 每个可见页面持有自己的守卫；页面隐藏时清空受保护的数据。
export class ContentPageGuard {
  private generation: number = 0;
  private active: boolean = false;
  open(): void { this.active = true; this.generation++; }
  close(): void { this.active = false; this.generation++; }
  // 发请求前取一张“票”：记录页面代次、会话代次、账号与内容版本。
  ticket(): ContentPageTicket { return { generation: this.generation, session: AuthSessionStore.generation(),
    owner: AccountRequestGuard.owner(), revision: AppStorage.get<number>('accountContentRevision') || 0 }; }
  // 票是否仍有效：页面仍打开、App 在前台、各项版本都没变化。
  valid(ticket: ContentPageTicket): boolean { return this.active && AppStorage.get<boolean>('stage47AppActive') !== false &&
    ticket.generation === this.generation && ticket.session === AuthSessionStore.generation() &&
    ticket.owner.length > 0 && ticket.owner === AccountRequestGuard.owner() &&
    ticket.revision === (AppStorage.get<number>('accountContentRevision') || 0); }
  // 生成带此票校验的读请求参数（页面关闭后请求会被取消）。
  options(ticket: ContentPageTicket): ReadRequestOptions { return { priority: 'metadata',
    mayContinue: async (): Promise<boolean> => this.valid(ticket) }; }
}
