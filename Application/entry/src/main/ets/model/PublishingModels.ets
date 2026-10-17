/**
 * 【文件职责】发布相关：11 个新分类及其中文名称、新旧分类互相转换、“元”输入与整数“分”的互转。
 */
import { FoodCategory, FoodCategoryV2 } from './CloudContracts';

// 分类选项。
export interface CategoryV2Option { key: FoodCategoryV2; label: string; }
export const CATEGORY_V2_OPTIONS: Array<CategoryV2Option> = [
  { key: 'NOODLES', label: '粉面' }, { key: 'RICE_SET', label: '米饭 / 套餐' },
  { key: 'HOT_POT', label: '火锅 / 麻辣烫' }, { key: 'GRILL_FRIED', label: '烧烤 / 炸物' },
  { key: 'SNACK', label: '小吃' }, { key: 'FAST_WESTERN', label: '快餐 / 西式' },
  { key: 'BREAKFAST_BAKERY', label: '早餐 / 烘焙' }, { key: 'DESSERT', label: '甜品' },
  { key: 'DRINK', label: '饮品' }, { key: 'PACKAGED', label: '零食 / 包装食品' }, { key: 'OTHER', label: '其他' }
];

// 分类中文名称。
export function categoryV2Label(key: string): string {
  for (const option of CATEGORY_V2_OPTIONS) if (option.key === key) return option.label;
  return '其他';
}

// 新分类 → 旧分类（旧版默认封面使用）。
export function legacyCategoryFor(key: FoodCategoryV2): FoodCategory {
  if (key === 'NOODLES') return 'bakery';
  if (key === 'RICE_SET') return 'staple';
  if (key === 'DRINK') return 'drink';
  if (key === 'GRILL_FRIED') return 'fresh';
  if (key === 'SNACK') return 'snack';
  return 'other';
}

// 旧分类 → 新分类。
export function categoryV2FromLegacy(key: FoodCategory): FoodCategoryV2 {
  if (key === 'staple') return 'RICE_SET';
  if (key === 'bakery') return 'NOODLES';
  if (key === 'drink') return 'DRINK';
  if (key === 'snack' || key === 'fresh') return 'GRILL_FRIED';
  return 'OTHER';
}

// “元”字符串 → 整数分：留空表示未知（返回 null），0 表示明确为 0；按字符串解析，不做浮点乘法，避免精度误差。
export function parseYuanInputToFen(value: string): number | null {
  const input: string = value.trim();
  if (input.length === 0) return null;
  if (!/^\d{1,7}(\.\d{1,2})?$/.test(input)) throw new Error('金额需为非负数字，最多两位小数。');
  const parts: Array<string> = input.split('.');
  const fraction: string = parts.length === 2 ? (parts[1] + '00').slice(0, 2) : '00';
  const fen: number = Number(parts[0]) * 100 + Number(fraction);
  if (!Number.isSafeInteger(fen) || fen > 100000000) throw new Error('金额不能超过 1000000 元。');
  return fen;
}

// 整数分 → 输入框显示的元字符串。
export function formatFenInput(fen: number | null | undefined): string {
  if (fen === undefined || fen === null) return '';
  return Math.floor(fen / 100).toString() + '.' + (fen % 100).toString().padStart(2, '0');
}
