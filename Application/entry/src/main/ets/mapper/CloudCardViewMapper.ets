/**
 * 【文件职责】把云端返回的 FoodCard 转换成卡片展示组件 ReviewCard 需要的视图数据（价格、时间、评分、标签等文案）。
 */
import { EvidenceTone, ReviewCardViewData } from '../components/review/ReviewDisplay';
import { foodCardCategoryLabel } from '../components/FoodCover';
import { FoodCard } from '../model/CloudContracts';
import { cardPriceText } from '../model/CardPrice';
import { tasteScoreText as formatTasteScore } from '../model/TasteScore';

// 分转为“¥x.xx”文本。
function formatFen(priceFen: number): string {
  const safeFen = Number.isFinite(priceFen) ? Math.max(0, Math.round(priceFen)) : 0;
  const yuan = Math.floor(safeFen / 100);
  const fen = safeFen % 100;
  return `¥${yuan}.${fen < 10 ? `0${fen}` : `${fen}`}`;
}

// 主价格文本。
function priceText(card: FoodCard): string {
  return cardPriceText(card);
}

// 原价文本（有划线价时）。
function originalPriceText(card: FoodCard): string {
  if (card.originalPriceFen <= 0 || card.originalPriceFen <= card.priceFen) return '';
  return formatFen(card.originalPriceFen);
}

// 卡片上展示的标签（分类、消费方式等）。
function displayTags(card: FoodCard): Array<string> {
  const tags: Array<string> = [];
  const seen: Set<string> = new Set<string>();
  const append = (value: string): void => {
    const normalized = value.trim();
    if (normalized.length > 0 && !seen.has(normalized) && tags.length < 3) {
      tags.push(normalized);
      seen.add(normalized);
    }
  };
  append(card.brand);
  card.publicOffers.forEach((offer: string): void => append(offer));
  append(card.specification);
  return tags;
}

// 点评摘要。
function reviewSummary(card: FoodCard): string {
  // 旧版云函数返回的卡片可能还没有 reviewText 字段，缺失时按空点评处理。
  const reviewText = typeof card.reviewText === 'string' ? card.reviewText.trim() : '';
  if (reviewText.length > 0) return reviewText;
  const points: Array<string> = [];
  card.sellingPoints.forEach((point: string): void => {
    const normalized = point.trim();
    if (normalized.length > 0 && points.length < 2) points.push(normalized);
  });
  if (points.length > 0) return points.join('；');
  return card.specification.trim().length > 0 ? card.specification.trim() : '发布者暂未补充推荐理由。';
}

// 评分文本。
function tasteScoreText(card: FoodCard): string {
  const score = typeof card.tasteScore === 'number' ? card.tasteScore : 0;
  return formatTasteScore(score);
}

// 发布日期“x月x日”；时间无效时显示“刚刚发布”。
function timeLabel(timestamp: number): string {
  if (!Number.isFinite(timestamp) || timestamp <= 0) return '刚刚发布';
  const date = new Date(timestamp);
  return `${date.getMonth() + 1}月${date.getDate()}日`;
}

// 位置描述（店铺名或历史发布位置）。
function locationLabel(card: FoodCard): string {
  if (card.merchantNameSnapshot !== undefined && card.merchantNameSnapshot.length > 0) return card.merchantNameSnapshot;
  if (card.consumptionMode === 'DELIVERY' || card.consumptionMode === 'DINE_IN') return '店铺未关联';
  const parts: Array<string> = [];
  if (card.district.trim().length > 0) parts.push(card.district.trim());
  if (Number.isFinite(card.distanceKm) && card.distanceKm > 0) parts.push(`${card.distanceKm.toFixed(1)} km`);
  return parts.join(' · ');
}

// 证据徽标的样式。
function evidenceTone(card: FoodCard): EvidenceTone {
  return card.status === 'APPROVED' ? 'verified' : 'pending';
}

// 证据徽标文字：已公开的卡片显示“实拍公开”，否则“待公开”。
function evidenceLabel(card: FoodCard): string {
  return card.status === 'APPROVED' ? '实拍公开' : '待公开';
}

// 转换入口。
export function mapFoodCardToReviewCardViewData(card: FoodCard): ReviewCardViewData {
  const productName = card.productName.trim().length > 0 ? card.productName.trim() : '未命名美食';
  return {
    id: card.id,
    productName,
    shop: card.shop.trim(),
    categoryLabel: foodCardCategoryLabel(card),
    coverUrl: card.photoUrl,
    coverLoading: card.photoPath.length > 0 && card.photoUrl.length === 0 && card.primaryPhotoResolved !== true,
    coverFailed: card.photoUrl.length === 0 && card.primaryPhotoLoadFailed === true,
    photoAlt: `${productName}的发布者实拍图`,
    priceText: priceText(card),
    originalPriceText: originalPriceText(card),
    reviewSummary: reviewSummary(card),
    tasteScoreText: tasteScoreText(card),
    tags: displayTags(card),
    evidenceLabel: evidenceLabel(card),
    evidenceTone: evidenceTone(card),
    authorName: card.authorNickname === undefined ? '' : card.authorNickname.trim(),
    timeLabel: timeLabel(card.publishedAt === undefined ? card.createdAt : card.publishedAt),
    locationLabel: locationLabel(card)
  };
}
