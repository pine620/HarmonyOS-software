/**
 * 【文件职责】用户主页内容与赞/踩（v2）调用。
 * 【链路位置】UserProfileContent → 本文件 → shike-content（stage7-services.js）。
 */
import { ReadRequestOptions } from '../service/ReadScheduler';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { UserPageRequest, UserPageResponse } from '../model/SocialDiscoveryModels';
import { SetCardReactionRequest, CardActionResponse } from '../model/CloudContracts';
import { CloudGateway } from '../service/CloudGateway';
// 用户主页仓库（无状态）。
export class SocialDiscoveryRepository {
  // 读取用户主页（资料 + 公开卡片分页）；已登录时带身份，以便返回“是否好友”等关系信息。
  async user(request: UserPageRequest, options: ReadRequestOptions = {}): Promise<UserPageResponse> { return CloudGateway.hasSession() ? AccountRequestGuard.authenticated<UserPageResponse>('get-user-page', request, options) : AccountRequestGuard.public<UserPageResponse>('get-user-page', request, options); }
  // 设置对卡片的赞/踩（v2 接口）。
  async react(request: SetCardReactionRequest): Promise<CardActionResponse> { return AccountRequestGuard.authenticated<CardActionResponse>('set-card-reaction-v2', request); }
}
