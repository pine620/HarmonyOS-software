import agconnect from '@hw-agconnect/api-ohos';
import { AGConnectConfig, ConfigValue } from '@hw-agconnect/remoteconfig-ohos';
import '@hw-agconnect/remoteconfig-ohos';
import { DeliveryPlatform, DeliveryPlatformDocument } from '../model/MerchantModels';

const CONFIG_KEY: string = 'shike_delivery_platforms';
const DEFAULTS: Array<DeliveryPlatform> = [
  { key: 'MEITUAN', label: '美团', enabled: true, sortOrder: 10 },
  { key: 'ELEME', label: '饿了么', enabled: true, sortOrder: 20 },
  { key: 'JD', label: '京东外卖', enabled: true, sortOrder: 30 },
  { key: 'OTHER', label: '其他', enabled: true, sortOrder: 100 }
];

export class DeliveryPlatformConfigService {
  private static lastValid: Array<DeliveryPlatform> | undefined = undefined;
  static defaults(): Array<DeliveryPlatform> { return DEFAULTS.slice(); }

  private static merge(raw: string): Array<DeliveryPlatform> {
    if (raw.length === 0 || raw.length > 16384) throw new Error('平台配置长度无效。');
    const parsed: DeliveryPlatformDocument = JSON.parse(raw) as DeliveryPlatformDocument;
    if (parsed === null || parsed.version !== 1 || !Array.isArray(parsed.platforms) || parsed.platforms.length > 50) {
      throw new Error('平台配置版本无效。');
    }
    const merged: Array<DeliveryPlatform> = DeliveryPlatformConfigService.defaults();
    const seen: Array<string> = [];
    for (const value of parsed.platforms) {
      if (value === null || typeof value.key !== 'string' || !/^[A-Z0-9_]{1,40}$/.test(value.key) ||
        typeof value.label !== 'string' || value.label.trim().length === 0 || value.label.length > 40 ||
        typeof value.enabled !== 'boolean' || seen.includes(value.key)) throw new Error('平台配置无效。');
      seen.push(value.key);
      const order: number = typeof value.sortOrder === 'number' && Number.isFinite(value.sortOrder) ? value.sortOrder : 50;
      const platform: DeliveryPlatform = { key: value.key, label: value.label.trim(), enabled: value.enabled, sortOrder: order };
      const index: number = merged.findIndex((entry: DeliveryPlatform): boolean => entry.key === platform.key);
      if (index < 0) merged.push(platform); else merged[index] = platform;
    }
    return merged.sort((left: DeliveryPlatform, right: DeliveryPlatform): number => left.sortOrder - right.sortOrder || left.key.localeCompare(right.key));
  }

  static async load(): Promise<Array<DeliveryPlatform>> {
    let cached: Array<DeliveryPlatform> = DeliveryPlatformConfigService.lastValid === undefined
      ? DeliveryPlatformConfigService.defaults() : DeliveryPlatformConfigService.lastValid.slice();
    try {
      const config: AGConnectConfig = agconnect.remoteConfig();
      await config.initialized();
      const defaults: Map<string, string | number | boolean> = new Map<string, string | number | boolean>();
      const document: DeliveryPlatformDocument = { version: 1, platforms: DEFAULTS };
      defaults.set(CONFIG_KEY, JSON.stringify(document));
      await config.applyDefault(defaults);
      // A poisoned applied cache must not prevent the next fetch.
      try {
        cached = DeliveryPlatformConfigService.merge(config.getValueAsString(CONFIG_KEY));
        DeliveryPlatformConfigService.lastValid = cached.slice();
      } catch (_error) { }
      const fetched: ConfigValue = await config.fetch(43200);
      const next: Array<DeliveryPlatform> = fetched.containKey(CONFIG_KEY)
        ? DeliveryPlatformConfigService.merge(fetched.getValueAsString(CONFIG_KEY))
        : DeliveryPlatformConfigService.defaults();
      // Validate before activation; an invalid document never replaces valid data.
      await config.apply(fetched);
      DeliveryPlatformConfigService.lastValid = next.slice();
      return next;
    } catch (_error) { return cached; }
  }
}
