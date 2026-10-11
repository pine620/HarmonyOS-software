import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { MealQuery, MealCandidatePage, CreateMealPollRequest, MealPollResponse, MealPollIdRequest, MealPollMutationRequest } from '../model/MealModels';
export class MealRepository {
  async candidates(query: MealQuery): Promise<MealCandidatePage> { return AccountRequestGuard.authenticated<MealCandidatePage>('get-meal-candidates', query); }
  async createPoll(request: CreateMealPollRequest): Promise<MealPollResponse> { return AccountRequestGuard.authenticated<MealPollResponse>('create-meal-poll', request); }
  async poll(pollId: string): Promise<MealPollResponse> { const request: MealPollIdRequest = { pollId }; return AccountRequestGuard.authenticated<MealPollResponse>('get-meal-poll', request); }
  async mutatePoll(operation: string, request: MealPollMutationRequest): Promise<MealPollResponse> { return AccountRequestGuard.authenticated<MealPollResponse>(operation, request); }
}
