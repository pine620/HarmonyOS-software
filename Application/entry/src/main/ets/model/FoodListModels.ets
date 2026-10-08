import { FoodCard } from './CloudContracts';
export interface FoodList { listId: string; name: string; coverCardId: string; sortOrder: number; version: number; updatedAt: number; cover?: FoodCard | null; }
export interface FoodListsPageResult { lists: Array<FoodList>; systemList: FoodList; nextCursor: string; }
export type PersonalFoodStatus = 'NONE' | 'WANT_TO_EAT' | 'EATEN';
export interface PersonalFoodState { cardId: string; state: PersonalFoodStatus; privateNote: string; eatenAt: number | null; personalScore: number | null; version: number; updatedAt: number; }
export interface PersonalFoodRequest extends PersonalFoodState { clear?: boolean; }
export interface FoodListItem { cardId: string; card: FoodCard | null; accessible: boolean; sortKey: number; personal: PersonalFoodState; }
export interface FoodListItemsPage { items: Array<FoodListItem>; nextCursor: string; }
export interface CursorRequest { cursor: string; }
export interface CreateFoodListRequest { requestId: string; name: string; }
export interface UpdateFoodListRequest { listId: string; version: number; name?: string; coverCardId?: string; sortOrder?: number; }
export interface FoodListItemRequest { listId: string; cardId: string; version: number; }
export interface FoodListItemsRequest { listId: string; cursor: string; pageSize: number; }
export interface ReorderFoodListRequest extends FoodListItemRequest { beforeCardId: string; }
export interface VersionedResult { success: boolean; version?: number; }
export function emptyPersonal(cardId: string): PersonalFoodState { return { cardId, state: 'NONE', privateNote: '', eatenAt: null, personalScore: null, version: 0, updatedAt: 0 }; }
