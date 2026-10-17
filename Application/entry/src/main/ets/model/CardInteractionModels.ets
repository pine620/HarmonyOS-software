/**
 * 【文件职责】卡片互动（反应 / 收藏）协议 v3 的数据结构，供 CardInteractionRepository 与 CardInteractionController 使用。
 */
import { CardReactionType } from './CloudContracts';

// 反应值：LIKE / DISLIKE / 空串（无反应）。
export type InteractionReaction = CardReactionType | '';
// 只含卡片 id 的请求。
export interface InteractionIdentity { cardId: string; }
// 按 requestId 查询写入回执的请求。
export interface InteractionReceiptRequest extends InteractionIdentity { requestId: string; }
// 写入内容：只包含要修改的字段。
export interface InteractionPatch { reaction?: InteractionReaction; favorited?: boolean; }
// 期望的当前状态（写入版本 + 原值），服务端不一致时拒绝，避免覆盖别处的修改。
export interface InteractionExpected { writeVersion: number; myReaction?: InteractionReaction; viewerFavorited?: boolean; }
// 一次互动写入请求（requestId 用于幂等）。
export interface InteractionWriteRequest extends InteractionReceiptRequest { patch: InteractionPatch; expected: InteractionExpected; }
// “我”对卡片的互动状态与功能开关。
export interface InteractionState extends InteractionIdentity {
  protocolVersion: number;
  myReaction: InteractionReaction;
  viewerFavorited: boolean;
  writeVersion: number;
  reactionsEnabled: boolean;
  reactionsReason: string;
  collectionEnabled: boolean;
  collectionReady: boolean;
  collectionReason: string;
}
// 写入回执：COMMITTED 已写入 / UNCHANGED 无需修改。
export interface InteractionCommit extends InteractionReceiptRequest {
  protocolVersion: number;
  status: 'COMMITTED' | 'UNCHANGED';
  myReaction: InteractionReaction;
  viewerFavorited: boolean;
  writeVersion: number;
}
// 回执查询结果：found=false 表示服务端从未收到这次写入。
export interface InteractionReceipt extends InteractionReceiptRequest {
  protocolVersion: number;
  found: boolean;
  receipt: InteractionCommit | null;
}
// 赞 / 踩 / 收藏总数。
export interface InteractionCounts extends InteractionIdentity {
  protocolVersion: number; likeCount: number; dislikeCount: number; favoriteCount: number;
  writeVersion: number; myReaction: InteractionReaction; viewerFavorited: boolean;
}
// 本机意图日志中的一条记录。
export interface InteractionJournal {
  owner: string; createdAt: number; request: InteractionWriteRequest;
}
// 界面显示用的合成状态（确认状态 + 未确认意图 + 忙碌标记 + 提示）。
export interface InteractionView {
  known: boolean; reaction: InteractionReaction; favorited: boolean;
  reactionsEnabled: boolean; reactionsReason: string;
  collectionEnabled: boolean; collectionReady: boolean; collectionReason: string;
  reactionBusy: boolean; favoriteBusy: boolean; recovering: boolean; canRetry: boolean;
  likeCount: number; dislikeCount: number; favoriteCount: number; countsKnown: boolean;
  message: string; countsMessage: string;
}
// 校验反应值是否合法。
export function validInteractionReaction(value: string): boolean {
  return value === '' || value === 'LIKE' || value === 'DISLIKE';
}
