import { FoodCard } from './CloudContracts';
export interface UserPageProfile { uid: string; nickname: string; avatarPath: string; avatarBucket: string; publishCount: number; coverPath?: string; coverBucket?: string; }
export interface UserPageRequest { userUid: string; cursor: string; pageSize: number; }
export interface UserPageResponse { relationshipState?: 'SELF' | 'FRIEND' | 'VISITOR'; profile: UserPageProfile; cards: Array<FoodCard>; nextCursor: string; }
export interface MerchantRankingRequest { kind: 'HIGH_SCORE' | 'FRIENDS'; lat: number; lon: number; coordinateSystem: string; centerSource: string; cursor: string; }
export interface MerchantRankingPage { cards: Array<FoodCard>; nextCursor: string; coverage: string; scannedCandidateCount: number; radiusMeters: number; centerSource: string; }
