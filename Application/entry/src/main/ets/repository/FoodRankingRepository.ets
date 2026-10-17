/**
 * 【文件职责】榜单读取（高分榜 / 好友榜）。
 * 【链路位置】FoodRankingPage → 本文件 → shike-content.listFoodRankings。榜单由服务端生成快照后分页返回，
 * 快照生成期间返回“准备中”状态。已登录时带 Token（好友榜需要身份），游客匿名读取高分榜。
 */
import { FoodRankingRequest, FoodRankingResponse } from '../model/FoodRankingModels';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { CloudGateway } from '../service/CloudGateway';
import { ReadRequestOptions } from '../service/ReadScheduler';

// 榜单仓库（无状态）。
export class FoodRankingRepository {
  // 读取一页榜单；根据是否登录选择带身份或匿名调用。
  list(request: FoodRankingRequest, options: ReadRequestOptions): Promise<FoodRankingResponse> {
    return CloudGateway.hasSession()
      ? AccountRequestGuard.authenticated<FoodRankingResponse>('list-food-rankings', request, options)
      : AccountRequestGuard.public<FoodRankingResponse>('list-food-rankings', request, options);
  }
}
