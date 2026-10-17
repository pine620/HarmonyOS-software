/**
 * 【文件职责】外卖平台列表（发布页“外卖平台”选项）。从 AGC Remote Config 键 shike_delivery_platforms 读取
 * （格式：{ version: 1, platforms: [...] }），校验通过才启用；缺失、无效或请求失败时使用上一次的有效配置或内置默认值。
 */
import agconnect from '@hw-agconnect/api-ohos';
import { AGConnectConfig, ConfigValue } from '@hw-agconnect/remoteconfig-ohos';
import '@hw-agconnect/remoteconfig-ohos';
import { DeliveryPlatform, DeliveryPlatformDocument } from '../model/MerchantModels';

// Remote Config 键名与内置默认平台列表。
const CONFIG_KEY: string = 'shike_delivery_platforms';
const DEFAULTS: Array<DeliveryPlatform> = [
  { key: 'MEITUAN', label: '美团', enabled: true, sortOrder: 10 },
  { key: 'ELEME', label: '饿了么', enabled: true, sortOrder: 20 },
  { key: 'JD', label: '京东外卖', enabled: true, sortOrder: 30 },
  { key: 'OTHER', label: '其他', enabled: true, sortOrder: 100 }
];

// 外卖平台配置（静态类）。
export class DeliveryPlatformConfigService {
  // 上一次校验通过的配置（进程内缓存）。
  private static lastValid: Array<DeliveryPlatform> | undefined = undefined;
  // 内置默认平台列表的副本。
  static defaults(): Array<DeliveryPlatform> { return DEFAULTS.slice(); }

  // 解析并校验配置文档，与默认值合并；格式不合法时抛错。
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

  // 加载外卖平台列表：先应用已缓存的配置，再异步拉取最新配置；任何失败都返回可用的列表。
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
      // 即使已应用的缓存配置损坏，也不能阻止下一次拉取。
      try {
        cached = DeliveryPlatformConfigService.merge(config.getValueAsString(CONFIG_KEY));
        DeliveryPlatformConfigService.lastValid = cached.slice();
      } catch (_error) { }
      const fetched: ConfigValue = await config.fetch(43200);
      const next: Array<DeliveryPlatform> = fetched.containKey(CONFIG_KEY)
        ? DeliveryPlatformConfigService.merge(fetched.getValueAsString(CONFIG_KEY))
        : DeliveryPlatformConfigService.defaults();
      // 启用前先校验；无效的配置文档绝不替换有效数据。
      await config.apply(fetched);
      DeliveryPlatformConfigService.lastValid = next.slice();
      return next;
    } catch (_error) { return cached; }
  }
}
