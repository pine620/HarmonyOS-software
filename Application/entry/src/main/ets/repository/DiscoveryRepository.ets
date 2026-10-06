import { DiscoveryCapabilities, DiscoveryCardPage, MapMerchantPage, MapMerchantQuery,
  MerchantRecommendationQuery, PublicCardQuery } from '../model/DiscoveryModels';
import { EmptyRequest } from '../model/CloudContracts';
import { CloudGateway } from '../service/CloudGateway';

export class DiscoveryRepository {
  private async read<T>(operation: string, payload: object): Promise<T> {
    return CloudGateway.hasSession() ? CloudGateway.callAuthenticated<T>(operation, payload) : CloudGateway.callPublic<T>(operation, payload);
  }
  async capabilities(): Promise<DiscoveryCapabilities> {
    const request: EmptyRequest = {};
    return this.read<DiscoveryCapabilities>('get-discovery-capabilities', request);
  }
  async map(query: MapMerchantQuery): Promise<MapMerchantPage> { return this.read<MapMerchantPage>('list-map-merchants', query); }
  async search(query: PublicCardQuery): Promise<DiscoveryCardPage> { return this.read<DiscoveryCardPage>('search-public-cards', query); }
  async merchant(query: MerchantRecommendationQuery): Promise<DiscoveryCardPage> {
    return this.read<DiscoveryCardPage>('get-merchant-recommendations', query);
  }
}
