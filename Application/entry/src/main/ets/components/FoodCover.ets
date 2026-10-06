import { FoodCard, FoodCategory } from '../model/CloudContracts';
import { categoryV2Label } from '../model/PublishingModels';

export function coverFor(category: FoodCategory): Resource {
  if (category === 'staple') return $r('app.media.food_staple');
  if (category === 'bakery') return $r('app.media.food_bakery');
  if (category === 'drink') return $r('app.media.food_drink');
  if (category === 'snack') return $r('app.media.food_snack');
  if (category === 'fresh') return $r('app.media.food_fresh');
  return $r('app.media.food_other');
}

export function categoryLabel(category: FoodCategory): string {
  if (category === 'staple') return '米饭';
  if (category === 'bakery') return '汤粉';
  if (category === 'drink') return '饮品';
  if (category === 'snack') return '炸鸡';
  if (category === 'fresh') return '烧烤';
  return '其他';
}

export function foodCardCategoryLabel(card: FoodCard): string {
  return card.categoryV2 === undefined ? categoryLabel(card.category) : categoryV2Label(card.categoryV2);
}
