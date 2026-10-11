import { ReadRequestOptions } from '../service/ReadScheduler';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { UserPageRequest, UserPageResponse } from '../model/SocialDiscoveryModels';
import { SetCardReactionRequest, CardActionResponse } from '../model/CloudContracts';
import { CloudGateway } from '../service/CloudGateway';
export class SocialDiscoveryRepository {
  async user(request: UserPageRequest, options: ReadRequestOptions = {}): Promise<UserPageResponse> { return CloudGateway.hasSession() ? AccountRequestGuard.authenticated<UserPageResponse>('get-user-page', request, options) : AccountRequestGuard.public<UserPageResponse>('get-user-page', request, options); }
  async react(request: SetCardReactionRequest): Promise<CardActionResponse> { return AccountRequestGuard.authenticated<CardActionResponse>('set-card-reaction-v2', request); }
}
