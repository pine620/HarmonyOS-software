import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { geoLocationManager } from '@kit.LocationKit';
import { map, mapCommon } from '@kit.MapKit';

const LOCATION_PERMISSIONS: Array<Permissions> = [
  'ohos.permission.APPROXIMATELY_LOCATION',
  'ohos.permission.LOCATION'
];

// Location is read only for the map "locate me" action and the permission summary. No coordinate is cached
// or persisted on the device.
export class LocationService {
  static async hasFullLocationPermission(context: common.UIAbilityContext): Promise<boolean> {
    const manager = abilityAccessCtrl.createAtManager();
    const tokenId = context.applicationInfo.accessTokenId;
    const approximate = await manager.checkAccessToken(tokenId, LOCATION_PERMISSIONS[0]);
    const precise = await manager.checkAccessToken(tokenId, LOCATION_PERMISSIONS[1]);
    return approximate === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED &&
      precise === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  }

  private static async ensureFullLocationPermission(context: common.UIAbilityContext): Promise<void> {
    if (await LocationService.hasFullLocationPermission(context)) return;
    const manager = abilityAccessCtrl.createAtManager();
    const permissionResult = await manager.requestPermissionsFromUser(context, LOCATION_PERMISSIONS);
    if (permissionResult.authResults.length !== 2 || permissionResult.authResults[0] !== 0 ||
      permissionResult.authResults[1] !== 0) {
      throw new Error('定位到我需要模糊位置和精确位置授权；未授权仍可手动浏览地图。');
    }
  }

  /** Called only after the user confirms the map location action. No cloud write or persistent location cache. */
  static async getMapLocation(context: common.UIAbilityContext): Promise<mapCommon.LatLng> {
    await LocationService.ensureFullLocationPermission(context);
    if (!geoLocationManager.isLocationEnabled()) throw new Error('定位服务未开启，仍可手动浏览地图。');
    const request: geoLocationManager.SingleLocationRequest = {
      locatingPriority: geoLocationManager.LocatingPriority.PRIORITY_ACCURACY, locatingTimeoutMs: 10000
    };
    const location: geoLocationManager.Location = await geoLocationManager.getCurrentLocation(request);
    const point: mapCommon.LatLng = { latitude: location.latitude, longitude: location.longitude };
    const coordinate: mapCommon.CoordinateLatLng = { coordinateType: mapCommon.CoordinateType.WGS84, location: point };
    const adapted: Array<mapCommon.CoordinateLatLng> = await map.rectifyCoordinate(context, [coordinate]);
    if (adapted.length !== 1 || adapted[0].coordinateType !== mapCommon.CoordinateType.GCJ02) {
      throw new Error('当前地图查询仅支持已验证的 GCJ02 地区，请手动浏览默认区域。');
    }
    return adapted[0].location;
  }

  static async permissionSummary(context: common.UIAbilityContext): Promise<string> {
    const authorized: boolean = await LocationService.hasFullLocationPermission(context);
    return authorized
      ? '精确位置：已授权（仅使用期间）'
      : '精确位置：未完整授权';
  }
}
