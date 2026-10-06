import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { geoLocationManager } from '@kit.LocationKit';
import { map, mapCommon } from '@kit.MapKit';
import { RoundedLocation } from '../model/CloudContracts';
import { NearbyPerformanceTrace } from './NearbyPerformanceTrace';

const LOCATION_PERMISSIONS: Array<Permissions> = [
  'ohos.permission.APPROXIMATELY_LOCATION',
  'ohos.permission.LOCATION'
];
const FAST_LOCATION_CACHE_TTL_MS: number = 90 * 1000;

class RoundedLocationCache {
  location: RoundedLocation = { latE3: 0, lonE3: 0, district: '当前位置' };
  expiresAt: number = 0;
}

export class LocationService {
  private static fastLocationCache: RoundedLocationCache | undefined = undefined;
  private static fastLocationCacheExpiryTimer: number | undefined = undefined;
  private static fastLocationRequest: Promise<RoundedLocation> | undefined = undefined;
  private static fastLocationCacheGeneration: number = 0;

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

  private static copyLocation(location: RoundedLocation): RoundedLocation {
    return {
      latE3: location.latE3,
      lonE3: location.lonE3,
      district: location.district
    };
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

  private static clearFastLocationCache(): void {
    LocationService.fastLocationCache = undefined;
    if (LocationService.fastLocationCacheExpiryTimer !== undefined) {
      clearTimeout(LocationService.fastLocationCacheExpiryTimer);
      LocationService.fastLocationCacheExpiryTimer = undefined;
    }
  }

  private static cacheFastLocation(location: RoundedLocation): void {
    LocationService.clearFastLocationCache();
    const cache = new RoundedLocationCache();
    cache.location = LocationService.copyLocation(location);
    cache.expiresAt = Date.now() + FAST_LOCATION_CACHE_TTL_MS;
    LocationService.fastLocationCache = cache;
    LocationService.fastLocationCacheExpiryTimer = setTimeout((): void => {
      if (LocationService.fastLocationCache === cache) {
        LocationService.fastLocationCache = undefined;
        LocationService.fastLocationCacheExpiryTimer = undefined;
      }
    }, FAST_LOCATION_CACHE_TTL_MS);
  }

  /** Clears the non-persistent nearby cache when the signed-in session ends. */
  static clearCachedRoundedLocation(): void {
    LocationService.fastLocationCacheGeneration += 1;
    LocationService.clearFastLocationCache();
    LocationService.fastLocationRequest = undefined;
  }

  private static async requestFreshRoundedLocation(context: common.UIAbilityContext,
    requestPermission: boolean): Promise<RoundedLocation> {
    const traceTaskId: number = NearbyPerformanceTrace.start('shike.nearby.location.rounded');
    try {
      if (requestPermission) {
        await LocationService.ensureFullLocationPermission(context);
      } else if (!await LocationService.hasFullLocationPermission(context)) {
        throw new Error('定位权限未完整授权。');
      }
      if (!geoLocationManager.isLocationEnabled()) {
        throw new Error('定位服务尚未开启，请在系统设置中开启后重试。');
      }
      const request: geoLocationManager.SingleLocationRequest = {
        locatingPriority: geoLocationManager.LocatingPriority.PRIORITY_ACCURACY,
        locatingTimeoutMs: 10000
      };
      const location = await geoLocationManager.getCurrentLocation(request);
      return {
        latE3: Math.round(location.latitude * 1000),
        lonE3: Math.round(location.longitude * 1000),
        district: '当前位置'
      };
    } finally {
      NearbyPerformanceTrace.finish('shike.nearby.location.rounded', traceTaskId);
    }
  }

  /**
   * Nearby refreshes reuse an in-memory rounded coordinate for 90 seconds.
   * The value is never persisted, and an explicit pull-to-refresh bypasses it.
   */
  private static async getRoundedLocation(context: common.UIAbilityContext,
    forceRefresh: boolean = false, requestPermission: boolean = true): Promise<RoundedLocation> {
    const cached: RoundedLocationCache | undefined = LocationService.fastLocationCache;
    if (cached !== undefined && cached.expiresAt <= Date.now()) {
      LocationService.clearFastLocationCache();
    }
    if (!forceRefresh && cached !== undefined && cached.expiresAt > Date.now()) {
      return LocationService.copyLocation(cached.location);
    }
    const inFlight: Promise<RoundedLocation> | undefined = LocationService.fastLocationRequest;
    if (inFlight !== undefined) return LocationService.copyLocation(await inFlight);
    const cacheGeneration: number = LocationService.fastLocationCacheGeneration;
    const locationRequest: Promise<RoundedLocation> = LocationService.requestFreshRoundedLocation(context, requestPermission);
    LocationService.fastLocationRequest = locationRequest;
    try {
      const location: RoundedLocation = await locationRequest;
      if (cacheGeneration === LocationService.fastLocationCacheGeneration) {
        LocationService.cacheFastLocation(location);
      }
      return LocationService.copyLocation(location);
    } finally {
      if (LocationService.fastLocationRequest === locationRequest) {
        LocationService.fastLocationRequest = undefined;
      }
    }
  }

  static async permissionSummary(context: common.UIAbilityContext): Promise<string> {
    const authorized: boolean = await LocationService.hasFullLocationPermission(context);
    return authorized
      ? '精确位置：已授权（仅使用期间）'
      : '精确位置：未完整授权';
  }

  static async resolveDistrict(latE3: number, lonE3: number): Promise<string> {
    let district = '当前位置';
    try {
      const addresses = await geoLocationManager.getAddressesFromLocation({
        latitude: latE3 / 1000,
        longitude: lonE3 / 1000,
        maxItems: 1,
        locale: 'zh_CN'
      });
      if (addresses.length > 0) {
        district = addresses[0].subAdministrativeArea || addresses[0].administrativeArea ||
          addresses[0].locality || '当前位置';
      }
    } catch (_error) {
      // Reverse geocoding is display-only. Precise location success still permits the operation.
    }
    return district;
  }

  /**
   * Keeps the nearby recommendation's critical path to permission and precise
   * coordinates. The page resolves its display-only administrative area after
   * the card list becomes available.
   */
  static async getPreciseRoundedLocationFast(context: common.UIAbilityContext,
    forceRefresh: boolean = false, requestPermission: boolean = true): Promise<RoundedLocation> {
    return LocationService.getRoundedLocation(context, forceRefresh, requestPermission);
  }

  /** Retains the existing publish/ranking contract with an administrative area. */
  static async getPreciseRoundedLocation(context: common.UIAbilityContext): Promise<RoundedLocation> {
    const location: RoundedLocation = await LocationService.getRoundedLocation(context, true);
    return {
      latE3: location.latE3,
      lonE3: location.lonE3,
      district: await LocationService.resolveDistrict(location.latE3, location.lonE3)
    };
  }
}
