/**
 * 【文件职责】群聊“一起选餐”投票的云端调用。
 * 【链路位置】GroupChatPage、MealPollPage → 本文件 → shike-social（stage6-services.js）。
 */
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { MealQuery, MealCandidatePage, CreateMealPollRequest, MealPollResponse, MealPollIdRequest, MealPollMutationRequest } from '../model/MealModels';
// 群投票仓库（无状态）。
export class MealRepository {
  // 读取可作为投票选项的候选卡片 / 店铺。
  async candidates(query: MealQuery): Promise<MealCandidatePage> { return AccountRequestGuard.authenticated<MealCandidatePage>('get-meal-candidates', query); }
  // 在群里创建一个投票。
  async createPoll(request: CreateMealPollRequest): Promise<MealPollResponse> { return AccountRequestGuard.authenticated<MealPollResponse>('create-meal-poll', request); }
  // 读取投票详情（选项、票数、我的投票）。
  async poll(pollId: string): Promise<MealPollResponse> { const request: MealPollIdRequest = { pollId }; return AccountRequestGuard.authenticated<MealPollResponse>('get-meal-poll', request); }
  // 投票变更：operation 可为 add-meal-poll-option / vote-meal-poll / close-meal-poll / cancel-meal-poll / stop-meal-poll-options。
  async mutatePoll(operation: string, request: MealPollMutationRequest): Promise<MealPollResponse> { return AccountRequestGuard.authenticated<MealPollResponse>(operation, request); }
}
