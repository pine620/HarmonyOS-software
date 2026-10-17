/**
 * 【文件职责】发布页“选择店铺位置”：调用 Map Kit 地点选择器，由用户主动选点；
 * 起始中心使用已选店铺或上次选点位置（只存内存），绝不自动请求设备定位。
 */
import { common } from '@kit.AbilityKit';
import { mapCommon, sceneMap } from '@kit.MapKit';
import { Merchant, MerchantChoice } from '../model/MerchantModels';

// 店铺选点（静态类）。
export class MerchantLocationPicker {
  // 上次选点的地图中心（只在内存中，App 重启即丢失）。
  private static lastCenter: mapCommon.LatLng | undefined = undefined;
  // 清除上次选点中心（退出发布页时）。
  static clearSelectionCenter(): void { MerchantLocationPicker.lastCenter = undefined; }
  // 打开地点选择器，返回用户选择的地点信息；用户取消返回 undefined。
  static async choose(context: common.UIAbilityContext, selected?: Merchant): Promise<MerchantChoice | undefined> {
    // 显式给定固定的起始中心，而不是省略中心（省略会触发请求设备定位）。这只是浏览起点，不是用户位置，也不会保存为店铺。
    const center: mapCommon.LatLng = { latitude: 39.9042, longitude: 116.4074 };
    void selected;
    const last: mapCommon.LatLng | undefined = MerchantLocationPicker.lastCenter;
    if (last !== undefined) {
      center.latitude = last.latitude; center.longitude = last.longitude;
    }
    let cancelled: boolean = false;
    const options: sceneMap.LocationChoosingOptions = { location: center, searchEnabled: true, showNearbyPoi: true,
      cancelCallback: (): void => { cancelled = true; } };
    try {
      const result: sceneMap.LocationChoosingResult = await sceneMap.chooseLocation(context, options);
      if (cancelled) return undefined;
      const latitude: number = result.location.latitude;
      const longitude: number = result.location.longitude;
      if (!Number.isFinite(latitude) || !Number.isFinite(longitude) || Math.abs(latitude) > 90 || Math.abs(longitude) > 180) {
        throw new Error('选点未返回有效位置，请重新选择。');
      }
      const lastCenter: mapCommon.LatLng = { latitude, longitude };
      MerchantLocationPicker.lastCenter = lastCenter;
      const choice: MerchantChoice = { providerPoiId: result.siteId === undefined ? '' : result.siteId,
        name: result.name === undefined ? '' : result.name, address: result.address,
        latitudeE6: Math.round(latitude * 1000000), longitudeE6: Math.round(longitude * 1000000) };
      return choice;
    } catch (error) {
      if (cancelled) return undefined;
      if (error instanceof Error) throw error;
      throw new Error('地点选取不可用，可取消店铺关联后继续发布。');
    }
  }
}
