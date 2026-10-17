import { AuthService } from './AuthService';
import { AuthSessionStore } from './AuthSessionStore';
import { CloudGateway } from './CloudGateway';
import { ReadRequestOptions } from './ReadScheduler';
/**
 * 【文件职责】账号请求守卫：包装 CloudGateway 的调用，在结果返回时检查“发起请求时的账号与会话代次”是否仍是当前的。
 * 如果期间用户退出、换号，甚至退出后用同一账号重新登录（会话代次变了），都会丢弃旧结果并抛错，
 * 防止旧账号的数据显示到新账号的界面上。大多数 Repository 通过它发请求。
 */
export class AccountRequestGuard {
  // 当前登录用户的业务 UID；未登录返回空串。
  static owner(): string { const profile = AuthService.profile(); return profile === undefined ? '' : profile.uid; }
  // 结果返回时校验：账号或会话代次不一致就抛错丢弃。
  private static check(owner: string, generation: number): void {
    if (owner !== AccountRequestGuard.owner() || generation !== AuthSessionStore.generation()) throw new Error('账号已变化，已取消旧账号请求。');
  }
  // 需要登录的调用：未登录直接拒绝；返回后做账号校验。
  static authenticated<T>(operation: string, payload: object, options: ReadRequestOptions = {}): Promise<T> {
    const owner: string = AccountRequestGuard.owner(); const generation: number = AuthSessionStore.generation();
    if (owner.length === 0) return Promise.reject(new Error('请先登录。'));
    return CloudGateway.callAuthenticated<T>(operation, payload, options).then((value: T): T => { AccountRequestGuard.check(owner, generation); return value; });
  }
  // 游客也可调用的操作（已登录时自动带 Token）；返回后同样做账号校验。
  static public<T>(operation: string, payload: object, options: ReadRequestOptions = {}): Promise<T> {
    const owner: string = AccountRequestGuard.owner(); const generation: number = AuthSessionStore.generation();
    return CloudGateway.callPublic<T>(operation, payload, options).then((value: T): T => { AccountRequestGuard.check(owner, generation); return value; });
  }
}
