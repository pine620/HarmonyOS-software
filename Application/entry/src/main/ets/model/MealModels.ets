import { FoodCard, FoodCategoryV2 } from './CloudContracts';
import { DiscoveryMode } from './DiscoveryModels';
export type MealSource = 'ALL' | 'MY_LISTS' | 'FRIENDS_ONLY' | 'PUBLIC_ONLY';
export interface MealQuery { keyword: string; mode: DiscoveryMode; categories: Array<FoodCategoryV2>; priceMinFen?: number; priceMaxExclusiveFen?: number; source: MealSource; listId?: string; nearby: boolean; lat?: number; lon?: number; radiusMeters: number; coordinateSystem: string; excludedCardIds: Array<string>; }
export interface PersonalMealQuery { personalRandom: boolean; excludedCardIds: Array<string>; }
export interface MealCandidate { card: FoodCard; reasons: Array<string>; distanceMeters: number | null; }
export interface MealCandidatePage { candidates: Array<MealCandidate>; coverage: string; scannedCandidateCount: number; fetchedCandidateCount?: number; insufficient: boolean; sessionExhausted: boolean; emptyReason?: string; }
export interface PersonalMealCandidatePage extends MealCandidatePage { personalRandom: boolean; }
export interface MealChoiceRequest { requestId: string; cardId: string; }
export interface MealChoice { historyId: string; cardId: string; selectedAt: number; }
export interface MealHistoryItem extends MealChoice { merchantId: string; consumptionMode: string; card: FoodCard | null; }
export interface MealHistoryPage { items: Array<MealHistoryItem>; nextCursor: string; }
export type PollStatus = 'OPEN' | 'CLOSED' | 'CANCELLED';
export interface MealPoll { pollId: string; groupId: string; creatorUid: string; title: string; mode: 'CARD' | 'MERCHANT'; visibilityMode: 'NAMED' | 'ANONYMOUS'; consumptionMode: 'ANY' | 'DELIVERY' | 'DINE_IN'; status: PollStatus; deadlineAt: number | null; acceptingOptions: boolean; closeOutcome: string; closeReason: string; winnerOptionId: string; winnerResolvedAt: number | null; version: number; serverTime: number; }
export interface PollVoter { uid: string; nickname: string; }
export interface PollMerchant { merchantId: string; name: string; address: string; latitude: number; longitude: number; }
export interface MealPollOption { optionId: string; status: string; accessible: boolean; card: FoodCard | null; merchant: PollMerchant | null; voteCount: number; voters?: Array<PollVoter>; }
export interface MealPollResponse { poll: MealPoll; options: Array<MealPollOption>; myVote: string; }
export interface CreateMealPollRequest { requestId: string; groupId: string; title: string; mode: 'CARD' | 'MERCHANT'; visibilityMode: 'NAMED' | 'ANONYMOUS'; consumptionMode: 'ANY' | 'DELIVERY' | 'DINE_IN'; deadlineAt: number | null; }
export interface MealPollIdRequest { pollId: string; }
export interface MealPollMutationRequest extends MealPollIdRequest { version: number; cardId?: string; merchantId?: string; optionId?: string; }
