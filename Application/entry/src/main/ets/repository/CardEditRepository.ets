/**
 * 【文件职责】作者修改已发布卡片：读取编辑上下文、提交修订、撤回修订。
 * 【链路位置】CreateCardPage（编辑模式）→ 本文件 → shike-content（stage1 模块）。
 * 修订直接生效时 CloudGateway 会清理读缓存并撤销旧图片授权。
 */
import { common } from '@kit.AbilityKit';
import { CardEditContextResponse, CardIdRequest, CardRevisionIdRequest, CardRevisionResponse,
  OperationResponse, SubmitCardRevisionRequest } from '../model/CloudContracts';
import { AuthService } from '../service/AuthService';
import { CloudGateway } from '../service/CloudGateway';

// 作者修改仓库（无状态）。
export class CardEditRepository {
  // 读取编辑上下文：当前内容、基准版本号与可编辑状态，提交时用于冲突检测。
  async context(context: common.Context, cardId: string): Promise<CardEditContextResponse> {
    await AuthService.ensureSession(context);
    const request: CardIdRequest = { cardId };
    return CloudGateway.callAuthenticated<CardEditContextResponse>('get-card-edit-context', request);
  }
  // 提交一次修订；若期间卡片已被改动，云端返回 CONFLICT。
  async submit(context: common.Context, request: SubmitCardRevisionRequest): Promise<CardRevisionResponse> {
    await AuthService.ensureSession(context);
    return CloudGateway.callAuthenticated<CardRevisionResponse>('submit-card-revision', request);
  }
  // 撤回尚未生效的修订。
  async withdraw(context: common.Context, revisionId: string): Promise<OperationResponse> {
    await AuthService.ensureSession(context);
    const request: CardRevisionIdRequest = { revisionId };
    return CloudGateway.callAuthenticated<OperationResponse>('withdraw-card-revision', request);
  }
}
