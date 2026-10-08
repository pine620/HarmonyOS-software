import { AuthService } from './AuthService';
import { AuthSessionStore } from './AuthSessionStore';
import { CloudGateway } from './CloudGateway';
import { ReadRequestOptions } from './ReadScheduler';
/** Reject stale account responses, including logout/login of the same UID. */
export class AccountRequestGuard {
  static owner(): string { const profile = AuthService.profile(); return profile === undefined ? '' : profile.uid; }
  private static check(owner: string, generation: number): void {
    if (owner !== AccountRequestGuard.owner() || generation !== AuthSessionStore.generation()) throw new Error('账号已变化，已取消旧账号请求。');
  }
  static authenticated<T>(operation: string, payload: object, options: ReadRequestOptions = {}): Promise<T> {
    const owner: string = AccountRequestGuard.owner(); const generation: number = AuthSessionStore.generation();
    if (owner.length === 0) return Promise.reject(new Error('请先登录。'));
    return CloudGateway.callAuthenticated<T>(operation, payload, options).then((value: T): T => { AccountRequestGuard.check(owner, generation); return value; });
  }
  static public<T>(operation: string, payload: object, options: ReadRequestOptions = {}): Promise<T> {
    const owner: string = AccountRequestGuard.owner(); const generation: number = AuthSessionStore.generation();
    return CloudGateway.callPublic<T>(operation, payload, options).then((value: T): T => { AccountRequestGuard.check(owner, generation); return value; });
  }
}
