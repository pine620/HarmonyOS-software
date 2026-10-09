import { FoodCard } from '../model/CloudContracts';
import { mapFoodCardToReviewCardViewData } from '../mapper/CloudCardViewMapper';
import { ReviewCard, ReviewCardViewData } from './review/ReviewDisplay';

@Component
export struct DiscoveryCard {
  @Require @Prop card: FoodCard;
  @Prop coverUrl: string = '';
  @Prop selected: boolean = false;
  @Prop featured: boolean = false;
  @Prop coverScale: number = 1;
  onCoverFailed: () => void = (): void => {};
  onRetry: () => void = (): void => {};
  onOpen: () => void = (): void => {};
  private merchantLabel(): string {
    const snapshot: string | undefined = this.card.merchantNameSnapshot;
    const name: string = snapshot === undefined || snapshot.length === 0 ? this.card.shop : snapshot;
    const mode: string = this.card.consumptionMode === 'DELIVERY' ? '外卖' : this.card.consumptionMode === 'DINE_IN' ? '到店' : '历史推荐';
    return (name.length > 0 ? name : '未关联店铺') + ' · ' + mode;
  }
  private reviewData(): ReviewCardViewData {
    const data: ReviewCardViewData = mapFoodCardToReviewCardViewData(this.card);
    data.coverUrl = this.coverUrl;
    data.coverLoading = this.coverUrl.length === 0 && this.card.primaryPhotoResolved !== true &&
      this.card.primaryPhotoLoadFailed !== true && this.card.photoPath.length > 0;
    data.coverFailed = this.coverUrl.length === 0 && this.card.primaryPhotoLoadFailed === true;
    data.shop = this.merchantLabel();
    if (this.card.visibility === 'FRIENDS') data.evidenceLabel = '好友可见';
    return data;
  }
  build() {
    Column({ space: 0 }) {
      ReviewCard({ data: this.reviewData(), featured: this.featured, coverScale: this.coverScale,
        onCoverFailed: this.onCoverFailed,
        onCoverDecoded: (cardId: string, _url: string): void => { console.info('[PhotoDisplay] cardId=' + cardId + ' sinceReadMs=' + (Date.now() - (this.card.photos?.[0]?.readAcceptedAt || Date.now()))); },
        onOpen: (_cardId: string): void => this.onOpen() })
      if (this.card.primaryPhotoLoadFailed === true && this.coverUrl.length === 0) {
        Button('重试实拍图').height(48).borderRadius(24).backgroundColor($r('app.color.accent_soft')).fontColor($r('app.color.action_text'))
          .margin({ left: 8, right: 8, top: 8 }).onClick((): void => this.onRetry())
      }
      if (this.card.visibility === 'FRIENDS') {
        Text('仅好友可见').fontSize(12).fontColor($r('app.color.accent_action')).width('100%')
          .padding({ left: 12, right: 12, bottom: 8 }).onClick((): void => this.onOpen())
      }
      if (this.card.recommendationReasons !== undefined && this.card.recommendationReasons.length > 0) {
        Text(this.card.recommendationReasons.join(' · ')).fontSize(12).lineHeight(18)
          .fontColor($r('app.color.muted')).maxLines(2).width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 12 }).onClick((): void => this.onOpen())
      }
    }.width('100%').backgroundColor($r('app.color.surface')).borderRadius(20)
      .border({ width: this.selected ? 2 : 0, color: $r('app.color.accent_action') })
  }
}
