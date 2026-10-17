/**
 * 【文件职责】卡片互动（👍/🖕 反应与❤️收藏）的云端读写封装，并逐字段校验响应是否完整。
 * 【链路位置】CardInteractionController → 本文件 → AccountRequestGuard → CloudGateway → shike-content
 * （get-card-interaction-state / set-card-interaction / get-card-interaction-receipt / get-card-interaction-counts）。
 * 【新人注意】页面不要直接用本类，统一通过 CardInteractionController（它负责乐观更新、去重与超时恢复）。
 * 协议版本固定为 3，云端返回的结构不符时直接报错，提示核对云端部署版本。
 */
import { InteractionIdentity, InteractionState, InteractionWriteRequest, InteractionCommit,
  InteractionReceiptRequest, InteractionReceipt, InteractionCounts, validInteractionReaction } from '../model/CardInteractionModels';
import { AccountRequestGuard } from '../service/AccountRequestGuard';
import { ReadRequestOptions } from '../service/ReadScheduler';

// 互动读写仓库（只被 CardInteractionController 使用）。
export class CardInteractionRepository {
  // 校验互动状态的公共字段：卡片 id、协议版本 3、反应值合法、收藏为布尔值、写入版本为非负整数。
  private validState(cardId: string, protocol: number, reaction: string, favorited: boolean, version: number): boolean {
    return cardId.length > 0 && protocol === 3 && validInteractionReaction(reaction) &&
      typeof favorited === 'boolean' && Number.isSafeInteger(version) && version >= 0;
  }
  // 读取“我”对这张卡片的互动状态以及功能开关（反应/收藏是否开放、是否已完成数据迁移）。
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
  // 写入一次互动（反应和/或收藏）。request.requestId 由控制器生成，同一次点击重发时保持不变，云端据此去重。
  async write(request: InteractionWriteRequest): Promise<InteractionCommit> {
    const result: InteractionCommit = await AccountRequestGuard.authenticated<InteractionCommit>('set-card-interaction', request);
    this.checkCommit(result, request.cardId, request.requestId);
    return result;
  }
  // 校验写入回执：必须对应同一卡片与同一 requestId，状态为 COMMITTED（已写入）或 UNCHANGED（无变化）。
  checkCommit(result: InteractionCommit, cardId: string, requestId: string): void {
    if (result === undefined || result === null || result.cardId !== cardId || result.requestId !== requestId ||
      !this.validState(result.cardId, result.protocolVersion, result.myReaction, result.viewerFavorited, result.writeVersion) ||
      (result.status !== 'COMMITTED' && result.status !== 'UNCHANGED')) throw new Error('保存回执不完整，请核对原请求结果。');
  }
  // 按 requestId 查询之前那次写入是否已生效（写入超时、结果未知时使用）。found=false 表示云端没有收到。
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
  // 读取赞/踩/收藏总数（次要优先级，可被页面离开取消）。
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
