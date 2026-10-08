import { common } from '@kit.AbilityKit';
import { petalMaps, mapCommon } from '@kit.MapKit';
import { Merchant } from '../model/MerchantModels';
/** The user initiates navigation; no origin position is collected or persisted here. */
export class MerchantNavigationService {
  static async open(context: common.UIAbilityContext, merchant: Merchant): Promise<void> {
    if (!['VERIFIED_PROVIDER', 'USER_CONFIRMED_APPROVED'].includes(merchant.verificationStatus) || merchant.coordinateSystem !== 'GCJ02' || !Number.isSafeInteger(merchant.latitudeE6) || Math.abs(merchant.latitudeE6) > 90000000 || !Number.isSafeInteger(merchant.longitudeE6) || Math.abs(merchant.longitudeE6) > 180000000) throw new Error('商家坐标尚未验证，暂不能导航。');
    if (!canIUse('SystemCapability.Map.Core')) throw new Error('当前设备暂不支持地图导航。');
    const point: mapCommon.LatLng = { latitude: merchant.latitudeE6 / 1000000, longitude: merchant.longitudeE6 / 1000000 };
    const parameters: petalMaps.RoutePlanParams = { destinationPosition: point, destinationName: merchant.name, coordinateType: mapCommon.CoordinateType.GCJ02 };
    await petalMaps.openMapRoutePlan(context, parameters);
  }
}
