import { FoodCard } from './CloudContracts';
export interface UserPageProfile { uid: string; nickname: string; avatarPath: string; avatarBucket: string; publishCount: number; coverPath?: string; coverBucket?: string; }
export interface UserPageRequest { userUid: string; cursor: string; pageSize: number; }
export interface UserPageResponse { relationshipState?: 'SELF' | 'FRIEND' | 'VISITOR'; profile: UserPageProfile; cards: Array<FoodCard>; nextCursor: string; }
