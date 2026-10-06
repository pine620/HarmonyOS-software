import { common } from '@kit.AbilityKit';
import { EmptyRequest } from '../model/CloudContracts';
import { CreateUserMerchantRequest, MerchantIdRequest, MerchantResponse, ResolveMerchantRequest,
  Stage2Capabilities, UpdateUserMerchantRequest } from '../model/MerchantModels';
import { AuthService } from '../service/AuthService';
import { CloudGateway } from '../service/CloudGateway';

export class MerchantRepository {
  async capabilities(context: common.Context): Promise<Stage2Capabilities> {
    await AuthService.ensureSession(context);
    const request: EmptyRequest = {};
    return CloudGateway.callAuthenticated<Stage2Capabilities>('get-stage2-capabilities', request);
  }
  async resolve(context: common.Context, request: ResolveMerchantRequest): Promise<MerchantResponse> {
    await AuthService.ensureSession(context);
    return CloudGateway.callAuthenticated<MerchantResponse>('resolve-merchant', request);
  }
  async create(context: common.Context, request: CreateUserMerchantRequest): Promise<MerchantResponse> {
    await AuthService.ensureSession(context);
    return CloudGateway.callAuthenticated<MerchantResponse>('create-user-merchant', request);
  }
  async update(context: common.Context, request: UpdateUserMerchantRequest): Promise<MerchantResponse> {
    await AuthService.ensureSession(context);
    return CloudGateway.callAuthenticated<MerchantResponse>('update-user-merchant', request);
  }
  async get(context: common.Context, merchantId: string): Promise<MerchantResponse> {
    await AuthService.ensureSession(context);
    const request: MerchantIdRequest = { merchantId };
    return CloudGateway.callAuthenticated<MerchantResponse>('get-merchant', request);
  }
}
