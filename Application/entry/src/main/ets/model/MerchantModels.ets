/**
 * 【文件职责】店铺与外卖平台的数据结构。
 */
// 店铺坐标系：GCJ02（国内地图）/ WGS84 / 未知。地图功能要求 GCJ02。
export type MerchantCoordinateSystem = 'GCJ02' | 'WGS84' | 'UNKNOWN';
// 店铺核验状态：官方 POI / 用户确认待审 / 用户确认已通过 等。
export type MerchantVerificationStatus = 'VERIFIED_PROVIDER' | 'USER_CONFIRMED_PENDING' | 'USER_CONFIRMED_APPROVED' | 'REJECTED';

// 店铺。
export interface Merchant {
  merchantId: string;
  name: string;
  address: string;
  district: string;
  sourceType: 'HUAWEI_POI' | 'USER_CONFIRMED';
  provider: string;
  providerPoiId: string;
  latitudeE6: number;
  longitudeE6: number;
  coordinateSystem: MerchantCoordinateSystem;
  verificationStatus: MerchantVerificationStatus;
  mapVisible: boolean;
  publicRecommendationCount: number;
  publicDeliveryCount: number;
  publicDineInCount: number;
  updatedAt: number;
  reviewAction: string;
  reviewReason: string;
}

// 地点选择器返回的结果。
export interface MerchantChoice {
  providerPoiId: string;
  name: string;
  address: string;
  latitudeE6: number;
  longitudeE6: number;
}

// 解析官方地点请求。
export interface ResolveMerchantRequest {
  provider: 'HUAWEI_MAP';
  providerPoiId: string;
}

// 创建用户店铺请求。
export interface CreateUserMerchantRequest {
  requestId: string;
  name: string;
  address: string;
  latitudeE6: number;
  longitudeE6: number;
}

// 更新用户店铺请求。
export interface UpdateUserMerchantRequest extends CreateUserMerchantRequest {
  merchantId: string;
  expectedUpdatedAt: number;
}

export interface MerchantIdRequest { merchantId: string; }
export interface MerchantResponse { merchant: Merchant; alreadyProcessed?: boolean; }
// 店铺能力开关。
export interface Stage2Capabilities {
  pickerCoordinateSystem: MerchantCoordinateSystem;
  providerVerificationEnabled: boolean;
}

// 外卖平台选项。
export interface DeliveryPlatform {
  key: string;
  label: string;
  enabled: boolean;
  sortOrder: number;
}

// Remote Config 下发的外卖平台文档（version=1）。
export interface DeliveryPlatformDocument {
  version: number;
  platforms: Array<DeliveryPlatform>;
}
