/**
 * 【文件职责】推荐页“发现”能力：功能开关、地图上的店铺、公开搜索、单个店铺的推荐卡片。
 * 【链路位置】NearbyPage / DiscoveryFeed → 本文件 → CloudGateway → shike-content（stage3 模块实现）。
 * 搜索与地图是否开放由云端开关 SHIKE_STAGE3_SEARCH_VERIFIED / SHIKE_STAGE3_MAP_VERIFIED 决定，先调 capabilities 再展示入口。
 */
import { DiscoveryCapabilities, DiscoveryCardPage, MapMerchantPage, MapMerchantQuery,
  MerchantRecommendationQuery, PublicCardQuery } from '../model/DiscoveryModels';
import { EmptyRequest } from '../model/CloudContracts';
import { CloudGateway } from '../service/CloudGateway';

// 发现功能仓库（无状态）。
export class DiscoveryRepository {
  // 已登录时带身份调用，否则匿名调用（这些都是公开内容）。
  private async read<T>(operation: string, payload: object): Promise<T> {
    return CloudGateway.hasSession() ? CloudGateway.callAuthenticated<T>(operation, payload) : CloudGateway.callPublic<T>(operation, payload);
  }
  // 读取发现页能力开关（地图、搜索是否开放、坐标系等）。
  async capabilities(): Promise<DiscoveryCapabilities> {
    const request: EmptyRequest = {};
    return this.read<DiscoveryCapabilities>('get-discovery-capabilities', request);
  }
  // 地图视野内的店铺标记（分页）。
  async map(query: MapMerchantQuery): Promise<MapMerchantPage> { return this.read<MapMerchantPage>('list-map-merchants', query); }
  // 按关键词搜索公开卡片（菜名或店名）。
  async search(query: PublicCardQuery): Promise<DiscoveryCardPage> { return this.read<DiscoveryCardPage>('search-public-cards', query); }
  // 某个店铺的推荐卡片（地图上点开店铺抽屉时使用）。
  async merchant(query: MerchantRecommendationQuery): Promise<DiscoveryCardPage> {
    return this.read<DiscoveryCardPage>('get-merchant-recommendations', query);
  }
}
