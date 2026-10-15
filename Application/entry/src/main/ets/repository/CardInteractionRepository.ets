import { InteractionIdentity, InteractionState, InteractionWriteRequest, InteractionCommit,
  InteractionReceiptRequest, InteractionReceipt, InteractionCounts, validInteractionReaction } from '../model/CardInteractionModels';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { ReadRequestOptions } from '../service/ReadScheduler';

export class CardInteractionRepository {
  private validState(cardId: string, protocol: number, reaction: string, favorited: boolean, version: number): boolean {
    return cardId.length > 0 && protocol === 3 && validInteractionReaction(reaction) &&
      typeof favorited === 'boolean' && Number.isSafeInteger(version) && version >= 0;
  }
  async state(cardId: string): Promise<InteractionState> {
    const request: InteractionIdentity = { cardId };
    const options: ReadRequestOptions = { priority: 'metadata' };
    const result: InteractionState = await AccountRequestGuard.authenticated<InteractionState>('get-card-interaction-state', request, options);
    if (result === undefined || result === null || result.cardId !== cardId ||
      !this.validState(result.cardId, result.protocolVersion, result.myReaction, result.viewerFavorited, result.writeVersion) ||
      typeof result.reactionsEnabled !== 'boolean' || typeof result.collectionEnabled !== 'boolean' || typeof result.collectionReady !== 'boolean' ||
      typeof result.reactionsReason !== 'string' || typeof result.collectionReason !== 'string') {
      throw new Error('互动状态响应不完整，请核对云端部署版本。');
    }
    return result;
  }
  async write(request: InteractionWriteRequest): Promise<InteractionCommit> {
    const result: InteractionCommit = await AccountRequestGuard.authenticated<InteractionCommit>('set-card-interaction', request);
    this.checkCommit(result, request.cardId, request.requestId);
    return result;
  }
  checkCommit(result: InteractionCommit, cardId: string, requestId: string): void {
    if (result === undefined || result === null || result.cardId !== cardId || result.requestId !== requestId ||
      !this.validState(result.cardId, result.protocolVersion, result.myReaction, result.viewerFavorited, result.writeVersion) ||
      (result.status !== 'COMMITTED' && result.status !== 'UNCHANGED')) throw new Error('保存回执不完整，请核对原请求结果。');
  }
  async receipt(cardId: string, requestId: string): Promise<InteractionReceipt> {
    const request: InteractionReceiptRequest = { cardId, requestId };
    const options: ReadRequestOptions = { priority: 'metadata' };
    const result: InteractionReceipt = await AccountRequestGuard.authenticated<InteractionReceipt>('get-card-interaction-receipt', request, options);
    if (result === undefined || result === null || result.protocolVersion !== 3 || result.cardId !== cardId ||
      result.requestId !== requestId || typeof result.found !== 'boolean') throw new Error('回执查询响应不完整。');
    if (result.found) {
      if (result.receipt === null || result.receipt === undefined) throw new Error('回执内容缺失。');
      this.checkCommit(result.receipt, cardId, requestId);
    }
    return result;
  }
  async counts(cardId: string, guard: ReadRequestOptions = {}): Promise<InteractionCounts> {
    const request: InteractionIdentity = { cardId };
    const options: ReadRequestOptions = { priority: 'secondary', mayContinue: guard.mayContinue };
    const result: InteractionCounts = await AccountRequestGuard.authenticated<InteractionCounts>('get-card-interaction-counts', request, options);
    if (result === undefined || result === null || result.protocolVersion !== 3 || result.cardId !== cardId ||
      !this.validState(result.cardId, result.protocolVersion, result.myReaction, result.viewerFavorited, result.writeVersion) ||
      !Number.isSafeInteger(result.likeCount) || result.likeCount < 0 || !Number.isSafeInteger(result.dislikeCount) || result.dislikeCount < 0 ||
      !Number.isSafeInteger(result.favoriteCount) || result.favoriteCount < 0) throw new Error('互动计数响应不完整。');
    return result;
  }
}
