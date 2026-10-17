/**
 * 【文件职责】用户主页的数据结构（get-user-page）。
 */
import { FoodCard } from './CloudContracts';
// 主页资料。
export interface UserPageProfile { uid: string; nickname: string; avatarPath: string; avatarBucket: string; publishCount: number; coverPath?: string; coverBucket?: string; }
// 主页请求（分页）。
export interface UserPageRequest { userUid: string; cursor: string; pageSize: number; }
// 主页响应：与“我”的关系、资料与公开卡片。
export interface UserPageResponse { relationshipState?: 'SELF' | 'FRIEND' | 'VISITOR'; profile: UserPageProfile; cards: Array<FoodCard>; nextCursor: string; }
