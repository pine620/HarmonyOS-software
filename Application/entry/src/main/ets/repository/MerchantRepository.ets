/**
 * 【文件职责】店铺相关调用：店铺能力开关、解析官方 POI 店铺、创建/更新用户自建店铺、读取店铺。
 * 【链路位置】CreateCardPage（关联店铺）、CardDetailPage（店铺信息）→ 本文件 → shike-content（stage2-services.js）。
 */
import { common } from '@kit.AbilityKit';
import { EmptyRequest } from '../model/CloudContracts';
import { CreateUserMerchantRequest, MerchantIdRequest, MerchantResponse, ResolveMerchantRequest,
  Stage2Capabilities, UpdateUserMerchantRequest } from '../model/MerchantModels';
import { AuthService } from '../service/AuthService';
import { CloudGateway } from '../service/CloudGateway';

// 店铺仓库（无状态）。
export class MerchantRepository {
  // 读取店铺能力：选点坐标系、是否开放官方 POI 校验等。
  async capabilities(context: common.Context): Promise<Stage2Capabilities> {
    await AuthService.ensureSession(context);
    const request: EmptyRequest = {};
    return CloudGateway.callAuthenticated<Stage2Capabilities>('get-stage2-capabilities', request);
  }
  // 把地图上选中的官方地点解析成食刻店铺（不存在时由云端创建）。
  async resolve(context: common.Context, request: ResolveMerchantRequest): Promise<MerchantResponse> {
    await AuthService.ensureSession(context);
    return CloudGateway.callAuthenticated<MerchantResponse>('resolve-merchant', request);
  }
  // 创建用户自建店铺（官方 POI 不可用时）。
  async create(context: common.Context, request: CreateUserMerchantRequest): Promise<MerchantResponse> {
    await AuthService.ensureSession(context);
    return CloudGateway.callAuthenticated<MerchantResponse>('create-user-merchant', request);
  }
  // 更新自己创建的店铺信息。
  async update(context: common.Context, request: UpdateUserMerchantRequest): Promise<MerchantResponse> {
    await AuthService.ensureSession(context);
    return CloudGateway.callAuthenticated<MerchantResponse>('update-user-merchant', request);
  }
  // 按 id 读取店铺详情。
  async get(context: common.Context, merchantId: string): Promise<MerchantResponse> {
    await AuthService.ensureSession(context);
    const request: MerchantIdRequest = { merchantId };
    return CloudGateway.callAuthenticated<MerchantResponse>('get-merchant', request);
  }
}
