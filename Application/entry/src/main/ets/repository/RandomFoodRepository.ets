/**
 * 【文件职责】「今日吃什么」相关的云端调用：候选池、翻牌内容、选择记录的保存 / 列表 / 删除。
 * 【链路位置】RandomFoodPage、FoodChoiceHistoryPage、RandomFoodWidgetStore → 本文件 → shike-content。
 */
import { OperationResponse } from '../model/CloudContracts';
import util from '@ohos.util';
import { FoodChoiceDeleteRequest, FoodChoicePage, FoodChoicePageRequest, FoodChoiceReceipt, FoodChoiceRequest,
  RandomFoodCards, RandomFoodCardsRequest, RandomFoodPool, RandomFoodPoolRequest } from '../model/RandomFoodModels';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { CloudGateway } from '../service/CloudGateway';
import { ReadRequestOptions } from '../service/ReadScheduler';

// 今日吃什么仓库（无状态）。
export class RandomFoodRepository {
  // 候选池与卡片内容游客也能读：已登录时带身份（可按好友等来源筛选），否则匿名读取。
  private read<T>(operation: string, request: object, options: ReadRequestOptions): Promise<T> {
    return CloudGateway.hasSession() ? AccountRequestGuard.authenticated<T>(operation, request, options) :
      AccountRequestGuard.public<T>(operation, request, options);
  }
  // 读取候选池（只含卡片 id 等轻量信息）。
  pool(request: RandomFoodPoolRequest, options: ReadRequestOptions): Promise<RandomFoodPool> {
    return this.read<RandomFoodPool>('get-random-food-pool', request, options);
  }
  // 按候选 id 读取要翻开的卡片内容（含图片描述符）。
  cards(request: RandomFoodCardsRequest, options: ReadRequestOptions): Promise<RandomFoodCards> {
    return this.read<RandomFoodCards>('get-random-food-cards', request, options);
  }
  // 保存一次“我选了这张”的记录（必须登录）。
  save(request: FoodChoiceRequest): Promise<FoodChoiceReceipt> {
    return AccountRequestGuard.authenticated<FoodChoiceReceipt>('save-food-choice', request);
  }
  // 分页读取选择记录；每次带新的 requestId 便于云端日志区分。
  history(cursor: string, options: ReadRequestOptions): Promise<FoodChoicePage> {
    const request: FoodChoicePageRequest = { cursor, requestId: util.generateRandomUUID() };
    return AccountRequestGuard.authenticated<FoodChoicePage>('list-food-choices', request, options);
  }
  // 删除一条选择记录。
  remove(historyId: string): Promise<OperationResponse> {
    const request: FoodChoiceDeleteRequest = { historyId };
    return AccountRequestGuard.authenticated<OperationResponse>('delete-food-choice', request);
  }
}
