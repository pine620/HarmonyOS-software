import { EvidenceTone, ReviewCardViewData } from '../components/review/ReviewDisplay';
import { categoryLabel } from '../components/FoodCover';
import { FoodCard } from '../model/CloudContracts';
import { cardPriceText } from '../model/CardPrice';
import { tasteScoreText as formatTasteScore } from '../model/TasteScore';

function formatFen(priceFen: number): string {
  const safeFen = Number.isFinite(priceFen) ? Math.max(0, Math.round(priceFen)) : 0;
  const yuan = Math.floor(safeFen / 100);
  const fen = safeFen % 100;
  return `¥${yuan}.${fen < 10 ? `0${fen}` : `${fen}`}`;
}

function priceText(card: FoodCard): string {
  return cardPriceText(card);
}

function originalPriceText(card: FoodCard): string {
  if (card.originalPriceFen <= 0 || card.originalPriceFen <= card.priceFen) return '';
  return formatFen(card.originalPriceFen);
}

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

function reviewSummary(card: FoodCard): string {
  // Existing cards returned by an older deployed cloud function do not yet
  // contain reviewText. Treat that missing additive field as an empty note.
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

function tasteScoreText(card: FoodCard): string {
  const score = typeof card.tasteScore === 'number' ? card.tasteScore : 0;
  return formatTasteScore(score);
}

function timeLabel(timestamp: number): string {
  if (!Number.isFinite(timestamp) || timestamp <= 0) return '刚刚发布';
  const date = new Date(timestamp);
  return `${date.getMonth() + 1}月${date.getDate()}日`;
}

function locationLabel(card: FoodCard): string {
  const parts: Array<string> = [];
  if (card.district.trim().length > 0) parts.push(card.district.trim());
  if (Number.isFinite(card.distanceKm) && card.distanceKm > 0) parts.push(`${card.distanceKm.toFixed(1)} km`);
  return parts.join(' · ');
}

function evidenceTone(card: FoodCard): EvidenceTone {
  return card.status === 'APPROVED' ? 'verified' : 'pending';
}

function evidenceLabel(card: FoodCard): string {
  return card.status === 'APPROVED' ? '实拍公开' : '待公开';
}

export function mapFoodCardToReviewCardViewData(card: FoodCard): ReviewCardViewData {
  const productName = card.productName.trim().length > 0 ? card.productName.trim() : '未命名美食';
  return {
    id: card.id,
    productName,
    shop: card.shop.trim(),
    categoryLabel: categoryLabel(card.category),
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
    timeLabel: timeLabel(card.createdAt),
    locationLabel: locationLabel(card)
  };
}
