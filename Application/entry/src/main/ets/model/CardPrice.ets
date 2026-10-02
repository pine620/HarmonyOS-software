import { FoodCard } from './CloudContracts';

export function cardPriceText(card: FoodCard, missingText: string = '价格待补充'): string {
  if (!Number.isFinite(card.priceFen) || card.priceFen <= 0) return missingText;
  return `¥${(card.priceFen / 100).toFixed(2)}`;
}
