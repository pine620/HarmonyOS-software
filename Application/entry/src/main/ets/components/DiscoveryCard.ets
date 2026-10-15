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
  @Prop marketStyle: boolean = false;
  @Prop motionEnabled: boolean = true;
  onCoverFailed: () => void = (): void => {};
  onCoverDecoded: (id: string, url: string) => void = (_id: string, _url: string): void => {};
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
    return data;
  }
  build() {
    Column({ space: 0 }) {
      ReviewCard({ data: this.reviewData(), featured: this.featured, coverScale: this.coverScale,
        marketStyle: this.marketStyle, motionEnabled: this.motionEnabled,
        onCoverFailed: this.onCoverFailed,
        onCoverDecoded: (cardId: string, url: string): void => {
          console.info('[PhotoDisplay] cardId=' + cardId + ' sinceReadMs=' + (Date.now() - (this.card.photos?.[0]?.readAcceptedAt || Date.now())));
          this.onCoverDecoded(cardId, url);
        },
        onOpen: (_cardId: string): void => this.onOpen() })
      if (this.card.primaryPhotoLoadFailed === true && this.coverUrl.length === 0) {
        Button('重试实拍图').height(48).borderRadius(this.marketStyle ? 16 : 24)
          .backgroundColor(this.marketStyle ? $r('app.color.discovery_soft') : $r('app.color.accent_soft'))
          .fontColor(this.marketStyle ? $r('app.color.discovery_accent') : $r('app.color.action_text'))
          .margin({ left: 8, right: 8, top: 8 }).onClick((): void => this.onRetry())
      }
    }.width('100%').backgroundColor(this.marketStyle ? $r('app.color.discovery_surface') : $r('app.color.surface')).borderRadius(this.marketStyle ? 16 : 20)
      .border({ width: this.selected ? 2 : 0, color: this.marketStyle ? $r('app.color.discovery_accent') : $r('app.color.accent_action') })
  }
}
