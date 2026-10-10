import { common } from '@kit.AbilityKit';
import { CardEditContextResponse, CardIdRequest, CardRevisionIdRequest, CardRevisionResponse,
  OperationResponse, SubmitCardRevisionRequest } from '../model/CloudContracts';
import { AuthService } from '../service/AuthService';
import { CloudGateway } from '../service/CloudGateway';

export class CardEditRepository {
  async context(context: common.Context, cardId: string): Promise<CardEditContextResponse> {
    await AuthService.ensureSession(context);
    const request: CardIdRequest = { cardId };
    return CloudGateway.callAuthenticated<CardEditContextResponse>('get-card-edit-context', request);
  }
  async submit(context: common.Context, request: SubmitCardRevisionRequest): Promise<CardRevisionResponse> {
    await AuthService.ensureSession(context);
    return CloudGateway.callAuthenticated<CardRevisionResponse>('submit-card-revision', request);
  }
  async withdraw(context: common.Context, revisionId: string): Promise<OperationResponse> {
    await AuthService.ensureSession(context);
    const request: CardRevisionIdRequest = { revisionId };
    return CloudGateway.callAuthenticated<OperationResponse>('withdraw-card-revision', request);
  }
}
