import { AuthSessionStore } from './AuthSessionStore';
import { AccountRequestGuard } from './AccountRequestGuard';
import { ReadRequestOptions } from './ReadScheduler';
export interface OperationsTicket { generation: number; session: number; owner: string; revision: number; }
/** Each visible destination owns its guard; hidden pages clear protected data. */
export class OperationsPageGuard {
  private generation: number = 0;
  private active: boolean = false;
  open(): void { this.active = true; this.generation++; }
  close(): void { this.active = false; this.generation++; }
  ticket(): OperationsTicket { return { generation: this.generation, session: AuthSessionStore.generation(),
    owner: AccountRequestGuard.owner(), revision: AppStorage.get<number>('accountContentRevision') || 0 }; }
  valid(ticket: OperationsTicket): boolean { return this.active && AppStorage.get<boolean>('stage47AppActive') !== false &&
    ticket.generation === this.generation && ticket.session === AuthSessionStore.generation() &&
    ticket.owner.length > 0 && ticket.owner === AccountRequestGuard.owner() &&
    ticket.revision === (AppStorage.get<number>('accountContentRevision') || 0); }
  options(ticket: OperationsTicket): ReadRequestOptions { return { priority: 'metadata',
    mayContinue: async (): Promise<boolean> => this.valid(ticket) }; }
}
