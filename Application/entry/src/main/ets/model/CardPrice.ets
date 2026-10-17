/**
 * 【文件职责】卡片价格的展示文本：按外卖单品价 / 到店人均 / 旧版价格字段依次取值并格式化为“¥xx”。
 */
import { FoodCard } from './CloudContracts';
import { formatFenInput } from './PublishingModels';

// 生成价格文本；没有价格时返回 missingText。
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

// 只看旧版 priceFen 字段的简短价格（私信 / 群聊卡片气泡、分享页使用）。
export function legacyPriceText(card: FoodCard): string {
  return card.priceFen > 0 ? `¥${(card.priceFen / 100).toFixed(2)}` : '价格待补充';
}
