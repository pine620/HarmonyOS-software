/**
 * 【文件职责】分类兜底封面与分类名称：卡片没有可用图片时按分类显示内置图片（resources/base/media/food_*.png）。
 */
import { FoodCard, FoodCategory } from '../model/CloudContracts';
import { categoryV2Label } from '../model/PublishingModels';

// 旧分类对应的兜底封面资源。
export function coverFor(category: FoodCategory): Resource {
  if (category === 'staple') return $r('app.media.food_staple');
  if (category === 'bakery') return $r('app.media.food_bakery');
  if (category === 'drink') return $r('app.media.food_drink');
  if (category === 'snack') return $r('app.media.food_snack');
  if (category === 'fresh') return $r('app.media.food_fresh');
  return $r('app.media.food_other');
}

// 旧分类的中文名称。
export function categoryLabel(category: FoodCategory): string {
  if (category === 'staple') return '米饭';
  if (category === 'bakery') return '汤粉';
  if (category === 'drink') return '饮品';
  if (category === 'snack') return '炸鸡';
  if (category === 'fresh') return '烧烤';
  return '其他';
}

// 卡片的分类名称（优先新分类，没有时用旧分类）。
export function foodCardCategoryLabel(card: FoodCard): string {
  return card.categoryV2 === undefined ? categoryLabel(card.category) : categoryV2Label(card.categoryV2);
}
