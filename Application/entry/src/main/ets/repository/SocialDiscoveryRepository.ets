import { ReadRequestOptions } from '../service/ReadScheduler';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { UserPageRequest, UserPageResponse, MerchantRankingRequest, MerchantRankingPage, FormerFriendGrantsPage } from '../model/SocialDiscoveryModels';
import { CursorRequest } from '../model/FoodListModels';
import { OperationResponse, RevokeFriendContentAccessRequest, SetCardReactionRequest, CardActionResponse } from '../model/CloudContracts';
import { CloudGateway } from '../service/CloudGateway';
export class SocialDiscoveryRepository {
  async user(request: UserPageRequest, options: ReadRequestOptions = {}): Promise<UserPageResponse> { return CloudGateway.hasSession() ? AccountRequestGuard.authenticated<UserPageResponse>('get-user-page', request, options) : AccountRequestGuard.public<UserPageResponse>('get-user-page', request, options); }
  async ranking(request: MerchantRankingRequest): Promise<MerchantRankingPage> { return CloudGateway.hasSession() ? AccountRequestGuard.authenticated<MerchantRankingPage>('list-merchant-rankings', request) : AccountRequestGuard.public<MerchantRankingPage>('list-merchant-rankings', request); }
  async formerGrants(cursor: string = ''): Promise<FormerFriendGrantsPage> { const request: CursorRequest = { cursor }; return AccountRequestGuard.authenticated<FormerFriendGrantsPage>('list-former-friend-content-grants', request); }
  async revoke(viewerUid: string): Promise<void> { const request: RevokeFriendContentAccessRequest = { viewerUid }; await AccountRequestGuard.authenticated<OperationResponse>('revoke-friend-content-access', request); AppStorage.setOrCreate('friendRelationshipRevision', (AppStorage.get<number>('friendRelationshipRevision') || 0) + 1); }
  async react(request: SetCardReactionRequest): Promise<CardActionResponse> { return AccountRequestGuard.authenticated<CardActionResponse>('set-card-reaction-v2', request); }
}
