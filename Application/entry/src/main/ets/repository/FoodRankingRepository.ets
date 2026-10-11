import { FoodRankingRequest, FoodRankingResponse } from '../model/FoodRankingModels';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { CloudGateway } from '../service/CloudGateway';
import { ReadRequestOptions } from '../service/ReadScheduler';

export class FoodRankingRepository {
  list(request: FoodRankingRequest, options: ReadRequestOptions): Promise<FoodRankingResponse> {
    return CloudGateway.hasSession()
      ? AccountRequestGuard.authenticated<FoodRankingResponse>('list-food-rankings', request, options)
      : AccountRequestGuard.public<FoodRankingResponse>('list-food-rankings', request, options);
  }
}
