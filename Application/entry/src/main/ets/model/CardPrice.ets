import { FoodCard } from './CloudContracts';
import { formatFenInput } from './PublishingModels';

export function cardPriceText(card: FoodCard, missingText: string = '价格待补充'): string {
  if (card.consumptionMode === 'DELIVERY') {
    return card.itemPriceFen === undefined ? missingText : '¥' + formatFenInput(card.itemPriceFen) + ' / 单品';
  }
  if (card.consumptionMode === 'DINE_IN') {
    return card.dineInAvgFen === undefined ? '人均待补充' : '¥' + formatFenInput(card.dineInAvgFen) + ' / 人均';
  }
  if (card.itemPriceFen !== undefined) return '¥' + formatFenInput(card.itemPriceFen) + ' / 历史单品';
  if (!Number.isFinite(card.priceFen) || card.priceFen <= 0) return missingText;
  return `¥${(card.priceFen / 100).toFixed(2)}`;
}
