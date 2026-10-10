import { FoodCard, FoodCategoryV2 } from './CloudContracts';
export type PreferredMode = 'ANY' | 'DELIVERY' | 'DINE_IN';
export interface TastePreference {
  likedCategories: Array<FoodCategoryV2>; lessCategories: Array<FoodCategoryV2>;
  preferredMode: PreferredMode; budgetMinFen: number | null; budgetMaxFen: number | null;
  version: number; updatedAt: number;
}
export interface PreferenceClearRequest { field: 'ALL' | 'LIKED' | 'LESS' | 'MODE' | 'BUDGET'; version: number; }
export interface RecommendationQuery { cursor: string; pageSize: number; preference?: TastePreference; }
export interface RecommendationReason { cardId: string; reasons: Array<string>; exploration: boolean; }
export interface RecommendationPage { cards: Array<FoodCard>; reasons: Array<RecommendationReason>; seed: string; nextCursor: string; coverage: string; scannedCandidateCount: number; consumedCandidateCount?: number; fetchedCandidateCount?: number; sessionExhausted: boolean; }
export interface Stage47Capabilities { reactionsEnabled: boolean; mealEnabled: boolean; merchantEnabled: boolean; collectionEnabled?: boolean; protocolVersion?: number; reactionsReason?: string; rankingsEnabled?: boolean; rankingsReason?: string; }
export function emptyPreference(): TastePreference { return { likedCategories: [], lessCategories: [], preferredMode: 'ANY', budgetMinFen: null, budgetMaxFen: null, version: 0, updatedAt: 0 }; }
export function copyPreference(p: TastePreference): TastePreference { return { likedCategories: p.likedCategories.slice(), lessCategories: p.lessCategories.slice(), preferredMode: p.preferredMode, budgetMinFen: p.budgetMinFen, budgetMaxFen: p.budgetMaxFen, version: p.version, updatedAt: p.updatedAt }; }
