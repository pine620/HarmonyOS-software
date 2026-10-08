import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { FoodList, FoodListItemsPage, FoodListItemsRequest, FoodListItemRequest, FoodListsPageResult, CreateFoodListRequest, CursorRequest, UpdateFoodListRequest, ReorderFoodListRequest, PersonalFoodState, PersonalFoodRequest, VersionedResult } from '../model/FoodListModels';
import { CardIdRequest } from '../model/CloudContracts';
import { CloudGateway } from '../service/CloudGateway';
export class FoodListRepository {
  private invalidate(): void { AppStorage.setOrCreate('personalFoodRevision', (AppStorage.get<number>('personalFoodRevision') || 0) + 1); }
  async lists(cursor: string = ''): Promise<FoodListsPageResult> { const request: CursorRequest = { cursor }; return AccountRequestGuard.authenticated<FoodListsPageResult>('list-food-lists', request); }
  async create(request: CreateFoodListRequest): Promise<FoodList> { const result: FoodList = await AccountRequestGuard.authenticated<FoodList>('create-food-list', request); this.invalidate(); return result; }
  async update(request: UpdateFoodListRequest): Promise<FoodList> { const result: FoodList = await AccountRequestGuard.authenticated<FoodList>('update-food-list', request); this.invalidate(); return result; }
  async delete(request: UpdateFoodListRequest): Promise<void> { await AccountRequestGuard.authenticated<VersionedResult>('delete-food-list', request); this.invalidate(); }
  async items(listId: string, cursor: string = ''): Promise<FoodListItemsPage> { const request: FoodListItemsRequest = { listId, cursor, pageSize: 30 }; return AccountRequestGuard.authenticated<FoodListItemsPage>('list-food-list-items', request); }
  async addCard(request: FoodListItemRequest): Promise<void> { await AccountRequestGuard.authenticated<VersionedResult>('add-food-list-item', request); this.invalidate(); }
  async removeCard(request: FoodListItemRequest): Promise<void> { await AccountRequestGuard.authenticated<VersionedResult>('remove-food-list-item', request); this.invalidate(); }
  async reorder(request: ReorderFoodListRequest): Promise<void> { await AccountRequestGuard.authenticated<VersionedResult>('reorder-food-list-items', request); this.invalidate(); }
  async personal(cardId: string): Promise<PersonalFoodState> { const request: CardIdRequest = { cardId }; return AccountRequestGuard.authenticated<PersonalFoodState>('get-personal-food-state', request); }
  async savePersonal(request: PersonalFoodRequest): Promise<PersonalFoodState> { const result: PersonalFoodState = await AccountRequestGuard.authenticated<PersonalFoodState>('update-personal-food-state', request); this.invalidate(); return result; }
}
