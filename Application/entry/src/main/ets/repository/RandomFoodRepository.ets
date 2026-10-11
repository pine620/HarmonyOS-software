import { OperationResponse } from '../model/CloudContracts';
import util from '@ohos.util';
import { FoodChoiceDeleteRequest, FoodChoicePage, FoodChoicePageRequest, FoodChoiceReceipt, FoodChoiceRequest,
  RandomFoodCards, RandomFoodCardsRequest, RandomFoodPool, RandomFoodPoolRequest } from '../model/RandomFoodModels';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { CloudGateway } from '../service/CloudGateway';
import { ReadRequestOptions } from '../service/ReadScheduler';

export class RandomFoodRepository {
  private read<T>(operation: string, request: object, options: ReadRequestOptions): Promise<T> {
    return CloudGateway.hasSession() ? AccountRequestGuard.authenticated<T>(operation, request, options) :
      AccountRequestGuard.public<T>(operation, request, options);
  }
  pool(request: RandomFoodPoolRequest, options: ReadRequestOptions): Promise<RandomFoodPool> {
    return this.read<RandomFoodPool>('get-random-food-pool', request, options);
  }
  cards(request: RandomFoodCardsRequest, options: ReadRequestOptions): Promise<RandomFoodCards> {
    return this.read<RandomFoodCards>('get-random-food-cards', request, options);
  }
  save(request: FoodChoiceRequest): Promise<FoodChoiceReceipt> {
    return AccountRequestGuard.authenticated<FoodChoiceReceipt>('save-food-choice', request);
  }
  history(cursor: string, options: ReadRequestOptions): Promise<FoodChoicePage> {
    const request: FoodChoicePageRequest = { cursor, requestId: util.generateRandomUUID() };
    return AccountRequestGuard.authenticated<FoodChoicePage>('list-food-choices', request, options);
  }
  remove(historyId: string): Promise<OperationResponse> {
    const request: FoodChoiceDeleteRequest = { historyId };
    return AccountRequestGuard.authenticated<OperationResponse>('delete-food-choice', request);
  }
}
