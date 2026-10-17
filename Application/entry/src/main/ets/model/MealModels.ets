/**
 * 【文件职责】群聊“一起选餐”投票的数据结构。
 */
import { FoodCard, FoodCategoryV2 } from './CloudContracts';
import { DiscoveryMode } from './DiscoveryModels';
// 候选来源。
export type MealSource = 'ALL' | 'MY_COLLECTIONS' | 'FRIENDS_ONLY' | 'PUBLIC_ONLY';
// 候选查询条件。
export interface MealQuery { keyword: string; mode: DiscoveryMode; categories: Array<FoodCategoryV2>; priceMinFen?: number; priceMaxExclusiveFen?: number; source: MealSource; nearby: boolean; lat?: number; lon?: number; radiusMeters: number; coordinateSystem: string; excludedCardIds: Array<string>; }
// 一个候选（卡片 + 推荐理由）。
export interface MealCandidate { card: FoodCard; reasons: Array<string>; distanceMeters: number | null; }
// 候选一页。
export interface MealCandidatePage { candidates: Array<MealCandidate>; coverage: string; scannedCandidateCount: number; fetchedCandidateCount?: number; insufficient: boolean; sessionExhausted: boolean; emptyReason?: string; }
// 投票状态。
export type PollStatus = 'OPEN' | 'CLOSED' | 'CANCELLED';
// 投票主体信息（具名或匿名、截止时间等）。
export interface MealPoll { pollId: string; groupId: string; creatorUid: string; title: string; mode: 'CARD' | 'MERCHANT'; visibilityMode: 'NAMED' | 'ANONYMOUS'; consumptionMode: 'ANY' | 'DELIVERY' | 'DINE_IN'; status: PollStatus; deadlineAt: number | null; acceptingOptions: boolean; closeOutcome: string; closeReason: string; winnerOptionId: string; winnerResolvedAt: number | null; version: number; serverTime: number; }
// 投票人。
export interface PollVoter { uid: string; nickname: string; }
// 作为选项的店铺。
export interface PollMerchant { merchantId: string; name: string; address: string; latitude: number; longitude: number; }
export interface MealPollOption { optionId: string; status: string; accessible: boolean; card: FoodCard | null; merchant: PollMerchant | null; voteCount: number; voters?: Array<PollVoter>; }
export interface MealPollResponse { poll: MealPoll; options: Array<MealPollOption>; myVote: string; }
export interface CreateMealPollRequest { requestId: string; groupId: string; title: string; mode: 'CARD' | 'MERCHANT'; visibilityMode: 'NAMED' | 'ANONYMOUS'; consumptionMode: 'ANY' | 'DELIVERY' | 'DINE_IN'; deadlineAt: number | null; }
export interface MealPollIdRequest { pollId: string; }
export interface MealPollMutationRequest extends MealPollIdRequest { version: number; cardId?: string; merchantId?: string; optionId?: string; }
