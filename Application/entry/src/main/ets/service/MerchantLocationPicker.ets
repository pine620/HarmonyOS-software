import { common } from '@kit.AbilityKit';
import { mapCommon, sceneMap } from '@kit.MapKit';
import { Merchant, MerchantChoice } from '../model/MerchantModels';

export class MerchantLocationPicker {
  private static lastCenter: mapCommon.LatLng | undefined = undefined;
  static clearSelectionCenter(): void { MerchantLocationPicker.lastCenter = undefined; }
  static async choose(context: common.UIAbilityContext, selected?: Merchant): Promise<MerchantChoice | undefined> {
    // Explicit fixed center, never an omitted center that requests device location.
    // This is a browsing starting point, not a user's location or saved Merchant.
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
