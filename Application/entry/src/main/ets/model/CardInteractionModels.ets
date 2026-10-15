import { CardReactionType } from './CloudContracts';

export type InteractionReaction = CardReactionType | '';
export interface InteractionIdentity { cardId: string; }
export interface InteractionReceiptRequest extends InteractionIdentity { requestId: string; }
export interface InteractionPatch { reaction?: InteractionReaction; favorited?: boolean; }
export interface InteractionExpected { writeVersion: number; myReaction?: InteractionReaction; viewerFavorited?: boolean; }
export interface InteractionWriteRequest extends InteractionReceiptRequest { patch: InteractionPatch; expected: InteractionExpected; }
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
export interface InteractionCommit extends InteractionReceiptRequest {
  protocolVersion: number;
  status: 'COMMITTED' | 'UNCHANGED';
  myReaction: InteractionReaction;
  viewerFavorited: boolean;
  writeVersion: number;
}
export interface InteractionReceipt extends InteractionReceiptRequest {
  protocolVersion: number;
  found: boolean;
  receipt: InteractionCommit | null;
}
export interface InteractionCounts extends InteractionIdentity {
  protocolVersion: number; likeCount: number; dislikeCount: number; favoriteCount: number;
  writeVersion: number; myReaction: InteractionReaction; viewerFavorited: boolean;
}
export interface InteractionJournal {
  owner: string; createdAt: number; request: InteractionWriteRequest;
}
export interface InteractionView {
  known: boolean; reaction: InteractionReaction; favorited: boolean;
  reactionsEnabled: boolean; reactionsReason: string;
  collectionEnabled: boolean; collectionReady: boolean; collectionReason: string;
  reactionBusy: boolean; favoriteBusy: boolean; recovering: boolean; canRetry: boolean;
  likeCount: number; dislikeCount: number; favoriteCount: number; countsKnown: boolean;
  message: string; countsMessage: string;
}
export function validInteractionReaction(value: string): boolean {
  return value === '' || value === 'LIKE' || value === 'DISLIKE';
}
