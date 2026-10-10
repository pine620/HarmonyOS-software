export type MerchantCoordinateSystem = 'GCJ02' | 'WGS84' | 'UNKNOWN';
export type MerchantVerificationStatus = 'VERIFIED_PROVIDER' | 'USER_CONFIRMED_PENDING' | 'USER_CONFIRMED_APPROVED' | 'REJECTED';

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

export interface MerchantChoice {
  providerPoiId: string;
  name: string;
  address: string;
  latitudeE6: number;
  longitudeE6: number;
}

export interface ResolveMerchantRequest {
  provider: 'HUAWEI_MAP';
  providerPoiId: string;
}

export interface CreateUserMerchantRequest {
  requestId: string;
  name: string;
  address: string;
  latitudeE6: number;
  longitudeE6: number;
}

export interface UpdateUserMerchantRequest extends CreateUserMerchantRequest {
  merchantId: string;
  expectedUpdatedAt: number;
}

export interface MerchantIdRequest { merchantId: string; }
export interface MerchantResponse { merchant: Merchant; alreadyProcessed?: boolean; }
export interface Stage2Capabilities {
  pickerCoordinateSystem: MerchantCoordinateSystem;
  providerVerificationEnabled: boolean;
}

export interface DeliveryPlatform {
  key: string;
  label: string;
  enabled: boolean;
  sortOrder: number;
}

export interface DeliveryPlatformDocument {
  version: number;
  platforms: Array<DeliveryPlatform>;
}
