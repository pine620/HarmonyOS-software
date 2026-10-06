import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { DiscoveryCamera } from '../model/DiscoveryModels';

export class MapViewportStore {
  static defaults(): DiscoveryCamera { return { latitude: 39.9, longitude: 116.4, zoom: 15 }; }
  static read(context: common.Context, uid: string): DiscoveryCamera {
    try {
      const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: 'shike_map_viewport' });
      const raw: preferences.ValueType = store.getSync(uid, '');
      if (typeof raw !== 'string' || raw.length === 0 || raw.length > 1024) return MapViewportStore.defaults();
      const value: DiscoveryCamera = JSON.parse(raw) as DiscoveryCamera;
      if (value !== null && Number.isFinite(value.latitude) && Math.abs(value.latitude) <= 85 &&
        Number.isFinite(value.longitude) && Math.abs(value.longitude) <= 180 && Number.isFinite(value.zoom) && value.zoom >= 10 && value.zoom <= 20) return value;
    } catch (_error) { }
    return MapViewportStore.defaults();
  }
  static save(context: common.Context, uid: string, camera: DiscoveryCamera): void {
    const store: preferences.Preferences = preferences.getPreferencesSync(context, { name: 'shike_map_viewport' });
    store.putSync(uid, JSON.stringify(camera)); store.flushSync();
  }
}
