import { ReadRequestOptions } from '../service/ReadScheduler';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { MealQuery, PersonalMealQuery, MealCandidatePage, PersonalMealCandidatePage, CreateMealPollRequest, MealPollResponse, MealPollIdRequest, MealPollMutationRequest } from '../model/MealModels';
import { CloudGateway } from '../service/CloudGateway';
export class MealRepository {
  async candidates(query: MealQuery): Promise<MealCandidatePage> { return AccountRequestGuard.authenticated<MealCandidatePage>('get-meal-candidates', query); }
  async personalCandidates(excludedCardIds: Array<string>, options: ReadRequestOptions = {}): Promise<MealCandidatePage> {
    const query: PersonalMealQuery = { personalRandom: true, excludedCardIds: excludedCardIds.slice() };
    const page: PersonalMealCandidatePage = await AccountRequestGuard.authenticated<PersonalMealCandidatePage>('get-meal-candidates', query, options);
    if (page.personalRandom !== true) throw new Error('选餐服务暂不可用，请稍后重试。');
    return page;
  }
  async createPoll(request: CreateMealPollRequest): Promise<MealPollResponse> { return AccountRequestGuard.authenticated<MealPollResponse>('create-meal-poll', request); }
  async poll(pollId: string): Promise<MealPollResponse> { const request: MealPollIdRequest = { pollId }; return AccountRequestGuard.authenticated<MealPollResponse>('get-meal-poll', request); }
  async mutatePoll(operation: string, request: MealPollMutationRequest): Promise<MealPollResponse> { return AccountRequestGuard.authenticated<MealPollResponse>(operation, request); }
}
