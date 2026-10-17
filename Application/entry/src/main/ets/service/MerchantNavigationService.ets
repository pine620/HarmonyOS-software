import { common } from '@kit.AbilityKit';
import { petalMaps, mapCommon } from '@kit.MapKit';
import { Merchant } from '../model/MerchantModels';
/**
 * 【文件职责】调起地图 App 导航到店铺。由用户主动发起；这里不采集、也不保存出发位置。只允许已核验（官方 POI 或审核通过）的店铺。
 */
export class MerchantNavigationService {
  // 打开导航（店铺未核验时抛错提示）。
  static async open(context: common.UIAbilityContext, merchant: Merchant): Promise<void> {
    if (!['VERIFIED_PROVIDER', 'USER_CONFIRMED_APPROVED'].includes(merchant.verificationStatus) || merchant.coordinateSystem !== 'GCJ02' || !Number.isSafeInteger(merchant.latitudeE6) || Math.abs(merchant.latitudeE6) > 90000000 || !Number.isSafeInteger(merchant.longitudeE6) || Math.abs(merchant.longitudeE6) > 180000000) throw new Error('商家坐标尚未验证，暂不能导航。');
    if (!canIUse('SystemCapability.Map.Core')) throw new Error('当前设备暂不支持地图导航。');
    const point: mapCommon.LatLng = { latitude: merchant.latitudeE6 / 1000000, longitude: merchant.longitudeE6 / 1000000 };
    const parameters: petalMaps.RoutePlanParams = { destinationPosition: point, destinationName: merchant.name, coordinateType: mapCommon.CoordinateType.GCJ02 };
    await petalMaps.openMapRoutePlan(context, parameters);
  }
}
